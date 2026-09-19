import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync, readFileSync, writeFileSync, rmSync, chmodSync, statSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
const helper=readFileSync(new URL('../../guest/runtime-start/device-pairing/approve-app-device.mjs',import.meta.url),'utf8');
const launcher=readFileSync(new URL('../../guest/runtime-start/device-pairing/approve-app-device.sh',import.meta.url),'utf8');
const entry='file:///usr/local/lib/node_modules/openclaw/dist/plugin-sdk/device-bootstrap.js';
function run(scenario,signal='SIGTERM'){
 const dir=mkdtempSync(join(tmpdir(),'operator-pairing-sdk-'));
 try{
  assert.ok(helper.includes(entry));
  writeFileSync(join(dir,'helper.mjs'),helper.replace(entry,'./sdk.mjs'));
  writeFileSync(join(dir,'sdk.mjs'),`
   let approvals=0, calls=0;
   const identity={deviceId:'device',publicKey:'key'};
   const scenario=${JSON.stringify(scenario)};
   setTimeout(()=>process.kill(process.pid,${JSON.stringify(signal)}),scenario==='stale'?2200:150).unref();
   export async function listDevicePairing(){
    if(scenario==='error') throw new Error('test store unavailable');
    if(approvals && scenario!=='forbidden') return {pending:[],paired:[{...identity,roles:['operator','node']}]};
    const request={...identity,requestId:'request',role:'node',roles:['operator','node']};
    if(scenario==='foreign') request.publicKey='foreign';
    if(scenario==='invalid-role') request.roles.push('unknown');
    return {paired:scenario==='upgrade'?[{...identity,roles:['operator','node']}]:[],
      pending:scenario==='ambiguous'?[request,{...request,requestId:'second'}]:[request]};
   }
   export async function approveDevicePairing(id,options){
    console.log('APPROVE:'+id+':'+options.callerScopes.join(','));
    if(scenario==='stale' && calls++===0) return null;
    if(scenario==='forbidden') return {status:'forbidden'};
    approvals++;
    return {status:'approved',device:{...identity,roles:['operator','node']}};
   }
  `);
  return spawnSync(process.execPath,[join(dir,'helper.mjs')],{encoding:'utf8',timeout:2500,
   env:{...process.env,OPENCLAW_EXPECTED_DEVICE_ID:'device',OPENCLAW_EXPECTED_PUBLIC_KEY:'key',OPENCLAW_GATEWAY_PARENT_PID:String(process.pid)}});
 }finally{rmSync(dir,{recursive:true,force:true});}
}
for(const scenario of ['merged','upgrade']){
 test(scenario+' pending request is approved',()=>{
  const r=run(scenario);assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/APPROVE:request:operator.admin/);
 });
}
for(const scenario of ['foreign','ambiguous','invalid-role','error']){
 test(scenario+' cannot approve',()=>{
  const r=run(scenario);assert.equal(r.status,143,r.stderr);assert.doesNotMatch(r.stdout,/APPROVE:/);
 });
}
test('forbidden cannot complete',()=>assert.equal(run('forbidden').status,143));
test('disappeared request is retried without declaring success',()=>{
 const result=run('stale');
 assert.equal(result.status,0,result.stderr);
 assert.equal(result.stdout.match(/APPROVE:/g)?.length,2);
});
for(const [signal,status] of [['SIGHUP',129],['SIGINT',130],['SIGTERM',143]]){
 test(signal+' exits without approval',()=>{
  const r=run('foreign',signal);assert.equal(r.status,status,r.stderr);assert.doesNotMatch(r.stdout,/APPROVE:/);
 });
}
test('launcher waits for health then execs one Node helper without CLI',()=>{
 assert.doesNotMatch(launcher,/openclaw devices/);
 assert.ok(launcher.indexOf('wget -q')<launcher.indexOf('exec node'));
 assert.equal(launcher.match(/exec node/g)?.length,1);
});
for(const available of [false,true]){
 test('real shell health wait, available='+available,()=>{
  const dir=mkdtempSync(join(tmpdir(),'operator-launcher-'));
  try{
   writeFileSync(join(dir,'node'),'#!/bin/sh\nprintf "node:%s\\n" "$1"\nprintf "private detail\\n" >&2\n');
   chmodSync(join(dir,'node'),0o755);
   const relocated=launcher.replace('runtime_dir=/run/openclaw','runtime_dir="$TEST_DIRECTORY"');
   const mocks=`
checks=0
probes=0
kill() { checks=$((checks+1)); test "$checks" -le 3; }
wget() { probes=$((probes+1)); printf 'probe\\n'; test '${available}' = true && test "$probes" -ge 2; }
sleep() { :; }
`;
   const result=spawnSync('/bin/sh',[],{input:mocks+relocated,encoding:'utf8',timeout:2000,
    env:{...process.env,PATH:dir+':'+process.env.PATH,TEST_DIRECTORY:dir,
     OPENCLAW_EXPECTED_DEVICE_ID:'device',OPENCLAW_EXPECTED_PUBLIC_KEY:'key',OPENCLAW_GATEWAY_PARENT_PID:'123'}});
   assert.equal(result.status,available?0:75,result.stderr);
   assert.equal(result.stdout.match(/node:/g)?.length??0,available?1:0);
   assert.equal(statSync(join(dir,'app-device-error.log')).mode&0o777,0o600);
   if(available){
    assert.match(result.stdout,/probe\nprobe\nnode:/);
    assert.match(readFileSync(join(dir,'app-device-error.log'),'utf8'),/private detail/);
    assert.doesNotMatch(result.stderr,/private detail/);
   }
  }finally{rmSync(dir,{recursive:true,force:true});}
 });
}
