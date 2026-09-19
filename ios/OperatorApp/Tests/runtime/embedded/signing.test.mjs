import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import test from 'node:test';

const ios = resolve(dirname(fileURLToPath(import.meta.url)), '../../../..');
const entitlementPath = 'OperatorApp/Sources/runtime/embedded/signing/Simulator.entitlements';
test('native Simulator signing has its own bundle-derived Keychain identity', () => {
  const entitlement = readFileSync(resolve(ios, entitlementPath), 'utf8');
  assert.match(entitlement, /<key>application-identifier<\/key>\s*<string>\$\(CFBundleIdentifier\)<\/string>/);
  assert.match(entitlement, /<key>keychain-access-groups<\/key>\s*<array>\s*<string>\$\(CFBundleIdentifier\)<\/string>/);
  const project = readFileSync(resolve(ios, 'Operator.xcodeproj/project.pbxproj'), 'utf8');
  assert.equal(project.split(`"CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]" = ${entitlementPath};`).length - 1, 2,
    'Debug and Release must both include Simulator-only entitlements');
  // Debug and Release for the app, plus Debug and Release for OperatorAppUITests,
  // which also signs ad hoc on the Simulator. Only the app carries the entitlements.
  assert.equal(project.split('"CODE_SIGN_IDENTITY[sdk=iphonesimulator*]" = "-";').length - 1, 4);
  const definition = readFileSync(resolve(ios, 'project.yml'), 'utf8');
  assert.ok(definition.includes(`"CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]": ${entitlementPath}`));
});
