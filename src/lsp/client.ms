import { jsonValueToStructE } from "std/serialize/json";
import { Framer, framed } from "./rpc";

export const METHOD_NOT_FOUND: int32 = -32601;
export const REQUEST_CANCELLED: int32 = -32800;
export const CONTENT_MODIFIED: int32 = -32801;
export const NO_ERROR: int32 = 0;

export struct Reply {
	result: JsonValue;
	code: int32;
	message: string;
}

export function failed(this r: Reply): boolean { return r.code != NO_ERROR; }

export type ReplyHandler = (reply: Reply) => void;
export type NotificationHandler = (params: JsonValue) => void;
export type RequestHandler = (params: JsonValue) => string;

export function decoded<T>(v: JsonValue): Result<T, string> {
	if (v == null || v.kind != JsonKind.Object) {
		return Result.err(`expected an object, got ${v == null ? "null" : kindName(v.kind)}`);
	}
	const errs: string[] = [];
	const value: T = jsonValueToStructE(v, null as T | null, errs, "");
	if (errs.length > 0) { return Result.err(joinDecodeErrors(errs)); }
	return Result.ok(value);
}

export function quoted(text: string): string {
	return stringify(jsonString(text));
}

export class Client {
	private framer: Framer = new Framer();
	private nextId: int32 = 1;
	private waiting: Map<int32, ReplyHandler> = new Map();
	private notified: Map<string, NotificationHandler> = new Map();
	private answered: Map<string, RequestHandler> = new Map();
	private write: (bytes: string) => void;
	private complain: (message: string) => void;

	constructor(write: (bytes: string) => void, complain: (message: string) => void) {
		this.write = write;
		this.complain = complain;
	}

	request(method: string, params: string, done: ReplyHandler): int32 {
		const id = this.nextId;
		this.nextId += 1;
		this.waiting.set(id, done);
		this.write(framed(`{"jsonrpc":"2.0","id":${id},"method":${quoted(method)},"params":${params}}`));
		return id;
	}

	notify(method: string, params: string): void {
		this.write(framed(`{"jsonrpc":"2.0","method":${quoted(method)},"params":${params}}`));
	}

	cancel(id: int32): void {
		if (!this.waiting.has(id)) { return; }
		this.waiting.delete(id);
		this.notify("$/cancelRequest", `{"id":${id}}`);
	}

	pending(): int32 { return this.waiting.size as int32; }

	on(method: string, handler: NotificationHandler): void { this.notified.set(method, handler); }

	answer(method: string, handler: RequestHandler): void { this.answered.set(method, handler); }

	receive(chunk: string): void {
		const bodies = this.framer.feed(chunk);
		if (!bodies.ok) {
			this.complain(bodies.error);
			return;
		}
		for (const body of bodies.value) { this.dispatch(body); }
	}

	private dispatch(body: string): void {
		const parsed = JSON.parseValue(body);
		if (!parsed.ok) {
			this.complain(`a message is not JSON (${parsed.error}): ${body.byteSlice(0, Math.min(body.byteLength, 200))}`);
			return;
		}
		const message = parsed.value;
		const method = message.getDynamicField("method").asString();
		const id = message.getDynamicField("id");
		if (method.byteLength > 0) {
			const params = message.getDynamicField("params");
			if (id.kind == JsonKind.Null) {
				const handler = this.notified.get(method);
				if (handler != null) { handler(params); }
				return;
			}
			const handler = this.answered.get(method);
			const reply = handler == null ?
				`"error":{"code":${METHOD_NOT_FOUND},"message":${quoted(`Unrecognized method \`${method}\``)}}`
				: `"result":${handler(params)}`;
			this.write(framed(`{"jsonrpc":"2.0","id":${stringify(id)},${reply}}`));
			return;
		}
		const key = id.asInt32(-1);
		const done = this.waiting.get(key);
		if (done == null) { return; }
		this.waiting.delete(key);
		const error = message.getDynamicField("error");
		const code = error.getDynamicField("code").asInt32(NO_ERROR);
		if (code != NO_ERROR) {
			done({ result: jsonNull(), code, message: error.getDynamicField("message").asString() });
			return;
		}
		done({ result: message.getDynamicField("result"), code: NO_ERROR, message: "" });
	}
}

when (testBuild) {
	struct Wire {
		sent: string[];
		complaints: string[];
	}

	function wired(): [Client, Wire] {
		const wire: Wire = { sent: [], complaints: [] };
		const client = new Client(
			(bytes: string): void => { wire.sent.push(bytes); },
			(message: string): void => { wire.complaints.push(message); },
		);
		return [client, wire];
	}

	struct Point2 {
		line: int32;
		character: int32;
	}

	test "a reply reaches the handler of the request with its id, once" {
		const [client, wire] = wired();
		let got = -1;
		let calls = 0;
		const first = client.request("textDocument/hover", "{}", (r: Reply): void => {
			calls += 1;
			got = r.result.getDynamicField("line").asInt32();
		});
		const second = client.request("shutdown", "null", (r: Reply): void => { calls += 10; });
		assert first == 1 && second == 2 && client.pending() == 2;
		assert wire.sent[0] == framed("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"textDocument/hover\",\"params\":{}}");
		const reply = framed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"line\":4,\"character\":2}}");
		client.receive(reply);
		client.receive(reply);
		assert got == 4 && calls == 1 && client.pending() == 1;
	}

	test "an error reply carries its code and message" {
		const [client, _wire] = wired();
		let code = 0;
		let message = "";
		const _id = client.request("x", "{}", (r: Reply): void => {
			code = r.code;
			message = r.message;
		});
		client.receive(framed("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32801,\"message\":\"modified\"}}"));
		assert code == CONTENT_MODIFIED && message == "modified";
	}

	test "a cancelled request tells the server and drops its handler" {
		const [client, wire] = wired();
		let calls = 0;
		const id = client.request("x", "{}", (r: Reply): void => { calls += 1; });
		client.cancel(id);
		client.receive(framed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}"));
		assert calls == 0 && client.pending() == 0;
		assert wire.sent[1].includes("\"method\":\"$/cancelRequest\",\"params\":{\"id\":1}");
	}

	test "notifications reach their handler and server requests get an answer or method-not-found" {
		const [client, wire] = wired();
		let message = "";
		client.on("window/showMessage", (params: JsonValue): void => {
			message = params.getDynamicField("message").asString();
		});
		client.answer("workspace/configuration", (params: JsonValue): string => { return "[null]"; });
		client.receive(framed("{\"jsonrpc\":\"2.0\",\"method\":\"window/showMessage\",\"params\":{\"type\":3,\"message\":\"hi\"}}"));
		client.receive(framed("{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"method\":\"workspace/configuration\",\"params\":{}}"));
		client.receive(framed("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"window/workDoneProgress/create\",\"params\":{}}"));
		client.receive(framed("{\"jsonrpc\":\"2.0\",\"method\":\"$/progress\",\"params\":{}}"));
		assert message == "hi";
		assert wire.sent[0] == framed("{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"result\":[null]}");
		assert wire.sent[1].includes("\"id\":7,\"error\":{\"code\":-32601,");
		assert wire.sent.length == 2 && wire.complaints.length == 0;
	}

	test "a body that is not JSON is reported, and the stream goes on" {
		const [client, wire] = wired();
		let calls = 0;
		const _id = client.request("x", "{}", (r: Reply): void => { calls += 1; });
		client.receive(framed("{oops") + framed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":3}"));
		assert wire.complaints.length == 1 && calls == 1;
	}

	test "a result decodes into a struct" {
		const parsed = JSON.parseValue("{\"line\":3,\"character\":9}");
		assert parsed.ok;
		if (parsed.ok) {
			const p = decoded<Point2>(parsed.value);
			assert p.ok;
			if (p.ok) { assert p.value.line == 3 && p.value.character == 9; }
		}
		assert !decoded<Point2>(jsonNull()).ok;
	}
}
