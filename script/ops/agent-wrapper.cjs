// Independent BSC AgentSwapWrapper v1 deployment. Secrets remain in the local environment.
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const crypto = require('node:crypto');
const ethers = require(require.resolve('ethers', { paths: [process.cwd(), path.resolve('../buy-bot')] }));
const dotenv = require(require.resolve('dotenv', { paths: [process.cwd(), path.resolve('../tagai-api')] }));
const { batch, read, MC, checkIPShare } = require('./version18-chain.cjs');
const env = { ...dotenv.parse(fs.readFileSync('.env')), ...process.env };
const BASE = 'deployments/56/agent-swap-wrapper-v1';
const SAFE = '0x871fb7006C5964B21695Ba20006021777A26146C';
const OLD = '0xDfFc699FB095a693708E3c15e6F0a224cbbCc98F';
const V18 = JSON.parse(fs.readFileSync('deployments/56/version18.json'));
const IP = '0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922';
const HANDLE = V18.HandleRegistry;
const FQN = 'src/helper/AgentSwapWrapper.sol:AgentSwapWrapper';
const ARTIFACT = 'out/AgentSwapWrapper.sol/AgentSwapWrapper.json';
const SHA = value => crypto.createHash('sha256').update(value).digest('hex');
const stringify = value => JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2) + '\n';
const write = (name, data) => fs.writeFileSync(name, stringify(data));
const load = name => JSON.parse(fs.readFileSync(name));
const git = (...args) => cp.execFileSync('git', args, { encoding: 'utf8' }).trim();
const same = (a,b) => a.toLowerCase() === b.toLowerCase();
function assert(value, reason) { if (!value) throw new Error(reason); }
function provider() { return new ethers.JsonRpcProvider(env.BSC_RPC_URL, 56, { staticNetwork: true, batchMaxCount: 1 }); }
function artifact() { return load(ARTIFACT); }
function sourceHashes() {
  return Object.fromEntries(['src/helper/AgentSwapWrapper.sol', 'src/helper/ImportedTokenSwapWrapper.sol', 'foundry.toml'].map(f => [f,SHA(fs.readFileSync(f))]));
}
function checkSources(record) {
  for (const [f,sha] of Object.entries(record.sourceHashes)) assert(SHA(fs.readFileSync(f)) === sha, 'Deployment source changed: ' + f);
  assert(SHA(fs.readFileSync(ARTIFACT)) === record.artifactSha256, 'Deployment artifact changed');
}
async function snapshot(p) {
  assert(BigInt(await p.send('eth_chainId',[])) === 56n, 'BSC chain ID mismatch');
  return await p.send('eth_getBlockByNumber',['latest',false]);
}
async function readDependencies(p,pin,deployer,audit=[]) {
  return batch(p,pin,[read(OLD,'nutboxRouter'),read(OLD,'feeAddress'),read(OLD,'ipshare'),read(V18.Pump,'nutboxRouter'),read(V18.Pump,'getFeeReceiver'),read(V18.Pump,'getIPShare'),read(SAFE,'getThreshold',[],[],['uint256']),read(SAFE,'getOwners',[],[],['address[]']),read(HANDLE,'handleOf',['address'],[deployer],['string'])],audit);
}
async function readRouter(p,pin,router,manager,deployer,audit=[]) {
  const wbnb='0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c', usdt='0x55d398326f99059fF775485246999027B3197955';
  const v2Factory='0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73';
  return batch(p,pin,[read(router,'wrappedNative'),read(router,'allowedV2Factory',['address'],[v2Factory],['bool']),read(router,'v2RouterForFactory',['address'],[v2Factory]),read(router,'allowedV3Factory',['address'],['0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865'],['bool']),read(router,'allowedPancakeV4CLManager',['address'],[manager],['bool']),read(router,'hasRoute',['address','address'],[wbnb,usdt],['bool']),read(router,'hasRoute',['address','address'],[usdt,wbnb],['bool']),read(MC,'getEthBalance',['address'],[deployer],['uint256'])],audit);
}
async function preflight(p) {
  assert(!fs.existsSync(BASE+'.json'), 'Deployment already recorded; reconcile first');
  const block = await snapshot(p), pin = Number(BigInt(block.number)), audit = [];
  const deployer = new ethers.Wallet(env.PRIVATE_KEY_MAIN).address;
  const primary = await readDependencies(p,pin,deployer,audit);
  const [legacyRouter,legacyFee,legacyIP,router,fee,ipshare,threshold,owners,deployerHandle] = primary;
  assert(same(ipshare,IP) && same(legacyIP,IP), 'IPShare mismatch');
  assert(same(fee,legacyFee), 'Fee receiver mismatch between deployed entry points');
  assert(same(router,V18.state.nutboxRouter), 'V18 router mismatch');
  assert(threshold > 0n && threshold <= BigInt(owners.length), 'Invalid Safe threshold');
  const wbnb='0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c', usdt='0x55d398326f99059fF775485246999027B3197955';
  const v2Factory='0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73';
  const stage2 = await readRouter(p,pin,router,V18.state.getPoolManager,deployer,audit);
  assert(same(stage2[0],wbnb) && stage2[1] && stage2[3] && stage2[4] && stage2[5] && stage2[6], 'Required DEX factories/managers/routes missing');
  assert(same(stage2[2],'0x10ED43C718714eb63d5aA57B78B54704E256024E'), 'Unexpected V2 router');
  const ipState=await checkIPShare(p,pin,IP,audit);
  const pendingNonce=await p.send('eth_getTransactionCount',[deployer,'pending']);
  const latestNonce=await p.send('eth_getTransactionCount',[deployer,'latest']);
  assert(pendingNonce === latestNonce, 'Deployer has pending transactions');
  const nonce=Number(BigInt(pendingNonce)), art=artifact();
  const factory=new ethers.ContractFactory(art.abi,art.bytecode.object);
  const request=await factory.getDeployTransaction(router,fee,IP);
  const gas=BigInt(await p.send('eth_estimateGas',[{from:deployer,data:request.data}]));
  const gasPrice=BigInt(await p.send('eth_gasPrice',[]));
  const gasLimit=gas*130n/100n;
  assert(stage2[7] > (gasLimit+300000n)*gasPrice, 'Insufficient deployment balance');
  const record={component:'AgentSwapWrapper',version:1,chainId:56,checkedAt:new Date().toISOString(),blockNumber:pin,blockHash:block.hash,sourceCommit:git('rev-parse','HEAD'),sourceBranch:git('branch','--show-current'),sourceHashes:sourceHashes(),artifactSha256:SHA(fs.readFileSync(ARTIFACT)),compiler:art.metadata.compiler,settings:art.metadata.settings,deployer,targetOwner:SAFE,nonce,predictedAddress:ethers.getCreateAddress({from:deployer,nonce}),constructor:{nutboxRouter:router,feeAddress:fee,ipshare:IP},legacyWrapper:OLD,legacyRouter,handleRegistry:HANDLE,deployerHandle,operator:ethers.ZeroAddress,safe:{threshold,owners},ipshare:ipState,gasEstimate:gas,gasLimit,gasPriceWei:gasPrice,balanceWei:stage2[7],multicallAudit:audit};
  write(BASE+'-preflight.json',record);
  console.log(stringify({mode:'preflight',block:pin,deployer,targetOwner:SAFE,constructor:record.constructor,predictedAddress:record.predictedAddress,gasEstimate:gas,gasPriceWei:gasPrice,balanceBNB:ethers.formatEther(stage2[7]),safeThreshold:threshold,safeOwners:owners.length}));
}
async function deploy(p) {
  assert(!fs.existsSync(BASE+'.json') && !fs.existsSync(BASE+'-journal.json'), 'Existing deployment/journal: recover rather than redeploy');
  const pre=load(BASE+'-preflight.json'); checkSources(pre);
  const wallet=new ethers.Wallet(env.PRIVATE_KEY_MAIN,p); assert(same(wallet.address,pre.deployer),'Wrong deployer');
  const block=await snapshot(p); assert(Number(BigInt(block.number))-pre.blockNumber < 1200,'Refresh stale preflight');
  assert(Number(BigInt(await p.send('eth_getTransactionCount',[wallet.address,'pending'])))===pre.nonce,'Nonce changed');
  const art=artifact(), factory=new ethers.ContractFactory(art.abi,art.bytecode.object,wallet);
  const tx=await factory.getDeployTransaction(pre.constructor.nutboxRouter,pre.constructor.feeAddress,IP);
  const journal={address:pre.predictedAddress,sourceCommit:pre.sourceCommit,createdAt:new Date().toISOString(),status:'prepared',nonce:pre.nonce};
  write(BASE+'-journal.json',journal);
  const sent=await wallet.sendTransaction({...tx,nonce:pre.nonce,chainId:56,type:0,gasLimit:BigInt(pre.gasLimit),gasPrice:BigInt(pre.gasPriceWei)});
  journal.hash=sent.hash;journal.status='submitted';write(BASE+'-journal.json',journal);
  const receipt=await sent.wait(2);assert(receipt.status===1 && same(receipt.contractAddress,pre.predictedAddress),'Deployment receipt mismatch');
  const record={...pre,address:receipt.contractAddress,status:'deployed-unverified-owner-not-transferred',deployedAt:new Date().toISOString(),deploymentTransaction:receipt.toJSON(),version:1};
  write(BASE+'.json',record);journal.status='mined';write(BASE+'-journal.json',journal);
  console.log(stringify({mode:'deploy',address:record.address,hash:sent.hash,block:receipt.blockNumber,gasUsed:receipt.gasUsed}));
}
async function status(p) {
  const record=load(BASE+'.json'),block=await snapshot(p),pin=Number(BigInt(block.number)),audit=[];
  const names=[['owner'],['pendingOwner'],['operator'],['nutboxRouter'],['feeAddress'],['ipshare'],['HANDLE_REGISTRY'],['sellsmanRatio','uint16'],['tagaiRatio','uint16'],['nutboxTokenRatio','uint16'],['paused','bool'],['registrar']];
  const values=await batch(p,pin,names.map(([name,type])=>read(record.address,name,[],[],[type||'address'])),audit);
  const state=Object.fromEntries(names.map(([name],i)=>[name,values[i]]));
  assert(same(state.nutboxRouter,record.constructor.nutboxRouter)&&same(state.feeAddress,record.constructor.feeAddress)&&same(state.ipshare,IP)&&same(state.HANDLE_REGISTRY,HANDLE),'Deployed dependencies mismatch');
  assert(state.sellsmanRatio===20n&&state.tagaiRatio===20n&&state.nutboxTokenRatio===0n&&!state.paused,'Deployed fees/pause mismatch');
  const code=await p.send('eth_getCode',[record.address,ethers.toQuantity(pin)]);
  const art=artifact(),expected=art.deployedBytecode.object.replace(/^0x/,''); let actual=code.slice(2),masked=expected;
  for(const refs of Object.values(art.deployedBytecode.immutableReferences))for(const {start,length}of refs){masked=masked.slice(0,start*2)+'0'.repeat(length*2)+masked.slice((start+length)*2);actual=actual.slice(0,start*2)+'0'.repeat(length*2)+actual.slice((start+length)*2);}
  assert(actual===masked,'Deployed runtime does not match compiled source');
  const proof={checkedAt:new Date().toISOString(),blockNumber:pin,blockHash:block.hash,...state,runtime:{bytes:(code.length-2)/2,keccak256:ethers.keccak256(code),immutableMaskedMatch:true},multicallAudit:audit};
  write(BASE+'-status.json',proof);record.lastCheckedState=proof;
  if(same(state.owner,SAFE)&&same(state.pendingOwner,ethers.ZeroAddress)){
    record.status=record.sourceVerification?.status==='verified'?'deployed-verified-owned-by-safe':'deployed-owned-by-safe';
    record.handover={...record.handover,status:'accepted',targetOwner:SAFE,confirmedAt:proof.checkedAt,confirmedBlock:pin};
  }
  write(BASE+'.json',record);
  console.log(stringify({mode:'status',address:record.address,block:pin,...state,runtime:proof.runtime}));
  return proof;
}
async function handover(p) {
  const record=load(BASE+'.json');checkSources(record);
  const state=await status(p);assert(same(state.owner,record.deployer),'Deployer no longer owner');
  assert(same(state.pendingOwner,ethers.ZeroAddress),'Ownership transfer already pending; reconcile');
  const wallet=new ethers.Wallet(env.PRIVATE_KEY_MAIN,p),agent=new ethers.Contract(record.address,artifact().abi,wallet);
  const tx=await agent.transferOwnership(SAFE);record.handoverTransactionHash=tx.hash;write(BASE+'.json',record);
  const receipt=await tx.wait(2);assert(receipt.status===1,'Ownership initiation failed');
  const proof=await status(p);assert(same(proof.pendingOwner,SAFE),'Wrong pending owner');
  const current=load(BASE+'.json');current.handover={status:'pending-safe-acceptance',targetOwner:SAFE,transaction:receipt.toJSON()};current.status=current.sourceVerification?.status==='verified'?'deployed-verified-pending-safe-acceptance':'deployed-pending-verification-and-safe-acceptance';
  write(BASE+'.json',current);
  const safe={version:'1.0',chainId:'56',createdAt:Date.now(),meta:{name:'AgentSwapWrapper v1: accept ownership',description:'Accept two-step ownership of the independently deployed AgentSwapWrapper. Operator remains unset.',txBuilderVersion:'1.18.0',createdFromSafeAddress:SAFE,createdFromOwnerAddress:''},transactions:[{to:record.address,value:'0',data:agent.interface.encodeFunctionData('acceptOwnership'),contractMethod:{inputs:[],name:'acceptOwnership',payable:false},contractInputsValues:{}}]};
  write(BASE+'.safe.json',safe);fs.writeFileSync(BASE+'.safe.json.sha256',SHA(fs.readFileSync(BASE+'.safe.json'))+'  agent-swap-wrapper-v1.safe.json\n');
  console.log(stringify({mode:'handover',hash:tx.hash,pendingOwner:SAFE,safeFile:BASE+'.safe.json'}));
}
async function main() {
  const mode=process.argv[2];assert(['preflight','deploy','status','handover'].includes(mode),'Expected preflight, deploy, status or handover');
  const p=provider();try{await ({preflight,deploy,status,handover}[mode])(p);}finally{p.destroy();}
}
if(require.main===module)main().catch(e=>{console.error('Agent wrapper operation failed: '+(e.shortMessage||e.code||e.message).replace(/https?:\/\/[^\s]+/g,'[RPC URL suppressed]'));process.exitCode=1;});
module.exports={BASE,SAFE,FQN,readDependencies,readRouter};
