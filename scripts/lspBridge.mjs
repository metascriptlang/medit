// Carries a language server's stdio over a WebSocket, so the web build can use the same
// servers as the desktop. Each connection starts its own server; bytes pass through unchanged
// in both directions (the Content-Length framing travels inside the frames).
//
//   node scripts/lspBridge.mjs [port] [--trace] [--root <dir>] [-- command args...]
//
// The port defaults to 8766 and the command to `msc lsp`. It listens on 127.0.0.1 only, and
// refuses a page served from another host, since a WebSocket is not held to the page's origin.
// --trace prints the start of every chunk that passes, page to server as ">", back as "<".
// --root starts the server in <dir> and lets the page list (GET /files: git's tracked and
// untracked files, else a walk), read and save (GET/PUT /file?path=) the files under it, and
// search them (GET /search?q=&case=1&word=1).
import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { execFileSync, spawn } from "node:child_process";
import { readdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const dash = process.argv.indexOf("--");
const options = dash >= 0 ? process.argv.slice(2, dash) : process.argv.slice(2);
const trace = options.includes("--trace");
const rootAt = options.indexOf("--root");
const root = rootAt >= 0 ? realpathSync(resolve(options[rootAt + 1])) : null;
const port = Number(options.find((o, i) => /^\d+$/.test(o) && (rootAt < 0 || i !== rootAt + 1)) ?? 8766);
const command = dash >= 0 ? process.argv.slice(dash + 1) : ["msc", "lsp"];
const TRACE_BYTES = 300;
const LOOPBACK = new Set(["127.0.0.1", "localhost", "[::1]"]);
const FILES_LIMIT = 200000;
const SKIPPED = new Set([".git", "node_modules", "out", "target"]);

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
		? spawn(command.join(" "), { stdio: ["pipe", "pipe", "inherit"], shell: true, cwd: root ?? undefined })
		: spawn(command[0], command.slice(1), { stdio: ["pipe", "pipe", "inherit"], cwd: root ?? undefined });
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

function underRoot(relative) {
	if (relative === null) return null;
	try {
		const path = realpathSync(resolve(root, relative));
		return path.startsWith(root + sep) ? path : null;
	} catch {
		return null;
	}
}

function answer(res, status, headers, body) {
	res.writeHead(status, { "Content-Type": "text/plain; charset=utf-8", ...headers });
	res.end(body);
}

function corsFor(req, res) {
	const origin = req.headers.origin;
	if (!fromThisMachine(origin)) {
		answer(res, 403, {}, `refused a page from ${origin}\n`);
		return null;
	}
	return origin === undefined ? {} : { "Access-Control-Allow-Origin": origin };
}

function walked(dir, prefix, files) {
	for (const entry of readdirSync(dir, { withFileTypes: true })) {
		if (files.length >= FILES_LIMIT) return files;
		const path = prefix + entry.name;
		if (!entry.isDirectory()) files.push(path);
		else if (!SKIPPED.has(entry.name)) walked(resolve(dir, entry.name), `${path}/`, files);
	}
	return files;
}

function projectFiles() {
	try {
		const listed = execFileSync("git", ["ls-files", "-co", "--exclude-standard", "-z"],
			{ cwd: root, maxBuffer: 1 << 30, stdio: ["ignore", "pipe", "ignore"] });
		return listed.toString("utf8").split("\0").filter((p) => p.length > 0).slice(0, FILES_LIMIT);
	} catch {
		return walked(root, "", []).sort();
	}
}

function serveList(req, res) {
	const cors = corsFor(req, res);
	if (cors === null) return;
	if (root === null) return answer(res, 404, cors, "the bridge lists no files: start it with --root <dir>\n");
	if (req.method !== "GET") return answer(res, 405, cors, `no ${req.method} on the file list\n`);
	answer(res, 200, { ...cors, "Content-Type": "application/json; charset=utf-8" }, JSON.stringify({ rootUri: pathToFileURL(root).href, files: projectFiles() }));
}

// Keep matching, cutting and limits in step with src/model/projectSearch.ms: the page merges
// these hits with its own searches of open files.
const MAX_RESULT_FILES = 5000;
const MAX_RESULT_HITS = 10000;
const HIT_TEXT_BYTES = 240;
const HIT_LEAD_BYTES = 40;
const BINARY_PROBE_BYTES = 8000;
const BOM = Buffer.from([0xef, 0xbb, 0xbf]);

const isTrail = (b) => (b & 0xc0) === 0x80;
const isWordByte = (b) => b === 0x5f || (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || b >= 0x80;
const folded = (bytes) => bytes.map((b) => (b >= 0x41 && b <= 0x5a ? b + 0x20 : b));

function documentBytes(raw) {
	const body = raw.subarray(0, 3).equals(BOM) ? raw.subarray(3) : raw;
	return body.includes(0x0d) ? Buffer.from(body.toString("latin1").replaceAll("\r\n", "\n"), "latin1") : body;
}

function hitOn(lineNumber, line, from, to) {
	const startOf = (at) => {
		while (at > 0 && isTrail(line[at])) at -= 1;
		return at;
	};
	let indent = 0;
	while (indent < line.length && (line[indent] === 0x20 || line[indent] === 0x09)) indent += 1;
	let textFrom = Math.min(indent, from);
	if (to - textFrom > HIT_TEXT_BYTES) textFrom = startOf(Math.max(textFrom, from - HIT_LEAD_BYTES));
	const textTo = startOf(Math.min(line.length, textFrom + HIT_TEXT_BYTES));
	return { line: lineNumber, from, to, text: line.toString("utf8", textFrom, textTo), textFrom };
}

function hitsIn(bytes, needle, fold, wholeWord, room) {
	const haystack = fold ? folded(bytes) : bytes;
	const word = (at) => at >= 0 && at < bytes.length && isWordByte(bytes[at]);
	const n = needle.length;
	const hits = [];
	let lineNumber = 0;
	let lineStart = 0;
	let at = haystack.indexOf(needle);
	while (at >= 0) {
		if (wholeWord && ((word(at) && word(at - 1)) || (word(at + n - 1) && word(at + n)))) {
			at = haystack.indexOf(needle, at + 1);
			continue;
		}
		if (hits.length === room) return [hits, true];
		for (let k = bytes.indexOf(0x0a, lineStart); k >= 0 && k < at; k = bytes.indexOf(0x0a, lineStart)) {
			lineNumber += 1;
			lineStart = k + 1;
		}
		let lineEnd = bytes.indexOf(0x0a, lineStart);
		if (lineEnd < 0) lineEnd = bytes.length;
		hits.push(hitOn(lineNumber, bytes.subarray(lineStart, lineEnd), at - lineStart, Math.min(lineEnd, at + n) - lineStart));
		at = haystack.indexOf(needle, at + n);
	}
	return [hits, false];
}

function searched(text, caseSensitive, wholeWord) {
	const typed = Buffer.from(text, "utf8");
	const needle = caseSensitive ? typed : folded(typed);
	const files = [];
	let matches = 0;
	for (const key of projectFiles()) {
		if (files.length === MAX_RESULT_FILES || matches === MAX_RESULT_HITS) return { files, matches, limitReached: true };
		let raw;
		try { raw = readFileSync(resolve(root, key)); } catch { continue; }
		if (raw.subarray(0, BINARY_PROBE_BYTES).includes(0)) continue;
		const [hits, cut] = hitsIn(documentBytes(raw), needle, !caseSensitive, wholeWord, MAX_RESULT_HITS - matches);
		if (hits.length > 0) {
			files.push({ key, hits });
			matches += hits.length;
		}
		if (cut) return { files, matches, limitReached: true };
	}
	return { files, matches, limitReached: false };
}

function serveSearch(req, res, url) {
	const cors = corsFor(req, res);
	if (cors === null) return;
	if (root === null) return answer(res, 404, cors, "the bridge searches no files: start it with --root <dir>\n");
	if (req.method !== "GET") return answer(res, 405, cors, `no ${req.method} on a search\n`);
	const text = url.searchParams.get("q") ?? "";
	if (text.length === 0) return answer(res, 400, cors, "a search needs a non-empty q\n");
	const found = searched(text, url.searchParams.get("case") === "1", url.searchParams.get("word") === "1");
	answer(res, 200, { ...cors, "Content-Type": "application/json; charset=utf-8" }, JSON.stringify(found));
}

function serveFile(req, res, url) {
	const cors = corsFor(req, res);
	if (cors === null) return;
	if (req.method === "OPTIONS") {
		return answer(res, 204, { ...cors, "Access-Control-Allow-Methods": "GET, PUT", "Access-Control-Allow-Headers": "Content-Type" }, "");
	}
	if (root === null) return answer(res, 404, cors, "the bridge serves no files: start it with --root <dir>\n");
	const path = underRoot(url.searchParams.get("path"));
	if (path === null) return answer(res, 404, cors, `no file ${url.searchParams.get("path")} under ${root}\n`);
	if (req.method === "GET") {
		const text = readFileSync(path, "utf8");
		const body = JSON.stringify({ uri: pathToFileURL(path).href, rootUri: pathToFileURL(root).href, text });
		return answer(res, 200, { ...cors, "Content-Type": "application/json; charset=utf-8" }, body);
	}
	if (req.method !== "PUT") return answer(res, 405, cors, `no ${req.method} on a file\n`);
	const chunks = [];
	req.on("data", (chunk) => chunks.push(chunk));
	req.on("end", () => {
		try {
			writeFileSync(`${path}.medic-save`, Buffer.concat(chunks));
			renameSync(`${path}.medic-save`, path);
			answer(res, 204, cors, "");
		} catch (e) {
			answer(res, 500, cors, `${e.message}\n`);
		}
	});
}

const server = createServer((req, res) => {
	const url = new URL(req.url, "http://127.0.0.1");
	if (url.pathname === "/file") return serveFile(req, res, url);
	if (url.pathname === "/files") return serveList(req, res);
	if (url.pathname === "/search") return serveSearch(req, res, url);
	answer(res, 426, {}, "medic lsp bridge: connect with a WebSocket\n");
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
server.listen(port, "127.0.0.1", () => console.log(`bridge: ws://127.0.0.1:${port} runs ${command.join(" ")}`
	+ (root === null ? "" : ` in ${root}`)));
