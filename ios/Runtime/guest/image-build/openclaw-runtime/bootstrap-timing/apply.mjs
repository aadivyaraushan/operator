import { readFileSync, writeFileSync } from 'node:fs';
import { transform } from './transform.mjs';

const [input, output, ...extra] = process.argv.slice(2);
if (!input || !output || extra.length) throw new Error('Usage: node apply.mjs INPUT_JS NEW_OUTPUT_JS');
// Never replace an existing source or candidate; callers stage the new file.
const result = transform(readFileSync(input, 'utf8'));
writeFileSync(output, result, { flag: 'wx', mode: 0o600 });
console.log('BOOTSTRAP_TIMING_CANDIDATE_WRITTEN');
