import { createHash } from 'node:crypto';

const pinnedHash = 'a40d5a53bb2fcae45a272a1d997c270b4033926637c06db17e14257cf31c83fe';
const name = 'async function prepareEmbeddedAttemptBootstrap(params) {';
const replacements = [
  ['const resolveWorkspaceBootstrapFiles = (workspaceDir) => resolveBootstrapFilesForRun({', 'const resolveWorkspaceBootstrapFiles = async (workspaceDir) => {\n\t\tparams.markStage("bootstrap-files-start");\n\t\tconst result = await resolveBootstrapFilesForRun({'],
  ['\t\trunKind: attempt.bootstrapContextRunKind\n\t});', '\t\trunKind: attempt.bootstrapContextRunKind\n\t\t});\n\t\tparams.markStage("bootstrap-files-end");\n\t\treturn result;\n\t};'],
  ['const resolveBootstrapRouting = (bootstrapFiles) => resolveWorkspaceBootstrapRouting({', 'const resolveBootstrapRouting = async (bootstrapFiles) => {\n\t\tparams.markStage("bootstrap-routing-start");\n\t\tconst result = await resolveWorkspaceBootstrapRouting({'],
  ['\t\thasBootstrapFileAccess: params.hasReadTool\n\t});', '\t\thasBootstrapFileAccess: params.hasReadTool\n\t\t});\n\t\tparams.markStage("bootstrap-routing-end");\n\t\treturn result;\n\t};'],
];
const digest = s => createHash('sha256').update(s).digest('hex');
function replaceExactly(s, from, to) {
  if (s.split(from).length !== 2) throw new Error('Unsupported bootstrap timing source shape');
  return s.replace(from, to);
}
export function transform(source) {
  const start = source.indexOf(name);
  const end = source.indexOf('\n//#endregion', start);
  if (start < 0 || end < 0 || source.indexOf(name, start + 1) >= 0) throw new Error('Unsupported bootstrap timing function');
  const current = source.slice(start, end);
  if (digest(current) === pinnedHash) {
    const changed = replacements.reduce((s, [from, to]) => replaceExactly(s, from, to), current);
    return source.slice(0, start) + changed + source.slice(end);
  }
  // Only accept the exact transformed pinned function, not a marker substring.
  try {
    const original = replacements.reduce((s, [from, to]) => replaceExactly(s, to, from), current);
    if (digest(original) === pinnedHash) return source;
  } catch {}
  throw new Error('Unsupported bootstrap timing source; pinned function differs');
}
