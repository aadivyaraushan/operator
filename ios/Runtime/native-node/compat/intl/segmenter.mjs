// A pure-JavaScript Intl.Segmenter for the embedded runtime.
//
// The pinned NodeMobile build (nodejs-mobile 24.18.0-0, see
// Runtime/DEPENDENCIES.md) ships ICU data whose break-iterator directory holds
// only res_index.res: no grapheme, word or sentence rules. V8 only DCHECKs
// that the constructor got a break iterator, so `new Intl.Segmenter()`
// succeeds and the first `.segment(text)` dereferences null
// (JSSegments::Create <- Builtin_SegmenterPrototypeSegment, EXC_BAD_ACCESS).
// OpenClaw segments the model's reply text on every turn, so the app died on
// the first reply that reached that code - reproduced four times by the
// connector QA runs of 2026-09-15 (saved-results/connector-qa/runs/*/crash-*.ips).
//
// This module replaces Intl.Segmenter with an implementation of the same
// surface that follows UAX #29 closely enough for what the runtime does with
// it (display width, chunking, mention matching). Known departures from ICU:
// no dictionary breaks for CJK and Thai (each Han character is its own word,
// kana runs stay together), no Indic conjunct clusters (GB9c), and the
// sentence rules are the core of UAX #29 without ICU's abbreviation lists.
// It is installed by entry.mjs before OpenClaw is imported.

const GRANULARITIES = new Set(['grapheme', 'word', 'sentence']);

// Grapheme_Extend, Emoji_Modifier, variation selectors, ZWNJ/ZWJ and emoji
// tag characters: everything GB9/GB9a glue onto the preceding cluster.
const EXT = String.raw`(?:\p{M}|\p{Emoji_Modifier}|[\u200C\u200D\uFE0E\uFE0F]|[\u{E0020}-\u{E007F}])`;
// The same set without ZWJ, for the run before a ZWJ-joined emoji: a greedy
// run that could swallow the joiner would succeed without ever trying it.
const EXTN = String.raw`(?:\p{M}|\p{Emoji_Modifier}|[\u200C\uFE0E\uFE0F]|[\u{E0020}-\u{E007F}])`;
// One emoji, including modifiers, keycaps and ZWJ sequences (GB11).
const PICTO = String.raw`\p{Extended_Pictographic}${EXTN}*(?:\u200D\p{Extended_Pictographic}${EXTN}*)*${EXT}*`;
const FLAG = String.raw`\p{Regional_Indicator}{2}`;
const HANGUL = String.raw`[\u1100-\u115F\uA960-\uA97F]*(?:[\uAC00-\uD7A3]|[\u1160-\u11A7\uD7B0-\uD7C6]+)[\u11A8-\u11FF\uD7CB-\uD7FB]*`;

const GRAPHEME = new RegExp(
  [String.raw`\r\n`, FLAG, PICTO, HANGUL + EXT + '*', String.raw`\P{M}${EXT}*`, `${EXT}+`, String.raw`[\s\S]`].join('|'),
  'gu');

// Word letters: letters, digits and connectors, minus the scripts ICU breaks
// with a dictionary, which get their own branch below.
const W = String.raw`(?:(?![\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}])[\p{L}\p{N}\p{Pc}])`;
const WORD_RUN = String.raw`${W}(?:${EXT}|${W}|[.'\u2018\u2019\u2024\uFE52\uFF07\uFF0E](?=${W})|[:\u00B7\u0387\u05F4\u2027\uFE13\uFE55\uFF1A](?=\p{L})|[,;\u066C\uFE50\uFE54\uFF0C\uFF1B](?=\p{N}))*`;
const KANA_RUN = String.raw`(?:\p{Script=Hiragana}+|[\p{Script=Katakana}\u30FC]+)${EXT}*`;
const HAN = String.raw`\p{Script=Han}${EXT}*`;
const HSPACE = String.raw`[\t \u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]+`;
const WORD = new RegExp(
  [String.raw`\r\n`, HSPACE, FLAG, PICTO, WORD_RUN, KANA_RUN, HAN, String.raw`[\s\S]${EXT}*`].join('|'),
  'gu');
const WORD_LIKE = /^[\p{L}\p{N}\p{Pc}]/u;

const PARA = /[\n\r\v\f\u0085\u2028\u2029]/u;
const TERM = /[.!?\u2026\u203C\u2047-\u2049\u3002\uFE52\uFE56\uFE57\uFF01\uFF0E\uFF1F\uFF61]/u;
const ATERM = /[.\u2024\uFE52\uFF0E]/u;
const CLOSE = /[\p{Pe}\p{Pf}\p{Pi}"']/u;
const SPACE = /[\t \u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]/u;
const LOWER = /\p{Ll}/u;
const LETTER = /\p{L}/u;
const CONTINUE = /[,\-\u2013\u2014:;\u055D\u060C\u060D\u07F8\u1802\u1808\u2013\u3001\uFE10\uFE11\uFE13\uFE31\uFE50\uFE51\uFE55\uFE58\uFE63\uFF0C\uFF0D\uFF1A\uFF1B\uFF64]/u;

function graphemeSegments(text) {
  const out = [];
  for (const match of text.matchAll(GRAPHEME)) out.push({segment: match[0], index: match.index, input: text});
  return out;
}

function wordSegments(text) {
  const out = [];
  for (const match of text.matchAll(WORD)) {
    out.push({segment: match[0], index: match.index, input: text, isWordLike: WORD_LIKE.test(match[0])});
  }
  return out;
}

// UAX #29 sentence boundaries, rules SB3 to SB11, without ICU's tailoring.
function sentenceSegments(text) {
  const out = [];
  const chars = Array.from(text);
  let start = 0;
  let position = 0;
  let i = 0;
  const push = end => {
    const segment = chars.slice(start, end).join('');
    if (segment) out.push({segment, index: position, input: text});
    position += segment.length;
    start = end;
  };
  while (i < chars.length) {
    const c = chars[i];
    if (c === '\r' && chars[i + 1] === '\n') { i += 2; push(i); continue; }
    if (PARA.test(c)) { i += 1; push(i); continue; }
    if (!TERM.test(c)) { i += 1; continue; }
    let onlyATerm = true;
    let j = i;
    while (j < chars.length && TERM.test(chars[j])) { if (!ATERM.test(chars[j])) onlyATerm = false; j += 1; }
    while (j < chars.length && CLOSE.test(chars[j])) j += 1;
    let k = j;
    while (k < chars.length && SPACE.test(chars[k])) k += 1;
    if (k >= chars.length) { i = k; break; }
    if (chars[k] === '\r' && chars[k + 1] === '\n') { i = k + 2; push(i); continue; }
    if (PARA.test(chars[k])) { i = k + 1; push(i); continue; }
    // SB8a: a continuation mark or another terminator keeps the sentence going.
    if (CONTINUE.test(chars[k]) || TERM.test(chars[k])) { i = k; continue; }
    if (onlyATerm) {
      // SB6/SB7/SB8: a full stop followed by a digit, an upper-case letter
      // with no space, or a lower-case letter anywhere before the next letter,
      // does not end the sentence ("3.14", "U.S", "e.g. this").
      let m = k;
      while (m < chars.length && !LETTER.test(chars[m]) && !PARA.test(chars[m]) && !TERM.test(chars[m])) m += 1;
      const next = chars[m];
      if (k === j && (next === undefined || !PARA.test(next) && !TERM.test(next))) { i = k; continue; }
      if (next !== undefined && LOWER.test(next)) { i = k; continue; }
    }
    i = k;
    push(k);
  }
  push(chars.length);
  return out;
}

function defaultLocale() {
  try { return new Intl.DateTimeFormat().resolvedOptions().locale; } catch { return 'en'; }
}

function canonicalLocales(locales) {
  if (locales === undefined) return [];
  try { return Intl.getCanonicalLocales(locales); } catch (error) {
    if (error instanceof RangeError || error instanceof TypeError) throw error;
    return Array.isArray(locales) ? locales.map(String) : [String(locales)];
  }
}

class Segments {
  #segments;
  #input;
  constructor(input, segments) { this.#input = input; this.#segments = segments; }
  containing(index = 0) {
    const n = Number(index);
    const at = Number.isNaN(n) ? 0 : Math.trunc(n);
    if (at < 0 || at >= this.#input.length) return undefined;
    // Segments are contiguous and sorted, so the answer is the last one that
    // starts at or before the index.
    let low = 0;
    let high = this.#segments.length - 1;
    while (low < high) {
      const mid = (low + high + 1) >> 1;
      if (this.#segments[mid].index <= at) low = mid; else high = mid - 1;
    }
    return {...this.#segments[low]};
  }
  [Symbol.iterator]() {
    const segments = this.#segments;
    let i = 0;
    return {
      next: () => (i < segments.length ? {value: {...segments[i++]}, done: false} : {value: undefined, done: true}),
      [Symbol.iterator]() { return this; },
    };
  }
}

export class SegmenterFallback {
  #locale;
  #granularity;
  constructor(locales = undefined, options = undefined) {
    if (options !== undefined && (options === null || typeof options !== 'object')) throw new TypeError('options must be an object');
    const requested = canonicalLocales(locales);
    const granularity = options?.granularity === undefined ? 'grapheme' : String(options.granularity);
    if (!GRANULARITIES.has(granularity)) throw new RangeError(`Value ${granularity} out of range for Intl.Segmenter options property granularity`);
    const matcher = options?.localeMatcher === undefined ? 'best fit' : String(options.localeMatcher);
    if (matcher !== 'lookup' && matcher !== 'best fit') throw new RangeError(`Value ${matcher} out of range for Intl.Segmenter options property localeMatcher`);
    this.#locale = requested[0] ?? defaultLocale();
    this.#granularity = granularity;
  }
  segment(input) {
    const text = String(input);
    const segments = this.#granularity === 'grapheme' ? graphemeSegments(text)
      : this.#granularity === 'word' ? wordSegments(text) : sentenceSegments(text);
    return new Segments(text, segments);
  }
  resolvedOptions() { return {locale: this.#locale, granularity: this.#granularity}; }
  static supportedLocalesOf(locales) { return canonicalLocales(locales); }
  get [Symbol.toStringTag]() { return 'Intl.Segmenter'; }
}

/// Replaces Intl.Segmenter on `intl` (the global Intl by default). Returns the
/// implementation that was there, so a caller can put it back.
export function installSegmenterFallback(intl = globalThis.Intl) {
  const previous = intl.Segmenter;
  Object.defineProperty(intl, 'Segmenter', {value: SegmenterFallback, writable: true, configurable: true, enumerable: false});
  return previous;
}
