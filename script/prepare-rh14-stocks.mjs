#!/usr/bin/env node
// Read-only chain validation + deterministic V14 config generation. Never broadcasts.
import fs from 'node:fs';
import { eligiblePool } from './config/rh14-stock-selection.mjs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const require = createRequire(path.resolve(process.env.RH14_NODE_PACKAGE || '../tiptag-ui/package.json'));
const { encodeAbiParameters, parseAbiParameters, encodeFunctionData, parseAbi, decodeFunctionResult, keccak256, getAddress, toHex } = require('viem');
const dir = 'deployments/4663/rh14-stocks';
const raw = fs.readFileSync(`${dir}/snapshot.json`, 'utf8');
const s = JSON.parse(raw);
const zero = '0x0000000000000000000000000000000000000000';
const weth = getAddress(s.quoteAssets[0]), usdg = getAddress(s.quoteAssets[1]);
const v3Factory = '0x1f7d7550B1b028f7571E69A784071F0205FD2EfA';
const manager = '0x8366a39CC670B4001A1121B8F6A443A643e40951';
const hubId = '0x52e65b17fb6e5ba00ed806f37afcd2daa50271ca';
const rpc = process.env.RH14_RPC_URL || 'https://rpc.mainnet.chain.robinhood.com';
const check = (v, msg) => { if (!v) throw new Error(msg); };
function batch(calls) {
  const payload = calls.map((c,i)=>({jsonrpc:'2.0', id:i, method:c[0], params:c[1]}));
  const response = JSON.parse(execFileSync('curl',['--fail-with-body','-sS','--max-time','45',rpc,'-H','Content-Type: application/json','--data-binary','@-'],{input:JSON.stringify(payload),maxBuffer:4*1024*1024}).toString());
  check(Array.isArray(response), 'invalid RPC response');
  return payload.map(c=>{const r=response.find(x=>x.id===c.id);check(r && !r.error,JSON.stringify(r));return r.result;});
}
check(Date.now() - Date.parse(s.completedAt) <= 86400000, 'refresh stock snapshot: older than 24 hours');
check(s.chainId === 4663 && s.paginationComplete && s.minPoolTvlUsdExclusive === 50000, 'incomplete/wrong snapshot');
const [chain, block] = batch([['eth_chainId',[]],['eth_blockNumber',[]]]);
check(BigInt(chain)===4663n,'wrong RPC chain');
const [blockData] = batch([['eth_getBlockByNumber',[block,false]]]);
const catalog = JSON.parse(fs.readFileSync(`${dir}/raw/uniswap-rwas.json`)).rwas;
// Preserve the two legacy ETF constituents; apply exactly the same liquidity rules.
const legacy = catalog.filter(x=>['SPY','QQQ'].includes(x.symbol));
check(legacy.length===2,'missing legacy ETF catalog');
const candidates = [...s.stocks, ...legacy].flatMap(r=>r.issuerTokens.filter(t=>t.chainId===4663 && (s.stocks.includes(r)||t.issuer==='robinhood')).map(t=>({
  symbol:r.issuerData[t.issuer]?.symbol || r.symbol, underlying:r.symbol, issuer:t.issuer,
  address:getAddress(t.address), category:s.stocks.includes(r)?'stock':'legacy-etf'
})));
check(new Set(candidates.map(t=>t.address)).size===candidates.length,'duplicate catalog address');

const selected=[], excluded=[];
for(const token of candidates) {
  const pools=s.pools.filter(p=>eligiblePool(p,token.address,weth,usdg)).sort((a,b)=>b.stats.tvl-a.stats.tvl || a.pool.poolId.localeCompare(b.pool.poolId));
  if(!pools.length){excluded.push({...token,reason:'No indexed active hookless V3/V4 USDG/WETH pool with TVL strictly above $50,000'});continue;}
  selected.push({...token,tvlUsdCents:Math.floor(pools[0].stats.tvl*100),pool:pools[0].pool});
}
selected.sort((a,b)=>a.symbol.localeCompare(b.symbol)||a.address.localeCompare(b.address));
check(selected.length>0,'empty selected list');
const hub=s.pools.find(r=>r.pool.poolId.toLowerCase()===hubId);
check(hub && eligiblePool(hub,weth,weth,usdg),'missing liquid USDG/WETH hub');
const rows=[{symbol:'USDG/WETH',pool:hub.pool},...selected];
const abi=parseAbi(['function factory() view returns(address)','function token0() view returns(address)','function token1() view returns(address)','function fee() view returns(uint24)','function liquidity() view returns(uint128)','function getPool(address,address,uint24) view returns(address)','function extsload(bytes32) view returns(bytes32)','function decimals() view returns(uint8)']);
function call(to,fn,args=[]){return ['eth_call',[{to,data:encodeFunctionData({abi,functionName:fn,args})},block]];}
function decode(fn,data){return decodeFunctionResult({abi,functionName:fn,data});}
for(let offset=0;offset<rows.length;offset+=5) {
  const jobs=rows.slice(offset,offset+5).map(row=>{
    const p=row.pool; p.token0.address=getAddress(p.token0.address);p.token1.address=getAddress(p.token1.address);
    check(BigInt(p.token0.address)<BigInt(p.token1.address),'noncanonical token order');
    if(p.protocolVersion==='PROTOCOL_VERSION_V3') {
      p.poolId=getAddress(p.poolId);
      return {row,calls:[call(p.poolId,'factory'),call(p.poolId,'token0'),call(p.poolId,'token1'),call(p.poolId,'fee'),call(p.poolId,'liquidity'),call(v3Factory,'getPool',[p.token0.address,p.token1.address,p.feeTier])]};
    }
    const key=encodeAbiParameters(parseAbiParameters('address,address,uint24,int24,address'),[p.token0.address,p.token1.address,p.feeTier,p.tickSpacing,zero]);
    check(keccak256(key).toLowerCase()===p.poolId.toLowerCase(),`wrong V4 PoolKey ${row.symbol}`);
    const slot=keccak256(encodeAbiParameters(parseAbiParameters('bytes32,uint256'),[p.poolId,6n]));
    return {row,calls:[call(manager,'extsload',[slot]),call(manager,'extsload',[toHex(BigInt(slot)+3n,{size:32})])]};
  });
  let result=batch(jobs.flatMap(j=>j.calls));
  for(const j of jobs){
    const r=result.splice(0,j.calls.length),p=j.row.pool;
    if(p.protocolVersion==='PROTOCOL_VERSION_V3'){
      check(decode('factory',r[0]).toLowerCase()===v3Factory.toLowerCase(),`factory mismatch ${j.row.symbol}`);
      check(decode('token0',r[1])===p.token0.address && decode('token1',r[2])===p.token1.address,`tokens mismatch ${j.row.symbol}`);
      check(decode('fee',r[3])===p.feeTier && decode('getPool',r[5])===p.poolId,`factory getPool mismatch ${j.row.symbol}`);
      check(decode('liquidity',r[4])>0n,`no active liquidity ${j.row.symbol}`);
      j.row.chainLiquidity=decode('liquidity',r[4]).toString();
    }else{
      check((BigInt(r[0])&((1n<<160n)-1n))>0n && BigInt(r[1])>0n,`uninitialized/inactive V4 pool ${j.row.symbol}`);
      j.row.chainLiquidity=BigInt(r[1]).toString();
    }
  }
  console.log(`Validated ${Math.min(offset+5,rows.length)}/${rows.length} pools at ${parseInt(block,16)}`);
}
// Metadata used by quotes must agree with the actual token contracts.
const tokenMap=new Map(rows.flatMap(r=>[r.pool.token0,r.pool.token1]).map(t=>[t.address,t]));
const tokens=[...tokenMap.values()];
for(let i=0;i<tokens.length;i+=20){const chunk=tokens.slice(i,i+20);const results=batch(chunk.map(t=>call(t.address,'decimals')));chunk.forEach((t,j)=>check(decode('decimals',results[j])===t.decimals,`decimals mismatch ${t.symbol}`));}
const manifest={chainId:4663, snapshotSha256:createHash('sha256').update(raw).digest('hex'),
  snapshotCompletedAt:s.completedAt, validatedAt:new Date().toISOString(), blockNumber:parseInt(block,16),blockHash:blockData.hash,
  minPoolTvlUsdExclusive:50000, selectedCount:selected.length,stockCount:selected.filter(x=>x.category==='stock').length,
  assets:selected.map(t=>t.address),tvlUsdCents:selected.map(t=>t.tvlUsdCents),hub,selected,excluded};
fs.writeFileSync(`${dir}/manifest.json`,JSON.stringify(manifest,null,2)+'\n');
const addressLiteral=a=>getAddress(a);
const commentText=value=>String(value).replace(/[\r\n]/g,' ');
const entries=rows.map((r,i)=>{
 const p=r.pool;
 if(p.protocolVersion==='PROTOCOL_VERSION_V3') return `        pools[${i}] = _v3(${addressLiteral(p.token0.address)}, ${addressLiteral(p.token1.address)}, ${addressLiteral(p.poolId)}); // ${commentText(r.symbol)}`;
 return `        pools[${i}] = _v4(${addressLiteral(p.token0.address)}, ${addressLiteral(p.token1.address)}, ${p.feeTier}, ${p.tickSpacing}); // ${commentText(r.symbol)}`;
}).join('\n');
const header=`// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {RHNutboxRouterConfig as Infra} from "./RHNutboxRouterConfig.sol";
/// @notice Generated by script/prepare-rh14-stocks.mjs. Do not edit addresses by hand.
/// @dev Snapshot ${s.completedAt}; chain validation block ${manifest.blockNumber}.
///      ${manifest.stockCount} stocks + ${selected.length-manifest.stockCount} retained ETFs; each selected pool TVL > $50,000.
library RHVersion14StockConfig {
    uint256 internal constant VALIDATED_BLOCK = ${manifest.blockNumber};
    uint256 internal constant SNAPSHOT_TIMESTAMP = ${Math.floor(Date.parse(s.completedAt)/1000)};
    function constituentAssets() internal pure returns (address[] memory assets) {
        assets = new address[](${selected.length});
${selected.map((t,i)=>`        assets[${i}] = ${t.address}; // ${commentText(t.symbol)}`).join('\n')}
    }
    function initialPricePools() internal pure returns (INutboxRouter.InitialPricePool[] memory pools) {
        pools = new INutboxRouter.InitialPricePool[](${rows.length});
${entries}
    }
`;
const helpers=fs.readFileSync('script/config/RHVersion14StockConfig.helpers.txt','utf8');
fs.writeFileSync('script/config/RHVersion14StockConfig.sol',header+helpers);
console.log(`Selected ${selected.length}; excluded ${excluded.length}`);
