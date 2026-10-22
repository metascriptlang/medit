#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "serverProcess.h"

#define SERVER_MAX 8
#define ARG_MAX_WORDS 64

extern char** environ;

typedef struct {
	int used;
	int input;
	int output;
	pid_t pid;
	pthread_t reader;
	pthread_t writer;
	int hasReader;
	int hasWriter;
	pthread_mutex_t lock;
	pthread_cond_t pending;
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
	int exited;
	int exitCode;
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

static void* readLoop(void* arg) {
	Server* s = arg;
	uint8_t chunk[65536];
	for (;;) {
		ssize_t got = read(s->output, chunk, sizeof chunk);
		if (got < 0 && errno == EINTR) continue;
		if (got <= 0) break;
		pthread_mutex_lock(&s->lock);
		if (grow(&s->data, &s->cap, s->len + got)) {
			memcpy(s->data + s->len, chunk, (size_t)got);
			s->len += got;
		} else {
			s->outOfMemory = 1;
		}
		pthread_mutex_unlock(&s->lock);
		wake();
	}
	pthread_mutex_lock(&s->lock);
	s->closed = 1;
	pthread_mutex_unlock(&s->lock);
	wake();
	return NULL;
}

static void* writeLoop(void* arg) {
	Server* s = arg;
	uint8_t* batch = NULL;
	int64_t batchCap = 0;
	pthread_mutex_lock(&s->lock);
	for (;;) {
		while (!s->stopping && s->outLen == 0) pthread_cond_wait(&s->pending, &s->lock);
		if (s->stopping) break;
		uint8_t* full = s->out;
		int64_t fullCap = s->outCap;
		int64_t n = s->outLen;
		s->out = batch;
		s->outCap = batchCap;
		s->outLen = 0;
		batch = full;
		batchCap = fullCap;
		pthread_mutex_unlock(&s->lock);
		int ok = 1;
		for (int64_t done = 0; ok && done < n;) {
			ssize_t wrote = write(s->input, batch + done, (size_t)(n - done));
			if (wrote < 0 && errno == EINTR) continue;
			ok = wrote > 0;
			if (ok) done += wrote;
		}
		pthread_mutex_lock(&s->lock);
		if (!ok) s->writeFailed = 1;
	}
	pthread_mutex_unlock(&s->lock);
	free(batch);
	return NULL;
}

static int splitCommand(const char* line, char* words, char** argv, int most) {
	int count = 0;
	while (*line) {
		while (*line == ' ' || *line == '\t') line++;
		if (!*line) break;
		if (count == most - 1) return -1;
		argv[count++] = words;
		int quoted = 0;
		while (*line && (quoted || (*line != ' ' && *line != '\t'))) {
			if (*line == '"') quoted = !quoted;
			else *words++ = *line;
			line++;
		}
		*words++ = '\0';
	}
	argv[count] = NULL;
	return count;
}

int serverOpen(const char* commandLine, const char* cwd) {
	int id = -1;
	for (int i = 0; i < SERVER_MAX; i++) {
		if (!servers[i].used) { id = i; break; }
	}
	if (id < 0) return -1;
	int in[2], out[2];
	if (pipe(in) != 0) return -1;
	if (pipe(out) != 0) {
		close(in[0]);
		close(in[1]);
		return -1;
	}
	fcntl(in[1], F_SETFD, FD_CLOEXEC);
	fcntl(out[0], F_SETFD, FD_CLOEXEC);
	signal(SIGPIPE, SIG_IGN);

	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_adddup2(&actions, in[0], 0);
	posix_spawn_file_actions_adddup2(&actions, out[1], 1);
	posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
	posix_spawn_file_actions_addclose(&actions, in[0]);
	posix_spawn_file_actions_addclose(&actions, out[1]);
	if (cwd[0] != '\0') posix_spawn_file_actions_addchdir_np(&actions, cwd);
	char* words = malloc(strlen(commandLine) + 1);
	char* argv[ARG_MAX_WORDS];
	pid_t pid = 0;
	int spawned = words && splitCommand(commandLine, words, argv, ARG_MAX_WORDS) > 0
		? posix_spawnp(&pid, argv[0], &actions, NULL, argv, environ)
		: -1;
	free(words);
	posix_spawn_file_actions_destroy(&actions);
	close(in[0]);
	close(out[1]);
	if (spawned != 0) {
		close(in[1]);
		close(out[0]);
		return -1;
	}

	Server* s = &servers[id];
	memset(s, 0, sizeof *s);
	s->used = 1;
	s->input = in[1];
	s->output = out[0];
	s->pid = pid;
	s->exitCode = -1;
	pthread_mutex_init(&s->lock, NULL);
	pthread_cond_init(&s->pending, NULL);
	s->hasReader = pthread_create(&s->reader, NULL, readLoop, s) == 0;
	if (s->hasReader) s->hasWriter = pthread_create(&s->writer, NULL, writeLoop, s) == 0;
	if (!s->hasWriter) {
		serverClose(id);
		return -1;
	}
	return id;
}

msString serverTake(int id) {
	Server* s = slot(id);
	if (!s) return MS_EMPTY_STRING;
	pthread_mutex_lock(&s->lock);
	msString taken = s->len > 0 ? msStringNew((const char*)s->data, s->len) : MS_EMPTY_STRING;
	s->len = 0;
	pthread_mutex_unlock(&s->lock);
	return taken;
}

int64_t serverWrite(int id, const uint8_t* data, int64_t len) {
	Server* s = slot(id);
	if (!s) return -1;
	pthread_mutex_lock(&s->lock);
	if (s->writeFailed) {
		pthread_mutex_unlock(&s->lock);
		return -1;
	}
	if (!grow(&s->out, &s->outCap, s->outLen + len)) {
		pthread_mutex_unlock(&s->lock);
		return -2;
	}
	memcpy(s->out + s->outLen, data, (size_t)len);
	s->outLen += len;
	pthread_cond_signal(&s->pending);
	pthread_mutex_unlock(&s->lock);
	return len;
}

int serverEnded(int id) {
	Server* s = slot(id);
	if (!s) return 1;
	pthread_mutex_lock(&s->lock);
	int ended = (s->closed && s->len == 0) || s->outOfMemory || s->writeFailed;
	pthread_mutex_unlock(&s->lock);
	return ended;
}

int serverExitCode(int id) {
	Server* s = slot(id);
	if (!s) return -1;
	if (!s->exited) {
		int status = 0;
		if (waitpid(s->pid, &status, WNOHANG) != s->pid) return -1;
		s->exited = 1;
		s->exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
	}
	return s->exitCode;
}

void serverClose(int id) {
	Server* s = slot(id);
	if (!s) return;
	pthread_mutex_lock(&s->lock);
	s->stopping = 1;
	pthread_cond_broadcast(&s->pending);
	pthread_mutex_unlock(&s->lock);
	if (s->hasWriter) pthread_join(s->writer, NULL);
	close(s->input);
	if (!s->exited) {
		int waited = 0;
		for (int i = 0; i < 200 && !waited; i++) {
			int status = 0;
			waited = waitpid(s->pid, &status, WNOHANG) == s->pid;
			if (!waited) {
				struct timespec tick = { 0, 10 * 1000 * 1000 };
				nanosleep(&tick, NULL);
			}
		}
		if (!waited) {
			kill(s->pid, SIGKILL);
			waitpid(s->pid, NULL, 0);
		}
	}
	if (s->hasReader) pthread_join(s->reader, NULL);
	close(s->output);
	pthread_mutex_destroy(&s->lock);
	pthread_cond_destroy(&s->pending);
	free(s->data);
	free(s->out);
	memset(s, 0, sizeof *s);
}

int serverParentId(void) {
	return (int)getpid();
}
