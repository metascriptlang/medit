// Drives the web build in headless Chrome over the DevTools protocol and saves screenshots.
//   node scripts/webDrive.mjs <url> <outDir> <step>...
// Steps: wait:<ms>  shot:<name>  wheel:<deltaY>  key:<key>  text:<text>  compose:<text>  commit:<text>
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const CHROME = process.env.CHROME ?? "C:/Program Files/Google/Chrome/Application/chrome.exe";
const PORT = 9300 + Math.floor(Math.random() * 500);
const [url, outDir, ...steps] = process.argv.slice(2);

const chrome = spawn(CHROME, [
	"--headless=new",
	"--use-angle=swiftshader",
	"--enable-unsafe-swiftshader",
	`--remote-debugging-port=${PORT}`,
	`--user-data-dir=${mkdtempSync(join(tmpdir(), "medic-chrome-"))}`,
	"--window-size=960,640",
	"about:blank",
], { stdio: "ignore" });

async function target() {
	for (let i = 0; i < 50; i++) {
		try {
			const list = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
			const page = list.find((t) => t.type === "page");
			if (page) return page.webSocketDebuggerUrl;
		} catch {}
		await new Promise((r) => setTimeout(r, 200));
	}
	throw new Error("chrome did not open a debugging target");
}

const ws = new WebSocket(await target());
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let nextId = 1;
const pending = new Map();
ws.addEventListener("message", (e) => {
	const m = JSON.parse(e.data);
	if (m.method === "Runtime.consoleAPICalled") {
		console.log("page:", m.params.args.map((a) => a.value ?? a.description).join(" "));
	}
	if (m.id && pending.has(m.id)) {
		pending.get(m.id)(m);
		pending.delete(m.id);
	}
});
function send(method, params = {}) {
	const id = nextId++;
	ws.send(JSON.stringify({ id, method, params }));
	return new Promise((r) => pending.set(id, r));
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

await send("Runtime.enable");
await send("Page.enable");
await send("Emulation.setDeviceMetricsOverride", { width: 960, height: 640, deviceScaleFactor: 1, mobile: false });
await send("Page.navigate", { url });
await sleep(3000);
await send("Input.dispatchMouseEvent", { type: "mousePressed", x: 400, y: 300, button: "left", clickCount: 1 });
await send("Input.dispatchMouseEvent", { type: "mouseReleased", x: 400, y: 300, button: "left", clickCount: 1 });

for (const step of steps) {
	const at = step.indexOf(":");
	const kind = step.slice(0, at);
	const arg = step.slice(at + 1);
	if (kind === "wait") await sleep(Number(arg));
	else if (kind === "shot") {
		const r = await send("Page.captureScreenshot", { format: "png" });
		writeFileSync(join(outDir, `${arg}.png`), Buffer.from(r.result.data, "base64"));
		console.log(`shot ${arg}`);
	} else if (kind === "wheel") {
		await send("Input.dispatchMouseEvent", { type: "mouseWheel", x: 400, y: 300, deltaX: 0, deltaY: Number(arg) });
		await sleep(100);
	} else if (kind === "key") {
		await send("Input.dispatchKeyEvent", { type: "keyDown", key: arg, code: arg });
		await send("Input.dispatchKeyEvent", { type: "keyUp", key: arg, code: arg });
		await sleep(50);
	} else if (kind === "text") {
		await send("Input.insertText", { text: arg });
		await sleep(50);
	} else if (kind === "compose") {
		await send("Input.imeSetComposition", { text: arg, selectionStart: arg.length, selectionEnd: arg.length });
		await sleep(50);
	} else if (kind === "commit") {
		await send("Input.insertText", { text: arg });
		await sleep(50);
	} else throw new Error(`unknown step ${step}`);
}

ws.close();
chrome.kill();
process.exit(0);
