// Export the exact Foundry standard input, verify on BscScan, and retain independent explorer evidence.
const fs=require('node:fs'),cp=require('node:child_process'),path=require('node:path'),crypto=require('node:crypto');
const dotenv=require(require.resolve('dotenv',{paths:[process.cwd(),path.resolve('../tagai-api')]}));
const env={...dotenv.parse(fs.readFileSync('.env')),...process.env,FOUNDRY_PROFILE:'bsc_mainnet',NO_PROXY:'*',no_proxy:'*'};
const ethers=require(require.resolve('ethers',{paths:[process.cwd(),path.resolve('../buy-bot')]}));
const {BASE,FQN}=require('./agent-wrapper.cjs');
const dir=BASE+'-verification';
const sha=value=>crypto.createHash('sha256').update(value).digest('hex');
const write=(file,value)=>fs.writeFileSync(file,JSON.stringify(value,null,2)+'\n');
function assert(value,reason){if(!value)throw new Error(reason);}
async function main(){
 const deployment=JSON.parse(fs.readFileSync(BASE+'.json'));
 for(const [file,hash]of Object.entries(deployment.sourceHashes))assert(sha(fs.readFileSync(file))===hash,'Source changed: '+file);
 assert(!deployment.sourceVerification||deployment.sourceVerification.status!=='verified','Already verified; preserve evidence');
 const args=ethers.AbiCoder.defaultAbiCoder().encode(['address','address','address'],Object.values(deployment.constructor));
 const compiler=deployment.compiler.version;
 const common=['verify-contract',deployment.address,FQN,'--chain','56','--compiler-version',compiler,'--num-of-optimizations','100','--constructor-args',args];
 const exported=cp.spawnSync('forge',[...common,'--show-standard-json-input'],{env,encoding:'utf8',maxBuffer:30*1024*1024});
 assert(exported.status===0,'Local standard JSON export failed');
 const input=JSON.parse(exported.stdout);
 assert(input.settings.viaIR===true&&input.settings.optimizer.runs===100&&input.settings.evmVersion==='cancun','Compiler settings mismatch');
 fs.mkdirSync(dir,{recursive:true});
 const jsonFile=dir+'/AgentSwapWrapper.standard-json.json';
 fs.writeFileSync(jsonFile,exported.stdout);fs.writeFileSync(dir+'/AgentSwapWrapper.constructor-args.txt',args+'\n');
 const sourceHashes={};
 for(const [file,source]of Object.entries(input.sources)){
  assert(fs.readFileSync(file,'utf8')===source.content,'Export source differs from checkout: '+file);
  sourceHashes[file]=sha(source.content);
 }
 const manifest={component:'AgentSwapWrapper',version:1,address:deployment.address,fqn:FQN,sourceCommit:deployment.sourceCommit,compiler,settings:input.settings,constructorArgs:args,standardJson:jsonFile,standardJsonSha256:sha(exported.stdout),sourceFileCount:Object.keys(input.sources).length,sourceHashes,method:'Foundry Standard JSON / Etherscan V2 API (BscScan, chain 56)',status:'exported',authorization:'User explicitly requested deployment and verification in this conversation',createdAt:new Date().toISOString()};
 write(dir+'/manifest.json',manifest);
 const log='/tmp/agent-wrapper-bscscan-verify.log';
 const fd=fs.openSync(log,'w');
 const code=await new Promise((resolve,reject)=>{
  const child=cp.spawn('forge',[...common,'--verifier','etherscan','--skip-is-verified-check','--watch','--retries','5','--delay','5'],{env,stdio:['ignore',fd,fd]});
  child.on('error',reject);child.on('exit',resolve);
 });
 fs.closeSync(fd);manifest.cliExitCode=code;manifest.logFile=log;write(dir+'/manifest.json',manifest);
 const url=new URL('https://api.etherscan.io/v2/api');url.search=new URLSearchParams({chainid:'56',module:'contract',action:'getsourcecode',address:deployment.address,apikey:env.ETHERSCAN_API_KEY});
 const response=await fetch(url,{signal:AbortSignal.timeout(45000)});assert(response.ok,'Explorer response unavailable');
 const data=await response.json(),r=data.result?.[0];
 assert(data.status==='1'&&r?.SourceCode&&r.ContractName==='AgentSwapWrapper','Explorer verification not confirmed');
 assert(r.CompilerVersion.includes(compiler)&&r.OptimizationUsed==='1'&&r.Runs==='100'&&r.EVMVersion==='cancun'&&!r.SimilarMatch,'Exact compiler/source verification not confirmed');
 assert((r.ConstructorArguments||'').replace(/^0x/,'').toLowerCase()===args.slice(2).toLowerCase(),'Explorer constructor arguments mismatch');
 manifest.status='verified';manifest.verifiedAt=new Date().toISOString();manifest.explorer='https://bscscan.com/address/'+deployment.address+'#code';
 manifest.resultSource={provider:'Etherscan V2 API / BscScan',action:'getsourcecode',chainId:56};
 manifest.explorerRecord={ContractName:r.ContractName,CompilerVersion:r.CompilerVersion,OptimizationUsed:r.OptimizationUsed,Runs:r.Runs,EVMVersion:r.EVMVersion,ConstructorArguments:r.ConstructorArguments,SourceCodeSha256:sha(r.SourceCode),ABISha256:sha(r.ABI),SimilarMatch:r.SimilarMatch};
 write(dir+'/manifest.json',manifest);
 deployment.sourceVerification={status:'verified',verifiedAt:manifest.verifiedAt,manifest:dir+'/manifest.json',method:manifest.method,explorer:manifest.explorer,standardJsonSha256:manifest.standardJsonSha256};
 deployment.status='deployed-verified-owner-not-transferred';write(BASE+'.json',deployment);
 console.log(JSON.stringify({status:'verified',address:deployment.address,manifest:dir+'/manifest.json',standardJsonSha256:manifest.standardJsonSha256}));
}
main().catch(e=>{console.error('Verification failed: '+(e.code||e.message));process.exitCode=1;});
