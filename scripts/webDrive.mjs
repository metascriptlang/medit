// Drives the web build in headless Chrome over the DevTools protocol and saves screenshots.
//   node scripts/webDrive.mjs <url> <outDir> <step>...
// Steps: wait:<ms>  shot:<name>  wheel:<deltaY>  hwheel:<deltaX>  key:[ctrl+][alt+][shift+]<key>[*n]  type:<text> (keypresses)  text:<text> (insertText)
//        compose:<text>  commit:<text>  click:<x>,<y>[,<count>][,alt|shift]  drag:<x1>,<y1>,<x2>,<y2>[,<moves>]
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

const VK = {
	ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40, Enter: 13, Backspace: 8, Tab: 9, Escape: 27,
	Home: 36, End: 35, Delete: 46, PageUp: 33, PageDown: 34, Insert: 45,
};
const PUNCTUATION = { "/": ["Slash", 191], ".": ["Period", 190], ",": ["Comma", 188], "[": ["BracketLeft", 219], "]": ["BracketRight", 221] };
const MOD_BITS = { alt: 1, ctrl: 2, meta: 4, shift: 8 };

function keyOf(chord) {
	const parts = chord.split("+");
	const key = parts.pop();
	const modifiers = parts.reduce((m, p) => m | MOD_BITS[p], 0);
	const letter = key.length === 1 && /[a-z]/i.test(key);
	const [punctuationCode, punctuationVk] = PUNCTUATION[key] ?? [key, 0];
	const code = letter ? `Key${key.toUpperCase()}` : /^[0-9]$/.test(key) ? `Digit${key}` : punctuationCode;
	const windowsVirtualKeyCode = letter ? key.toUpperCase().charCodeAt(0) : VK[key] ?? punctuationVk;
	return { key, code, modifiers, windowsVirtualKeyCode };
}

async function mouse(type, x, y, modifiers, clickCount) {
	await send("Input.dispatchMouseEvent", { type, x, y, button: "left", buttons: type === "mouseReleased" ? 0 : 1, modifiers, clickCount });
}

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
	} else if (kind === "hwheel") {
		await send("Input.dispatchMouseEvent", { type: "mouseWheel", x: 400, y: 300, deltaX: Number(arg), deltaY: 0 });
		await sleep(100);
	} else if (kind === "key") {
		const [chord, times = "1"] = arg.split("*");
		const k = keyOf(chord);
		for (let i = 0; i < Number(times); i++) {
			await send("Input.dispatchKeyEvent", { type: "rawKeyDown", ...k });
			await send("Input.dispatchKeyEvent", { type: "keyUp", ...k });
			await sleep(50);
		}
	} else if (kind === "click") {
		const [x, y, count = "1", mod] = arg.split(",");
		const modifiers = mod ? MOD_BITS[mod] : 0;
		for (let c = 1; c <= Number(count); c++) {
			await mouse("mousePressed", Number(x), Number(y), modifiers, c);
			await mouse("mouseReleased", Number(x), Number(y), modifiers, c);
		}
		await sleep(100);
	} else if (kind === "drag") {
		const [x1, y1, x2, y2, moves = 2] = arg.split(",").map(Number);
		await mouse("mousePressed", x1, y1, 0, 1);
		for (let k = 1; k <= moves; k++) {
			await mouse("mouseMoved", x1 + (x2 - x1) * k / moves, y1 + (y2 - y1) * k / moves, 0, 0);
			await sleep(10);
		}
		await mouse("mouseReleased", x2, y2, 0, 1);
		await sleep(100);
	} else if (kind === "type") {
		for (const ch of arg) {
			const k = keyOf(ch);
			const shifted = ch !== ch.toLowerCase();
			const press = { ...k, key: ch, text: ch, unmodifiedText: ch, modifiers: shifted ? MOD_BITS.shift : 0 };
			await send("Input.dispatchKeyEvent", { type: "keyDown", ...press });
			await send("Input.dispatchKeyEvent", { type: "keyUp", ...press });
			await sleep(20);
		}
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
