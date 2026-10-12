// Read-only RH preflight and post-deployment verification. No wallet or secret is loaded.
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import fs from 'node:fs';
import path from 'node:path';
const require = createRequire(path.resolve('../tiptag-ui/package.json'));
const { parseAbi, encodeFunctionData, decodeFunctionResult, getAddress } = require('viem');
export const addresses = Object.freeze({
  oldHelper: '0xD0baaF8D314b0C6AB6bebd24ddbC86157c9c7b09',
  wrapper: '0x53e65DE68A0eB7f3662579F44Eb9849Ae5cA44ab',
  communityFactory: '0x24328DccA1bA54EeE82e2993F021802e64290486',
  tradeFactory: '0x73cb7A6Ad01686659F72011eb952fBa53fe6212B',
  committee: '0x7B0ddC305C32AAEbabc0FE372a4460e9903e95D0',
  calculator: '0x3DC52C69C3C8be568372E16d50E9F3FEc796610c',
  multicall: '0xcA11bde05977b3631167028862bE2a173976CA11',
  weth: '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73',
});
const getters = parseAbi([
  'function owner() view returns(address)', 'function registrar() view returns(address)',
  'function wrappedNative() view returns(address)', 'function swapWrapper() view returns(address)',
  'function communityFactory() view returns(address)', 'function claimSigner() view returns(address)',
  'function committee() view returns(address)', 'function hourlyTickCalculator() view returns(address)',
  'function tradeCurationFactory() view returns(address)', 'function VERSION() view returns(uint256)',
  'function defaultPoolCount() view returns(uint256)',
  'function verifyContract(address) view returns(bool)',
  'function getDefaultPools() view returns((address factory,uint16 rewardRatio,bytes meta)[])',
]);
const multicallAbi = parseAbi(['function aggregate3((address target,bool allowFailure,bytes callData)[] calls) payable returns((bool success,bytes returnData)[])']);
const check = (ok, message) => { if (!ok) throw new Error(message); };
const same = (a,b) => String(a).toLowerCase() === String(b).toLowerCase();
export async function verifyState(rpc, helper = null, activated = false) {
  check(BigInt(await rpc('eth_chainId', [])) === 4663n, 'Wrong chain');
  const blockTag = await rpc('eth_blockNumber', []);
  check(await rpc('eth_getCode', [addresses.multicall, blockTag]) !== '0x', 'Multicall missing');
  const reads = [
    [addresses.wrapper, 'owner'], [addresses.wrapper, 'registrar'], [addresses.wrapper, 'wrappedNative'],
    [addresses.oldHelper, 'swapWrapper'], [addresses.tradeFactory, 'communityFactory'],
    [addresses.tradeFactory, 'claimSigner'], [addresses.calculator, 'communityFactory'],
    [addresses.committee, 'verifyContract', [addresses.tradeFactory]],
    [addresses.committee, 'verifyContract', [addresses.calculator]],
  ];
  if (helper) {
    helper = getAddress(helper);
    check(await rpc('eth_getCode', [helper, blockTag]) !== '0x', 'Helper missing');
    for (const name of ['VERSION', 'owner', 'communityFactory', 'tradeCurationFactory', 'committee', 'hourlyTickCalculator', 'swapWrapper', 'defaultPoolCount', 'getDefaultPools']) reads.push([helper, name]);
  }
  const data = encodeFunctionData({abi: multicallAbi, functionName: 'aggregate3', args: [reads.map(([target, functionName, args=[]]) => ({
    target, allowFailure: false, callData: encodeFunctionData({abi:getters,functionName,args}),
  }))]});
  const raw = await rpc('eth_call', [{to:addresses.multicall,data},blockTag]);
  const rows = decodeFunctionResult({abi:multicallAbi,functionName:'aggregate3',data:raw});
  check(rows.length === reads.length, 'Incomplete Multicall');
  const values = rows.map((row,i) => {
    check(row.success, `Required read failed: ${reads[i][1]}`);
    return decodeFunctionResult({abi:getters,functionName:reads[i][1],data:row.returnData});
  });
  const [owner,registrar,weth,oldWrapper,tradeFactory,signer,calculatorFactory,tradeAllowed,calculatorAllowed] = values;
  check(!same(owner, '0x0000000000000000000000000000000000000000'), 'Missing owner');
  check(same(registrar, activated ? helper : addresses.oldHelper), 'Unexpected registrar');
  check(same(weth,addresses.weth) && same(oldWrapper,addresses.wrapper), 'Wrapper mismatch');
  check(same(tradeFactory,addresses.communityFactory) && same(calculatorFactory,addresses.communityFactory), 'Community factory mismatch');
  check(!same(signer,'0x0000000000000000000000000000000000000000'), 'Missing signer');
  check(tradeAllowed && calculatorAllowed, 'Missing Committee approval');
  if (helper) {
    check(values[9] === 2n && same(values[10],owner), 'Helper version/owner mismatch');
    const expected = [addresses.communityFactory,addresses.tradeFactory,addresses.committee,addresses.calculator,addresses.wrapper];
    expected.forEach((value,i) => check(same(values[11+i],value),'Helper dependency mismatch'));
    const defaults = values[17];
    check(values[16] === 1n && defaults.length === 1 && same(defaults[0].factory,addresses.tradeFactory)
      && defaults[0].rewardRatio === 10000 && defaults[0].meta === '0x', 'Unexpected defaults');
  }
  return {chainId:4663,block:Number(BigInt(blockTag)),blockTag,...addresses,owner,registrar,claimSigner:signer,helper,activated,defaultPools:helper?values[17]:null};
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const helper = process.argv.find(x => /^0x[0-9a-fA-F]{40}$/.test(x)) || null;
  const activated = process.argv.includes('--activated');
  check(!activated || helper, 'Activation verification needs the deployed helper address');
  const rpc = async (method,params) => {
    const response = await fetch(process.env.RH_RPC_URL || 'https://rpc.mainnet.chain.robinhood.com', {
      method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:1,method,params}),signal:AbortSignal.timeout(45000),
    });
    check(response.ok, `RPC HTTP ${response.status}`);
    const body = await response.json(); check(!body.error && body.result !== undefined, `RPC ${method} failed`); return body.result;
  };
  const result = await verifyState(rpc,helper,activated);
  const text = JSON.stringify(result,(_,v)=>typeof v==='bigint'?v.toString():v,2)+'\n';
  const outputIndex = process.argv.indexOf('--output');
  if (outputIndex >= 0) fs.writeFileSync(process.argv[outputIndex+1],text);
  console.log(text);
}
