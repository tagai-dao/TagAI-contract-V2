const fs=require('fs'),cp=require('child_process'),{sha,json,ethers}=require('./version19-chain.cjs');
const base='deployments/56/',recordFile=base+'version19.json',deployment=fs.existsSync(recordFile)?JSON.parse(fs.readFileSync(recordFile)):null;
const dir=deployment?base+'version19-verification':'previews/version19-standard-json';fs.mkdirSync(dir,{recursive:true});
const targets=[['Pump19',deployment?.Pump,'src/pump/Pump19.sol'],['Token19',deployment?.TokenImplementation,'src/pump/Token19.sol'],['TagAISwapHook',deployment?.TagAISwapHook,'src/hook/TagAISwapHook.sol'],['TagAIBuybackRouter',deployment?.TagAIBuybackRouter,'src/router/TagAIBuybackRouter.sol']];
const reports=[];let combined;
for(const[name,address,source]of targets){
 const a=JSON.parse(fs.readFileSync(`out/${name}.sol/${name}.json`)),m=typeof a.metadata==='string'?JSON.parse(a.metadata):a.metadata,settings=structuredClone(m.settings);delete settings.compilationTarget;
 if(settings.viaIR!==true||settings.optimizer.runs!==100||settings.evmVersion!=='cancun'||m.compiler.version!=='0.8.26+commit.8a97fa7a')throw Error('Compiler settings mismatch');
 settings.outputSelection={'*':{'*':['abi','metadata','evm.bytecode.object','evm.deployedBytecode.object']}};
 const input={language:m.language,sources:Object.fromEntries(Object.entries(m.sources).map(([file,info])=>{const content=fs.readFileSync(file,'utf8');if(ethers.keccak256(ethers.toUtf8Bytes(content))!==info.keccak256)throw Error('Source mismatch '+file);return[file,{content}]})),settings};
 if(!combined)combined=structuredClone(input);else Object.assign(combined.sources,input.sources);
 const file=`${dir}/${name}.standard-json.json`;fs.writeFileSync(file,json(input));if(deployment)fs.writeFileSync(`${dir}/${name}.constructor-args.txt`,deployment.constructorArgs[name]+'\n');
 reports.push({name,address:address||null,fqn:source+':'+name,status:'exported-not-uploaded',standardJson:file,standardJsonSha256:sha(file),sourceFileCount:Object.keys(input.sources).length,compiler:m.compiler.version,sourceCommit:deployment?.sourceCommit||cp.execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),constructorArgs:deployment?.constructorArgs[name]||null});
}
// Compiler metadata supplies the exact settings and source hashes. Recompile the complete input locally
// to prove the exported input reproduces every creation and deployed bytecode, including metadata.
const compiler=process.env.V19_SOLC||'/Users/wangxi/Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.26+commit.8a97fa7a';
const inputFile='previews/version19-standard-json/recompile-input.json';fs.mkdirSync('previews/version19-standard-json',{recursive:true});fs.writeFileSync(inputFile,json(combined));
const result=cp.spawnSync(compiler,['--standard-json'],{input:json(combined),encoding:'utf8',maxBuffer:50*1024*1024});if(result.status!==0)throw Error('Local solc execution failed');const out=JSON.parse(result.stdout);if(out.errors?.some(e=>e.severity==='error'))throw Error('Standard JSON compile error');
for(const[name,,source]of targets){const a=JSON.parse(fs.readFileSync(`out/${name}.sol/${name}.json`)),c=out.contracts[source][name];if('0x'+c.evm.bytecode.object!==a.bytecode.object||'0x'+c.evm.deployedBytecode.object!==a.deployedBytecode.object)throw Error('Standard JSON bytecode mismatch '+name)}
fs.writeFileSync(`${dir}/manifest.json`,json({status:'prepared-not-uploaded',generationMethod:'Exact compiler metadata settings and hashed source contents; locally recompiled with full solc 0.8.26; creation/runtime bytecode including metadata matches deployment artifacts',bytecodeReproduction:true,contracts:reports}));
console.log(json(reports.map(r=>({contract:r.name,address:r.address,sources:r.sourceFileCount,sha256:r.standardJsonSha256}))) );
