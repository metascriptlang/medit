#ifndef MEDIC_SOCKET_WEB_H
#define MEDIC_SOCKET_WEB_H

#include <stdint.h>
#include "runtime/core/string.h"

int socketOpen(const char* url);
msString socketTake(void);
int64_t socketSend(const uint8_t* data, int64_t len);
int socketState(void);
void socketClose(void);
msString pageQuery(const char* name);

#endif
