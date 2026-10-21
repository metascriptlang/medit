const LENGTH_HEADER = "content-length:";
const HEADER_END = "\r\n\r\n";
const NO_LENGTH: int32 = -1;

export function framed(body: string): string {
	return `Content-Length: ${body.byteLength}${HEADER_END}${body}`;
}

function lengthIn(headers: string): int32 {
	for (const line of headers.split("\r\n")) {
		const lower = line.toLowerCase();
		if (lower.startsWith(LENGTH_HEADER)) {
			const digits = line.byteSlice(LENGTH_HEADER.byteLength, line.byteLength).trim();
			let n = 0;
			if (digits.byteLength == 0) { return NO_LENGTH; }
			for (let k = 0; k < digits.byteLength; k++) {
				const d = digits.byteAt(k) - "0".code;
				if (d < 0 || d > 9) { return NO_LENGTH; }
				n = n * 10 + d;
			}
			return n;
		}
	}
	return NO_LENGTH;
}

export class Framer {
	private held: string = "";
	private pieces: string[] = [];
	private piecesLength: int32 = 0;
	private needed: int32 = 0;

	feed(chunk: string): Result<string[], string> {
		this.pieces.push(chunk);
		this.piecesLength += chunk.byteLength;
		const bodies: string[] = [];
		if (this.held.byteLength + this.piecesLength < this.needed) { return Result.ok(bodies); }
		this.held = this.held + this.pieces.join("");
		this.pieces = [];
		this.piecesLength = 0;
		this.needed = 0;
		let from = 0;
		while (true) {
			const end = this.held.byteIndexOf(HEADER_END, from);
			if (end < 0) { break; }
			const headers = this.held.byteSlice(from, end);
			const length = lengthIn(headers);
			if (length == NO_LENGTH) {
				this.held = "";
				return Result.err(`a message header has no Content-Length: ${headers}`);
			}
			const start = end + HEADER_END.byteLength;
			if (start + length > this.held.byteLength) {
				this.needed = start + length - from;
				break;
			}
			bodies.push(this.held.byteSlice(start, start + length));
			from = start + length;
		}
		this.held = this.held.byteSlice(from, this.held.byteLength);
		return Result.ok(bodies);
	}
}

test "a framed body comes back whole however its bytes arrive" {
	const body = "{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"params\":\"héllo\"}";
	const wire = framed(body) + framed("{}");
	assert wire.startsWith(`Content-Length: ${body.byteLength}\r\n\r\n`);
	for (const step of [1, 3, 7, wire.byteLength]) {
		const f = new Framer();
		const got: string[] = [];
		for (let k = 0; k < wire.byteLength; k += step) {
			const r = f.feed(wire.byteSlice(k, Math.min(k + step, wire.byteLength)));
			assert r.ok;
			if (r.ok) { for (const b of r.value) { got.push(b); } }
		}
		assert got.length == 2 && got[0] == body && got[1] == "{}";
	}
}

test "other headers ride beside the length in any case, and a missing length is an error" {
	const f = new Framer();
	const r = f.feed("Content-Type: application/vscode-jsonrpc\r\ncontent-length: 2\r\n\r\n{}");
	assert r.ok;
	if (r.ok) { assert r.value.length == 1 && r.value[0] == "{}"; }
	assert !new Framer().feed("Content-Type: x\r\n\r\n{}").ok;
}
