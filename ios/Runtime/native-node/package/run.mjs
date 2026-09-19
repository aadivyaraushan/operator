import {stageRuntime} from './stage.mjs';
const [source, output] = process.argv.slice(2);
if (!source || !output) throw new Error('Usage: node run.mjs public-openclaw-package new-output-directory');
stageRuntime(source, output);
process.stdout.write('NATIVE_RUNTIME_PACKAGE_PASS\n');
