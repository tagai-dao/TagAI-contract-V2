const fs=require('node:fs');const path=require('node:path');const cp=require('node:child_process');const crypto=require('node:crypto');
const dotenv=require(require.resolve('dotenv',{paths:[process.cwd(),path.resolve('../tagai-api')]}));
const env={...dotenv.parse(fs.readFileSync('.env')),...process.env,FOUNDRY_PROFILE:'bsc_mainnet',NO_PROXY:'*',no_proxy:'*'};
const dir='deployments/56/version18-verification';const deployment=JSON.parse(fs.readFileSync('deployments/56/version18.json'));
const manifest=JSON.parse(fs.readFileSync(`${dir}/manifest.json`));const reports=manifest.contracts;
const sha=v=>crypto.createHash('sha256').update(v).digest('hex');
function run(args,log){return new Promise((resolve,reject)=>{const fd=fs.openSync(log,'w');const child=cp.spawn('forge',args,{env,stdio:['ignore',fd,fd]});child.on('error',reject);child.on('exit',code=>{fs.closeSync(fd);resolve(code);});});}
async function main(){
 if(!process.argv.includes("--approved-bscscan-source-upload"))throw new Error("Explicit user approval to upload full source packages and constructor arguments to BscScan is required");
 if(manifest.sourceCommit!==deployment.sourceCommit||reports.length!==4)throw new Error('Approved verification manifest mismatch');
 for(const r of reports){if(sha(fs.readFileSync(r.standardJson))!==r.standardJsonSha256||r.constructorArgs!==deployment.constructorArgs[r.name])throw new Error('Approved file or constructor args changed: '+r.name);}
 // Invoke only after explicit user approval for full source disclosure to BscScan.
 manifest.uploadAuthorization={status:'explicit-source-upload-approval-confirmed-by-operator',destination:'BscScan / https://api.etherscan.io/v2/api (chainid=56)',approvedAt:new Date().toISOString()};
 for(let i=0;i<reports.length;++i){
  await Promise.all(reports.slice(i,i+1).map(async r=>{
   const log=`/tmp/tiptag-v18-verify-${r.name}.log`;
   const args=['verify-contract',r.address,r.fqn,'--chain','56','--compiler-version',deployment.compiler.version,'--num-of-optimizations','100','--constructor-args',r.constructorArgs,'--verifier','etherscan','--watch','--retries','5','--delay','5'];
   r.cliExitCode=await run(args,log);r.logFile=log;console.log(JSON.stringify({contract:r.name,cliExitCode:r.cliExitCode}));
  }));
 }
 await new Promise(resolve=>setTimeout(resolve,1200));
 for(const r of reports){
  const url=new URL('https://api.etherscan.io/v2/api');url.search=new URLSearchParams({chainid:'56',module:'contract',action:'getsourcecode',address:r.address,apikey:env.ETHERSCAN_API_KEY});
  const response=await fetch(url,{signal:AbortSignal.timeout(45000)});if(!response.ok)throw new Error('Explorer response unavailable');
  const data=await response.json();const record=data.result?.[0];
  if(data.status!=='1'||!record?.SourceCode||record.ContractName!==r.name||!record.CompilerVersion.includes('0.8.26+commit.8a97fa7a')||record.OptimizationUsed!=='1'||record.Runs!=='100')throw new Error('Explorer verification not confirmed: '+r.name);
  if((record.ConstructorArguments||'').replace(/^0x/,'').toLowerCase()!==r.constructorArgs.replace(/^0x/,'').toLowerCase())throw new Error('Explorer constructor mismatch: '+r.name);
  r.status='verified';r.verifiedAt=new Date().toISOString();r.resultSource={provider:'Etherscan V2 API / BscScan',action:'getsourcecode',chainId:56};r.explorer=`https://bscscan.com/address/${r.address}#code`;r.explorerRecord={ContractName:record.ContractName,CompilerVersion:record.CompilerVersion,OptimizationUsed:record.OptimizationUsed,Runs:record.Runs,EVMVersion:record.EVMVersion,ConstructorArguments:record.ConstructorArguments,SourceCodeSha256:sha(record.SourceCode),ABISha256:sha(record.ABI),SimilarMatch:record.SimilarMatch};
  await new Promise(resolve=>setTimeout(resolve,350));
 }
 manifest.status='verified';manifest.method='Foundry Standard JSON submitted to Etherscan V2 API (BscScan, chain 56)';fs.writeFileSync(`${dir}/manifest.json`,JSON.stringify(manifest,null,2)+'\n');
 deployment.status='deployed-verified-pending-owner-activation';deployment.sourceVerification={status:'verified',explorer:'BscScan',method:'Foundry Standard JSON / Etherscan V2 API',verifiedAt:new Date().toISOString(),manifest:`${dir}/manifest.json`,contracts:reports.map(r=>({name:r.name,address:r.address,status:r.status,explorer:r.explorer,standardJsonSha256:r.standardJsonSha256}))};
 fs.writeFileSync('deployments/56/version18.json',JSON.stringify(deployment,null,2)+'\n');
 console.log(JSON.stringify({status:'all-four-verified',manifest:`${dir}/manifest.json`}));
}
main().catch(e=>{console.error(e.code?`Verification failed (${e.code}); credentials suppressed.`:e.message);process.exitCode=1;});
