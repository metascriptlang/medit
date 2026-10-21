const BASE_DISTANCE_PENALTY: float64 = 0.6;
const ADDITIONAL_DISTANCE_PENALTY: float64 = 0.05;
const MIN_DISTANCE_PENALTY: float64 = 0.2;
const CASE_MISMATCH_PENALTY: float64 = 0.001;
const UNSCORED: float64 = -1;

export struct FuzzyMatch {
	score: float64;
	positions: int32[];
}

export struct Chars {
	text: string[];
	at: int32[];
}

function charLength(lead: int32): int32 {
	if (lead < 0x80) { return 1; }
	if (lead < 0xe0) { return 2; }
	if (lead < 0xf0) { return 3; }
	return 4;
}

export function charsOf(s: string): Chars {
	const text: string[] = [];
	const at: int32[] = [];
	let k = 0;
	const n = s.byteLength as int32;
	while (k < n) {
		const end = Math.min(n, k + charLength(s.byteAt(k)));
		text.push(s.byteSlice(k, end));
		at.push(k);
		k = end;
	}
	return { text, at };
}

export function lowered(c: string): string {
	const lower = c.toLowerCase();
	return lower == c ? c : charsOf(lower).text[0];
}

export function isUpper(c: string): boolean {
	return c.toUpperCase() == c && c.toLowerCase() != c;
}

export function isLower(c: string): boolean {
	return c.toLowerCase() == c && c.toUpperCase() != c;
}

export function isDigit(c: string): boolean {
	return c.byteLength == 1 && c.byteAt(0) >= "0".code && c.byteAt(0) <= "9".code;
}

function charScore(last: string, curr: string, j: int32, from: int32, first: boolean): float64 {
	if (last == "/") { return 0.9; }
	if (last == "-" || last == "_" || last == " " || isDigit(last) || (isLower(last) && isUpper(curr))) { return 0.8; }
	if (last == ".") { return 0.7; }
	if (first) { return BASE_DISTANCE_PENALTY; }
	return Math.max(MIN_DISTANCE_PENALTY, BASE_DISTANCE_PENALTY - (j - from - 1) * ADDITIONAL_DISTANCE_PENALTY);
}

class Scorer {
	private query: string[];
	private lowerQuery: string[];
	private chars: string[];
	private lowerChars: string[];
	private smartCase: boolean;
	private last: int32[];
	private memo: float64[] = [];
	best: int32[] = [];

	constructor(query: string[], lowerQuery: string[], chars: string[], lowerChars: string[], smartCase: boolean, last: int32[]) {
		this.query = query;
		this.lowerQuery = lowerQuery;
		this.chars = chars;
		this.lowerChars = lowerChars;
		this.smartCase = smartCase;
		this.last = last;
		const cells = query.length * chars.length;
		for (let i = 0; i < cells; i++) {
			this.memo.push(UNSCORED);
			this.best.push(0);
		}
	}

	score(qi: int32, from: int32): float64 {
		if (qi == (this.query.length as int32)) { return 1; }
		const limit = Math.min(this.last[qi], (this.chars.length as int32) - 1);
		if (from > limit) { return 0; }
		const cell = qi * (this.chars.length as int32) + from;
		if (this.memo[cell] != UNSCORED) { return this.memo[cell]; }
		let score: float64 = 0;
		let best = 0;
		const want = this.lowerQuery[qi];
		for (let j = from; j <= limit; j++) {
			const have = this.lowerChars[j];
			const separator = have == "/";
			if (want != have && !(separator && want == "_")) { continue; }
			const curr = this.chars[j];
			let multiplier: float64 = j > from ? charScore(this.chars[j - 1], curr, j, from, qi == 0) : 1;
			if ((this.smartCase || curr == "/") && this.query[qi] != curr) { multiplier *= CASE_MISMATCH_PENALTY; }
			const next = this.score(qi + 1, j + 1) * multiplier;
			if (next > score) {
				score = next;
				best = j;
				if (next == 1) { break; }
			}
		}
		if (best != 0) { this.best[cell] = best; }
		this.memo[cell] = score;
		return score;
	}
}

export function fuzzyMatch(query: string, candidate: string, smartCase: boolean): FuzzyMatch | null {
	if (query.byteLength == 0) { return { score: 0, positions: [] }; }
	const q = charsOf(query).text;
	const lowerQuery = q.map((c: string): string => lowered(c));
	const c = charsOf(candidate);
	const lowerChars = c.text.map((ch: string): string => lowered(ch));
	const last: int32[] = q.map((_: string): int32 => 0);
	let end = lowerChars.length as int32;
	for (let i = (q.length as int32) - 1; i >= 0; i--) {
		let j = end - 1;
		while (j >= 0 && lowerChars[j] != lowerQuery[i]) { j--; }
		if (j < 0) { return null; }
		last[i] = j;
		end = j;
	}
	const scorer = new Scorer(q, lowerQuery, c.text, lowerChars, smartCase, last);
	const score = scorer.score(0, 0) * q.length;
	if (score <= 0) { return null; }
	const positions: int32[] = [];
	let from = 0;
	for (let i = 0; i < (q.length as int32); i++) {
		const j = scorer.best[i * (c.text.length as int32) + from];
		positions.push(c.at[j]);
		from = j + 1;
	}
	return { score, positions };
}

test "a query matches its characters in order, scoring a prefix above a scattered match" {
	const prefix = fuzzyMatch("con", "console", false) as FuzzyMatch;
	assert prefix.score == 3;
	assert prefix.positions.length == 3 && prefix.positions[0] == 0 && prefix.positions[2] == 2;
	const scattered = fuzzyMatch("cnl", "console", false) as FuzzyMatch;
	assert scattered.score < prefix.score;
	assert scattered.positions[1] == 2 && scattered.positions[2] == 5;
	assert fuzzyMatch("xyz", "console", false) === null;
	assert fuzzyMatch("lc", "console", false) === null;
}

test "a word start after an underscore or a case change scores above the middle of a word" {
	const boundary = fuzzyMatch("gv", "getValue", false) as FuzzyMatch;
	const middle = fuzzyMatch("gv", "giveaway", false) as FuzzyMatch;
	assert boundary.score > middle.score;
	assert boundary.positions[1] == 3;
	const snake = fuzzyMatch("gv", "get_value", false) as FuzzyMatch;
	assert snake.positions[1] == 4 && snake.score == boundary.score;
}

test "smart case penalizes a case mismatch, and positions are bytes" {
	const exact = fuzzyMatch("Fo", "Foo", true) as FuzzyMatch;
	const folded = fuzzyMatch("Fo", "foo", true) as FuzzyMatch;
	assert exact.score > folded.score * 100;
	assert (fuzzyMatch("fo", "Foo", false) as FuzzyMatch).score == 2;
	const wide = fuzzyMatch("éb", "aébc", false) as FuzzyMatch;
	assert wide.positions[0] == 1 && wide.positions[1] == 3;
	assert fuzzyMatch("", "anything", true) !== null;
}
