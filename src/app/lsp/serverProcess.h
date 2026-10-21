#ifndef MEDIC_SERVER_PROCESS_H
#define MEDIC_SERVER_PROCESS_H

#include <stdint.h>
#include "runtime/core/string.h"

void serverSetWake(void (*wake)(void));
int serverOpen(const char* commandLine, const char* cwd);
msString serverTake(int id);
int64_t serverWrite(int id, const uint8_t* data, int64_t len);
int serverEnded(int id);
int serverExitCode(int id);
void serverClose(int id);

#endif
