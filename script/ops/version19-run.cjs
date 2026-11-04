const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),cp=require('node:child_process');
const dotenv=require(require.resolve('dotenv',{paths:[process.cwd(),path.resolve('../tagai-api')]}));
const {ethers,CurlRpc,preflight,read,batch,MC,PREVIOUS,TRADE,sha,json}=require('./version19-chain.cjs');
const BASE='deployments/56/',PLAN=BASE+'version19-deployment-plan.json',JOURNAL=BASE+'version19-broadcast-journal.json';
const FACTORY='0x4e59b44847b379578588920cA78FbF26c0B4956C';
const sourceFiles=['src/pump/Pump19.sol','src/pump/Token19.sol','src/hook/TagAISwapHook.sol','src/router/TagAIBuybackRouter.sol','script/DeployBSCPump19.s.sol'];
function equal(a,b,label){const norm=v=>typeof v==='bigint'?v.toString():Array.isArray(v)?v.map(norm):v&&typeof v==='object'?Object.fromEntries(Object.entries(v).map(([k,x])=>[k,norm(x)])):typeof v==='string'?v.toLowerCase():v;if(JSON.stringify(norm(a))!==JSON.stringify(norm(b)))throw Error('Mismatch: '+label);}
const artifact=n=>JSON.parse(fs.readFileSync(`out/${n}.sol/${n}.json`));
function checkSources(){
 const manifest=JSON.parse(fs.readFileSync('previews/pump19-readiness-source-manifest.json'));
 for(const [file,info]of Object.entries(manifest.sources))if(sha(file)!==info.sha256)throw Error('Reviewed compiler source changed: '+file);
 const commit=cp.execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim();
 for(const f of sourceFiles){const committed=cp.execFileSync('git',['show',commit+':'+f],{maxBuffer:2*1024*1024});const digest=require('crypto').createHash('sha256').update(committed).digest('hex');if(digest!==sha(f))throw Error('Deployment source not frozen in commit: '+f);}
 return commit;
}
function validateRun(run,pre){
 const txs=run.transactions;if(txs?.length!==7)throw Error('Expected seven deployment/configuration transactions');
 const start=Number(pre.pendingNonce),pump=ethers.getCreateAddress({from:pre.deployer,nonce:start}),buyback=ethers.getCreateAddress({from:pre.deployer,nonce:start+3});
 const coder=ethers.AbiCoder.defaultAbiCoder(),c=pre.configuration;
 const init0=artifact('Pump19').bytecode.object+coder.encode(['address','address','address[]','address'],[c.getIPShare,c.getFeeReceiver,pre.constituents,ethers.ZeroAddress]).slice(2);
 const hookTx=txs[1].transaction,salt='0x'+hookTx.input.slice(2,66),hookInit='0x'+hookTx.input.slice(66);
 const expectedHookInit=artifact('TagAISwapHook').bytecode.object+coder.encode(['address','address','address'],[c.getPoolManager,c.getVault,pump]).slice(2);
 equal(hookInit,expectedHookInit,'Hook constructor');const hook=ethers.getCreate2Address(FACTORY,salt,ethers.keccak256(hookInit));if(!hook.toLowerCase().endsWith('0cc1'))throw Error('Hook permission suffix mismatch');
 const init3=artifact('TagAIBuybackRouter').bytecode.object+coder.encode(['address','address','address','address'],[pump,c.nutboxRouter,pre.infrastructure.basketRouter,c.settlementToken]).slice(2);
 const abi=new ethers.Interface(['function adminSetHookAddress(address)','function adminSetBuybackRouter(address)','function adminSetOptionalPoolFactory(address,string,uint16,bool)','function transferOwnership(address)']);
 const expected=[{to:null,data:init0},{to:FACTORY,data:hookTx.input},{to:pump,data:abi.encodeFunctionData('adminSetHookAddress',[hook])},{to:null,data:init3},{to:pump,data:abi.encodeFunctionData('adminSetBuybackRouter',[buyback])},{to:pump,data:abi.encodeFunctionData('adminSetOptionalPoolFactory',[TRADE,'Trade Curation',8000,true])},{to:pump,data:abi.encodeFunctionData('transferOwnership',[pre.targetOwner])}];
 let gasLimit=0n;
 txs.forEach((t,i)=>{const x=t.transaction;if(Number(BigInt(x.chainId))!==56||Number(BigInt(x.nonce))!==start+i||BigInt(x.value)!==0n)throw Error('Chain/nonce/value mismatch');equal(x.from,pre.deployer,'sender');equal(x.to??null,expected[i].to,'target '+i);equal(x.input,expected[i].data,'calldata '+i);if(BigInt(x.gas)<=0n||BigInt(x.gas)>BigInt(pre.blockGasLimit))throw Error('Gas limit invalid');gasLimit+=BigInt(x.gas);});
 equal(txs[0].contractAddress,pump,'Pump CREATE address');equal(txs[1].contractAddress,hook,'Hook CREATE2 address');equal(txs[3].contractAddress,buyback,'Buyback CREATE address');
 return {Pump:pump,TokenImplementation:ethers.getCreateAddress({from:pump,nonce:1}),TagAISwapHook:hook,TagAIBuybackRouter:buyback,totalGasLimit:gasLimit,maxFeeWei:gasLimit*BigInt(pre.gasPriceWei)};
}
async function dry(env,pre,provider){
 const sourceCommit=checkSources();if(new ethers.Wallet(env.PRIVATE_KEY_MAIN).address.toLowerCase()!==pre.deployer.toLowerCase())throw Error('Deployment wallet changed');
 const cache=new Map(),file=`previews/version19-dry-rpc-${pre.blockNumber}.ndjson`;
 if(fs.existsSync(file))for(const row of fs.readFileSync(file,'utf8').split('\n').filter(Boolean)){const x=JSON.parse(row);cache.set(x.key,x.result);}
 const readMethods=new Set(['eth_chainId','eth_blockNumber','eth_getBlockByNumber','eth_getBlockByHash','eth_getBalance','eth_getTransactionCount','eth_getCode','eth_getStorageAt','eth_getLogs','eth_gasPrice','eth_call']);
 const server=http.createServer((req,res)=>{let body='';req.on('data',x=>body+=x);req.on('end',async()=>{let p;res.setHeader('Content-Type','application/json');try{p=JSON.parse(body);if(Array.isArray(p)||!readMethods.has(p.method))throw Error('READ_ONLY_DRY_RELAY');const key=JSON.stringify([p.method,p.params]);let result;if(cache.has(key))result=cache.get(key);else{result=await provider.send(p.method,p.params);cache.set(key,result);fs.appendFileSync(file,JSON.stringify({key,result})+'\n');}res.end(JSON.stringify({jsonrpc:'2.0',id:p.id,result}));}catch(e){res.end(JSON.stringify({jsonrpc:'2.0',id:p?.id??null,error:{code:p?.method==='eth_getAccountInfo'?-32601:-32000,message:e.message}}));}})});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const endpoint=`http://127.0.0.1:${server.address().port}`;
 const childEnv={...process.env,FOUNDRY_PROFILE:'bsc_mainnet',BSC_RPC_URL:endpoint,FOUNDRY_ETH_RPC_URL:'',PRIVATE_KEY_MAIN:env.PRIVATE_KEY_MAIN,PUMP19_OWNER:pre.targetOwner,NO_PROXY:'*',no_proxy:'*',HTTP_PROXY:'',HTTPS_PROXY:'',ALL_PROXY:'',http_proxy:'',https_proxy:'',all_proxy:''};
 const solc=env.V19_SOLC||'/Users/wangxi/Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.26+commit.8a97fa7a';
 const args=['script','--use',solc,'script/DeployBSCPump19.s.sol:DeployBSCPump19Script','--offline','--rpc-url',endpoint,'--fork-block-number',String(pre.blockNumber),'--sender',pre.deployer,'--slow','--with-gas-price',String(BigInt(pre.gasPriceWei)),'--gas-estimate-multiplier','130','--no-proxy','--rpc-timeout','45','--fork-retries','0','--non-interactive'];
 const logFile='/private/tmp/tiptag-v19-actual-wallet-dry.log';const output=fs.createWriteStream(logFile,{mode:0o600});
 const secrets=[env.PRIVATE_KEY_MAIN,env.PRIVATE_KEY_MAIN.replace(/^0x/,''),BigInt(env.PRIVATE_KEY_MAIN).toString(),env.BSC_RPC_URL];let buffer='';
 const log=x=>{buffer+=x.toString();const lines=buffer.split('\n');buffer=lines.pop();for(let line of lines){for(const secret of secrets)if(secret)line=line.split(secret).join('<redacted>');output.write(line+'\n');}};
 const child=cp.spawn('forge',args,{env:childEnv,stdio:['ignore','pipe','pipe']});child.stdout.on('data',log);child.stderr.on('data',log);
 let timedOut=false;const timer=setTimeout(()=>{timedOut=true;child.kill('SIGTERM')},600000);
 const code=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',resolve)});clearTimeout(timer);if(buffer)log('\n');output.end();server.close();if(code!==0||timedOut)throw Error('Actual-account deployment dry run failed; inspect redacted log');
 const runFile='broadcast/DeployBSCPump19.s.sol/56/dry-run/run-latest.json';const run=JSON.parse(fs.readFileSync(runFile));const validated=validateRun(run,pre);
 if(BigInt(pre.balanceWei)<validated.maxFeeWei)throw Error('Insufficient BNB for gas limit budget');
 const plan={chainId:56,status:'validated-not-broadcast',sourceCommit,preflightBlock:pre.blockNumber,preflightBlockHash:pre.blockHash,deployer:pre.deployer,startNonce:pre.pendingNonce,gasPriceWei:String(BigInt(pre.gasPriceWei)),...validated,runFile,transactions:run.transactions,createdAt:new Date().toISOString(),sourceSha256:Object.fromEntries(sourceFiles.map(f=>[f,sha(f)]))};
 fs.writeFileSync(PLAN,json(plan));console.log(JSON.stringify({phase:'dry-run-passed',sourceCommit,deployer:plan.deployer,startNonce:plan.startNonce,transactions:7,totalGasLimit:plan.totalGasLimit.toString(),maxFeeBNB:ethers.formatEther(plan.maxFeeWei),addresses:validated,log:logFile},(_,v)=>typeof v==='bigint'?v.toString():v));
}
async function waitReceipt(provider,hash){for(let i=0;i<90;i++){const r=await provider.send('eth_getTransactionReceipt',[hash]);if(r)return r;await new Promise(r=>setTimeout(r,2000));}throw Error('Transaction still pending; reconcile journal before further action');}
async function broadcast(env,pre,provider){
 if(!process.argv.includes('--authorized-mainnet-v19'))throw Error('Mainnet deployment authorization flag missing');
 if(fs.existsSync(BASE+'version19.json'))throw Error('Deployment record already exists');
 if(!pre.mappingLogAudit||pre.mappingLogAudit.toBlock!==pre.blockNumber)throw Error('Mapping audit incomplete');
 const plan=JSON.parse(fs.readFileSync(PLAN));equal(checkSources(),plan.sourceCommit,'deployment commit');validateRun({transactions:plan.transactions},pre);
 const wallet=new ethers.Wallet(env.PRIVATE_KEY_MAIN);equal(wallet.address,plan.deployer,'deployment wallet');
 const block=await provider.send('eth_getBlockByNumber',['latest',false]);const pin=Number(BigInt(block.number));const fresh=await preflight(provider,pin,plan.deployer);equal(fresh.configuration,pre.configuration,'preserved V18 configuration');equal(fresh.constituents,pre.constituents,'V18 constituent catalogue');equal(fresh.safe.address,pre.targetOwner,'target Safe');
 const eventABI=new ethers.Interface(['event ConstituentApprovalSet(address indexed asset,bool approved)','event OptionalPoolFactorySet(address indexed factory,string name,uint16 maxRewardRatio,bool enabled)']);
 const changes=pin>pre.blockNumber?await provider.send('eth_getLogs',[{address:PREVIOUS,fromBlock:ethers.toQuantity(pre.blockNumber+1),toBlock:ethers.toQuantity(pin),topics:[[eventABI.getEvent('ConstituentApprovalSet').topicHash,eventABI.getEvent('OptionalPoolFactorySet').topicHash]]}]):[];if(changes.length)throw Error('V18 emitted new configuration/events after preflight; recheck before broadcasting');
 if(BigInt(fresh.balanceWei)<BigInt(plan.maxFeeWei))throw Error('Insufficient BNB gas budget');
 const currentGas=BigInt(await provider.send('eth_gasPrice',[]));if(currentGas>BigInt(plan.gasPriceWei))throw Error('Gas quote increased; recheck approved plan');
 const pending=Number(BigInt(await provider.send('eth_getTransactionCount',[plan.deployer,'pending'])));
 const planHash=ethers.keccak256(ethers.toUtf8Bytes(json(plan)));let journal=fs.existsSync(JOURNAL)?JSON.parse(fs.readFileSync(JOURNAL)):{chainId:56,sourceCommit:plan.sourceCommit,planHash,deployer:plan.deployer,startedAt:new Date().toISOString(),transactions:[]};
 equal(journal.planHash,planHash,'journal plan');if(!journal.transactions.length&&pending!==plan.startNonce)throw Error('Account nonce changed before broadcast');
 for(let i=0;i<plan.transactions.length;i++){
  const x=plan.transactions[i].transaction;
  const unsigned={type:0,chainId:56,nonce:Number(BigInt(x.nonce)),gasPrice:BigInt(plan.gasPriceWei),gasLimit:BigInt(x.gas),to:x.to||null,value:0n,data:x.input};
  const raw=await wallet.signTransaction(unsigned),hash=ethers.keccak256(raw);let entry=journal.transactions[i];
  if(entry)equal(entry.hash,hash,'journal transaction hash');else{entry={index:i,hash,nonce:unsigned.nonce,contract:plan.transactions[i].contractName,type:plan.transactions[i].transactionType,function:plan.transactions[i].function,status:'prepared',to:x.to||null};journal.transactions.push(entry);fs.writeFileSync(JOURNAL,json(journal));}
  let receipt=await provider.send('eth_getTransactionReceipt',[hash]);
  if(!receipt){const known=await provider.send('eth_getTransactionByHash',[hash]);if(!known){const nonce=Number(BigInt(await provider.send('eth_getTransactionCount',[plan.deployer,'pending'])));if(nonce!==unsigned.nonce)throw Error('Unexpected nonce; reconcile '+hash);provider.authorizeRaw(hash);let accepted;try{accepted=await provider.send('eth_sendRawTransaction',[raw]);equal(accepted,hash,'broadcast transaction hash');}catch(e){const seen=await provider.send('eth_getTransactionByHash',[hash]);if(!seen)throw e;}entry.status='submitted';entry.submittedAt=new Date().toISOString();fs.writeFileSync(JOURNAL,json(journal));console.log(JSON.stringify({phase:'submitted',index:i,hash,nonce:unsigned.nonce,contract:entry.contract}));}receipt=await waitReceipt(provider,hash);}
  entry.receipt=receipt;entry.status=BigInt(receipt.status)===1n?'confirmed':'reverted';fs.writeFileSync(JOURNAL,json(journal));if(BigInt(receipt.status)!==1n)throw Error('Deployment transaction reverted: '+hash);
  console.log(JSON.stringify({phase:'confirmed',index:i,hash,block:Number(BigInt(receipt.blockNumber)),gasUsed:Number(BigInt(receipt.gasUsed))}));
 }
 journal.completedAt=new Date().toISOString();journal.status='all-seven-confirmed';fs.writeFileSync(JOURNAL,json(journal));console.log(JSON.stringify({phase:'deployment-confirmed',Pump:plan.Pump,TokenImplementation:plan.TokenImplementation,TagAISwapHook:plan.TagAISwapHook,TagAIBuybackRouter:plan.TagAIBuybackRouter}));
}
async function main(){const mode=process.argv[2];if(!['dry','broadcast'].includes(mode))throw Error('Expected dry or broadcast');const env={...dotenv.parse(fs.readFileSync('.env')),...process.env};const pre=JSON.parse(fs.readFileSync(BASE+'version19-deployment-preflight.json'));const provider=new CurlRpc(env.BSC_RPC_URL);if(BigInt(await provider.send('eth_chainId',[]))!==56n)throw Error('Wrong chain');if(mode==='dry')await dry(env,pre,provider);else await broadcast(env,pre,provider);}
if(require.main===module)main().catch(e=>{console.error(JSON.stringify({error:e.message,code:e.code,rpcMessage:e.rpcMessage}));process.exitCode=1});
module.exports={validateRun,checkSources};
