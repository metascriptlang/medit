#include <emscripten.h>
#include <emscripten/websocket.h>
#include <stdlib.h>
#include <string.h>

#include "socketWeb.h"

enum { SOCKET_CONNECTING = 0, SOCKET_OPEN = 1, SOCKET_CLOSED = 2 };

static EMSCRIPTEN_WEBSOCKET_T sock;
static int state = SOCKET_CLOSED;
static uint8_t* inbox;
static int64_t inboxLen;
static int64_t inboxCap;
static uint8_t* outbox;
static int64_t outboxLen;
static int64_t outboxCap;

static int append(uint8_t** bytes, int64_t* len, int64_t* cap, const uint8_t* data, int64_t n) {
	if (*len + n > *cap) {
		int64_t next = *cap ? *cap : 65536;
		while (next < *len + n) next *= 2;
		uint8_t* grown = realloc(*bytes, (size_t)next);
		if (!grown) return 0;
		*bytes = grown;
		*cap = next;
	}
	memcpy(*bytes + *len, data, (size_t)n);
	*len += n;
	return 1;
}

static bool opened(int type, const EmscriptenWebSocketOpenEvent* e, void* user) {
	state = SOCKET_OPEN;
	if (outboxLen > 0) {
		emscripten_websocket_send_binary(sock, outbox, (uint32_t)outboxLen);
		outboxLen = 0;
	}
	return true;
}

static bool received(int type, const EmscriptenWebSocketMessageEvent* e, void* user) {
	uint32_t n = e->numBytes;
	if (e->isText && n > 0 && e->data[n - 1] == 0) n -= 1;
	if (!append(&inbox, &inboxLen, &inboxCap, e->data, n)) state = SOCKET_CLOSED;
	return true;
}

static bool closed(int type, const EmscriptenWebSocketCloseEvent* e, void* user) {
	state = SOCKET_CLOSED;
	return true;
}

static bool failed(int type, const EmscriptenWebSocketErrorEvent* e, void* user) {
	state = SOCKET_CLOSED;
	return true;
}

int socketOpen(const char* url) {
	if (!emscripten_websocket_is_supported() || state != SOCKET_CLOSED) return -1;
	EmscriptenWebSocketCreateAttributes attrs;
	emscripten_websocket_init_create_attributes(&attrs);
	attrs.url = url;
	sock = emscripten_websocket_new(&attrs);
	if (sock <= 0) return -1;
	state = SOCKET_CONNECTING;
	emscripten_websocket_set_onopen_callback(sock, NULL, opened);
	emscripten_websocket_set_onmessage_callback(sock, NULL, received);
	emscripten_websocket_set_onclose_callback(sock, NULL, closed);
	emscripten_websocket_set_onerror_callback(sock, NULL, failed);
	return 0;
}

msString socketTake(void) {
	msString taken = inboxLen > 0 ? msStringNew((const char*)inbox, inboxLen) : MS_EMPTY_STRING;
	inboxLen = 0;
	return taken;
}

int64_t socketSend(const uint8_t* data, int64_t len) {
	if (state == SOCKET_CLOSED) return -1;
	if (state == SOCKET_CONNECTING) {
		return append(&outbox, &outboxLen, &outboxCap, data, len) ? len : -2;
	}
	return emscripten_websocket_send_binary(sock, (void*)data, (uint32_t)len) == EMSCRIPTEN_RESULT_SUCCESS ? len : -1;
}

int socketState(void) {
	return state;
}

void socketClose(void) {
	if (state != SOCKET_CLOSED) emscripten_websocket_close(sock, 1000, "medic closed");
	state = SOCKET_CLOSED;
}

EM_JS_DEPS(medicWebQuery, "$UTF8ToString,$stringToUTF8,$lengthBytesUTF8,malloc");

EM_JS(char*, medicJsQuery, (const char* name), {
	const value = new URLSearchParams(location.search).get(UTF8ToString(name));
	if (value === null) return 0;
	const size = lengthBytesUTF8(value) + 1;
	const out = _malloc(size);
	stringToUTF8(value, out, size);
	return out;
});

msString pageQuery(const char* name) {
	char* value = medicJsQuery(name);
	if (!value) return MS_EMPTY_STRING;
	msString out = msStringNew(value, (int64_t)strlen(value));
	free(value);
	return out;
}
