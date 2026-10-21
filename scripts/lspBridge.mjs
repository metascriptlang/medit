// Carries a language server's stdio over a WebSocket, so the web build can use the same
// servers as the desktop. Each connection starts its own server; bytes pass through unchanged
// in both directions (the Content-Length framing travels inside the frames).
//
//   node scripts/lspBridge.mjs [port] [--trace] [-- command args...]
//
// The port defaults to 8766 and the command to `msc lsp`. It listens on 127.0.0.1 only, and
// refuses a page served from another host, since a WebSocket is not held to the page's origin.
// --trace prints the start of every chunk that passes, page to server as ">", back as "<".
import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const dash = process.argv.indexOf("--");
const options = dash >= 0 ? process.argv.slice(2, dash) : process.argv.slice(2);
const trace = options.includes("--trace");
const port = Number(options.find((o) => /^\d+$/.test(o)) ?? 8766);
const command = dash >= 0 ? process.argv.slice(dash + 1) : ["msc", "lsp"];
const TRACE_BYTES = 300;
const LOOPBACK = new Set(["127.0.0.1", "localhost", "[::1]"]);

function fromThisMachine(origin) {
	if (origin === undefined) return true;
	try { return LOOPBACK.has(new URL(origin).hostname); } catch { return false; }
}

function traced(way, chunk) {
	if (trace) console.log(`${way} ${chunk.subarray(0, TRACE_BYTES).toString().replace(/\r\n/g, " ")}`);
}

function frame(opcode, payload) {
	const n = payload.length;
	const head = n < 126 ? Buffer.from([0x80 | opcode, n])
		: n < 65536 ? Buffer.from([0x80 | opcode, 126, n >> 8, n & 255])
		: Buffer.concat([Buffer.from([0x80 | opcode, 127]), (() => {
			const b = Buffer.alloc(8);
			b.writeBigUInt64BE(BigInt(n));
			return b;
		})()]);
	return Buffer.concat([head, payload]);
}

function connect(socket) {
	const child = process.platform === "win32"
		? spawn(command.join(" "), { stdio: ["pipe", "pipe", "inherit"], shell: true })
		: spawn(command[0], command.slice(1), { stdio: ["pipe", "pipe", "inherit"] });
	console.log(`bridge: started ${command.join(" ")} (pid ${child.pid})`);
	let held = Buffer.alloc(0);
	let message = [];
	let open = true;
	const end = (why) => {
		if (!open) return;
		open = false;
		console.log(`bridge: ${why}`);
		try { socket.end(frame(8, Buffer.alloc(0))); } catch {}
		child.stdin.end();
		setTimeout(() => child.kill(), 2000).unref();
	};
	child.stdout.on("data", (chunk) => {
		traced("<", chunk);
		if (open) socket.write(frame(2, chunk));
	});
	child.on("exit", (code) => end(`server exited with ${code}`));
	child.on("error", (e) => end(`server failed: ${e.message}`));
	socket.on("close", () => end("page closed the socket"));
	socket.on("error", () => end("socket error"));
	socket.on("data", (chunk) => {
		held = Buffer.concat([held, chunk]);
		while (held.length >= 2) {
			const fin = (held[0] & 0x80) !== 0;
			const opcode = held[0] & 0x0f;
			let length = held[1] & 0x7f;
			let at = 2;
			if (length === 126) {
				if (held.length < 4) return;
				length = held.readUInt16BE(2);
				at = 4;
			} else if (length === 127) {
				if (held.length < 10) return;
				length = Number(held.readBigUInt64BE(2));
				at = 10;
			}
			const masked = (held[1] & 0x80) !== 0;
			const maskAt = at;
			if (masked) at += 4;
			if (held.length < at + length) return;
			const payload = Buffer.from(held.subarray(at, at + length));
			if (masked) {
				for (let i = 0; i < payload.length; i++) payload[i] ^= held[maskAt + (i & 3)];
			}
			held = held.subarray(at + length);
			if (opcode === 8) return end("page closed the socket");
			if (opcode === 9) {
				socket.write(frame(10, payload));
				continue;
			}
			if (opcode === 10) continue;
			message.push(payload);
			if (fin) {
				traced(">", Buffer.concat(message));
				child.stdin.write(Buffer.concat(message));
				message = [];
			}
		}
	});
}

const server = createServer((req, res) => {
	res.writeHead(426, { "Content-Type": "text/plain" });
	res.end("medic lsp bridge: connect with a WebSocket\n");
});
server.on("upgrade", (req, socket) => {
	const key = req.headers["sec-websocket-key"];
	if (!key) return socket.destroy();
	if (!fromThisMachine(req.headers.origin)) {
		console.log(`bridge: refused a page from ${req.headers.origin}`);
		return socket.end("HTTP/1.1 403 Forbidden\r\n\r\n");
	}
	const accept = createHash("sha1").update(key + GUID).digest("base64");
	socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
		+ `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);
	socket.setNoDelay(true);
	connect(socket);
});
server.listen(port, "127.0.0.1", () => console.log(`bridge: ws://127.0.0.1:${port} runs ${command.join(" ")}`));
