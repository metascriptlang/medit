@include("./socketWeb.h");
@compile("./socketWeb.c");
@passL("-lwebsocket.js");

extern function socketOpen(url: cstring): int32;
extern function socketTake(): string;
extern function socketSend(data: Readonly<Span<uint8>>): int64;
extern function socketState(): int32;
extern function socketClose(): void;
extern function pageQuery(name: cstring): string;
extern function bridgeRequest(
	method: cstring,
	base: cstring,
	route: cstring,
	path: cstring,
	body: Readonly<Span<uint8>>,
): string;
extern function bridgeStatus(): int32;

const CLOSED: int32 = 2;

export function queryParam(name: string): string { return pageQuery(name); }

export interface Reply {
	status: int32;
	text: string;
}

export function requestFile(method: string, base: string, path: string, body: string): Reply {
	const text = bridgeRequest(method, base, "/file?path=", path, body.asBytes());
	return { status: bridgeStatus(), text };
}

export function requestFiles(base: string): Reply {
	const text = bridgeRequest("GET", base, "/files", "", "".asBytes());
	return { status: bridgeStatus(), text };
}

export function requestSearch(base: string, text: string, caseSensitive: boolean, wholeWord: boolean): Reply {
	const route = `/search?case=${caseSensitive ? 1 : 0}&word=${wholeWord ? 1 : 0}&q=`;
	const found = bridgeRequest("GET", base, route, text, "".asBytes());
	return { status: bridgeStatus(), text: found };
}

export function openSocket(url: string): boolean { return socketOpen(url) == 0; }

export function socketBytes(): string { return socketTake(); }

export function sendSocket(bytes: string): boolean { return socketSend(bytes.asBytes()) >= 0; }

export function socketClosed(): boolean { return socketState() == CLOSED; }

export function closeSocket(): void { socketClose(); }
