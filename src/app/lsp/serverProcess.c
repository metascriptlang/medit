#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include <string.h>

#include "serverProcess.h"

#define SERVER_MAX 8

typedef struct {
	int used;
	HANDLE input;
	HANDLE output;
	HANDLE process;
	HANDLE reader;
	HANDLE writer;
	CRITICAL_SECTION lock;
	CONDITION_VARIABLE pending;
	uint8_t* data;
	int64_t len;
	int64_t cap;
	uint8_t* out;
	int64_t outLen;
	int64_t outCap;
	int writeFailed;
	int stopping;
	int closed;
	int outOfMemory;
} Server;

static Server servers[SERVER_MAX];
static void (*wakeApp)(void);

void serverSetWake(void (*wake)(void)) {
	wakeApp = wake;
}

static void wake(void) {
	if (wakeApp) wakeApp();
}

static Server* slot(int id) {
	if (id < 0 || id >= SERVER_MAX || !servers[id].used) return NULL;
	return &servers[id];
}

static int grow(uint8_t** bytes, int64_t* cap, int64_t need) {
	if (need <= *cap) return 1;
	int64_t next = *cap ? *cap : 65536;
	while (next < need) next *= 2;
	uint8_t* grown = realloc(*bytes, (size_t)next);
	if (!grown) return 0;
	*bytes = grown;
	*cap = next;
	return 1;
}

static DWORD WINAPI readLoop(LPVOID arg) {
	Server* s = arg;
	uint8_t chunk[65536];
	DWORD got = 0;
	while (ReadFile(s->output, chunk, sizeof chunk, &got, NULL) && got > 0) {
		EnterCriticalSection(&s->lock);
		if (grow(&s->data, &s->cap, s->len + got)) {
			memcpy(s->data + s->len, chunk, got);
			s->len += got;
		} else {
			s->outOfMemory = 1;
		}
		LeaveCriticalSection(&s->lock);
		wake();
	}
	EnterCriticalSection(&s->lock);
	s->closed = 1;
	LeaveCriticalSection(&s->lock);
	wake();
	return 0;
}

static DWORD WINAPI writeLoop(LPVOID arg) {
	Server* s = arg;
	uint8_t* batch = NULL;
	int64_t batchCap = 0;
	EnterCriticalSection(&s->lock);
	for (;;) {
		while (!s->stopping && s->outLen == 0) {
			SleepConditionVariableCS(&s->pending, &s->lock, INFINITE);
		}
		if (s->stopping) break;
		uint8_t* full = s->out;
		int64_t fullCap = s->outCap;
		int64_t n = s->outLen;
		s->out = batch;
		s->outCap = batchCap;
		s->outLen = 0;
		batch = full;
		batchCap = fullCap;
		LeaveCriticalSection(&s->lock);
		int ok = 1;
		for (int64_t done = 0; ok && done < n;) {
			DWORD wrote = 0;
			DWORD want = n - done > (1 << 30) ? (1 << 30) : (DWORD)(n - done);
			ok = WriteFile(s->input, batch + done, want, &wrote, NULL);
			done += wrote;
		}
		EnterCriticalSection(&s->lock);
		if (!ok) s->writeFailed = 1;
	}
	LeaveCriticalSection(&s->lock);
	free(batch);
	return 0;
}

static wchar_t* widened(const char* text) {
	int len = MultiByteToWideChar(CP_UTF8, 0, text, -1, NULL, 0);
	wchar_t* wide = len > 0 ? malloc(sizeof(wchar_t) * (size_t)len) : NULL;
	if (wide && !MultiByteToWideChar(CP_UTF8, 0, text, -1, wide, len)) {
		free(wide);
		return NULL;
	}
	return wide;
}

int serverOpen(const char* commandLine, const char* cwd) {
	int id = -1;
	for (int i = 0; i < SERVER_MAX; i++) {
		if (!servers[i].used) { id = i; break; }
	}
	if (id < 0) return -1;

	SECURITY_ATTRIBUTES inherit = { sizeof inherit, NULL, TRUE };
	HANDLE inRead = NULL, inWrite = NULL, outRead = NULL, outWrite = NULL;
	if (!CreatePipe(&inRead, &inWrite, &inherit, 0)) return -1;
	if (!CreatePipe(&outRead, &outWrite, &inherit, 0)) {
		CloseHandle(inRead);
		CloseHandle(inWrite);
		return -1;
	}
	SetHandleInformation(inWrite, HANDLE_FLAG_INHERIT, 0);
	SetHandleInformation(outRead, HANDLE_FLAG_INHERIT, 0);
	HANDLE nul = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &inherit,
		OPEN_EXISTING, 0, NULL);

	HANDLE handed[3] = { inRead, outWrite, nul };
	int handedCount = nul == INVALID_HANDLE_VALUE ? 2 : 3;
	SIZE_T attrSize = 0;
	InitializeProcThreadAttributeList(NULL, 1, 0, &attrSize);
	LPPROC_THREAD_ATTRIBUTE_LIST attrs = malloc(attrSize);
	STARTUPINFOEXW si;
	memset(&si, 0, sizeof si);
	si.StartupInfo.cb = sizeof si;
	si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
	si.StartupInfo.hStdInput = inRead;
	si.StartupInfo.hStdOutput = outWrite;
	si.StartupInfo.hStdError = handedCount == 3 ? nul : NULL;
	si.lpAttributeList = attrs;
	wchar_t* wide = widened(commandLine);
	wchar_t* wideCwd = cwd[0] != '\0' ? widened(cwd) : NULL;
	PROCESS_INFORMATION pi;
	memset(&pi, 0, sizeof pi);
	int ok = attrs && wide && (cwd[0] == '\0' || wideCwd)
		&& InitializeProcThreadAttributeList(attrs, 1, 0, &attrSize)
		&& UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handed,
			sizeof(HANDLE) * (SIZE_T)handedCount, NULL, NULL)
		&& CreateProcessW(NULL, wide, NULL, NULL, TRUE,
			EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW, NULL, wideCwd, &si.StartupInfo, &pi);
	if (attrs) {
		DeleteProcThreadAttributeList(attrs);
		free(attrs);
	}
	free(wide);
	free(wideCwd);
	CloseHandle(inRead);
	CloseHandle(outWrite);
	if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
	if (!ok) {
		CloseHandle(inWrite);
		CloseHandle(outRead);
		return -1;
	}
	CloseHandle(pi.hThread);

	Server* s = &servers[id];
	memset(s, 0, sizeof *s);
	s->used = 1;
	s->input = inWrite;
	s->output = outRead;
	s->process = pi.hProcess;
	InitializeCriticalSection(&s->lock);
	InitializeConditionVariable(&s->pending);
	s->reader = CreateThread(NULL, 0, readLoop, s, 0, NULL);
	if (s->reader) s->writer = CreateThread(NULL, 0, writeLoop, s, 0, NULL);
	if (!s->writer) {
		serverClose(id);
		return -1;
	}
	return id;
}

msString serverTake(int id) {
	Server* s = slot(id);
	if (!s) return MS_EMPTY_STRING;
	EnterCriticalSection(&s->lock);
	msString taken = s->len > 0 ? msStringNew((const char*)s->data, s->len) : MS_EMPTY_STRING;
	s->len = 0;
	LeaveCriticalSection(&s->lock);
	return taken;
}

int64_t serverWrite(int id, const uint8_t* data, int64_t len) {
	Server* s = slot(id);
	if (!s) return -1;
	EnterCriticalSection(&s->lock);
	if (s->writeFailed) {
		LeaveCriticalSection(&s->lock);
		return -1;
	}
	if (!grow(&s->out, &s->outCap, s->outLen + len)) {
		LeaveCriticalSection(&s->lock);
		return -2;
	}
	memcpy(s->out + s->outLen, data, (size_t)len);
	s->outLen += len;
	WakeConditionVariable(&s->pending);
	LeaveCriticalSection(&s->lock);
	return len;
}

int serverEnded(int id) {
	Server* s = slot(id);
	if (!s) return 1;
	EnterCriticalSection(&s->lock);
	int ended = (s->closed && s->len == 0) || s->outOfMemory || s->writeFailed;
	LeaveCriticalSection(&s->lock);
	return ended;
}

int serverExitCode(int id) {
	Server* s = slot(id);
	if (!s) return -1;
	DWORD code = 0;
	if (!GetExitCodeProcess(s->process, &code) || code == STILL_ACTIVE) return -1;
	return (int)code;
}

void serverClose(int id) {
	Server* s = slot(id);
	if (!s) return;
	EnterCriticalSection(&s->lock);
	s->stopping = 1;
	WakeAllConditionVariable(&s->pending);
	LeaveCriticalSection(&s->lock);
	if (s->writer) WaitForSingleObject(s->writer, INFINITE);
	CloseHandle(s->input);
	if (WaitForSingleObject(s->process, 2000) != WAIT_OBJECT_0) TerminateProcess(s->process, 1);
	if (s->reader) WaitForSingleObject(s->reader, INFINITE);
	CloseHandle(s->output);
	if (s->reader) CloseHandle(s->reader);
	if (s->writer) CloseHandle(s->writer);
	CloseHandle(s->process);
	DeleteCriticalSection(&s->lock);
	free(s->data);
	free(s->out);
	memset(s, 0, sizeof *s);
}

int serverParentId(void) {
	return (int)GetCurrentProcessId();
}
