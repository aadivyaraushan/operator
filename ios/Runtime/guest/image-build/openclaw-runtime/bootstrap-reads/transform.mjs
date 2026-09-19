// Preserve guarded file reads and result order while overlapping independent I/O.
const before = `\tconst result = [];
\tfor (const entry of entries) {
\t\tif ((entry.name === DEFAULT_MEMORY_FILENAME || entry.name === "USER.md") && !await exactWorkspaceEntryExists(resolvedDir, entry.name)) continue;
\t\tconst loaded = await readWorkspaceFileWithGuards({
\t\t\tfilePath: entry.filePath,
\t\t\tworkspaceDir: resolvedDir
\t\t});`;
const after = `\tconst loadedEntries = await Promise.all(entries.map(async (entry) => {
\t\tif ((entry.name === DEFAULT_MEMORY_FILENAME || entry.name === "USER.md") && !await exactWorkspaceEntryExists(resolvedDir, entry.name)) return { entry };
\t\tconst loaded = await readWorkspaceFileWithGuards({
\t\t\tfilePath: entry.filePath,
\t\t\tworkspaceDir: resolvedDir
\t\t});
\t\treturn { entry, loaded };
\t}));
\tconst result = [];
\tfor (const { entry, loaded } of loadedEntries) {
\t\tif (!loaded) continue;`;

export function parallelizeBootstrapReads(source) {
 if (source.split(before).length !== 2) throw new Error('Expected one pinned sequential bootstrap-read block; runtime left unchanged');
 return source.replace(before, after);
}
