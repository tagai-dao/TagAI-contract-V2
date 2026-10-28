const {test}=require('node:test');
const assert=require('node:assert/strict');
const {batch,read,MC,multicall,checkIPShare}=require('./version18-chain.cjs');
const path=require('node:path');
const ethers=require(require.resolve('ethers',{paths:[process.cwd(),path.resolve('../buy-bot')]}));
const coder=ethers.AbiCoder.defaultAbiCoder();
const target='0x01B2308653c7e371B28A862444a40c12ca18b353';
const descriptors=[read(target,'VERSION',[],[],['uint256']),read(target,'createFee',[],[],['uint256'])];
function providerFor(mutator) {return {send:async(method,args)=>{
 assert.equal(method,'eth_call');assert.equal(args[0].to,MC);assert.equal(args[1],'0x7b');
 const calls=multicall.decodeFunctionData('aggregate3',args[0].data)[0];
 assert.equal(calls.length,3);assert.equal(calls[0].target,MC);assert.equal(calls[0].callData,multicall.encodeFunctionData('getBlockNumber'));
 descriptors.forEach((d,i)=>{assert.equal(calls[i+1].target,d.target);assert.equal(calls[i+1].callData,d.callData);assert.equal(calls[i+1].allowFailure,false);});
 const results=[[true,coder.encode(['uint256'],[123])],[true,coder.encode(['uint256'],[17])],[true,coder.encode(['uint256'],[5])]];
 mutator?.(results);return multicall.encodeFunctionResult('aggregate3',[results]);
 }};}
test('only Multicall receives eth_call, exact ordered subcalls and fixed blockTag',async()=>{assert.deepEqual(await batch(providerFor(),123,descriptors),[17n,5n]);});
test('reject wrong snapshot',async()=>{await assert.rejects(batch(providerFor(r=>{r[0][1]=coder.encode(['uint256'],[124]);}),123,descriptors));});
test('reject missing required data',async()=>{await assert.rejects(batch(providerFor(r=>{r[2][1]='0x';}),123,descriptors));});
test('reject failed required subcall',async()=>{await assert.rejects(batch(providerFor(r=>{r[1][0]=false;}),123,descriptors));});
test('reject result count mismatch',async()=>{await assert.rejects(batch(providerFor(r=>r.pop()),123,descriptors));});

const ipshare='0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922';
function feeProvider(fee=0n,price=0n,paused=false) {return {send:async(method,args)=>{
 assert.equal(method,'eth_call');assert.equal(args[0].to,MC);assert.equal(args[1],'0x7b');
 const calls=multicall.decodeFunctionData('aggregate3',args[0].data)[0];
 const expected=[read(MC,'getBlockNumber',[],[],['uint256']),read(ipshare,'createFee',[],[],['uint256']),read(ipshare,'getPrice',['uint256','uint256'],[10n**19n,0],['uint256']),read(ipshare,'paused',[],[],['bool'])];
 assert.equal(calls.length,expected.length);
 calls.forEach((c,i)=>{assert.equal(c.target,expected[i].target);assert.equal(c.callData,expected[i].callData);assert.equal(c.allowFailure,false);});
 return multicall.encodeFunctionResult('aggregate3',[[[true,coder.encode(['uint256'],[123])],[true,coder.encode(['uint256'],[fee])],[true,coder.encode(['uint256'],[price])],[true,coder.encode(['bool'],[paused])]]]);
 }};}
test('IPShare preflight uses exact fee/price/pause subcalls through pinned Multicall',async()=>{assert.deepEqual(await checkIPShare(feeProvider(),123,ipshare),{ipshareCreateFee:0n,initialSharePrice:0n,ipsharePaused:false});});
test('IPShare preflight rejects nonzero fee',async()=>{await assert.rejects(checkIPShare(feeProvider(1n),123,ipshare));});
test('IPShare preflight rejects nonzero initial price',async()=>{await assert.rejects(checkIPShare(feeProvider(0n,1n),123,ipshare));});
test('IPShare preflight rejects paused creation',async()=>{await assert.rejects(checkIPShare(feeProvider(0n,0n,true),123,ipshare));});
