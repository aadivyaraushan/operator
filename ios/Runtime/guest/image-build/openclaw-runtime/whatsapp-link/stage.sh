#!/bin/sh
# Include the app-owned iPhone plugin without modifying the official Codex project.
set -eu
source_dir=$1
staging_root=$2
destination=$staging_root/usr/local/share/openclaw-plugins/operator-iphone-whatsapp-link
for file in package.json openclaw.plugin.json index.js; do
  test -f "$source_dir/$file" && test ! -L "$source_dir/$file" || {
    printf '[whatsapp-link] required plugin file missing or linked: %s\n' "$file" >&2
    exit 66
  }
done
test ! -e "$destination" || {
  printf '[whatsapp-link] refusing to replace staged plugin\n' >&2
  exit 67
}
node -e '
const fs=require("node:fs"),path=require("node:path");
const root=process.argv[1],id="operator-iphone-whatsapp-link";
try {
 const pkg=JSON.parse(fs.readFileSync(path.join(root,"package.json")));
 const manifest=JSON.parse(fs.readFileSync(path.join(root,"openclaw.plugin.json")));
 if(pkg.name!==id || pkg.type!=="module" || JSON.stringify(pkg.openclaw?.extensions)!==JSON.stringify(["./index.js"]) || manifest.id!==id || manifest.configSchema?.type!=="object")throw Error();
 function check(directory) { for(const entry of fs.readdirSync(directory,{withFileTypes:true})) {
   const file=path.join(directory,entry.name);
   if(entry.isDirectory())check(file);else if(!entry.isFile())throw Error();
 } }
 check(root);
} catch { console.error("[whatsapp-link] invalid plugin package or descriptor");process.exit(65); }
' "$source_dir"
node --check "$source_dir/index.js" >/dev/null
install -d -m 0755 "$destination"
cp -R "$source_dir/." "$destination/"
find "$destination" -type d -exec chmod 0755 {} +
find "$destination" -type f -exec chmod 0644 {} +
printf '[whatsapp-link] staged iPhone plugin\n'
