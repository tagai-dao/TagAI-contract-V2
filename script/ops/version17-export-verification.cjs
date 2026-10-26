const fs=require('node:fs');const cp=require('node:child_process');const crypto=require('node:crypto');
const deployment=JSON.parse(fs.readFileSync('deployments/56/version17.json'));
const dir='deployments/56/version17-verification';fs.mkdirSync(dir,{recursive:true});
const targets=[['Pump',deployment.Pump,'src/pump/Pump.sol:Pump'],['Token',deployment.TokenImplementation,'src/pump/Token.sol:Token'],['TagAISwapHook',deployment.TagAISwapHook,'src/hook/TagAISwapHook.sol:TagAISwapHook'],['TagAIBuybackRouter',deployment.TagAIBuybackRouter,'src/router/TagAIBuybackRouter.sol:TagAIBuybackRouter']];
if(fs.existsSync(`${dir}/manifest.json`)&&JSON.parse(fs.readFileSync(`${dir}/manifest.json`)).status==='verified')throw new Error('Verified V17 manifest exists; refusing to overwrite verification evidence');
const reports=[];
for(const[name,address,fqn]of targets){
 const args=['verify-contract',address,fqn,'--chain','56','--compiler-version',deployment.compiler.version,'--num-of-optimizations','100','--show-standard-json-input'];
 const result=cp.spawnSync('forge',args,{env:{...process.env,FOUNDRY_PROFILE:'bsc_mainnet'},encoding:'utf8',maxBuffer:30*1024*1024});
 if(result.status!==0){fs.writeFileSync('/tmp/tiptag-v17-export-error.log',String(result.stderr||result.error||''));throw new Error('Local Standard JSON export failed: '+name);}
 const input=JSON.parse(result.stdout);if(input.settings.viaIR!==true||input.settings.optimizer.runs!==100||input.settings.evmVersion!=='cancun')throw new Error('Compiler settings mismatch: '+name);
 const jsonFile=`${dir}/${name}.standard-json.json`;fs.writeFileSync(jsonFile,result.stdout);
 fs.writeFileSync(`${dir}/${name}.constructor-args.txt`,deployment.constructorArgs[name]+'\n');
 reports.push({name,address,fqn,status:'exported-not-uploaded',standardJson:jsonFile,standardJsonSha256:crypto.createHash('sha256').update(result.stdout).digest('hex'),bytes:Buffer.byteLength(result.stdout),sourceFileCount:Object.keys(input.sources).length,constructorArgs:deployment.constructorArgs[name],compiler:deployment.compiler,sourceCommit:deployment.sourceCommit,proposedDestination:'BscScan through https://api.etherscan.io/v2/api (chainid=56)'});
}
fs.writeFileSync(`${dir}/manifest.json`,JSON.stringify({status:'prepared-pending-explicit-upload-approval',sourceCommit:deployment.sourceCommit,contracts:reports},null,2)+'\n');
console.log(JSON.stringify(reports.map(r=>({contract:r.name,bytes:r.bytes,sources:r.sourceFileCount,sha256:r.standardJsonSha256}))));
