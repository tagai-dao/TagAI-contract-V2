// Read-only post-deployment verification; no wallet or transaction submission.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
const require = createRequire(path.resolve(process.env.RH14_NODE_PACKAGE || '../tiptag-ui/package.json'));
const { encodeFunctionData, decodeFunctionData, decodeFunctionResult, getAddress, keccak256 } = require('viem');
const load = p => JSON.parse(fs.readFileSync(p));
const check = (v, m) => { if (!v) throw Error(m); };
const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
const dir = 'deployments/4663';
const original = load(`${dir}/rh14-recovery/original-broadcast.json`);
const broadcastPath = 'broadcast/ResumeRHPump14.s.sol/4663/run-latest.json';
const completed = load(broadcastPath);
check(completed.transactions.length === 25 && completed.receipts.length === 25 && !completed.pending.length, 'Incomplete recovery broadcast');
const rpc = process.env.RH14_RPC_URL || 'https://rpc.mainnet.chain.robinhood.com';
function batch(calls) {
  const results = [];
  for (let i = 0; i < calls.length; i += 20) {
    const input = calls.slice(i, i + 20).map(([method, params], id) => ({ jsonrpc: '2.0', id, method, params }));
    let raw;
    try {
      raw = execFileSync('curl', ['--fail-with-body', '-sS', '--max-time', '45', rpc, '-H', 'Content-Type: application/json', '--data-binary', '@-'], { input: JSON.stringify(input), maxBuffer: 8e6, stdio: ['pipe', 'pipe', 'pipe'] });
    } catch { throw Error('RPC request failed; check RH14_RPC_URL. No deployment records updated.'); }
    const rows = JSON.parse(raw);
    for (const req of input) {
      const row = Array.isArray(rows) && rows.find(r => r.id === req.id);
      check(row && !row.error, `RPC ${req.method} failed`);
      results.push(row.result);
    }
  }
  return results;
}
const [chain, block] = batch([['eth_chainId', []], ['eth_blockNumber', []]]);
check(BigInt(chain) === 4663n, 'Wrong chain');
const liveReceipts = batch(completed.transactions.map(t => ['eth_getTransactionReceipt', [t.hash]]));
liveReceipts.forEach((r, i) => {
  check(r && r.status === '0x1' && same(r.transactionHash, completed.transactions[i].hash), 'Transaction not confirmed successfully');
  const stored = completed.receipts.find(x => same(x.transactionHash, r.transactionHash));
  check(stored && same(stored.blockHash, r.blockHash), 'Receipt block changed');
});
const at = i => getAddress(completed.transactions[i].contractAddress);
const addresses = { Pump: at(8), TagAISwapHook: at(12), NutboxRouter: at(0), TagAITradeRouter: at(19), TagAILiquidityRouter: at(20), TagAIBuybackRouter: at(14), TradeCurationFactory: at(16), BasketRebalanceExecutorV3: at(5), BasketHookV3: at(6), BasketSwapRouter: at(7) };
const abis = {};
function abi(name) { return abis[name] ||= load(`out/${name}.sol/${name}.json`).abi; }
function reads(items) {
  const responses = batch(items.map(([name, to, fn, args = []]) => ['eth_call', [{ to, data: encodeFunctionData({ abi: abi(name), functionName: fn, args }) }, block]]));
  return responses.map((data, i) => decodeFunctionResult({ abi: abi(items[i][0]), functionName: items[i][2], data }));
}
const pump = addresses.Pump, router = addresses.NutboxRouter;
const [token, reader, keeper, routerBinding, hookBinding, buyback, basketHook, operator, pumpEnabled] = reads([
  ['RHPumpV14', pump, 'tokenImplementation'], ['NutboxRouter', router, 'priceReader'], ['RHPumpV14', pump, 'listingKeeper'],
  ['RHPumpV14', pump, 'nutboxRouter'], ['RHPumpV14', pump, 'getHookAddress'], ['RHPumpV14', pump, 'buybackRouter'],
  ['RHPumpV14', pump, 'basketHookV4'], ['NutboxRouter', router, 'operators', [pump]], ['TagAITradeRouter', addresses.TagAITradeRouter, 'pumpEnabled', [pump]],
]);
check(same(keeper, '0x8047FcC508446E2673195B8125d3388defc23688'), 'Keeper mismatch');
check(same(routerBinding, router) && same(hookBinding, addresses.TagAISwapHook) && same(buyback, addresses.TagAIBuybackRouter) && same(basketHook, addresses.BasketHookV3) && operator && pumpEnabled, 'Stack configuration mismatch');
Object.assign(addresses, { TokenImplementation: token, NutboxPriceReader: reader });
const code = batch(Object.values(addresses).map(a => ['eth_getCode', [a, block]]));
code.forEach(c => check(c && c !== '0x', 'Missing contract code'));
check(keccak256(code[Object.keys(addresses).indexOf('NutboxRouter')]) === load(`${dir}/rh14-recovery/plan.json`).routerCodeHash, 'Original Router code changed');
const manifest = load(`${dir}/rh14-stocks/manifest.json`);
reads(manifest.assets.map(a => ['RHPumpV14', pump, 'approvedConstituent', [a]])).forEach(v => check(v, 'Missing approved stock'));
const routes = original.transactions.filter(t => t.function === 'addRoute(address,address,bytes32[])').map(t => decodeFunctionData({ abi: abi('NutboxRouter'), data: t.transaction.input }).args);
const routeChecks = [];
for (const [a, b, ids] of routes) {
  routeChecks.push({ call: ['NutboxRouter', router, 'hasRoute', [a, b]], expected: true });
  routeChecks.push({ call: ['NutboxRouter', router, 'routePoolCount', [a, b]], expected: BigInt(ids.length) });
  ids.forEach((id, i) => routeChecks.push({ call: ['NutboxRouter', router, 'routePoolAt', [a, b, BigInt(i)]], expected: id }));
}
reads(routeChecks.map(c => c.call)).forEach((v, i) => check(v === routeChecks[i].expected, 'Route differs from frozen deployment plan'));
const ids = [...new Set(routes.flatMap(r => r[2]))];
const expectedPools = new Map(original.transactions.filter(t => t.function === 'addPricePool(uint8,bytes)').map(t => {
  const { args } = decodeFunctionData({ abi: abi('NutboxRouter'), data: t.transaction.input });
  return [args[1].toLowerCase(), args[0]];
}));
reads(ids.map(id => ['NutboxRouter', router, 'pricePool', [id]])).forEach(([enabled,,a,b,kind,data], i) => {
  check(enabled && expectedPools.get(data.toLowerCase()) === kind, `Pool ${ids[i]} mismatch`);
});
const old = load(`${dir}/version11.json`);
const basket = load('../robinhood-basket-contract/deployments/4663/version3.json');
abis.BasketRegistry = load('../robinhood-basket-contract/out/BasketRegistry.sol/BasketRegistry.json').abi;
const owned = [['RHPumpV14', pump], ['NutboxRouter', router], ['TagAITradeRouter', addresses.TagAITradeRouter], ['TradeCurationFactory', addresses.TradeCurationFactory]];
const ownership = reads(owned.flatMap(([name, a]) => [[name, a, 'owner'], [name, a, 'pendingOwner']]));
const [committeeOwner, registryOwner, whitelist, registrar, pumpForwarder, swapForwarder] = reads([
  ['Committee', old.Committee, 'owner'], ['BasketRegistry', basket.BasketRegistry, 'owner'],
  ['Committee', old.Committee, 'verifyContract', [addresses.TradeCurationFactory]],
  ['BasketRegistry', basket.BasketRegistry, 'approvedRegistrars', [addresses.BasketHookV3]],
  ['BasketRegistry', basket.BasketRegistry, 'approvedCreatorForwarders', [pump]],
  ['BasketRegistry', basket.BasketRegistry, 'approvedCreatorForwarders', [addresses.BasketSwapRouter]],
]);
const governance = [];
function action(name, target, fn, args, executor, done) {
  governance.push({ target, function: fn, args, executor, completed: done, value: '0', data: encodeFunctionData({ abi: abi(name), functionName: fn, args }) });
}
action('Committee', old.Committee, 'adminAddContract', [addresses.TradeCurationFactory], committeeOwner, whitelist);
action('BasketRegistry', basket.BasketRegistry, 'setRegistrarApproval', [addresses.BasketHookV3, true], registryOwner, registrar);
action('BasketRegistry', basket.BasketRegistry, 'setCreatorForwarderApproval', [pump, true], registryOwner, pumpForwarder);
action('BasketRegistry', basket.BasketRegistry, 'setCreatorForwarderApproval', [addresses.BasketSwapRouter, true], registryOwner, swapForwarder);
const intendedOwner = getAddress(completed.transactions[21].arguments[0]);
owned.forEach(([name, target], i) => {
  const owner = ownership[2 * i], pending = ownership[2 * i + 1];
  const done = same(owner, intendedOwner) && same(pending, '0x0000000000000000000000000000000000000000');
  check(done || same(pending, intendedOwner), 'Ownership transfer has unexpected recipient');
  action(name, target, 'acceptOwnership', [], intendedOwner, done);
});
const pendingCount = governance.filter(g => !g.completed).length;
const report = { version: 14, chainId: 4663, status: pendingCount ? 'deployed-governance-pending' : 'deployed-governance-complete', deployer: getAddress(completed.transactions[0].transaction.from), owner: intendedOwner, verifiedAt: new Date().toISOString(), verifiedBlock: parseInt(block, 16), deploymentBlockStart: parseInt(liveReceipts[0].blockNumber, 16), deploymentBlockEnd: parseInt(liveReceipts.at(-1).blockNumber, 16), ...addresses, Committee: old.Committee, BasketRegistry: basket.BasketRegistry, IPShare: old.IPShare, CommunityFactory: old.CommunityFactory, ERC20StakingFactory: old.ERC20StakingFactory, HourlyTickCalculator: old.HourlyTickCalculator, PoolManager: old.PoolManager, WETH: old.WETH, USDG: old.USDG, feeAddress: old.feeAddress, listingKeeper: keeper, approvedConstituents: manifest.assets, configuredPricePools: ids.length, configuredRoutes: routes.length, recoveryTransactions: 25, pendingGovernanceOperations: pendingCount, routerSupportsBatchInitialization: false };
fs.copyFileSync(broadcastPath, `${dir}/rh14-recovery/completed-broadcast.json`);
fs.writeFileSync(`${dir}/version14.json`, JSON.stringify(report, null, 2) + '\n');
fs.writeFileSync(`${dir}/rh14-governance.json`, JSON.stringify({ chainId: 4663, verifiedBlock: report.verifiedBlock, operations: governance }, null, 2) + '\n');
console.log(JSON.stringify({ status: report.status, verifiedBlock: report.verifiedBlock, receipts: liveReceipts.length, contractsWithCode: code.length, approvedConstituents: manifest.assets.length, pools: ids.length, routes: routes.length, pendingGovernance: pendingCount, committeeOwner, registryOwner, intendedOwner }, null, 2));
