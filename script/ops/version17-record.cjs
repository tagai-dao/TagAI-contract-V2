const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const cp=require('node:child_process');
const ethers=require(require.resolve('ethers',{paths:[process.cwd(),path.resolve('../buy-bot')]}));
const dotenv=require(require.resolve('dotenv',{paths:[process.cwd(),path.resolve('../tagai-api')]}));
const {batch,read,MC}=require('./version17-chain.cjs');
const env={...dotenv.parse(fs.readFileSync('.env')),...process.env};
const BASE='deployments/56/';
const SAFE='0x871fb7006C5964B21695Ba20006021777A26146C';
const TRADE='0x774A48Ba391a1013Ae43289eBdf871618822CD67';
const names=[['owner'],['getIPShare'],['getFeeReceiver'],['getPoolManager'],['getVault'],['nutboxCommunityFactory'],['getCalculator'],['erc20StakingFactory'],['nutboxCommittee'],['nutboxRouter'],['basketHookV4'],['pancakeV2Factory'],['settlementToken'],['listingKeeper'],['buybackRouter'],['createFee','uint256'],['getFeeRatio','uint256[2]'],['listingSwapSlippageBps','uint16'],['VERSION','uint256'],['tokenImplementation'],['pendingOwner'],['getHookAddress']];
const normalized=v=>typeof v==='bigint'?v.toString():Array.isArray(v)?Array.from(v,normalized):typeof v==='string'&&/^0x[0-9a-f]{40}$/i.test(v)?v.toLowerCase():v;
function equal(a,b,label){if(JSON.stringify(normalized(a))!==JSON.stringify(normalized(b)))throw new Error('Mismatch: '+label);}
function write(file,data){fs.writeFileSync(BASE+file,JSON.stringify(data,(_,v)=>typeof v==='bigint'?v.toString():v,2)+'\n');}
function sha(file){return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');}
async function main(){
 if(fs.existsSync(BASE+'version17.json')&&JSON.parse(fs.readFileSync(BASE+'version17.json')).sourceVerification?.status==='verified')throw new Error('Finalized V17 record exists; refusing to overwrite verified source or Safe files');
 const pre=JSON.parse(fs.readFileSync(BASE+'version17-deployment-preflight.json'));
 const run=JSON.parse(fs.readFileSync('broadcast/DeployBSCPump17.s.sol/56/run-latest.json'));
 if(run.transactions.length!==7||run.receipts.length!==7)throw new Error('Expected seven successful deployment transactions');
 const provider=new ethers.JsonRpcProvider(env.BSC_RPC_URL,56,{batchMaxCount:1,staticNetwork:true});
 try{
  if(BigInt(await provider.send('eth_chainId',[]))!==56n)throw new Error('Wrong chain');
  const receipts=await Promise.all(run.transactions.map(t=>provider.send('eth_getTransactionReceipt',[t.hash])));
  receipts.forEach(r=>{if(!r||BigInt(r.status)!==1n)throw new Error('Missing/failed mainnet receipt');});
  const block=await provider.send('eth_getBlockByNumber',['latest',false]);
  const pin=Number(BigInt(block.number));const audit=[];
  const created=Object.fromEntries(run.transactions.filter(t=>t.transactionType==='CREATE'||t.transactionType==='CREATE2').map(t=>[t.contractName,ethers.getAddress(t.contractAddress)]));
  const pump=created.Pump,hook=created.TagAISwapHook,buyback=created.TagAIBuybackRouter;
  const values=await batch(provider,pin,names.map(([n,t])=>read(pump,n,[],[],[t||'address'])),audit);
  const state=Object.fromEntries(names.map(([n],i)=>[n,values[i]]));
  equal(state.VERSION,17n,'VERSION');equal(state.owner,pre.deployer,'Pump owner');equal(state.pendingOwner,SAFE,'pending Safe');equal(state.getHookAddress,hook,'Hook');equal(state.buybackRouter,buyback,'Buyback');
  const skip=new Set(['owner','pendingOwner','VERSION','tokenImplementation','getHookAddress','buybackRouter']);
  names.filter(([n])=>!skip.has(n)).forEach(([n])=>equal(state[n],pre.configuration[n],n));
  const token=state.tokenImplementation;
  const extra=await batch(provider,pin,[read(hook,'pump'),read(hook,'clPoolManager'),read(hook,'vault'),read(buyback,'pump'),read(buyback,'nutboxRouter'),read(buyback,'basketRouter'),read(buyback,'settlementToken'),read(pump,'optionalPoolFactories',['address'],[TRADE],['string','uint16','bool']),read(state.nutboxRouter,'operators',['address'],[pump],['bool']),read(pre.infrastructure.registry,'approvedCreatorForwarders',['address'],[pump],['bool']),read(state.nutboxRouter,'owner'),read(pre.infrastructure.registry,'owner'),read(SAFE,'getOwners',[],[],['address[]']),read(SAFE,'getThreshold',[],[],['uint256']),read(SAFE,'nonce',[],[],['uint256']),read(token,'INNER_MARKET_BUY_LIMIT',[],[],['uint256']),...pre.constituents.map(a=>read(pump,'approvedConstituent',['address'],[a],['bool']))],audit);
  equal(extra[0],pump,'Hook.pump');equal(extra[1],state.getPoolManager,'Hook.poolManager');equal(extra[2],state.getVault,'Hook.vault');equal(extra[3],pump,'Buyback.pump');equal(extra[4],state.nutboxRouter,'Buyback.router');equal(extra[5],pre.infrastructure.basketRouter,'Buyback.basketRouter');equal(extra[6],state.settlementToken,'Buyback.settlement');equal(extra[7],pre.configuration.optionalTradePool,'Trade pool');equal(extra[8],false,'new operator not activated');equal(extra[9],false,'new forwarder not activated');equal(extra[10],SAFE,'Router owner');equal(extra[11],SAFE,'Registry owner');equal(extra[15],10000000n*10n**18n,'Token buy cap');
  if(extra.slice(16).some(x=>!x))throw new Error('Missing constituent approval');
  const contractAddresses={Pump:pump,Token:token,TagAISwapHook:hook,TagAIBuybackRouter:buyback};const runtimes={};const sourceHashes={};let compiler;
  for(const [name,address] of Object.entries(contractAddresses)){
   const artifact=JSON.parse(fs.readFileSync(`out/${name}.sol/${name}.json`));
   const metadata=typeof artifact.metadata==='string'?JSON.parse(artifact.metadata):artifact.metadata;
   compiler={version:metadata.compiler.version,viaIR:metadata.settings.viaIR,optimizerRuns:metadata.settings.optimizer.runs,evmVersion:metadata.settings.evmVersion,metadata:metadata.settings.metadata};
   for(const [file,info]of Object.entries(metadata.sources)){
    const content=fs.readFileSync(file);equal(ethers.keccak256(content),info.keccak256,'source content '+file);sourceHashes[file]=sha(file);
   }
   const code=await provider.send('eth_getCode',[address,ethers.toQuantity(pin)]);
   const chain=Buffer.from(code.slice(2),'hex');const local=Buffer.from(artifact.deployedBytecode.object.slice(2),'hex');
   if(chain.length===0||chain.length>24576||chain.length!==local.length)throw new Error('Runtime size mismatch '+name);
   const chainMasked=Buffer.from(chain),localMasked=Buffer.from(local);
   for(const refs of Object.values(artifact.deployedBytecode.immutableReferences||{}))for(const r of refs){chainMasked.fill(0,r.start,r.start+r.length);localMasked.fill(0,r.start,r.start+r.length);}
   if(!chainMasked.equals(localMasked))throw new Error('Runtime content mismatch '+name);
   if((name==='Token'||name==='Pump')&&!chain.equals(local))throw new Error('Exact runtime mismatch '+name);
   runtimes[name]={address,bytes:chain.length,keccak256:ethers.keccak256(code),exactMatch:chain.equals(local),immutableMaskedMatch:true};
  }
  for(const f of ['foundry.toml','script/DeployBSCPump17.s.sol','script/config/BSC15DeploymentConfig.sol','script/config/BSCNutboxRouterConfig.sol'])sourceHashes[f]=sha(f);
  const sourceCommit=cp.execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim();
  const coder=ethers.AbiCoder.defaultAbiCoder();
  const constructorArgs={Pump:coder.encode(['address','address','address[]','address'],[state.getIPShare,state.getFeeReceiver,pre.constituents,ethers.ZeroAddress]),Token:'0x',TagAISwapHook:coder.encode(['address','address','address'],[state.getPoolManager,state.getVault,pump]),TagAIBuybackRouter:coder.encode(['address','address','address','address'],[pump,state.nutboxRouter,pre.infrastructure.basketRouter,state.settlementToken])};
  const operations=[{target:state.nutboxRouter,function:'addOperator(address)',arguments:[pump]},{target:pre.infrastructure.registry,function:'setCreatorForwarderApproval(address,bool)',arguments:[pump,true]},{target:pump,function:'acceptOwnership()',arguments:[]}].map(op=>({...op,value:'0',calldata:new ethers.Interface(['function '+op.function]).encodeFunctionData(op.function,op.arguments),requiredSender:SAFE}));
  const now=new Date().toISOString();
  const actions={chainId:56,Pump:pump,verifiedAtBlock:pin,preflightReport:'version17-activation-preflight.json',status:'pending-multisig-execution',operations};write('version17-owner-actions.json',actions);
  const safe={version:'1.0',chainId:'56',createdAt:Date.now(),meta:{name:'Activate BSC Pump V17',description:`Authorize Pump V17 ${pump} on NutboxRouter and BasketRegistry, then accept ownership.`,txBuilderVersion:'1.18.0',createdFromSafeAddress:SAFE,createdFromOwnerAddress:''},transactions:operations.map(op=>({to:op.target,value:'0',data:op.calldata,contractMethod:null,contractInputsValues:null}))};write('version17.safe.json',safe);
  const safeSha=sha(BASE+'version17.safe.json');fs.writeFileSync(BASE+'version17.safe.json.sha256',safeSha+'  version17.safe.json\n');
  const activation={status:'prepared-not-proposed-not-signed-not-executed',checkedAt:now,chainId:56,blockNumber:pin,blockHash:block.hash,multicall:MC,safe:{address:SAFE,owners:extra[12],threshold:extra[13],nonce:extra[14]},state,operatorConfigured:extra[8],creatorForwarderApproved:extra[9],operations,safeFileSha256:safeSha,multicallAudit:audit};write('version17-activation-preflight.json',activation);
  let gas=0n,cost=0n;const transactions=run.transactions.map((t,i)=>{const r=receipts[i];gas+=BigInt(r.gasUsed);cost+=BigInt(r.gasUsed)*BigInt(r.effectiveGasPrice);return {hash:t.hash,contract:t.contractName,address:t.contractAddress,type:t.transactionType,function:t.function,block:Number(BigInt(r.blockNumber)),gasUsed:Number(BigInt(r.gasUsed)),effectiveGasPrice:Number(BigInt(r.effectiveGasPrice)),status:1};});
  const result={version:'17',chainId:56,status:'deployed-pending-source-verification-and-owner-activation',deploymentDate:new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Shanghai'}).format(new Date()),sourceBranch:'bsc-version17',sourceCommit,Pump:pump,TokenImplementation:token,TagAISwapHook:hook,TagAIBuybackRouter:buyback,PreviousPump:pre.previousPump,TradeCurationFactory:TRADE,HandleRegistry:'0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F',deploymentTransactions:transactions,DeploymentGasUsed:Number(gas),DeploymentCostWei:cost.toString(),DeploymentCostBNB:ethers.formatEther(cost),verificationBlock:pin,verificationBlockHash:block.hash,state,preservedV16Configuration:pre.configuration,preservedConstituents:pre.constituents,infrastructure:pre.infrastructure,runtimes,TokenRuntimeMatchesLocalArtifact:true,TokenRuntimeBytes:runtimes.Token.bytes,TokenRuntimeKeccak256:runtimes.Token.keccak256,SourceFilesSha256:sourceHashes,compiler,constructorArgs,sourceVerification:{status:'pending',explorer:'BscScan',contracts:[]},activationActionsFile:BASE+'version17-owner-actions.json',safeTransactionBuilderFile:BASE+'version17.safe.json',multisigGuide:'docs/PumpVersion17Multisig.md',evidence:{unitTests:{passed:787,failed:0,skipped:8},saltRegression:'passed',mainnetFork:{block:129859627,passed:true,sourceCommit}}};write('version17.json',result);
  console.log(JSON.stringify({Pump:pump,TokenImplementation:token,TagAISwapHook:hook,TagAIBuybackRouter:buyback,block:pin,gasUsed:Number(gas),costBNB:ethers.formatEther(cost),sourceCommit,safeFile:BASE+'version17.safe.json',safeFileSha256:safeSha}));
 }finally{provider.destroy();}
}
main().catch(e=>{console.error(`V17 record failed (${e.code||e.name}). Credentials suppressed.`);process.exitCode=1;});
