const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const {batch,read,MC,multicall,preflight,PREVIOUS,TRADE,MULTI_ROUTER,ADAPTER,ethers}=require('./version19-chain.cjs');
const coder=ethers.AbiCoder.defaultAbiCoder(),pin=123;
const target='0x'+'11'.repeat(20);
const descriptors=[read(target,'VERSION',[],[],['uint256']),read(target,'createFee',[],[],['uint256'])];
function provider(mutator){return {send:async(method,args)=>{
 assert.equal(method,'eth_call');assert.equal(args[0].to,MC);assert.equal(args[1],'0x7b');
 const calls=multicall.decodeFunctionData('aggregate3',args[0].data)[0];
 assert.deepEqual(calls.map(c=>[c.target,c.allowFailure,c.callData]),[[MC,false,multicall.encodeFunctionData('getBlockNumber')],...descriptors.map(d=>[d.target,false,d.callData])]);
 const rows=[[true,coder.encode(['uint256'],[pin])],[true,coder.encode(['uint256'],[19])],[true,coder.encode(['uint256'],[5])]];mutator?.(rows);
 return multicall.encodeFunctionResult('aggregate3',[rows]);
}}}
test('pinned Multicall target and exact ordered required subcalls',async()=>assert.deepEqual(await batch(provider(),pin,descriptors),[19n,5n]));
for(const [name,mutate]of [['wrong block',r=>r[0][1]=coder.encode(['uint256'],[124])],['missing result',r=>r.pop()],['child failure',r=>r[1][0]=false],['empty required data',r=>r[2][1]='0x']])test(`refuses ${name}`,async()=>assert.rejects(batch(provider(mutate),pin,descriptors)));
test('oversized reads split only into pinned Multicalls while preserving order',async()=>{
 const ds=Array.from({length:5},(_,i)=>read(target,'value',['uint256'],[i],['uint256']));let offset=0,calls=0;
 const p={send:async(method,args)=>{calls++;assert.equal(method,'eth_call');assert.equal(args[0].to,MC);assert.equal(args[1],'0x7b');const children=multicall.decodeFunctionData('aggregate3',args[0].data)[0];const part=ds.slice(offset,offset+2);assert.deepEqual(children.slice(1).map(c=>c.callData),part.map(d=>d.callData));const rows=[[true,coder.encode(['uint256'],[pin])],...part.map((_,i)=>[true,coder.encode(['uint256'],[offset+i])])];offset+=part.length;return multicall.encodeFunctionResult('aggregate3',[rows])}};
 assert.deepEqual(await batch(p,pin,ds,[],2),[0n,1n,2n,3n,4n]);assert.equal(calls,3);
});
test('complete V19 preflight checks exact snapshot, permissions, catalogue and existing V18',async()=>{
 const addr=n=>ethers.getAddress('0x'+n.toString(16).padStart(40,'0'));
 const c={owner:addr(1),getIPShare:addr(2),getFeeReceiver:addr(3),getPoolManager:addr(4),getVault:addr(5),nutboxCommunityFactory:addr(6),getCalculator:addr(7),erc20StakingFactory:addr(8),nutboxCommittee:addr(9),nutboxRouter:addr(10),basketHookV4:addr(11),pancakeV2Factory:addr(12),settlementToken:addr(13),listingKeeper:addr(14),buybackRouter:addr(15),tokenImplementation:addr(16),getHookAddress:addr(17)};
 const abi=new ethers.Interface([
 ...Object.keys(c).map(n=>`function ${n}() view returns(address)`),
 'function createFee() view returns(uint256)','function getFeeRatio() view returns(uint256[2])','function listingSwapSlippageBps() view returns(uint16)','function VERSION() view returns(uint256)','function pendingOwner() view returns(address)',
 'function optionalPoolFactories(address) view returns(string,uint16,bool)','function getEthBalance(address) view returns(uint256)',
 'function basketRegistry() view returns(address)','function basketRouter() view returns(address)','function getPrice(uint256,uint256) view returns(uint256)','function paused() view returns(bool)',
 'function getOwners() view returns(address[])','function getThreshold() view returns(uint256)','function nonce() view returns(uint256)',
 'function operators(address) view returns(bool)','function approvedCreatorForwarders(address) view returns(bool)','function verifyContract(address) view returns(bool)','function pumpEnabled(address) view returns(bool)',
 'function hookPolicies(address) view returns(bytes32,uint16,uint16,uint16)','function approvedConstituent(address) view returns(bool)','function hasRoute(address,address) view returns(bool)',
 ]);
 const seen=[],catalog=[...fs.readFileSync('script/config/BSCNutboxRouterConfig.sol','utf8').matchAll(/\btoken:\s*(0x[\da-fA-F]{40})/g)].map(m=>ethers.getAddress(m[1]));
 const p={send:async(method,args)=>{
  assert.equal(method,'eth_call');assert.equal(args[0].to,MC);assert.equal(args[1],'0x7b');
  const children=multicall.decodeFunctionData('aggregate3',args[0].data)[0];
  assert.equal(children[0].target,MC);assert.equal(children[0].callData,multicall.encodeFunctionData('getBlockNumber'));
  const rows=[[true,coder.encode(['uint256'],[pin])]];
  for(const child of children.slice(1)){
   assert.equal(child.allowFailure,false);const f=abi.parseTransaction({data:child.callData});seen.push([child.target,f.name,Array.from(f.args)]);
   let value;
   if(Object.hasOwn(c,f.name))value=c[f.name];
   else value={createFee:0n,getFeeRatio:[30n,30n],listingSwapSlippageBps:300n,VERSION:18n,pendingOwner:ethers.ZeroAddress,optionalPoolFactories:['Trade Curation',8000,true],getEthBalance:10n**18n,basketRegistry:addr(18),basketRouter:addr(19),getPrice:0n,paused:false,getOwners:[addr(20)],getThreshold:1n,nonce:0n,operators:true,approvedCreatorForwarders:true,verifyContract:true,pumpEnabled:true,hookPolicies:[ethers.ZeroHash,30n,30n,30n],approvedConstituent:true,hasRoute:true}[f.name];
   rows.push([true,abi.encodeFunctionResult(f.name,f.fragment.outputs.length===1?[value]:value)]);
  }
  return multicall.encodeFunctionResult('aggregate3',[rows]);
 }};
 const result=await preflight(p,pin,addr(21));assert.equal(result.previousPump,PREVIOUS);assert.equal(result.constituents.length,16);assert.equal(result.balanceWei,10n**18n);
 const methods=['owner','getIPShare','getFeeReceiver','getPoolManager','getVault','nutboxCommunityFactory','getCalculator','erc20StakingFactory','nutboxCommittee','nutboxRouter','basketHookV4','pancakeV2Factory','settlementToken','listingKeeper','buybackRouter','createFee','getFeeRatio','listingSwapSlippageBps','VERSION','tokenImplementation','pendingOwner','getHookAddress','optionalPoolFactories'];
 assert.deepEqual(seen.slice(0,23).map(([t,m])=>[t,m]),methods.map(m=>[PREVIOUS,m]));
 assert.deepEqual(seen.filter(([,m])=>m==='approvedConstituent'),catalog.map(a=>[PREVIOUS,'approvedConstituent',[a]]));
 assert.deepEqual(seen.filter(([,m])=>m==='hasRoute'),catalog.flatMap(a=>[[c.nutboxRouter,'hasRoute',[ethers.ZeroAddress,a]],[c.nutboxRouter,'hasRoute',[c.settlementToken,a]]]));
 assert.deepEqual(seen.find(([,m])=>m==='operators'),[c.nutboxRouter,'operators',[PREVIOUS]]);
 assert.deepEqual(seen.find(([,m])=>m==='approvedCreatorForwarders'),[addr(18),'approvedCreatorForwarders',[PREVIOUS]]);
 assert.deepEqual(seen.find(([,m])=>m==='optionalPoolFactories'),[PREVIOUS,'optionalPoolFactories',[TRADE]]);
 assert.deepEqual(seen.find(([,m])=>m==='getEthBalance'),[MC,'getEthBalance',[addr(21)]]);
 assert.deepEqual(seen.filter(([t,m])=>m==='owner'&&[MULTI_ROUTER,ADAPTER].includes(t)).map(([t])=>t),[MULTI_ROUTER,ADAPTER]);
 assert.equal(result.multicallAudit.length,3);assert.ok(result.multicallAudit.every(a=>a.blockTag==='0x7b'&&a.target===MC));
});
