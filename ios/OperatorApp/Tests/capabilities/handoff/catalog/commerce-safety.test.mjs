import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// The iPhone half of the two commerce guards in
// companion/internal/capability/adapters/deeplink/commerce_guard_test.go.
//
// The Go side stops a prohibited app entering Wave1Specs. That is most of the
// job, because catalog-completeness.test.mjs already pins the two ID sets to
// each other, so an app absent from Go cannot be present here. What it does
// not cover is the part of a catalog row Go has no opinion about: the URL.
// A destination is a string typed into JSON, and "open Target" and "open
// Target's checkout page with a saved card" are the same length.
//
// The prohibited list is read out of the Go test rather than copied, for the
// same reason catalog-completeness reads Wave1Specs out of adapter.go: two
// hand-maintained copies of one rule is one copy and one lie waiting.

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../../../../../../");
const catalogPath = path.join(root, "ios/OperatorApp/Resources/connections/handoff/android-handoff-catalog.json");
const guardPath = path.join(root, "companion/internal/capability/adapters/deeplink/commerce_guard_test.go");

const catalog = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
const guardSource = fs.readFileSync(guardPath, "utf8");

const block = guardSource.match(/var prohibitedApps = map\[string\]string\{([\s\S]*?)\n\}/);
assert.ok(block, "could not find prohibitedApps in the Go guard; this test now checks nothing");
const prohibited = [...block[1].matchAll(/^\s*"([a-z0-9]+)":/gm)].map((m) => m[1]);
assert.ok(prohibited.length > 0, "parsed an empty prohibited list; the regex has drifted from the Go source");
assert.ok(prohibited.includes("amazon"), "amazon missing from the parsed list; the parse is wrong or the ban was removed");

for (const row of catalog) {
  assert.ok(
    !prohibited.includes(String(row.id).toLowerCase()),
    `${row.id}: prohibited service present in the iPhone hand-off catalog`,
  );
}

// A destination may name a service. It may not name a way to spend money at
// that service. The existing completeness test already forbids a query and a
// fragment, which is what stops a product, a quantity or a one-click token
// being encoded; this forbids the other half, where the path itself is the
// purchase.
const commercePath = /(^|\/)(cart|carts|basket|checkout|check-out|buy|buynow|order|orders|purchase|pay|payment|payments|billing|subscribe|gp\/buy)(\/|$)/i;

for (const row of catalog) {
  if (!row.url) continue;
  const url = new URL(row.url);
  assert.ok(
    !commercePath.test(url.pathname),
    `${row.id}: destination path ${url.pathname} looks like a commerce endpoint; a hand-off opens a service, it does not open a checkout`,
  );
  // Restated rather than assumed. If catalog-completeness is ever relaxed,
  // this file must still refuse a destination carrying a cart in its query.
  assert.equal(url.search, "", `${row.id}: destination must not carry a query`);
  assert.equal(url.hash, "", `${row.id}: destination must not carry a fragment`);
  assert.equal(url.protocol, "https:", `${row.id}: destination must use HTTPS`);
}

console.log(
  `PASS: ${catalog.length} rows checked against ${prohibited.length} prohibited services ` +
    `(${prohibited.join(", ")}) and the commerce-path rule`,
);
