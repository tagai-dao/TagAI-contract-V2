import test from 'node:test';
import assert from 'node:assert/strict';
import { eligiblePool } from './rh14-stock-selection.mjs';
const asset = '0x0000000000000000000000000000000000000001';
const weth = '0x0000000000000000000000000000000000000002';
const usdg = '0x0000000000000000000000000000000000000003';
function sample() { return {stats:{tvl:50000.01},pool:{chainId:4663,token0:{address:asset},token1:{address:usdg},protocolVersion:'PROTOCOL_VERSION_V3',feeTier:500,liquidity:'100'}}; }
const accepted = r => eligiblePool(r,asset,weth,usdg);
test('threshold is strict, finite, per pool; huge volume does not qualify',()=>{
  assert.equal(accepted(sample()),true);
  for(const tvl of [50000,49999,0,NaN,Infinity]) {const r=sample();r.stats={tvl,volume1d:1e12};assert.equal(accepted(r),false);}
  assert.equal(accepted({...sample(),stats:{tvl:30000}}),false);
});
test('only RH stock pairs with supported quotes are selected',()=>{
  for(const change of [r=>r.pool.chainId=56,r=>r.pool.token0.address=weth,r=>r.pool.token1.address='0x0000000000000000000000000000000000000004']) {const r=sample();change(r);assert.equal(accepted(r),false);}
  const r=sample();r.pool.token1.address=weth;assert.equal(accepted(r),true);
});
test('inactive, hooked, dynamic and unsupported pools are rejected',()=>{
  for(const change of [r=>r.pool.liquidity='0',r=>r.pool.hookAddress=asset,r=>r.pool.isDynamicFee=true,r=>r.pool.feeTier=50000,r=>r.pool.protocolVersion='PROTOCOL_VERSION_V2']) {const r=sample();change(r);assert.equal(accepted(r),false);}
  const r=sample();r.pool.protocolVersion='PROTOCOL_VERSION_V4';r.pool.feeTier=0;r.pool.hookAddress='0x0000000000000000000000000000000000000000';assert.equal(accepted(r),true);
});
