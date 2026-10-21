const SCHEME = "file://";
const HEX = "0123456789ABCDEF";

function kept(b: int32): boolean {
	return (b >= "a".code && b <= "z".code) || (b >= "A".code && b <= "Z".code)
		|| (b >= "0".code && b <= "9".code)
		|| b == "-".code || b == ".".code || b == "_".code || b == "~".code || b == "/".code;
}

function hexValue(b: int32): int32 {
	if (b >= "0".code && b <= "9".code) { return b - "0".code; }
	if (b >= "a".code && b <= "f".code) { return b - "a".code + 10; }
	if (b >= "A".code && b <= "F".code) { return b - "A".code + 10; }
	return -1;
}

function hasDrive(path: string): boolean {
	if (path.byteLength < 2 || path.byteAt(1) != ":".code) { return false; }
	const b = path.byteAt(0);
	return (b >= "a".code && b <= "z".code) || (b >= "A".code && b <= "Z".code);
}

export function fileUri(absolutePath: string): string {
	const path = absolutePath.replaceAll("\\", "/");
	const from = hasDrive(path) ? 2 : 0;
	let out = from == 2 ? `${SCHEME}/${path.byteSlice(0, 2)}` : path.startsWith("/") ? SCHEME : `${SCHEME}/`;
	let run = from;
	for (let k = from; k < path.byteLength; k++) {
		const b = path.byteAt(k);
		if (kept(b)) { continue; }
		out += path.byteSlice(run, k) + "%" + HEX.byteSlice(b >> 4, (b >> 4) + 1) + HEX.byteSlice(b & 15, (b & 15) + 1);
		run = k + 1;
	}
	return out + path.byteSlice(run, path.byteLength);
}

function escapedAt(text: string, k: int32): int32 {
	if (k + 2 >= text.byteLength || text.byteAt(k) != "%".code) { return -1; }
	const high = hexValue(text.byteAt(k + 1));
	const low = hexValue(text.byteAt(k + 2));
	return high < 0 || low < 0 ? -1 : high * 16 + low;
}

function sequenceLength(lead: int32): int32 {
	if (lead < 0x80) { return 1; }
	if (lead >= 0xF0 && lead < 0xF8) { return 4; }
	if (lead >= 0xE0) { return lead < 0xF0 ? 3 : 0; }
	return lead >= 0xC2 ? 2 : 0;
}

function decodedAt(text: string, k: int32): [string, int32] {
	const lead = escapedAt(text, k);
	const length = lead < 0 ? 0 : sequenceLength(lead);
	if (length == 0) { return ["", 0]; }
	let cp = length == 1 ? lead : lead & (0xFF >> (length + 1));
	for (let i = 1; i < length; i++) {
		const b = escapedAt(text, k + 3 * i);
		if (b < 0x80 || b >= 0xC0) { return ["", 0]; }
		cp = (cp << 6) | (b & 0x3F);
	}
	return [fromCodePoint(cp), 3 * length];
}

export function filePath(uri: string): string | null {
	if (!uri.startsWith(SCHEME)) { return null; }
	const encoded = uri.byteSlice(SCHEME.byteLength, uri.byteLength);
	let path = "";
	let run = 0;
	let k = 0;
	while (k < encoded.byteLength) {
		const [text, used] = decodedAt(encoded, k);
		if (used == 0) {
			k += 1;
			continue;
		}
		path += encoded.byteSlice(run, k) + text;
		k += used;
		run = k;
	}
	path += encoded.byteSlice(run, encoded.byteLength);
	return path.byteLength > 2 && path.byteAt(0) == "/".code && hasDrive(path.byteSlice(1, path.byteLength)) ?
		path.byteSlice(1, path.byteLength) : path;
}

test "a file path becomes a file URI with reserved bytes escaped, and comes back" {
	assert fileUri("C:/Users/me/a b.ms") == "file:///C:/Users/me/a%20b.ms";
	assert fileUri("C:\\work\\x#1.ms") == "file:///C:/work/x%231.ms";
	assert fileUri("/home/me/é.ms") == "file:///home/me/%C3%A9.ms";
	assert filePath("file:///C:/Users/me/a%20b.ms") == "C:/Users/me/a b.ms";
	assert filePath("file:///c%3A/x.ms") == "c:/x.ms";
	assert filePath("file:///home/me/%C3%A9.ms") == "/home/me/é.ms";
	assert filePath("untitled:1") === null;
}
