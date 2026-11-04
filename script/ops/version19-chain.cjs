const fs=require('node:fs');
const path=require('node:path');
const {spawn}=require('node:child_process');
const crypto=require('node:crypto');
const ethers=require(require.resolve('ethers',{paths:[process.cwd(),path.resolve('../tagai-api')]}));
const MC='0xcA11bde05977b3631167028862bE2a173976CA11';
const PREVIOUS='0x3B174dB24A44d7172C1f4Fb8Ab387F3931681C24';
const TRADE='0x774A48Ba391a1013Ae43289eBdf871618822CD67';
const MULTI_ROUTER='0xB70544BfdACaBD8718261d7A6be5208b7D2f6Ebf';
const ADAPTER='0x226D3e94569c44578a892A5158F0a3Defe49B8ca';
const multicall=new ethers.Interface(['function aggregate3((address target,bool allowFailure,bytes callData)[] calls) payable returns ((bool success,bytes returnData)[] results)','function getBlockNumber() view returns(uint256)']);
const json=(value)=>JSON.stringify(value,(_,v)=>typeof v==='bigint'?v.toString():v,2)+'\n';
const sha=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
function read(target,name,inputs=[],args=[],outputs=['address']){const abi=new ethers.Interface([`function ${name}(${inputs.join(',')}) view returns(${outputs.join(',')})`]);return {target,name,args,abi,callData:abi.encodeFunctionData(name,args)};}
async function batch(provider,pin,descriptors,audit=[],size=64){
 const all=[];
 for(let offset=0;offset<descriptors.length;offset+=size){
  const part=descriptors.slice(offset,offset+size);
  const calls=[{target:MC,allowFailure:false,callData:multicall.encodeFunctionData('getBlockNumber')},...part.map(d=>({target:d.target,allowFailure:false,callData:d.callData}))];
  const blockTag=ethers.toQuantity(pin);
  const raw=await provider.send('eth_call',[{to:MC,data:multicall.encodeFunctionData('aggregate3',[calls])},blockTag]);
  const result=multicall.decodeFunctionResult('aggregate3',raw)[0];
  if(result.length!==calls.length||!result[0].success||ethers.AbiCoder.defaultAbiCoder().decode(['uint256'],result[0].returnData)[0]!==BigInt(pin))throw Error('Multicall snapshot/count mismatch');
  const values=part.map((d,i)=>{const r=result[i+1];if(!r.success||r.returnData==='0x')throw Error('Required Multicall read failed: '+d.name);const v=d.abi.decodeFunctionResult(d.name,r.returnData);return v.length===1?v[0]:Array.from(v)});
  audit.push({target:MC,blockTag,calls});all.push(...values);
 }
 return all;
}
class CurlRpc {
 constructor(url){this.url=url;this.authorizedRaw=new Set();}
 authorizeRaw(hash){this.authorizedRaw.add(hash.toLowerCase());}
 async send(method,params){
  for(let attempt=0;;attempt++){try{return await this.sendOnce(method,params)}catch(e){if(method==='eth_sendRawTransaction'||attempt>=3||!(String(e.code).startsWith('CURL_')||e.message==='RPC invalid JSON'||e.message==='RPC missing result'))throw e;}}
 }
 async sendOnce(method,params){
  if(method==='eth_sendRawTransaction'){
   if(!this.authorizedRaw.has(ethers.keccak256(params[0]).toLowerCase()))throw Error('Unapproved signed transaction');
  }else if(!new Set(['eth_chainId','eth_blockNumber','eth_getBlockByNumber','eth_getBlockByHash','eth_getBalance','eth_getTransactionCount','eth_getTransactionReceipt','eth_getTransactionByHash','eth_getCode','eth_getLogs','eth_getStorageAt','eth_gasPrice','eth_call']).has(method))throw Error('RPC method not allowed');
  if(method==='eth_call'&&(params[0].to?.toLowerCase()!==MC.toLowerCase()||!/^0x[0-9a-f]+$/i.test(params[1])))throw Error('Contract reads require pinned Multicall');
  const body=JSON.stringify({jsonrpc:'2.0',id:1,method,params});
  return new Promise((resolve,reject)=>{
   const p=spawn('curl',['--config','-'],{stdio:['pipe','pipe','pipe']});let out='';
   p.stdout.on('data',x=>out+=x);p.stderr.resume();p.on('error',()=>reject(Error('RPC transport launch failed')));
   p.on('close',code=>{if(code!==0)return reject(Object.assign(Error('RPC transport unavailable'),{code:'CURL_'+code}));let data;try{data=JSON.parse(out)}catch{return reject(Error('RPC invalid JSON'))}if(data.error)return reject(Object.assign(Error('RPC response error'),{code:data.error.code,rpcMessage:String(data.error.message||'').replace(/https?:\/\/\S+/g,'<URL>')}));if(!Object.hasOwn(data,'result'))return reject(Object.assign(Error('RPC missing result'),{code:'RPC_SHAPE_'+Object.keys(data).join('_'),rpcMessage:String(data.message||data.code||'').replace(/https?:\/\/\S+/g,'<URL>')}));resolve(data.result);});
   p.stdin.end('url = '+JSON.stringify(this.url)+'\nrequest = "POST"\nheader = "Content-Type: application/json"\ndata = '+JSON.stringify(body)+'\nmax-time = 25\nsilent\nshow-error\n');
  });
 }
}
const fields=[['owner'],['getIPShare'],['getFeeReceiver'],['getPoolManager'],['getVault'],['nutboxCommunityFactory'],['getCalculator'],['erc20StakingFactory'],['nutboxCommittee'],['nutboxRouter'],['basketHookV4'],['pancakeV2Factory'],['settlementToken'],['listingKeeper'],['buybackRouter'],['createFee','uint256'],['getFeeRatio','uint256[2]'],['listingSwapSlippageBps','uint16'],['VERSION','uint256'],['tokenImplementation'],['pendingOwner'],['getHookAddress']];
async function preflight(provider,pin,deployer){
 const audit=[];
 const primary=await batch(provider,pin,[...fields.map(([n,t])=>read(PREVIOUS,n,[],[],[t||'address'])),read(PREVIOUS,'optionalPoolFactories',['address'],[TRADE],['string','uint16','bool']),read(MC,'getEthBalance',['address'],[deployer],['uint256'])],audit);
 const c=Object.fromEntries(fields.map(([n],i)=>[n,primary[i]]));c.optionalTradePool=primary[fields.length];
 if(c.VERSION!==18n||c.pendingOwner!==ethers.ZeroAddress)throw Error('V18 ownership/version changed; review required');
 const infrastructure=await batch(provider,pin,[read(c.basketHookV4,'basketRegistry'),read(c.buybackRouter,'basketRouter'),read(c.nutboxRouter,'owner'),read(c.nutboxCommittee,'owner'),read(c.getIPShare,'createFee',[],[],['uint256']),read(c.getIPShare,'getPrice',['uint256','uint256'],[10n**19n,0],['uint256']),read(c.getIPShare,'paused',[],[],['bool'])],audit);
 const [registry,basketRouter,routerOwner,committeeOwner,ipshareCreateFee,initialSharePrice,ipsharePaused]=infrastructure;
 if(ipshareCreateFee!==0n||initialSharePrice!==0n||ipsharePaused)throw Error('V19 requires free and unpaused IPShare creation');
 const safe=c.owner;
 const catalog=[...fs.readFileSync('script/config/BSCNutboxRouterConfig.sol','utf8').matchAll(/\btoken:\s*(0x[\da-fA-F]{40})/g)].map(m=>ethers.getAddress(m[1]));
 if(catalog.length!==16)throw Error('Constituent catalog changed');
 const more=await batch(provider,pin,[read(registry,'owner'),read(safe,'getOwners',[],[],['address[]']),read(safe,'getThreshold',[],[],['uint256']),read(safe,'nonce',[],[],['uint256']),read(c.nutboxRouter,'operators',['address'],[PREVIOUS],['bool']),read(registry,'approvedCreatorForwarders',['address'],[PREVIOUS],['bool']),read(c.nutboxCommittee,'verifyContract',['address'],[c.erc20StakingFactory],['bool']),read(c.nutboxCommittee,'verifyContract',['address'],[c.getCalculator],['bool']),read(c.nutboxCommittee,'verifyContract',['address'],[TRADE],['bool']),read(MULTI_ROUTER,'owner'),read(MULTI_ROUTER,'pendingOwner'),read(MULTI_ROUTER,'pumpEnabled',['address'],[PREVIOUS],['bool']),read(ADAPTER,'owner'),read(ADAPTER,'pendingOwner'),read(ADAPTER,'hookPolicies',['address'],[c.getHookAddress],['bytes32','uint16','uint16','uint16']),...catalog.flatMap(a=>[read(PREVIOUS,'approvedConstituent',['address'],[a],['bool']),read(c.nutboxRouter,'hasRoute',['address','address'],[ethers.ZeroAddress,a],['bool']),read(c.nutboxRouter,'hasRoute',['address','address'],[c.settlementToken,a],['bool'])])],audit);
 const eq=(a,b)=>a.toLowerCase()===b.toLowerCase();
 if(!eq(safe,routerOwner)||!eq(safe,more[0]))throw Error('Activation owner mismatch');
 if(!more[4]||!more[5])throw Error('Existing V18 activation changed');
 const start=15,constituents=catalog.filter((_,i)=>more[start+i*3]);
 if(!constituents.length||catalog.some((_,i)=>more[start+i*3]&&(!more[start+i*3+1]||!more[start+i*3+2])))throw Error('Approved constituent route missing');
 if(c.optionalTradePool[0]!=='Trade Curation'||c.optionalTradePool[1]!==8000n||!c.optionalTradePool[2])throw Error('Optional pool policy changed');
 return {chainId:56,blockNumber:pin,previousPump:PREVIOUS,deployer,targetOwner:safe,balanceWei:primary[fields.length+1],configuration:c,infrastructure:{registry,basketRouter,routerOwner,registryOwner:more[0],committeeOwner,ipshareCreateFee,initialSharePrice,ipsharePaused},safe:{address:safe,owners:more[1],threshold:more[2],nonce:more[3]},previousActivation:{operator:more[4],creatorForwarder:more[5]},committeeAllowlist:{staking:more[6],calculator:more[7],trade:more[8]},tradingAdmission:{router:MULTI_ROUTER,routerOwner:more[9],routerPendingOwner:more[10],v18PumpEnabled:more[11],adapter:ADAPTER,adapterOwner:more[12],adapterPendingOwner:more[13],v18HookPolicy:more[14]},constituents,multicallAudit:audit};
}
async function auditMappings(provider,data){
 const events=new ethers.Interface(['event ConstituentApprovalSet(address indexed asset,bool approved)','event OptionalPoolFactorySet(address indexed factory,string name,uint16 maxRewardRatio,bool enabled)']);
 const logs=[],chunks=[];const span=5000,cache='previews/version19-v18-mapping-logs.ndjson',saved=new Map();
 if(fs.existsSync(cache))for(const row of fs.readFileSync(cache,'utf8').split('\n').filter(Boolean)){const x=JSON.parse(row);saved.set(x.key,x.logs)}
 for(let start=130215462;start<=data.blockNumber;start+=span)chunks.push([start,Math.min(data.blockNumber,start+span-1)]);
 let next=0,done=0;async function worker(){for(;;){const i=next++;if(i>=chunks.length)return;const[start,end]=chunks[i],key=start+':'+end;let rows=saved.get(key);if(!rows){rows=await provider.send('eth_getLogs',[{address:PREVIOUS,fromBlock:ethers.toQuantity(start),toBlock:ethers.toQuantity(end),topics:[[events.getEvent('ConstituentApprovalSet').topicHash,events.getEvent('OptionalPoolFactorySet').topicHash]]}]);fs.appendFileSync(cache,JSON.stringify({key,logs:rows})+'\n')}logs.push(...rows);if(++done%25===0)console.log(JSON.stringify({phase:'mapping-log-audit',completed:done,total:chunks.length}));}}
 const workers=await Promise.allSettled(Array.from({length:2},worker));for(const w of workers)if(w.status==='rejected')throw w.reason;
 const approvals=new Map(),factories=new Map();
 logs.sort((a,b)=>Number(BigInt(a.blockNumber)-BigInt(b.blockNumber))||Number(BigInt(a.logIndex)-BigInt(b.logIndex)));
 for(const log of logs){const e=events.parseLog(log);if(e.name==='ConstituentApprovalSet')approvals.set(e.args.asset.toLowerCase(),e.args.approved);else factories.set(e.args.factory.toLowerCase(),{name:e.args.name,maxRewardRatio:e.args.maxRewardRatio,enabled:e.args.enabled});}
 const active=[...approvals].filter(([,v])=>v).map(([k])=>k).sort();
 if(JSON.stringify(active)!==JSON.stringify(data.constituents.map(a=>a.toLowerCase()).sort()))throw Error('V18 has approvals outside the preserved catalog');
 if([...factories].some(([a,c])=>c.enabled&&a!==TRADE.toLowerCase()))throw Error('V18 has an additional enabled pool factory');
 data.mappingLogAudit={fromBlock:130215462,toBlock:data.blockNumber,logCount:logs.length,approvedConstituents:active,optionalPoolFactories:Object.fromEntries(factories)};
}
async function main(){
 const dotenv=require(require.resolve('dotenv',{paths:[process.cwd(),path.resolve('../tagai-api')]}));const env={...dotenv.parse(fs.readFileSync('.env')),...process.env};
 if(!env.BSC_RPC_URL||!env.PRIVATE_KEY_MAIN)throw Error('Missing deployment environment');
 if(fs.existsSync('deployments/56/version19.json'))throw Error('V19 deployment record exists; reconcile before continuing');
 const provider=new CurlRpc(env.BSC_RPC_URL);if(BigInt(await provider.send('eth_chainId',[]))!==56n)throw Error('Wrong chain');
 const block=await provider.send('eth_getBlockByNumber',['latest',false]);const pin=Number(BigInt(block.number));const deployer=new ethers.Wallet(env.PRIVATE_KEY_MAIN).address;
 const data=await preflight(provider,pin,deployer);data.blockHash=block.hash;data.checkedAt=new Date().toISOString();
 data.latestNonce=Number(BigInt(await provider.send('eth_getTransactionCount',[deployer,ethers.toQuantity(pin)])));data.pendingNonce=Number(BigInt(await provider.send('eth_getTransactionCount',[deployer,'pending'])));if(data.latestNonce!==data.pendingNonce)throw Error('Deployment account has pending transactions');
 data.gasPriceWei=await provider.send('eth_gasPrice',[]);data.blockGasLimit=block.gasLimit;data.blockBaseFee=block.baseFeePerGas||'0x0';
 if(BigInt(data.gasPriceWei)<BigInt(data.blockBaseFee))throw Error('Gas price below base fee');
 await auditMappings(provider,data);
 const readiness=JSON.parse(fs.readFileSync('previews/pump19-deployment-readiness-2026-11-04.json'));if(!readiness.mainnetFork.completedSuccessfully)throw Error('Mainnet fork not validated');
 for(const [file,hash]of Object.entries(readiness.sourceSha256))if(sha(file)!==hash)throw Error('Reviewed source changed: '+file);
 data.reviewedSourceSha256=readiness.sourceSha256;data.testEvidence={local:readiness.localTests,fork:readiness.mainnetFork};
 fs.writeFileSync('deployments/56/version19-deployment-preflight.json',json(data));
 console.log(JSON.stringify({file:'deployments/56/version19-deployment-preflight.json',block:pin,deployer,balanceBNB:ethers.formatEther(data.balanceWei),pendingNonce:data.pendingNonce,gasPriceGwei:ethers.formatUnits(BigInt(data.gasPriceWei),9),targetOwner:data.targetOwner,constituents:data.constituents.length,tradingAdmission:data.tradingAdmission}));
}
if(require.main===module)main().catch(e=>{console.error(JSON.stringify({error:e.message,code:e.code,rpcMessage:e.rpcMessage}));process.exitCode=1});
module.exports={MC,PREVIOUS,TRADE,MULTI_ROUTER,ADAPTER,multicall,read,batch,CurlRpc,preflight,auditMappings,fields,sha,json,ethers};
