import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// ios/Operator.xcodeproj is checked in, and it enumerates every source file
// by hand-assigned hex id in four separate places. project.yml would
// generate all of that from a directory path, but the generated project is
// what actually builds, and XcodeGen is not a dependency anyone is required
// to have installed.
//
// So the failure mode is silent and specific: add a .swift file, forget the
// project, and it compiles in every SwiftPM fixture suite while being absent
// from the app. Nothing catches that until someone calls the missing type on
// a device.
//
// This is the cheap half of the guard — it needs no Xcode, so it runs
// anywhere, including a machine with only Command Line Tools.

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../../../../");
const projectPath = path.join(root, "ios/Operator.xcodeproj/project.pbxproj");
const sourcesRoot = path.join(root, "ios/OperatorApp/Sources");

const project = fs.readFileSync(projectPath, "utf8");

const walk = (dir) =>
  fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? walk(full) : [full];
  });

const compiled = walk(sourcesRoot).filter((file) => /\.(swift|mm|c)$/.test(file));
assert.ok(compiled.length > 0, "found no compilable sources; this test would pass by finding nothing");

// Basenames are the join key. Verified unique across the tree below, because
// a duplicate would let one file vouch for another.
const basenames = compiled.map((file) => path.basename(file));
const duplicates = basenames.filter((name, index) => basenames.indexOf(name) !== index);
assert.deepEqual(duplicates, [], `duplicate source basenames make this check unsound: ${duplicates}`);

const missingReference = [];
const missingBuildFile = [];
for (const name of basenames) {
  // A PBXFileReference for this file, in either style the project uses:
  // a group-relative bare path, or a SOURCE_ROOT path from the repo root.
  const referenced =
    new RegExp(`path = ${escape(name)};`).test(project) ||
    new RegExp(`path = [^;]*/${escape(name)};`).test(project);
  if (!referenced) {
    missingReference.push(name);
    continue;
  }
  // And a PBXBuildFile putting it in a Sources phase. Without this the file
  // is visible in Xcode's navigator and never compiled, which is the
  // failure that looks most like success.
  if (!new RegExp(`${escape(name)} in Sources`).test(project)) missingBuildFile.push(name);
}

assert.deepEqual(
  missingReference,
  [],
  `source files absent from ios/Operator.xcodeproj entirely: ${missingReference.join(", ")}`,
);
assert.deepEqual(
  missingBuildFile,
  [],
  `source files referenced but never compiled (no "in Sources" build file): ${missingBuildFile.join(", ")}`,
);

function escape(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

console.log(`PASS: all ${compiled.length} compilable sources are referenced and compiled by the checked-in project`);
