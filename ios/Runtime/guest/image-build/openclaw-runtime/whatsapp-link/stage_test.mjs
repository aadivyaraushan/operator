import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import * as fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
const script=path.resolve('ios/Runtime/guest/image-build/openclaw-runtime/whatsapp-link/stage.sh');
function fixture() {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'operator-whatsapp-stage-'));
  const source=path.join(root,'source'), staging=path.join(root,'staging');
  fs.mkdirSync(source);fs.mkdirSync(staging);
  fs.writeFileSync(path.join(source,'package.json'),JSON.stringify({name:'operator-iphone-whatsapp-link',type:'module',openclaw:{extensions:['./index.js']}}));
  fs.writeFileSync(path.join(source,'openclaw.plugin.json'),JSON.stringify({id:'operator-iphone-whatsapp-link',configSchema:{type:'object',properties:{},additionalProperties:false}}));
  fs.writeFileSync(path.join(source,'index.js'),'export default { id: "operator-iphone-whatsapp-link", register(api) {} };\n');
  fs.mkdirSync(path.join(source,'runtime'));fs.writeFileSync(path.join(source,'runtime/service.js'),'export const service = true;\n');
  return {root,source,staging,destination:path.join(staging,'usr/local/share/openclaw-plugins/operator-iphone-whatsapp-link')};
}
const run=f=>execFileSync('/bin/sh',[script,f.source,f.staging],{env:{PATH:path.dirname(process.execPath)+':/usr/bin:/bin'},stdio:['ignore','pipe','pipe']});
test('iPhone staging includes exact plugin bytes and read-only code permissions',()=>{
  const f=fixture();try {
    run(f);
    for(const file of ['package.json','openclaw.plugin.json','index.js','runtime/service.js']) {
      assert(fs.readFileSync(path.join(f.source,file)).equals(fs.readFileSync(path.join(f.destination,file))));
      assert.equal(fs.statSync(path.join(f.destination,file)).mode&0o777,0o644);
    }
    assert.equal(fs.statSync(f.destination).mode&0o777,0o755);
    assert.throws(()=>run(f));
    assert(fs.readFileSync(path.join(f.source,'index.js')).equals(fs.readFileSync(path.join(f.destination,'index.js'))));
  }finally{fs.rmSync(f.root,{recursive:true,force:true});}
});
test('missing or mismatched plugin is rejected before creating a staged package',()=>{
  for(const problem of ['missing','wrong-id','missing-schema']) {
    const f=fixture();try {
      if(problem==='missing')fs.unlinkSync(path.join(f.source,'index.js'));
      else fs.writeFileSync(path.join(f.source,'openclaw.plugin.json'),JSON.stringify({id:problem==='wrong-id'?'wrong-plugin':'operator-iphone-whatsapp-link'}));
      assert.throws(()=>run(f),error=>error.status===(problem==='missing'?66:65));assert.equal(fs.existsSync(f.destination),false);
    }finally{fs.rmSync(f.root,{recursive:true,force:true});}
  }
});
test('production archive staging invokes the iPhone plugin staging step',()=>{
  const scripts=path.dirname(path.dirname(script));
  const restore=fs.readFileSync(path.join(scripts,'restore-workspace-templates.sh'),'utf8');
  const start=restore.indexOf('sh "$script_dir/whatsapp-link/stage.sh"');
  const end=restore.indexOf('(cd "$staging_root" && tar',start);
  assert(start>=0&&end>start,'production archive omits iPhone plugin');
  const f=fixture();try {
    execFileSync('/bin/sh',['-eu','-c','script_dir=$1; staging_root=$2\n'+restore.slice(start,end),'stage-hook',scripts,f.staging],{env:{PATH:path.dirname(process.execPath)+':/usr/bin:/bin'}});
    assert(fs.existsSync(path.join(f.destination,'index.js')));
    execFileSync(process.execPath,['--input-type=module','-e','const m=await import(process.argv[1]);if(typeof m.default.register!=="function")process.exit(1)',path.join(f.destination,'index.js')]);
  }finally{fs.rmSync(f.root,{recursive:true,force:true});}
});
test('fresh iPhone configuration explicitly loads the plugin without restricting Codex',()=>{
  const provision=fs.readFileSync(path.resolve('ios/Runtime/guest/first-boot/provision-guest.sh'),'utf8');
  const match=provision.match(/printf '%s\\n' '(\{"gateway"[^'\n]+)'/);
  assert(match,'missing first-boot config');
  const config=JSON.parse(match[1]);
  assert(config.plugins?.load?.paths?.includes('/usr/local/share/openclaw-plugins/operator-iphone-whatsapp-link'),'plugin is not loaded');
  assert.equal(config.plugins.entries['operator-iphone-whatsapp-link'].enabled,true);
  assert.equal(config.plugins.allow,undefined,'fresh setup must not exclude Codex');
  assert.equal(config.tools.exec.mode,'ask');assert.equal(config.tools.elevated.enabled,false);
});
