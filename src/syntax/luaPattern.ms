type Bytes = Readonly<Span<uint8>>;

const DELETE: int32 = 127;

function at(bytes: Bytes, i: int32): int32 {
	return i < bytes.length ? bytes[i] as int32 : -1;
}

function inClass(c: int32, letter: int32): boolean {
	const lower = letter | 0x20;
	const folded = c | 0x20;
	let hit = false;
	match (lower) {
		"a".code => { hit = folded >= "a".code && folded <= "z".code; },
		"d".code => { hit = c >= "0".code && c <= "9".code; },
		"l".code => { hit = c >= "a".code && c <= "z".code; },
		"u".code => { hit = c >= "A".code && c <= "Z".code; },
		"s".code => { hit = c == " ".code || (c >= "\t".code && c <= "\r".code); },
		"w".code => { hit = inClass(c, "a".code) || inClass(c, "d".code); },
		"x".code => { hit = inClass(c, "d".code) || (folded >= "a".code && folded <= "f".code); },
		"p".code => { hit = c > " ".code && c < DELETE && !inClass(c, "w".code); },
		"c".code => { hit = c < " ".code || c == DELETE; },
		_ => { return c == letter; },
	};
	return letter == lower ? hit : !hit;
}

function itemEnd(pattern: Bytes, start: int32): int32 {
	match (at(pattern, start)) {
		"%".code => {
			const escaped = at(pattern, start + 1);
			if (escaped < 0) { throw new Error("lua pattern ends with %"); }
			if (escaped == "b".code || escaped == "f".code) {
				throw new Error(`lua pattern %${String.fromCharCode(escaped)} is not supported`);
			}
			return start + 2;
		},
		"(".code | ")".code => { throw new Error("lua pattern captures are not supported"); },
		"[".code => {
			let k = start + 1;
			if (at(pattern, k) == "^".code) { k += 1; }
			do {
				if (k >= pattern.length) { throw new Error("lua pattern has an unclosed ["); }
				k += at(pattern, k) == "%".code ? 2 : 1;
			} while (at(pattern, k) != "]".code);
			return k + 1;
		},
		_ => { return start + 1; },
	};
}

function inSet(c: int32, set: Bytes): boolean {
	const negated = at(set, 0) == "^".code;
	let k = negated ? 1 : 0;
	while (k < set.length) {
		if (at(set, k) == "%".code) {
			if (inClass(c, at(set, k + 1))) { return !negated; }
			k += 2;
		} else if (at(set, k + 1) == "-".code && k + 2 < set.length) {
			if (c >= at(set, k) && c <= at(set, k + 2)) { return !negated; }
			k += 3;
		} else {
			if (c == at(set, k)) { return !negated; }
			k += 1;
		}
	}
	return negated;
}

function matchesItem(c: int32, item: Bytes): boolean {
	if (c < 0) { return false; }
	return match (at(item, 0)) {
		".".code => true,
		"%".code => inClass(c, at(item, 1)),
		"[".code => inSet(c, item[1..item.length - 1]),
		_ => c == at(item, 0),
	};
}

function matchesFrom(text: Bytes, start: int32, pattern: Bytes, from: int32): boolean {
	let i = start;
	let k = from;
	while (k < pattern.length) {
		if (at(pattern, k) == "$".code && k + 1 == pattern.length) { return i == text.length; }
		const end = itemEnd(pattern, k);
		const item = pattern[k..end];
		const quantifier = at(pattern, end);
		match (quantifier) {
			"?".code => {
				if (matchesItem(at(text, i), item) && matchesFrom(text, i + 1, pattern, end + 1)) {
					return true;
				}
				k = end + 1;
			},
			"*".code | "+".code => {
				let most = 0;
				while (matchesItem(at(text, i + most), item)) { most += 1; }
				const least = quantifier == "+".code ? 1 : 0;
				for (let count = most; count >= least; count--) {
					if (matchesFrom(text, i + count, pattern, end + 1)) { return true; }
				}
				return false;
			},
			"-".code => {
				while (!matchesFrom(text, i, pattern, end + 1)) {
					if (!matchesItem(at(text, i), item)) { return false; }
					i += 1;
				}
				return true;
			},
			_ => {
				if (!matchesItem(at(text, i), item)) { return false; }
				i += 1;
				k = end;
			},
		};
	}
	return true;
}

export function luaMatches(text: string, pattern: string): boolean {
	const bytes = text.asBytes();
	const items = pattern.asBytes();
	const anchored = at(items, 0) == "^".code;
	for (let start = 0; start <= bytes.length; start++) {
		if (matchesFrom(bytes, start, items, anchored ? 1 : 0)) { return true; }
		if (anchored) { return false; }
	}
	return false;
}

test "anchors, classes and sets" {
	assert luaMatches("Foo", "^[A-Z]");
	assert !luaMatches("foo", "^[A-Z]");
	assert luaMatches("MAX_SIZE2", "^_*[A-Z][A-Z%d_]*$");
	assert luaMatches("__A", "^_*[A-Z][A-Z%d_]*$");
	assert !luaMatches("MaxSize", "^_*[A-Z][A-Z%d_]*$");
	assert luaMatches("onMount", "^on[A-Z]");
	assert !luaMatches("only", "^on[A-Z]");
	assert luaMatches("xx12", "%d+$");
	assert luaMatches("a.b", "a%.b");
	assert !luaMatches("axb", "a%.b");
}

test "every class letter, its upper-case negation and an escaped literal" {
	assert luaMatches("aZ", "^%a%a$");
	assert !luaMatches("1", "%a");
	assert luaMatches("09", "^%d%d$");
	assert luaMatches("x", "^%D$");
	assert !luaMatches("5", "^%D$");
	assert luaMatches("q", "^%l$");
	assert !luaMatches("Q", "^%l$");
	assert luaMatches("Q", "^%u$");
	assert luaMatches("q", "^%U$");
	assert luaMatches(" \t\r\n", "^%s+$");
	assert !luaMatches("x", "%s");
	assert luaMatches("a1", "^%w%w$");
	assert !luaMatches("_", "^%w$");
	assert luaMatches("fF9", "^%x+$");
	assert !luaMatches("g", "^%x$");
	assert luaMatches("!_~", "^%p+$");
	assert !luaMatches("a", "^%p$");
	assert luaMatches("\t", "^%c$");
	assert !luaMatches(" ", "^%c$");
	assert luaMatches("%-", "^%%%-$");
	assert luaMatches("[x]", "^%[[%a]%]$");
}

test "a set may open with a bracket, escaped or not" {
	assert luaMatches("]", "^[%]]$");
	assert !luaMatches("]]", "^[%]]$");
	assert luaMatches("]", "^[]]$");
	assert luaMatches("a", "^[^]]$");
	assert !luaMatches("]", "^[^]]$");
}

test "greedy, lazy and optional repeats" {
	assert luaMatches("/** doc */", "^/[*][*][^*].*[*]/$");
	assert !luaMatches("/* note */", "^/[*][*][^*].*[*]/$");
	assert !luaMatches("/***/", "^/[*][*][^*].*[*]/$");
	assert luaMatches("ab", "^a-b$");
	assert luaMatches("colour", "^colou?r$");
	assert luaMatches("color", "^colou?r$");
	assert !luaMatches("x", "^%a%a");
}

test "an unsupported item is refused by name" {
	let refused = 0;
	try { const _m = luaMatches("x", "%b()"); } catch (e) { refused += 1; }
	try { const _n = luaMatches("x", "(x)"); } catch (e) { refused += 1; }
	assert refused == 2;
}
