import assert from 'node:assert/strict';
import {test} from 'node:test';
import {SegmenterFallback, installSegmenterFallback} from '../segmenter.mjs';

// Desktop Node carries full ICU, so the native Intl.Segmenter is the oracle
// here. Inside NodeMobile there is no oracle: calling it crashes the process.
const Native = Intl.Segmenter;
assert.ok(Native, 'these tests need a Node with full ICU');

const list = (Segmenter, text, granularity) => [...new Segmenter('en', {granularity}).segment(text)];
const same = (text, granularity) => {
  const expected = list(Native, text, granularity).map(s => [s.segment, s.index, ...(granularity === 'word' ? [s.isWordLike] : [])]);
  const actual = list(SegmenterFallback, text, granularity).map(s => [s.segment, s.index, ...(granularity === 'word' ? [s.isWordLike] : [])]);
  assert.deepEqual(actual, expected, `${granularity}: ${JSON.stringify(text)}`);
};

// The reply that crashed the Simulator app four times, and the emoji shapes
// that matter for width and mention matching.
const graphemeCorpus = [
  '🍂✨ Discover SMU this Fall – Special Transfer Specific Visits',
  'No, nothing new since the last check 🍂✨ still the SMU one',
  '👨‍👩‍👧‍👦 family 👍🏽 thumbs 🏴󠁧󠁢󠁥󠁮󠁧󠁿 flag 🇺🇸🇬🇧 pair',
  '#️⃣ keycap 1️⃣ é combining é precomposed',
  'line\r\nbreak\nlone\rcr',
  '한글 and 각 and 각 jamo',
  'плохо ないよ 日本語',
  '', 'a', '\uD83D', 'x\uDE00y',
];

test('grapheme clusters match ICU on emoji, marks, flags, jamo and newlines', () => {
  for (const text of graphemeCorpus) same(text, 'grapheme');
});

test('word segments match ICU on Latin prose, numbers, contractions and punctuation', () => {
  for (const text of [
    "Hello, world! It's 3.14 or 1,000 e.g. U.S.A. ok",
    'well-known foo_bar abc123 10:30 a:b @claude #tag',
    'two  spaces\ttab\nnewline\r\ncrlf end',
    '🍂✨ Discover SMU this Fall – Special Transfer Specific Visits',
    '👨‍👩‍👧‍👦 family 🇺🇸 flag',
    'наш дом; ¿qué tal? ¡hola!',
    '', ' ', 'a',
  ]) same(text, 'word');
});

test('sentence segments match ICU on ordinary prose', () => {
  for (const text of [
    'Hello world. This is Operator! Is it? Yes. Done',
    'One sentence.',
    'Ends with space. ',
    'Abbrev e.g. is not a break. Next one.',
    'Wait... what happens? Nothing! Then "quoted." After',
    'Line one\nLine two\r\nLine three',
    'Pi is 3.14 and U.S. Army marches. ok',
    'no terminator at all',
    '',
  ]) same(text, 'sentence');
});

test('Han characters break one by one and kana runs stay together', () => {
  const words = list(SegmenterFallback, '日本語テキストとひらがな', 'word');
  // ICU's dictionary would also split と from ひらがな; the fallback keeps a kana run whole.
  assert.deepEqual(words.map(s => s.segment), ['日', '本', '語', 'テキスト', 'とひらがな']);
  assert.ok(words.every(s => s.isWordLike));
});

test('every granularity reassembles the input with contiguous indices', () => {
  const inputs = [...graphemeCorpus, 'á́‍́', '‍‍', 'x️️', '\r\n\r\n', '👍🏽🏽', '🇺🇸🇬', 'a.', '.', '?!', '...'];
  for (const text of inputs) {
    for (const granularity of ['grapheme', 'word', 'sentence']) {
      const segments = list(SegmenterFallback, text, granularity);
      assert.equal(segments.map(s => s.segment).join(''), text, `${granularity} ${JSON.stringify(text)}`);
      let index = 0;
      for (const s of segments) { assert.equal(s.index, index); assert.equal(s.input, text); assert.ok(s.segment.length > 0); index += s.segment.length; }
    }
  }
});

test('containing() agrees with ICU and returns undefined outside the input', () => {
  const text = 'Hi there 👨‍👩‍👧 friend. Bye!';
  for (const granularity of ['grapheme', 'word', 'sentence']) {
    const native = new Native('en', {granularity}).segment(text);
    const fallback = new SegmenterFallback('en', {granularity}).segment(text);
    for (let i = -1; i <= text.length; i += 1) {
      const expected = native.containing(i);
      const actual = fallback.containing(i);
      if (expected === undefined) { assert.equal(actual, undefined); continue; }
      assert.deepEqual([actual.segment, actual.index, actual.isWordLike], [expected.segment, expected.index, expected.isWordLike], `${granularity} at ${i}`);
    }
    assert.deepEqual(fallback.containing(), fallback.containing(0));
    assert.deepEqual(fallback.containing('1'), fallback.containing(1));
  }
});

test('constructor and options follow the Intl.Segmenter surface', () => {
  assert.equal(new SegmenterFallback().resolvedOptions().granularity, 'grapheme');
  assert.deepEqual(new SegmenterFallback('fr-FR', {granularity: 'word'}).resolvedOptions(), {locale: 'fr-FR', granularity: 'word'});
  assert.equal(new SegmenterFallback(undefined, {granularity: 'sentence'}).resolvedOptions().granularity, 'sentence');
  assert.throws(() => new SegmenterFallback('en', {granularity: 'line'}), RangeError);
  assert.throws(() => new SegmenterFallback('en', {localeMatcher: 'exact'}), RangeError);
  assert.throws(() => new SegmenterFallback('en', 'grapheme'), TypeError);
  assert.deepEqual(SegmenterFallback.supportedLocalesOf(['en-US', 'de']), ['en-US', 'de']);
  assert.equal(Object.prototype.toString.call(new SegmenterFallback()), '[object Intl.Segmenter]');
  assert.equal([...new SegmenterFallback().segment(12.5)].map(s => s.segment).join(''), '12.5');
  const iterator = new SegmenterFallback().segment('ab')[Symbol.iterator]();
  assert.equal(iterator[Symbol.iterator](), iterator);
  assert.deepEqual(iterator.next(), {value: {segment: 'a', index: 0, input: 'ab'}, done: false});
});

test('install replaces Intl.Segmenter non-enumerably and hands back the previous one', () => {
  const intl = {Segmenter: Native, other: 1};
  const previous = installSegmenterFallback(intl);
  assert.equal(previous, Native);
  assert.equal(intl.Segmenter, SegmenterFallback);
  assert.equal(Object.getOwnPropertyDescriptor(intl, 'Segmenter').enumerable, false);
  assert.ok(Object.getOwnPropertyDescriptor(intl, 'Segmenter').writable);
  // The way OpenClaw uses it, verbatim from the bundle: module-level
  // construction, then [...segmenter.segment(text)] on reply text.
  const segmenter = new intl.Segmenter(void 0, {granularity: 'grapheme'});
  assert.equal([...segmenter.segment('🍂✨ ok')].length, 5);
});
