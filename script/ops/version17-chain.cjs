const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const localRequire = createRequire(path.join(process.cwd(), 'package.json'));
const ethers = localRequire(localRequire.resolve('ethers', { paths: [process.cwd(), path.resolve('../buy-bot')] }));
const dotenv = localRequire(localRequire.resolve('dotenv', { paths: [process.cwd(), path.resolve('../tagai-api')] }));
const env = { ...dotenv.parse(fs.readFileSync('.env')), ...process.env };
const MC = '0xcA11bde05977b3631167028862bE2a173976CA11';
const PREVIOUS = '0xee8D16f44c89B5F858e223Ab77c6091E184AaDf8';
const TRADE = '0x774A48Ba391a1013Ae43289eBdf871618822CD67';
const HANDLE = '0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F';
const multicall = new ethers.Interface(['function aggregate3((address target,bool allowFailure,bytes callData)[] calls) payable returns ((bool success,bytes returnData)[] results)', 'function getBlockNumber() view returns (uint256)']);
function read(target, name, inputs = [], args = [], outputs = ['address']) {
  const abi = new ethers.Interface([`function ${name}(${inputs.join(',')}) view returns (${outputs.join(',')})`]);
  return { target, name, args, abi, callData: abi.encodeFunctionData(name, args) };
}
async function batch(provider, pin, descriptors, audit = []) {
  const calls = [{ target: MC, allowFailure: false, callData: multicall.encodeFunctionData('getBlockNumber') }, ...descriptors.map(x => ({ target: x.target, allowFailure: false, callData: x.callData }))];
  const raw = await provider.send('eth_call', [{ to: MC, data: multicall.encodeFunctionData('aggregate3', [calls]) }, ethers.toQuantity(pin)]);
  const results = multicall.decodeFunctionResult('aggregate3', raw)[0];
  if (results.length !== calls.length || !results[0].success || ethers.AbiCoder.defaultAbiCoder().decode(['uint256'], results[0].returnData)[0] !== BigInt(pin)) throw new Error('Multicall snapshot/count mismatch');
  const values = descriptors.map((d, i) => {
    const r = results[i + 1];
    if (!r.success || r.returnData === '0x') throw new Error(`Required Multicall result missing: ${d.name} at ${d.target}`);
    const decoded = d.abi.decodeFunctionResult(d.name, r.returnData);
    return decoded.length === 1 ? decoded[0] : Array.from(decoded);
  });
  audit.push({ blockTag: ethers.toQuantity(pin), target: MC, calls: calls.map(({ target, allowFailure, callData }) => ({ target, allowFailure, callData })) });
  return values;
}
const fields = [
  ['owner'], ['getIPShare'], ['getFeeReceiver'], ['getPoolManager'], ['getVault'], ['nutboxCommunityFactory'], ['getCalculator'], ['erc20StakingFactory'], ['nutboxCommittee'], ['nutboxRouter'], ['basketHookV4'], ['pancakeV2Factory'], ['settlementToken'], ['listingKeeper'], ['buybackRouter'], ['createFee', 'uint256'], ['getFeeRatio', 'uint256[2]'], ['listingSwapSlippageBps', 'uint16'], ['VERSION', 'uint256'], ['tokenImplementation'], ['pendingOwner']
];
async function preflight(provider, pin, deployer) {
  const audit = [];
  const primary = await batch(provider, pin, [...fields.map(([n,t]) => read(PREVIOUS,n,[],[],[t || 'address'])), read(PREVIOUS,'optionalPoolFactories',['address'],[TRADE],['string','uint16','bool'])], audit);
  const c = Object.fromEntries(fields.map(([n],i) => [n, primary[i]]));
  c.optionalTradePool = primary[fields.length];
  if (c.VERSION !== 16n) throw new Error('Previous Pump is not V16');
  const infrastructure = await batch(provider, pin, [read(c.basketHookV4,'basketRegistry'),read(c.buybackRouter,'basketRouter'),read(c.nutboxRouter,'owner'),read(c.nutboxCommittee,'owner'),read(HANDLE,'owner'),read(HANDLE,'minLen',[],[],['uint8']),read(HANDLE,'maxLen',[],[],['uint8']),read(HANDLE,'handleOf',['address'],[deployer],['string'])],audit);
  const [registry,basketRouter,routerOwner,committeeOwner,handleOwner,minLen,maxLen,deployerHandle] = infrastructure;
  const safe = c.pendingOwner !== ethers.ZeroAddress ? c.pendingOwner : c.owner;
  const assetSource = fs.readFileSync('script/config/BSCNutboxRouterConfig.sol','utf8');
  const catalog = [...assetSource.matchAll(/\btoken:\s*(0x[0-9a-fA-F]{40})/g)].map(x=>ethers.getAddress(x[1]));
  if (catalog.length !== 16) throw new Error('Unexpected constituent catalog');
  const stage3 = await batch(provider,pin,[read(registry,'owner'),read(safe,'getOwners',[],[],['address[]']),read(safe,'getThreshold',[],[],['uint256']),read(safe,'nonce',[],[],['uint256']),read(c.nutboxRouter,'operators',['address'],[PREVIOUS],['bool']),read(registry,'approvedCreatorForwarders',['address'],[PREVIOUS],['bool']),read(c.nutboxCommittee,'verifyContract',['address'],[c.erc20StakingFactory],['bool']),read(c.nutboxCommittee,'verifyContract',['address'],[c.getCalculator],['bool']),read(c.nutboxCommittee,'verifyContract',['address'],[TRADE],['bool']),...catalog.flatMap(a=>[read(PREVIOUS,'approvedConstituent',['address'],[a],['bool']),read(c.nutboxRouter,'hasRoute',['address','address'],[ethers.ZeroAddress,a],['bool']),read(c.nutboxRouter,'hasRoute',['address','address'],[c.settlementToken,a],['bool'])])],audit);
  if (safe.toLowerCase() !== routerOwner.toLowerCase() || safe.toLowerCase() !== stage3[0].toLowerCase()) throw new Error('Activation owners are not the same Safe');
  const constituents = catalog.filter((a,i)=>stage3[9+i*3]);
  if (!constituents.length || catalog.some((a,i)=>stage3[9+i*3] && (!stage3[10+i*3] || !stage3[11+i*3]))) throw new Error('Approved constituent route missing');
  if (c.optionalTradePool[0] !== 'Trade Curation' || c.optionalTradePool[1] !== 8000n || !c.optionalTradePool[2]) throw new Error('Unexpected V16 optional pool configuration');
  return { chainId:56, blockNumber:pin, previousPump:PREVIOUS, deployer, targetOwner:safe, configuration:c, infrastructure:{registry,basketRouter,routerOwner,registryOwner:stage3[0],committeeOwner,handleOwner,minLen,maxLen,deployerHandle}, safe:{address:safe,owners:stage3[1],threshold:stage3[2],nonce:stage3[3]}, previousActivation:{operator:stage3[4],creatorForwarder:stage3[5]},committeeAllowlist:{staking:stage3[6],calculator:stage3[7],trade:stage3[8]},constituents,multicallAudit:audit };
}
async function main() {
  if (!env.BSC_RPC_URL || !env.PRIVATE_KEY_MAIN) throw new Error('Missing deployment environment');
  const provider = new ethers.JsonRpcProvider(env.BSC_RPC_URL,56,{batchMaxCount:1,staticNetwork:true});
  try {
    const chain = await provider.send('eth_chainId',[]);
    if (BigInt(chain) !== 56n) throw new Error('Wrong chain');
    const block = await provider.send('eth_getBlockByNumber',['latest',false]);
    const pin = Number(BigInt(block.number));
    const deployer = new ethers.Wallet(env.PRIVATE_KEY_MAIN).address;
    const data = await preflight(provider,pin,deployer);
    data.blockHash = block.hash;
    data.checkedAt = new Date().toISOString();
    data.balanceWei = await provider.send('eth_getBalance',[deployer,ethers.toQuantity(pin)]);
    data.pendingNonce = await provider.send('eth_getTransactionCount',[deployer,'pending']);
    data.gasPriceWei = await provider.send('eth_gasPrice',[]);
    // Recover enumerable mapping keys from logs, then refuse to silently drop a V16 setting.
    const events = new ethers.Interface(['event ConstituentApprovalSet(address indexed asset,bool approved)','event OptionalPoolFactorySet(address indexed factory,string name,uint16 maxRewardRatio,bool enabled)']);
    const logs = [];
    let cursor = 128964678;
    let span = 100000;
    while (cursor <= pin) {
      const end = Math.min(pin, cursor + span - 1);
      try {
        logs.push(...await provider.send('eth_getLogs',[{address:PREVIOUS,fromBlock:ethers.toQuantity(cursor),toBlock:ethers.toQuantity(end),topics:[[events.getEvent('ConstituentApprovalSet').topicHash,events.getEvent('OptionalPoolFactorySet').topicHash]]}]));
        cursor = end + 1;
      } catch (error) {
        if (span <= 1000) throw error;
        span = Math.max(1000,Math.floor(span/2));
      }
    }
    const approvals = new Map();
    const factories = new Map();
    for (const log of logs) {
      const event = events.parseLog(log);
      if (event.name === 'ConstituentApprovalSet') approvals.set(event.args.asset.toLowerCase(),event.args.approved);
      else factories.set(event.args.factory.toLowerCase(),{name:event.args.name,maxRewardRatio:event.args.maxRewardRatio,enabled:event.args.enabled});
    }
    const active = [...approvals].filter(([,approved])=>approved).map(([asset])=>asset).sort();
    if (JSON.stringify(active)!==JSON.stringify(data.constituents.map(x=>x.toLowerCase()).sort())) throw new Error('V16 has constituent approvals outside the preserved catalog');
    if ([...factories].some(([address,c])=>c.enabled && address!==TRADE.toLowerCase())) throw new Error('V16 has an additional optional pool factory that must be preserved');
    data.mappingLogAudit = {fromBlock:128964678,toBlock:pin,logCount:logs.length,approvedConstituents:active,optionalPoolFactories:Object.fromEntries(factories)};
    const output = 'deployments/56/version17-deployment-preflight.json';
    fs.writeFileSync(output, JSON.stringify(data,(_,v)=>typeof v==='bigint'?v.toString():v,2)+'\n');
    console.log(JSON.stringify({file:output,blockNumber:pin,deployer,targetOwner:data.targetOwner,balanceBNB:ethers.formatEther(data.balanceWei),gasPriceGwei:ethers.formatUnits(data.gasPriceWei,9),pendingNonce:Number(BigInt(data.pendingNonce)),safeThreshold:String(data.safe.threshold),safeOwners:data.safe.owners,constituents:data.constituents.length,previousActivation:data.previousActivation,committeeAllowlist:data.committeeAllowlist}));
  } finally { provider.destroy(); }
}
if (require.main === module) main().catch(e=>{console.error(`V17 preflight failed (${e.code || e.name || 'error'}). RPC credentials and private keys suppressed.`);process.exitCode=1;});
module.exports={batch,read,MC,multicall};
