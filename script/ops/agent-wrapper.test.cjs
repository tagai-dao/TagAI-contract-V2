const {test} = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const ethers = require(require.resolve('ethers',{paths:[process.cwd(),path.resolve('../buy-bot')]}));
const {readDependencies,readRouter} = require('./agent-wrapper.cjs');
const {MC,multicall} = require('./version18-chain.cjs');
const old='0xDfFc699FB095a693708E3c15e6F0a224cbbCc98F';
const pump='0x3B174dB24A44d7172C1f4Fb8Ab387F3931681C24';
const safe='0x871fb7006C5964B21695Ba20006021777A26146C';
const handle='0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F';
const router='0x72dc4F38A7E4159e97d826a6ab594748C6b68f17';
const manager='0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b';
const deployer='0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611';
const wbnb='0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c', usdt='0x55d398326f99059fF775485246999027B3197955';
function providerFor(specs) {
  let requests=0;
  return {get requests(){return requests;},send:async(method,args)=>{
    ++requests;
    assert.equal(method,'eth_call');assert.equal(args[0].to,MC);assert.equal(args[1],'0x7b');
    const calls=multicall.decodeFunctionData('aggregate3',args[0].data)[0];
    assert.equal(calls.length,specs.length+1);
    assert.equal(calls[0].target,MC);assert.equal(calls[0].callData,multicall.encodeFunctionData('getBlockNumber'));
    const results=[[true,ethers.AbiCoder.defaultAbiCoder().encode(['uint256'],[123])]];
    specs.forEach(([target,signature,inputs,value],i)=>{
      const abi=new ethers.Interface(['function '+signature]),fn=abi.fragments[0];
      assert.equal(calls[i+1].target,target);
      assert.equal(calls[i+1].callData,abi.encodeFunctionData(fn,inputs));
      assert.equal(calls[i+1].allowFailure,false);
      results.push([true,abi.encodeFunctionResult(fn,[value])]);
    });
    return multicall.encodeFunctionResult('aggregate3',[results]);
  }};
}
test('Agent dependencies use only pinned Multicall with exact deployed wrapper, Pump, Safe and Handle subcalls',async()=>{
  const specs=[
    ...['nutboxRouter','feeAddress','ipshare'].map(n=>[old,`${n}() view returns(address)`,[],router]),
    ...['nutboxRouter','getFeeReceiver','getIPShare'].map(n=>[pump,`${n}() view returns(address)`,[],router]),
    [safe,'getThreshold() view returns(uint256)',[],2],
    [safe,'getOwners() view returns(address[])',[],[deployer]],
    [handle,'handleOf(address) view returns(string)',[deployer],'agent']
  ];
  const p=providerFor(specs),audit=[];
  assert.equal((await readDependencies(p,123,deployer,audit)).length,specs.length);
  assert.equal(p.requests,1);assert.equal(audit[0].blockTag,'0x7b');
});
test('Agent router stage pins same block and preserves exact factory, manager, bidirectional bridge and balance calls',async()=>{
  const specs=[
    [router,'wrappedNative() view returns(address)',[],wbnb],
    [router,'allowedV2Factory(address) view returns(bool)',['0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73'],true],
    [router,'v2RouterForFactory(address) view returns(address)',['0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73'],deployer],
    [router,'allowedV3Factory(address) view returns(bool)',['0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865'],true],
    [router,'allowedPancakeV4CLManager(address) view returns(bool)',[manager],true],
    [router,'hasRoute(address,address) view returns(bool)',[wbnb,usdt],true],
    [router,'hasRoute(address,address) view returns(bool)',[usdt,wbnb],true],
    [MC,'getEthBalance(address) view returns(uint256)',[deployer],1]
  ];
  const p=providerFor(specs),audit=[];
  assert.equal((await readRouter(p,123,router,manager,deployer,audit)).length,specs.length);
  assert.equal(p.requests,1);assert.equal(audit[0].blockTag,'0x7b');
});
