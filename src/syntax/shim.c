#include <stdlib.h>
#include <string.h>
#include <tree_sitter/api.h>
#include "shim.h"

#define CHUNK 4096

const TSLanguage* tree_sitter_metascript(void);

/* syntax.ms defines it: copies the document bytes from byte onward into the chunk through medicSyntaxFill. */
void medicSyntaxRead(void* source, void* syntax, int32_t byte);

typedef struct {
	TSParser* parser;
	TSTree* tree;
	TSQuery* query;
	TSQueryCursor* cursor;
	TSQueryMatch match;
	void* source;
	uint8_t chunk[CHUNK];
	uint32_t chunkLength;
} Syntax;

void* medicSyntaxNew(const uint8_t* query, int64_t length, int32_t* errorOffset) {
	Syntax* s = calloc(1, sizeof(Syntax));
	if (!s) return NULL;
	s->parser = ts_parser_new();
	ts_parser_set_language(s->parser, tree_sitter_metascript());
	uint32_t offset = 0;
	TSQueryError error = TSQueryErrorNone;
	s->query = ts_query_new(tree_sitter_metascript(), (const char*)query, (uint32_t)length, &offset, &error);
	if (!s->query) {
		*errorOffset = (int32_t)offset;
		ts_parser_delete(s->parser);
		free(s);
		return NULL;
	}
	s->cursor = ts_query_cursor_new();
	return s;
}

void medicSyntaxFree(void* syntax) {
	Syntax* s = syntax;
	if (s->tree) ts_tree_delete(s->tree);
	ts_query_cursor_delete(s->cursor);
	ts_query_delete(s->query);
	ts_parser_delete(s->parser);
	free(s);
}

void medicSyntaxFill(void* syntax, const uint8_t* bytes, int64_t length) {
	Syntax* s = syntax;
	s->chunkLength = (uint32_t)(length < CHUNK ? length : CHUNK);
	memcpy(s->chunk, bytes, s->chunkLength);
}

void medicSyntaxForget(void* syntax) {
	Syntax* s = syntax;
	if (s->tree) ts_tree_delete(s->tree);
	s->tree = NULL;
}

void medicSyntaxEdit(void* syntax, int32_t start, int32_t oldEnd, int32_t newEnd, int32_t startRow, int32_t startColumn,
	int32_t oldEndRow, int32_t oldEndColumn, int32_t newEndRow, int32_t newEndColumn) {
	Syntax* s = syntax;
	if (!s->tree) return;
	TSInputEdit edit = {
		(uint32_t)start, (uint32_t)oldEnd, (uint32_t)newEnd,
		{ (uint32_t)startRow, (uint32_t)startColumn },
		{ (uint32_t)oldEndRow, (uint32_t)oldEndColumn },
		{ (uint32_t)newEndRow, (uint32_t)newEndColumn },
	};
	ts_tree_edit(s->tree, &edit);
}

static const char* readChunk(void* payload, uint32_t byte, TSPoint point, uint32_t* bytesRead) {
	(void)point;
	Syntax* s = payload;
	s->chunkLength = 0;
	medicSyntaxRead(s->source, s, (int32_t)byte);
	*bytesRead = s->chunkLength;
	return (const char*)s->chunk;
}

int32_t medicSyntaxParse(void* syntax, void* source) {
	Syntax* s = syntax;
	s->source = source;
	TSInput input = { s, readChunk, TSInputEncodingUTF8, NULL };
	TSTree* tree = ts_parser_parse(s->parser, s->tree, input);
	s->source = NULL;
	if (!tree) return -1;
	if (s->tree) ts_tree_delete(s->tree);
	s->tree = tree;
	return 0;
}

int32_t medicSyntaxCaptureCount(void* syntax) {
	return (int32_t)ts_query_capture_count(((Syntax*)syntax)->query);
}

int32_t medicSyntaxPatternCount(void* syntax) {
	return (int32_t)ts_query_pattern_count(((Syntax*)syntax)->query);
}

static int64_t copied(const char* text, uint32_t length, uint8_t* buf, int64_t cap) {
	memcpy(buf, text, length < cap ? length : (size_t)cap);
	return length;
}

int64_t medicSyntaxCaptureName(void* syntax, int32_t id, uint8_t* buf, int64_t cap) {
	uint32_t length = 0;
	const char* name = ts_query_capture_name_for_id(((Syntax*)syntax)->query, (uint32_t)id, &length);
	return copied(name, length, buf, cap);
}

int64_t medicSyntaxStringValue(void* syntax, int32_t id, uint8_t* buf, int64_t cap) {
	uint32_t length = 0;
	const char* value = ts_query_string_value_for_id(((Syntax*)syntax)->query, (uint32_t)id, &length);
	return copied(value, length, buf, cap);
}

int64_t medicSyntaxPredicates(void* syntax, int32_t pattern, int32_t* steps, int64_t cap) {
	uint32_t count = 0;
	const TSQueryPredicateStep* step = ts_query_predicates_for_pattern(((Syntax*)syntax)->query, (uint32_t)pattern, &count);
	for (uint32_t i = 0; i < count && 2 * (int64_t)i + 1 < cap; i++) {
		steps[2 * i] = (int32_t)step[i].type;
		steps[2 * i + 1] = (int32_t)step[i].value_id;
	}
	return 2 * (int64_t)count;
}

void medicSyntaxHighlight(void* syntax, int32_t from, int32_t to) {
	Syntax* s = syntax;
	ts_query_cursor_set_byte_range(s->cursor, (uint32_t)from, (uint32_t)to);
	ts_query_cursor_exec(s->cursor, s->query, ts_tree_root_node(s->tree));
}

int32_t medicSyntaxNextCapture(void* syntax, int32_t* start, int32_t* end, int32_t* capture, int32_t* pattern) {
	Syntax* s = syntax;
	uint32_t index = 0;
	if (!s->tree || !ts_query_cursor_next_capture(s->cursor, &s->match, &index)) return 0;
	TSNode node = s->match.captures[index].node;
	*start = (int32_t)ts_node_start_byte(node);
	*end = (int32_t)ts_node_end_byte(node);
	*capture = (int32_t)s->match.captures[index].index;
	*pattern = (int32_t)s->match.pattern_index;
	return 1;
}

int32_t medicSyntaxMatchCapture(void* syntax, int32_t capture, int32_t* start, int32_t* end) {
	Syntax* s = syntax;
	for (uint16_t i = 0; i < s->match.capture_count; i++) {
		if (s->match.captures[i].index != (uint32_t)capture) continue;
		*start = (int32_t)ts_node_start_byte(s->match.captures[i].node);
		*end = (int32_t)ts_node_end_byte(s->match.captures[i].node);
		return 1;
	}
	return 0;
}
