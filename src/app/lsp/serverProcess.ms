@include("./serverProcess.h");
when (windows) {
	@compile("./serverProcess.c");
} else {
	@compile("./serverProcessPosix.c");
}

extern function serverOpen(commandLine: cstring, cwd: cstring): int32;
extern function serverTake(id: int32): string;
extern function serverWrite(id: int32, data: Readonly<Span<uint8>>): int64;
extern function serverEnded(id: int32): int32;
extern function serverExitCode(id: int32): int32;
extern function serverClose(id: int32): void;
extern function serverParentId(): int32;

export struct ServerProcess {
	id: int32;
}

export function start(this typeof ServerProcess, commandLine: string, cwd: string): ServerProcess | null {
	const id = serverOpen(commandLine, cwd);
	return id < 0 ? null : { id };
}

export function take(this p: ServerProcess): string { return serverTake(p.id); }

export function send(this p: ServerProcess, bytes: string): boolean {
	return serverWrite(p.id, bytes.asBytes()) >= 0;
}

export function ended(this p: ServerProcess): boolean { return serverEnded(p.id) != 0; }

export function exitCode(this p: ServerProcess): int32 | null {
	const code = serverExitCode(p.id);
	return code < 0 ? null : code;
}

export function stop(this p: ServerProcess): void { serverClose(p.id); }

export function ownProcessId(): int32 { return serverParentId(); }

when (testBuild) {
	import { Client, Reply } from "../../lsp/client";

	test "msc lsp answers initialize through the pipes" {
		const started = ServerProcess.start("msc lsp", "");
		assert started !== null;
		if (started !== null) {
			const server = started;
			const client = new Client(
				(bytes: string): void => { const _sent = server.send(bytes); },
				(message: string): void => { console.log(`complaint: ${message}`); },
			);
			let sync = -1;
			const _id = client.request("initialize", "{\"processId\":null,\"rootUri\":null,\"capabilities\":{}}", (r: Reply): void => {
				sync = r.result.getDynamicField("capabilities").getDynamicField("textDocumentSync").asInt32(-2);
			});
			const deadline = performance.now() + 30000;
			while (sync == -1 && performance.now() < deadline && !server.ended()) {
				client.receive(server.take());
			}
			assert sync == 1;
			const _down = client.request("shutdown", "null", (r: Reply): void => { client.notify("exit", "null"); });
			const until = performance.now() + 10000;
			while (!server.ended() && performance.now() < until) { client.receive(server.take()); }
			assert server.ended();
			let code = server.exitCode();
			while (code === null && performance.now() < until) { code = server.exitCode(); }
			assert code === 0;
			server.stop();
		}
	}

	test "a command that cannot start is null" {
		assert ServerProcess.start("no-such-server-medic", "") === null;
	}

	when (!windows) {
		test "a quoted argument reaches the program as one word" {
			const started = ServerProcess.start("/bin/sh -c \"exit 3\"", "");
			assert started !== null;
			if (started !== null) {
				const until = performance.now() + 5000;
				let code = started.exitCode();
				while (code === null && performance.now() < until) { code = started.exitCode(); }
				assert code === 3;
				started.stop();
			}
		}
	}
}
