#ifndef MEDIC_SYNTAX_SHIM_H
#define MEDIC_SYNTAX_SHIM_H

#include <stdint.h>

void* medicSyntaxNew(const uint8_t* query, int64_t length, int32_t* errorOffset);
void medicSyntaxFree(void* syntax);
void medicSyntaxFill(void* syntax, const uint8_t* bytes, int64_t length);
void medicSyntaxForget(void* syntax);
void medicSyntaxEdit(void* syntax, int32_t start, int32_t oldEnd, int32_t newEnd, int32_t startRow, int32_t startColumn,
	int32_t oldEndRow, int32_t oldEndColumn, int32_t newEndRow, int32_t newEndColumn);
int32_t medicSyntaxParse(void* syntax, void* source);
int32_t medicSyntaxCaptureCount(void* syntax);
int32_t medicSyntaxPatternCount(void* syntax);
int64_t medicSyntaxCaptureName(void* syntax, int32_t id, uint8_t* buf, int64_t cap);
int64_t medicSyntaxStringValue(void* syntax, int32_t id, uint8_t* buf, int64_t cap);
int64_t medicSyntaxPredicates(void* syntax, int32_t pattern, int32_t* steps, int64_t cap);
void medicSyntaxHighlight(void* syntax, int32_t from, int32_t to);
int32_t medicSyntaxNextCapture(void* syntax, int32_t* start, int32_t* end, int32_t* capture, int32_t* pattern);
int32_t medicSyntaxMatchCapture(void* syntax, int32_t capture, int32_t* start, int32_t* end);

#endif
