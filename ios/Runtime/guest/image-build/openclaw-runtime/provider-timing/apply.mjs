import { readFileSync, writeFileSync } from 'node:fs';
import { transform } from './transform.mjs';

const [input, output, ...extra] = process.argv.slice(2);
if (!input || !output || extra.length) throw new Error('Usage: node apply.mjs INPUT_JS NEW_OUTPUT_JS');
// Leave the input and any existing candidate untouched.
writeFileSync(output, transform(readFileSync(input, 'utf8')), { flag: 'wx', mode: 0o600 });
console.log('PROVIDER_TIMING_CANDIDATE_WRITTEN');
