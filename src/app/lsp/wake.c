#include "wake.h"
#include "serverProcess.h"

void ionWakeLoop(void);

/* msc cannot pass ionWakeLoop as a function pointer:
   .inbox/compiler/2026-10-16-function-into-c-function-pointer-emits-msclosure.md */
void serverWireWake(void) {
	serverSetWake(ionWakeLoop);
}
