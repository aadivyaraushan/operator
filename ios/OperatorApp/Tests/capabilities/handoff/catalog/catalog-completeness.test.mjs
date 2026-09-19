import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../../../../../../");
const source = fs.readFileSync(path.join(root, "companion/internal/capability/adapters/deeplink/adapter.go"), "utf8");
const catalog = JSON.parse(fs.readFileSync(path.join(root, "ios/OperatorApp/Resources/connections/handoff/android-handoff-catalog.json"), "utf8"));

const sourceIds = [...source.matchAll(/\{ID:\s*"([^"]+)"/g)].map((match) => match[1]);
const catalogIds = catalog.map((row) => row.id);
const sortedUnique = (ids) => [...new Set(ids)].sort();
assert.deepEqual(sortedUnique(catalogIds), sortedUnique(sourceIds));
assert.equal(sourceIds.length, 84);
assert.equal(catalog.length, 84);
assert.equal(new Set(catalogIds).size, 84);

const expectedStates = {
  messages: "nativeHandled",
  whatsapp: "nativeHandled",
  discord: "excluded",
};
for (const row of catalog) {
  for (const key of ["id", "displayName", "url", "sourceURL", "verification", "provesOnly"]) assert.ok(key in row, `${row.id}: missing ${key}`);
  if (row.verification === "nativeHandled" || row.verification === "excluded") {
    assert.equal(row.url, null, `${row.id}: explicit non-URL state must have null URL`);
    assert.equal(expectedStates[row.id], row.verification, `${row.id}: unexpected explicit state`);
  } else {
    const url = new URL(row.url);
    assert.equal(url.protocol, "https:", `${row.id}: URL must use HTTPS`);
    assert.equal(url.username, "", `${row.id}: URL must not include user info`);
    assert.equal(url.password, "", `${row.id}: URL must not include user info`);
    assert.equal(url.search, "", `${row.id}: URL must not include a query`);
    assert.equal(url.hash, "", `${row.id}: URL must not include a fragment`);
  }
}
assert.equal(catalog.find((row) => row.id === "instagram"), undefined, "Instagram is separately excluded, not an Android Wave1 ID");
assert.equal(catalog.filter((row) => row.verification === "webOpenedOfficial").length, 74);
assert.equal(catalog.filter((row) => row.verification === "officialSearchVerified").length, 7);
assert.equal(catalog.filter((row) => row.verification === "officialDomainUnchecked").length, 0);
console.log(`PASS: ${catalog.length} Wave1Specs IDs mapped; ${catalog.filter((row) => row.url).length} URL rows; explicit states=${Object.keys(expectedStates).length}`);
