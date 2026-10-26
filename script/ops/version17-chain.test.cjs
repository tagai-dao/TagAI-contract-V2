const {test}=require('node:test');
const assert=require('node:assert/strict');
const {batch,read,MC,multicall}=require('./version17-chain.cjs');
const path=require('node:path');
const ethers=require(require.resolve('ethers',{paths:[process.cwd(),path.resolve('../buy-bot')]}));
const coder=ethers.AbiCoder.defaultAbiCoder();
const target='0xee8D16f44c89B5F858e223Ab77c6091E184AaDf8';
const descriptors=[read(target,'VERSION',[],[],['uint256']),read(target,'createFee',[],[],['uint256'])];
function providerFor(mutator) {return {send:async(method,args)=>{
 assert.equal(method,'eth_call');assert.equal(args[0].to,MC);assert.equal(args[1],'0x7b');
 const calls=multicall.decodeFunctionData('aggregate3',args[0].data)[0];
 assert.equal(calls.length,3);assert.equal(calls[0].target,MC);assert.equal(calls[0].callData,multicall.encodeFunctionData('getBlockNumber'));
 descriptors.forEach((d,i)=>{assert.equal(calls[i+1].target,d.target);assert.equal(calls[i+1].callData,d.callData);assert.equal(calls[i+1].allowFailure,false);});
 const results=[[true,coder.encode(['uint256'],[123])],[true,coder.encode(['uint256'],[16])],[true,coder.encode(['uint256'],[5])]];
 mutator?.(results);return multicall.encodeFunctionResult('aggregate3',[results]);
 }};}
test('only Multicall receives eth_call, exact ordered subcalls and fixed blockTag',async()=>{assert.deepEqual(await batch(providerFor(),123,descriptors),[16n,5n]);});
test('reject wrong snapshot',async()=>{await assert.rejects(batch(providerFor(r=>{r[0][1]=coder.encode(['uint256'],[124]);}),123,descriptors));});
test('reject missing required data',async()=>{await assert.rejects(batch(providerFor(r=>{r[2][1]='0x';}),123,descriptors));});
test('reject failed required subcall',async()=>{await assert.rejects(batch(providerFor(r=>{r[1][0]=false;}),123,descriptors));});
test('reject result count mismatch',async()=>{await assert.rejects(batch(providerFor(r=>r.pop()),123,descriptors));});
