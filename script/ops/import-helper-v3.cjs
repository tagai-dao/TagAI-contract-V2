// BSC ImportHelper V3 release. All batched contract reads use pinned on-chain Multicall.
const fs = require('node:fs'), path = require('node:path'), cp = require('node:child_process'), crypto = require('node:crypto');
const ethers = require(require.resolve('ethers', { paths: [process.cwd(), path.resolve('../buy-bot')] }));
const dotenv = require(require.resolve('dotenv', { paths: [process.cwd(), path.resolve('../tagai-api')] }));
const { batch, read } = require('./version18-chain.cjs');
const env = { ...dotenv.parse(fs.readFileSync('.env')), ...process.env };
const BASE = 'deployments/56/import-helper-v3';
const FQN = 'src/helper/ImportHelperV3.sol:ImportHelperV3';
const ARTIFACT = 'out/ImportHelperV3.sol/ImportHelperV3.json';
const OLD = '0x40BACB12D79dadf045c21C999b74484816F746F7';
const ORDINARY = '0xDfFc699FB095a693708E3c15e6F0a224cbbCc98F';
const AGENT = '0x3F7146D3D234Ed4C2021DE1A5B14da8754e6C577';
const SAFE = '0x871fb7006C5964B21695Ba20006021777A26146C';
const MANAGER = '0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611';
const load = file => JSON.parse(fs.readFileSync(file));
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const json = value => JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2) + '\n';
const write = (file, value) => fs.writeFileSync(file, json(value));
const same = (a, b) => a.toLowerCase() === b.toLowerCase();
const assert = (value, reason) => { if (!value) throw Error(reason); };
const git = (...args) => cp.execFileSync('git', args, { encoding: 'utf8' }).trim();
function dependencyCalls() {
  return [read(ORDINARY, 'owner'), read(ORDINARY, 'registrar'), read(AGENT, 'owner'), read(AGENT, 'operator'),
    ...['owner', 'communityFactory', 'tradeCurationFactory', 'committee', 'hourlyTickCalculator', 'swapWrapper'].map(n => read(OLD, n)),
    read(OLD, 'getDefaultPools', [], [], ['tuple(address factory,uint16 rewardRatio,bytes meta)[]']),
    read(SAFE, 'getThreshold', [], [], ['uint256']), read(SAFE, 'getOwners', [], [], ['address[]']), read(SAFE, 'nonce', [], [], ['uint256'])];
}
async function readDependencies(p, pin, audit) {
  const values = await batch(p, pin, dependencyCalls(), audit);
  const [normalOwner, registrar, agentOwner, operator, oldOwner, communityFactory, tradeCurationFactory, committee, hourlyTickCalculator, oldWrapper, pools, threshold, owners, nonce] = values;
  assert([normalOwner, agentOwner, oldOwner].every(a => same(a, SAFE)), 'Unexpected Wrapper/Helper owner');
  assert(same(oldWrapper, ORDINARY), 'Unexpected legacy Helper target');
  assert(pools.length === 1 && same(pools[0][0], tradeCurationFactory) && pools[0][1] === 10000n && pools[0][2] === '0x', 'V2 default pools changed; preserve configuration first');
  assert(threshold > 0n && threshold <= BigInt(owners.length), 'Invalid Safe configuration');
  return { normalOwner, registrar, agentOwner, operator, oldOwner, communityFactory, tradeCurationFactory, committee, hourlyTickCalculator, pools, safe: { address: SAFE, threshold, owners, nonce } };
}
async function snapshot(p) {
  assert(BigInt(await p.send('eth_chainId', [])) === 56n, 'Wrong chain');
  return p.send('eth_getBlockByNumber', ['latest', false]);
}
function checkSources(record) {
  for (const [file, hash] of Object.entries(record.sourceHashes)) assert(sha(fs.readFileSync(file)) === hash, 'Source changed: ' + file);
  assert(sha(fs.readFileSync(ARTIFACT)) === record.artifactSha256, 'Artifact changed');
}
async function preflight(p) {
  assert(!fs.existsSync(BASE + '.json') && !fs.existsSync(BASE + '-journal.json'), 'Existing release/journal: reconcile instead of deploying again');
  const block = await snapshot(p), pin = Number(BigInt(block.number)), audit = [];
  const dependencies = await readDependencies(p, pin, audit);
  assert(same(dependencies.registrar, OLD) && same(dependencies.operator, MANAGER), 'Activation state changed; review existing configuration');
  const extra = await batch(p, pin, [read(dependencies.committee, 'verifyContract', ['address'], [dependencies.tradeCurationFactory], ['bool']),
    read(dependencies.committee, 'verifyContract', ['address'], [dependencies.hourlyTickCalculator], ['bool']),
    read(dependencies.tradeCurationFactory, 'communityFactory'), read(dependencies.tradeCurationFactory, 'claimSigner'),
    read(OLD, 'poolFactoryCount', [], [], ['uint256'])], audit);
  assert(extra[0] && extra[1] && same(extra[2], dependencies.communityFactory) && !same(extra[3], ethers.ZeroAddress), 'Invalid import dependencies');
  assert(extra[4] === 1n, 'Additional V2 pool factory configuration requires explicit preservation');
  const deployer = new ethers.Wallet(env.PRIVATE_KEY_MAIN).address;
  assert(same(deployer, MANAGER), 'Unexpected deployment wallet');
  const pending = await p.send('eth_getTransactionCount', [deployer, 'pending']);
  assert(pending === await p.send('eth_getTransactionCount', [deployer, 'latest']), 'Pending deployment-wallet transactions');
  const constructor = { communityFactory: dependencies.communityFactory, tradeCurationFactory: dependencies.tradeCurationFactory,
    committee: dependencies.committee, hourlyTickCalculator: dependencies.hourlyTickCalculator,
    swapWrapper: ORDINARY, agentSwapWrapper: AGENT, managementOperator: MANAGER };
  const artifact = load(ARTIFACT), factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode.object);
  const request = await factory.getDeployTransaction(...Object.values(constructor));
  const gasEstimate = BigInt(await p.send('eth_estimateGas', [{ from: deployer, data: request.data }]));
  const gasPrice = BigInt(await p.send('eth_gasPrice', [])), gasLimit = gasEstimate * 130n / 100n;
  const balance = BigInt(await p.send('eth_getBalance', [deployer, ethers.toQuantity(pin)]));
  assert(balance > gasLimit * gasPrice, 'Insufficient deployment BNB');
  const sourceHashes = Object.fromEntries(Object.keys(artifact.metadata.sources).map(file => [file, sha(fs.readFileSync(file))]));
  const nonce = Number(BigInt(pending));
  const record = { component: 'ImportHelperV3', helperVersion: 3, chainId: 56, checkedAt: new Date().toISOString(), blockNumber: pin, blockHash: block.hash,
    sourceCommit: git('rev-parse', 'HEAD'), sourceBranch: git('branch', '--show-current'), sourceHashes, artifactSha256: sha(fs.readFileSync(ARTIFACT)),
    compiler: artifact.metadata.compiler, settings: artifact.metadata.settings, deployer, owner: SAFE, constructor, dependencies,
    nonce, predictedAddress: ethers.getCreateAddress({ from: deployer, nonce }), gasEstimate, gasLimit, gasPriceWei: gasPrice, balanceWei: balance, multicallAudit: audit };
  write(BASE + '-preflight.json', record);
  console.log(json({ mode: 'preflight', block: pin, predictedAddress: record.predictedAddress, deployer, owner: SAFE, managementOperator: MANAGER, gasEstimate, maximumGasCostBNB: ethers.formatEther(gasLimit * gasPrice), balanceBNB: ethers.formatEther(balance), requiresSafeActivation: true }));
}
async function deploy(p) {
  assert(!fs.existsSync(BASE + '.json') && !fs.existsSync(BASE + '-journal.json'), 'Existing release/journal: recover rather than redeploy');
  const pre = load(BASE + '-preflight.json'); checkSources(pre);
  const wallet = new ethers.Wallet(env.PRIVATE_KEY_MAIN, p), block = await snapshot(p);
  assert(same(wallet.address, pre.deployer), 'Wrong deployer');
  assert(Number(BigInt(block.number)) - pre.blockNumber < 1200, 'Preflight expired');
  assert(Number(BigInt(await p.send('eth_getTransactionCount', [wallet.address, 'pending']))) === pre.nonce, 'Nonce changed');
  const audit = [], deps = await readDependencies(p, Number(BigInt(block.number)), audit);
  assert(same(deps.registrar, OLD) && same(deps.operator, MANAGER), 'Activation state changed');
  const art = load(ARTIFACT), factory = new ethers.ContractFactory(art.abi, art.bytecode.object, wallet);
  const request = await factory.getDeployTransaction(...Object.values(pre.constructor));
  const journal = { status: 'prepared', address: pre.predictedAddress, sourceCommit: pre.sourceCommit, nonce: pre.nonce, createdAt: new Date().toISOString() };
  write(BASE + '-journal.json', journal);
  const tx = await wallet.sendTransaction({ ...request, nonce: pre.nonce, chainId: 56, type: 0, gasLimit: BigInt(pre.gasLimit), gasPrice: BigInt(pre.gasPriceWei) });
  journal.status = 'submitted'; journal.hash = tx.hash; write(BASE + '-journal.json', journal);
  const receipt = await tx.wait(2);
  assert(receipt.status === 1 && same(receipt.contractAddress, pre.predictedAddress), 'Deployment failed or wrong address');
  write(BASE + '.json', { ...pre, address: receipt.contractAddress, deployedAt: new Date().toISOString(), status: 'deployed-pending-verification-and-safe-activation', deploymentTransaction: receipt.toJSON(), deploymentRecheckAudit: audit });
  journal.status = 'mined'; write(BASE + '-journal.json', journal);
  console.log(json({ mode: 'deploy', address: receipt.contractAddress, hash: tx.hash, block: receipt.blockNumber, gasUsed: receipt.gasUsed }));
}
function stateCalls(address) {
  return [...['owner', 'pendingOwner', 'managementOperator', 'swapWrapper', 'agentSwapWrapper', 'communityFactory', 'tradeCurationFactory', 'committee', 'hourlyTickCalculator'].map(n => read(address, n)),
    read(address, 'VERSION', [], [], ['uint256']), read(address, 'getDefaultPools', [], [], ['tuple(address factory,uint16 rewardRatio,bytes meta)[]']),
    read(ORDINARY, 'registrar'), read(AGENT, 'operator'), read(ORDINARY, 'owner'), read(AGENT, 'owner')];
}
async function status(p) {
  const record = load(BASE + '.json'), block = await snapshot(p), pin = Number(BigInt(block.number)), audit = [];
  const calls = stateCalls(record.address), values = await batch(p, pin, calls, audit);
  const state = Object.fromEntries(calls.map((d, i) => [i < 11 ? d.name : i === 11 ? 'ordinaryRegistrar' : i === 12 ? 'agentOperator' : i === 13 ? 'ordinaryOwner' : 'agentOwner', values[i]]));
  assert(same(state.owner, SAFE) && same(state.pendingOwner, ethers.ZeroAddress) && same(state.managementOperator, MANAGER) && state.VERSION === 3n, 'Deployed management mismatch');
  for (const [key, value] of Object.entries(record.constructor)) assert(same(state[key], value), 'Constructor dependency mismatch: ' + key);
  assert(state.getDefaultPools.length === 1 && state.getDefaultPools[0][1] === 10000n && same(state.getDefaultPools[0][0], record.constructor.tradeCurationFactory), 'Wrong default pools');
  const art = load(ARTIFACT), code = await p.send('eth_getCode', [record.address, ethers.toQuantity(pin)]);
  let actual = code.replace(/^0x/, ''), expected = art.deployedBytecode.object.replace(/^0x/, '');
  for (const refs of Object.values(art.deployedBytecode.immutableReferences)) for (const { start, length } of refs) {
    actual = actual.slice(0, start * 2) + '0'.repeat(length * 2) + actual.slice((start + length) * 2);
    expected = expected.slice(0, start * 2) + '0'.repeat(length * 2) + expected.slice((start + length) * 2);
  }
  assert(actual === expected, 'Runtime/source mismatch');
  const proof = { checkedAt: new Date().toISOString(), blockNumber: pin, blockHash: block.hash, ...state,
    ordinaryActivated: same(state.ordinaryRegistrar, record.address), agentActivated: same(state.agentOperator, record.address),
    runtime: { bytes: (code.length - 2) / 2, keccak256: ethers.keccak256(code), immutableMaskedMatch: true }, multicallAudit: audit };
  write(BASE + '-status.json', proof); record.lastCheckedState = proof;
  record.status = `deployed-${record.sourceVerification?.status === 'verified' ? 'verified-' : ''}${proof.ordinaryActivated && proof.agentActivated ? 'activated' : 'pending-safe-activation'}`;
  write(BASE + '.json', record);
  console.log(json({ mode: 'status', address: record.address, block: pin, owner: state.owner, managementOperator: state.managementOperator, ordinaryRegistrar: state.ordinaryRegistrar, agentOperator: state.agentOperator, ordinaryActivated: proof.ordinaryActivated, agentActivated: proof.agentActivated, runtime: proof.runtime }));
  return proof;
}
async function prepareActivation(p) {
  const proof = await status(p), record = load(BASE + '.json');
  assert(same(proof.agentOwner, SAFE) && same(proof.ordinaryOwner, SAFE), 'Owner changed; rebuild activation');
  const iface = new ethers.Interface(['function setRegistrar(address)', 'function setOperator(address)']);
  const operator = { to: AGENT, value: '0', data: iface.encodeFunctionData('setOperator', [record.address]) };
  const registrar = { to: ORDINARY, value: '0', data: iface.encodeFunctionData('setRegistrar', [record.address]) };
  const simulation = [];
  for (const tx of [operator, registrar]) {
    const result = await p.send('eth_call', [{ ...tx, value: '0x0', from: SAFE }, ethers.toQuantity(proof.blockNumber)]);
    simulation.push({ ...tx, from: SAFE, blockNumber: proof.blockNumber, result });
  }
  for (const [suffix, transactions, description] of [
    ['-operator.safe.json', [operator], 'Set AgentSwapWrapper operator to ImportHelperV3. Ordinary Wrapper registrar remains unchanged; dual import is not active.'],
    ['.safe.json', [operator, registrar], 'Activate ImportHelperV3 for both wrappers. Coordinate UI/API Helper address switch: old V2 imports fail after registrar changes.']
  ]) {
    const file = BASE + suffix;
    write(file, { version: '1.0', chainId: '56', createdAt: Date.now(), meta: { name: 'ImportHelperV3 activation', description, createdFromSafeAddress: SAFE }, transactions });
    fs.writeFileSync(file + '.sha256', sha(fs.readFileSync(file)) + '  ' + path.basename(file) + '\n');
  }
  write(BASE + '-activation-preflight.json', { status: 'prepared-not-proposed-not-signed-not-executed', checkedAt: new Date().toISOString(), blockNumber: proof.blockNumber, blockHash: proof.blockHash, safe: SAFE, helper: record.address,
    simulation: 'Each original owner call simulated separately with Safe sender. Full Safe batch/signature simulation remains required.', calls: simulation,
    note: 'Operator-only and full activation files overlap. Do not submit both blindly; reconcile current state and pending Safe proposals.' });
  console.log(json({ mode: 'prepare-activation', helper: record.address, operatorFile: BASE + '-operator.safe.json', fullActivationFile: BASE + '.safe.json', broadcast: false }));
}
async function main() {
  const mode = process.argv[2];
  assert(['preflight', 'deploy', 'status', 'prepare-activation'].includes(mode), 'Expected preflight/deploy/status/prepare-activation');
  const request = new ethers.FetchRequest(env.BSC_RPC_URL); request.timeout = 20000;
  const p = new ethers.JsonRpcProvider(request, 56, { staticNetwork: true, batchMaxCount: 1 });
  try { await ({ preflight, deploy, status, 'prepare-activation': prepareActivation }[mode])(p); } finally { p.destroy(); }
}
if (require.main === module) main().catch(e => { console.error('ImportHelperV3 operation failed: ' + (e.shortMessage || e.code || e.message).replace(/https?:\/\/\S+/g, '[RPC URL suppressed]')); process.exitCode = 1; });
module.exports = { BASE, FQN, ARTIFACT, ORDINARY, AGENT, SAFE, MANAGER, dependencyCalls, stateCalls, readDependencies };
