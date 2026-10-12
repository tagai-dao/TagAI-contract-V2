import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import path from 'node:path';
import { addresses as a, verifyState } from './verify-rh-import-helper-v2.mjs';
const require = createRequire(path.resolve('../tiptag-ui/package.json'));
const { parseAbi,decodeFunctionData,encodeFunctionResult } = require('viem');
const mc = parseAbi(['function aggregate3((address target,bool allowFailure,bytes callData)[] calls) payable returns((bool success,bytes returnData)[])']);
const abi = parseAbi([
  'function owner() view returns(address)','function registrar() view returns(address)','function wrappedNative() view returns(address)',
  'function swapWrapper() view returns(address)','function communityFactory() view returns(address)','function claimSigner() view returns(address)',
  'function verifyContract(address) view returns(bool)','function VERSION() view returns(uint256)','function committee() view returns(address)',
  'function tradeCurationFactory() view returns(address)','function hourlyTickCalculator() view returns(address)','function defaultPoolCount() view returns(uint256)',
  'function getDefaultPools() view returns((address factory,uint16 rewardRatio,bytes meta)[])',
]);
const admin='0x'+'11'.repeat(20), helper='0x'+'22'.repeat(20), signer='0x'+'33'.repeat(20);
function fixture(options={}) {
  const calls=[];
  const expected=[
    [a.wrapper,'owner'],[a.wrapper,'registrar'],[a.wrapper,'wrappedNative'],[a.oldHelper,'swapWrapper'],
    [a.tradeFactory,'communityFactory'],[a.tradeFactory,'claimSigner'],[a.calculator,'communityFactory'],
    [a.committee,'verifyContract',[a.tradeFactory]],[a.committee,'verifyContract',[a.calculator]],
    ...options.helper?['VERSION','owner','communityFactory','tradeCurationFactory','committee','hourlyTickCalculator','swapWrapper','defaultPoolCount','getDefaultPools'].map(fn=>[helper,fn]):[],
  ];
  const values=[admin,options.activated?helper:a.oldHelper,a.weth,a.wrapper,a.communityFactory,signer,a.communityFactory,true,true,
    2n,admin,a.communityFactory,a.tradeFactory,a.committee,a.calculator,a.wrapper,1n,[{factory:a.tradeFactory,rewardRatio:10000,meta:'0x'}]];
  if (options.foreignFactory) values[4]=helper;
  if (options.wrongDefaults) values[17][0].rewardRatio=7000;
  const rpc = async(method,params)=>{
    calls.push([method,params]);
    if(method==='eth_chainId') return options.wrongChain?'0x38':'0x1237';
    if(method==='eth_blockNumber') return '0x123456';
    if(method==='eth_getCode') { assert.equal(params[1],'0x123456');return options.missingMulticall?'0x':'0x1234'; }
    assert.equal(method,'eth_call','No individual contract RPC fallback');
    assert.equal(params[1],'0x123456'); assert.equal(params[0].to,a.multicall);
    const children=decodeFunctionData({abi:mc,data:params[0].data}).args[0];
    assert.equal(children.length,expected.length);
    const result=children.map((child,i)=>{
      assert.equal(child.target.toLowerCase(),expected[i][0].toLowerCase()); assert.equal(child.allowFailure,false);
      const decoded=decodeFunctionData({abi,data:child.callData});
      assert.equal(decoded.functionName,expected[i][1]);
      assert.deepEqual(decoded.args?.map(x=>String(x).toLowerCase())||[],(expected[i][2]||[]).map(x=>x.toLowerCase()));
      return {success:!(options.failedChild&&i===5),returnData:encodeFunctionResult({abi,functionName:decoded.functionName,result:values[i]})};
    });
    return encodeFunctionResult({abi:mc,functionName:'aggregate3',result:options.incomplete?result.slice(1):result});
  };
  return {rpc,calls};
}
test('RH preflight uses one ordered on-chain Multicall with exact child targets and a fixed block',async()=>{
  const {rpc,calls}=fixture(); const state=await verifyState(rpc);
  assert.equal(state.owner,admin);assert.equal(state.registrar,a.oldHelper);assert.equal(state.helper,null);
  assert.equal(calls.filter(([method])=>method==='eth_call').length,1);
});
test('deployed helper and activation checks remain in the same Multicall snapshot',async()=>{
  for(const activated of [false,true]){
    const {rpc,calls}=fixture({helper:true,activated});const state=await verifyState(rpc,helper,activated);
    assert.equal(state.helper,helper);assert.equal(state.activated,activated);
    assert.equal(calls.filter(([method])=>method==='eth_call').length,1);
  }
});
test('wrong chain, absent Multicall, failed/incomplete reads and foreign factory fail closed',async()=>{
  for(const option of ['wrongChain','missingMulticall','failedChild','incomplete','foreignFactory'])
    await assert.rejects(verifyState(fixture({[option]:true}).rpc));
});
test('unexpected initial reward allocation is rejected',async()=>{
  await assert.rejects(verifyState(fixture({helper:true,wrongDefaults:true}).rpc,helper),/Unexpected defaults/);
});
