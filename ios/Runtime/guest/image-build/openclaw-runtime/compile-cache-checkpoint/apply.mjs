import { readFileSync, writeFileSync } from 'node:fs';
import { transform } from './transform.mjs';

const [input, output, ...extra] = process.argv.slice(2);
if (!input || !output || extra.length) throw new Error('Usage: node apply.mjs INPUT_JS NEW_OUTPUT_JS');
// Write only a new staged file; never overwrite the source or an existing output.
const result = transform(readFileSync(input, 'utf8'));
writeFileSync(output, result, { flag: 'wx', mode: 0o600 });
console.log('COMPILE_CACHE_CHECKPOINT_WRITTEN');
