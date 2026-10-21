// Parked: a JsonValue narrowed by `v.kind == …` loses its extension methods until msc syncs past
// a7c3117c2, ~/metascript/.inbox/compiler/2026-09-28-narrowed-ref-union-loses-extensions.md;
// then write `v.kind == kind` at each call site and delete this file.
export function isKind(v: JsonValue, kind: JsonKind): boolean { return v.kind == kind; }
