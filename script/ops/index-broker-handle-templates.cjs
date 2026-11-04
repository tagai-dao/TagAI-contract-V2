// Deploy only the Handle-gated NFT templates; keep the existing Factory and AMM.
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const crypto = require('node:crypto');
const ethers = require(require.resolve('ethers', { paths: [process.cwd(), path.resolve('../buy-bot')] }));
const dotenv = require(require.resolve('dotenv', { paths: [process.cwd(), path.resolve('../tagai-api')] }));
const { batch, read, MC } = require('./version18-chain.cjs');
const BASE = 'deployments/56/index-broker-handle-templates';
const FACTORY = '0x835E047D4BE6548E95F2Cbb9Ac02d62EFa2508A0';
const HANDLE = '0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F';
const SAFE = '0x871fb7006C5964B21695Ba20006021777A26146C';
const NAMES = ['IndexBrokerNFTBurn', 'IndexBrokerNFTStake'];
const FOLDER = 'src/nutbox/dapps/index-broker-nft/';
const factoryAbi = new ethers.Interface(['function addNFTTemplate(address template)']);
const json = v => JSON.stringify(v, (_, x) => typeof x === 'bigint' ? x.toString() : x, 2) + '\n';
const sha = v => crypto.createHash('sha256').update(v).digest('hex');
const load = f => JSON.parse(fs.readFileSync(f));
const write = (f, v) => fs.writeFileSync(f, json(v));
const same = (a, b) => a.toLowerCase() === b.toLowerCase();
const assert = (v, message) => { if (!v) throw Error(message); };
const artifactPath = name => `out/IndexBrokerNFT.sol/${name}.json`;
const artifact = name => load(artifactPath(name));

function factoryCalls() {
  return [read(FACTORY, 'owner'), read(FACTORY, 'pendingOwner'),
    read(FACTORY, 'communityFactory'), read(FACTORY, 'ammTemplate'), read(FACTORY, 'defaultRenderer'),
    read(FACTORY, 'platformFeeBps', [], [], ['uint16']), read(FACTORY, 'nftTemplateCount', [], [], ['uint256'])];
}
async function snapshot(p) {
  assert(BigInt(await p.send('eth_chainId', [])) === 56n, 'BSC chain mismatch');
  return p.send('eth_getBlockByNumber', ['latest', false]);
}
async function dependencies(p, block, audit) {
  const pin = Number(BigInt(block.number)), tag = ethers.toQuantity(pin);
  const v13 = load('deployments/56/version13.json');
  assert(same(v13.IndexBrokerV2Factory, FACTORY), 'Deployment record Factory changed');
  for (const address of [MC, FACTORY, HANDLE]) {
    assert(await p.send('eth_getCode', [address, tag]) !== '0x', 'Missing required deployment: ' + address);
  }
  const [owner, pendingOwner, communityFactory, ammTemplate, renderer, platformFeeBps, count] =
    await batch(p, pin, factoryCalls(), audit);
  assert(same(communityFactory, v13.CommunityFactory), 'Unexpected CommunityFactory');
  assert(same(pendingOwner, ethers.ZeroAddress), 'Factory ownership transfer pending');
  assert(count > 0n && count <= 64n, 'Unexpected template count');
  assert(same(owner, SAFE), 'Unexpected Factory owner');
  const calls = Array.from({ length: Number(count) }, (_, i) => read(FACTORY, 'nftTemplateAt', ['uint256'], [i]));
  calls.push(read(SAFE, 'getThreshold', [], [], ['uint256']), read(SAFE, 'getOwners', [], [], ['address[]']),
    read(SAFE, 'nonce', [], [], ['uint256']), read(v13.Committee, 'verifyContract', ['address'], [FACTORY], ['bool']));
  const values = await batch(p, pin, calls, audit);
  const [threshold, owners, nonce, whitelisted] = values.slice(Number(count));
  assert(whitelisted && threshold > 0n && threshold <= BigInt(owners.length), 'Invalid Factory/Safe configuration');
  return { owner, pendingOwner, communityFactory, ammTemplate, renderer, platformFeeBps,
    templates: values.slice(0, Number(count)), safe: { address: SAFE, threshold, owners, nonce } };
}
function checkSources(plan) {
  for (const [file, hash] of Object.entries(plan.sourceHashes)) {
    assert(sha(fs.readFileSync(file)) === hash, 'Source changed: ' + file);
  }
  for (const entry of plan.templates) {
    assert(sha(fs.readFileSync(artifactPath(entry.name))) === entry.artifactSha256, 'Artifact changed: ' + entry.name);
  }
}
async function preflight(p, env) {
  assert(!fs.existsSync(BASE + '.json') && !fs.existsSync(BASE + '-journal.json'), 'Release/journal exists; resume instead');
  const block = await snapshot(p), audit = [], state = await dependencies(p, block, audit);
  const wallet = new ethers.Wallet(env.PRIVATE_KEY_MAIN), tag = block.number;
  const latest = await p.send('eth_getTransactionCount', [wallet.address, 'latest']);
  const pending = await p.send('eth_getTransactionCount', [wallet.address, 'pending']);
  assert(latest === pending, 'Deployment wallet has pending transactions');
  const balance = BigInt(await p.send('eth_getBalance', [wallet.address, tag]));
  const networkGasPrice = BigInt(await p.send('eth_gasPrice', []));
  const gasPrice = networkGasPrice > 50_000_000n ? networkGasPrice : 50_000_000n;
  const sourceHashes = {}, templates = [];
  for (const [i, name] of NAMES.entries()) {
    const art = artifact(name), metadata = typeof art.metadata === 'string' ? JSON.parse(art.metadata) : art.metadata;
    assert(metadata.compiler.version === '0.8.26+commit.8a97fa7a', 'Compiler version mismatch');
    assert(metadata.settings.viaIR && metadata.settings.optimizer.runs === 100 && metadata.settings.evmVersion === 'cancun', 'Compiler settings mismatch');
    for (const [file, source] of Object.entries(metadata.sources)) {
      const content = fs.readFileSync(file);
      assert(ethers.keccak256(content) === source.keccak256, 'Artifact source mismatch: ' + file);
      sourceHashes[file] = sha(content);
    }
    const runtimeBytes = (art.deployedBytecode.object.replace(/^0x/, '').length / 2);
    assert(runtimeBytes <= 24576, 'Template exceeds deployment size limit');
    const gasEstimate = BigInt(await p.send('eth_estimateGas', [{ from: wallet.address, data: art.bytecode.object }]));
    const gasLimit = gasEstimate * 120n / 100n;
    assert(gasLimit <= 7_000_000n, 'Unexpected deployment gas estimate');
    assert(gasLimit < BigInt(block.gasLimit), 'Block gas limit too low');
    templates.push({ name, address: ethers.getCreateAddress({ from: wallet.address, nonce: Number(BigInt(pending)) + i }),
      nonce: Number(BigInt(pending)) + i, gasEstimate, gasLimit, runtimeBytes, artifactSha256: sha(fs.readFileSync(artifactPath(name))),
      initCodeHash: ethers.keccak256(art.bytecode.object), runtimeHash: ethers.keccak256(art.deployedBytecode.object),
      compiler: metadata.compiler.version, settings: metadata.settings });
  }
  assert(balance > templates.reduce((v, t) => v + t.gasLimit, 0n) * gasPrice, 'Insufficient deployment BNB');
  const plan = { chainId: 56, factory: FACTORY, handleRegistry: HANDLE, checkedAt: new Date().toISOString(),
    blockNumber: Number(BigInt(block.number)), blockHash: block.hash, deployer: wallet.address,
    sourceCommit: cp.execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
    sourceState: 'Reviewed working tree; exact compiled sources frozen by SHA-256 and exported Standard JSON',
    sourceHashes, templates, gasPriceWei: gasPrice, balanceWei: balance, dependencies: state, multicallAudit: audit };
  write(BASE + '-preflight.json', plan);
  console.log(json({ mode: 'preflight', block: plan.blockNumber, deployer: wallet.address, factory: FACTORY,
    templates: templates.map(t => ({ name: t.name, predictedAddress: t.address, runtimeBytes: t.runtimeBytes })),
    safe: state.safe, balanceBNB: ethers.formatEther(balance), gasPriceGwei: ethers.formatUnits(gasPrice, 9),
    maximumDeploymentGasCostBNB: ethers.formatEther(templates.reduce((v, t) => v + t.gasLimit, 0n) * gasPrice) }));
}
async function waitReceipt(p, hash) {
  for (let attempt = 0; attempt < 90; attempt++) {
    const receipt = await p.send('eth_getTransactionReceipt', [hash]);
    if (receipt) { assert(BigInt(receipt.status) === 1n, 'Transaction failed: ' + hash); return receipt; }
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  throw Error('Receipt pending; resume with journal: ' + hash);
}
async function deploy(p, env) {
  const plan = load(BASE + '-preflight.json'); checkSources(plan);
  assert(!fs.existsSync(BASE + '.json'), 'Release exists; use status');
  const wallet = new ethers.Wallet(env.PRIVATE_KEY_MAIN), block = await snapshot(p), audit = [];
  assert(same(wallet.address, plan.deployer), 'Wrong deployment wallet');
  assert(Number(BigInt(block.number)) - plan.blockNumber < 1200, 'Preflight expired');
  await dependencies(p, block, audit);
  const journal = fs.existsSync(BASE + '-journal.json') ? load(BASE + '-journal.json')
    : { createdAt: new Date().toISOString(), chainId: 56, factory: FACTORY, transactions: [] };
  for (const entry of plan.templates) {
    const tx = { type: 0, chainId: 56, nonce: entry.nonce, value: 0n,
      gasLimit: BigInt(entry.gasLimit), gasPrice: BigInt(plan.gasPriceWei), data: artifact(entry.name).bytecode.object };
    const raw = await wallet.signTransaction(tx), hash = ethers.keccak256(raw);
    let saved = journal.transactions.find(t => t.name === entry.name);
    if (saved) assert(saved.hash === hash, 'Journal transaction changed');
    else {
      saved = { name: entry.name, address: entry.address, nonce: entry.nonce, hash, status: 'prepared' };
      journal.transactions.push(saved); write(BASE + '-journal.json', journal);
    }
    let receipt = await p.send('eth_getTransactionReceipt', [hash]);
    if (!receipt && !await p.send('eth_getTransactionByHash', [hash])) {
      const nonce = Number(BigInt(await p.send('eth_getTransactionCount', [wallet.address, 'pending'])));
      assert(nonce === entry.nonce, 'Nonce changed; reconcile journal before sending');
      assert(await p.send('eth_getCode', [entry.address, 'latest']) === '0x', 'Predicted address already has code');
      const sent = await p.send('eth_sendRawTransaction', [raw]);
      assert(sent === hash, 'Broadcast hash mismatch');
      saved.status = 'submitted'; write(BASE + '-journal.json', journal);
      console.log(json({ mode: 'submitted', name: entry.name, address: entry.address, hash }));
    }
    receipt ||= await waitReceipt(p, hash);
    assert(BigInt(receipt.status) === 1n && same(receipt.contractAddress, entry.address), 'Deployment receipt mismatch');
    saved.status = 'confirmed'; saved.receipt = receipt; write(BASE + '-journal.json', journal);
    const runtime = await p.send('eth_getCode', [entry.address, receipt.blockNumber]);
    assert(ethers.keccak256(runtime) === entry.runtimeHash, 'Deployed runtime mismatch');
    console.log(json({ mode: 'deployed', name: entry.name, address: entry.address, hash,
      blockNumber: Number(BigInt(receipt.blockNumber)), gasUsed: BigInt(receipt.gasUsed) }));
  }
  write(BASE + '.json', { ...plan, deployedAt: new Date().toISOString(), status: 'deployed-pending-registration',
    transactions: journal.transactions, deploymentRecheckAudit: audit });
}
async function status(p) {
  const record = load(BASE + '.json'), block = await snapshot(p), pin = Number(BigInt(block.number)), audit = [];
  checkSources(record);
  const state = await dependencies(p, block, audit);
  const descriptors = record.templates.flatMap(t => [read(t.address, 'HANDLE_REGISTRY'),
    read(t.address, 'nftTemplateInterfaceId', [], [], ['bytes4']),
    read(FACTORY, 'supportedNFTTemplate', ['address'], [t.address], ['bool'])]);
  const values = await batch(p, pin, descriptors, audit);
  const templates = [];
  for (const [i, entry] of record.templates.entries()) {
    const [registry, interfaceId, registered] = values.slice(i * 3, i * 3 + 3);
    assert(same(registry, HANDLE), 'Handle registry mismatch');
    assert(interfaceId === new ethers.Interface(artifact(entry.name).abi).getFunction('initialize').selector, 'Template interface mismatch');
    const runtime = await p.send('eth_getCode', [entry.address, block.number]);
    assert(ethers.keccak256(runtime) === entry.runtimeHash, 'Runtime hash mismatch');
    templates.push({ name: entry.name, address: entry.address, handleRegistry: registry, interfaceId, registered, runtimeHash: entry.runtimeHash });
  }
  const proof = { checkedAt: new Date().toISOString(), blockNumber: pin, blockHash: block.hash,
    factory: FACTORY, state, templates, multicallAudit: audit };
  write(BASE + '-status.json', proof);
  record.status = templates.every(t => t.registered) ? 'deployed-registered' : 'deployed-pending-registration';
  record.lastCheckedState = proof; write(BASE + '.json', record);
  console.log(json({ mode: 'status', blockNumber: pin, status: record.status, factory: FACTORY, templates }));
  return proof;
}
async function prepareRegistration(p) {
  const proof = await status(p);
  const pending = proof.templates.filter(t => !t.registered);
  assert(pending.length > 0, 'All templates already registered');
  const transactions = pending.map(t => ({ to: FACTORY, value: '0',
    data: factoryAbi.encodeFunctionData('addNFTTemplate', [t.address]),
    contractMethod: { inputs: [{ internalType: 'address', name: 'template', type: 'address' }], name: 'addNFTTemplate', payable: false },
    contractInputsValues: { template: t.address } }));
  const simulations = [];
  for (const tx of transactions) {
    // State-changing owner-call simulation: preserve the Safe sender, not a contract-read batch.
    const result = await p.send('eth_call', [{ from: SAFE, to: tx.to, value: '0x0', data: tx.data }, ethers.toQuantity(proof.blockNumber)]);
    assert(result === '0x', 'Unexpected registration simulation result');
    simulations.push({ from: SAFE, to: tx.to, data: tx.data, blockTag: ethers.toQuantity(proof.blockNumber), result });
  }
  write(BASE + '.safe.json', { version: '1.0', chainId: '56', createdAt: Date.now(),
    meta: { name: 'Register Binance Handle-gated NFT templates', description: 'Register new Burn and Stake templates on the existing Factory. Existing templates and pools remain available.', createdFromSafeAddress: SAFE }, transactions });
  write(BASE + '-registration-simulation.json', { status: 'prepared-not-signed-not-executed',
    blockNumber: proof.blockNumber, blockHash: proof.blockHash, safe: proof.state.safe, simulations,
    limitation: 'Individual state-changing owner calls simulated; Safe batch signatures are not available.' });
  fs.writeFileSync(BASE + '.safe.json.sha256', sha(fs.readFileSync(BASE + '.safe.json')) + '  ' + path.basename(BASE + '.safe.json') + '\n');
  console.log(json({ mode: 'prepare-registration', file: BASE + '.safe.json', safe: SAFE,
    threshold: proof.state.safe.threshold, transactionCount: transactions.length, simulated: true, executed: false }));
}
async function main() {
  const env = { ...dotenv.parse(fs.readFileSync('.env')), ...process.env };
  assert(env.BSC_RPC_URL, 'Missing BSC_RPC_URL');
  const request = new ethers.FetchRequest(env.BSC_RPC_URL); request.timeout = 20000;
  const p = new ethers.JsonRpcProvider(request, 56, { staticNetwork: true, batchMaxCount: 1 });
  try {
    const command = process.argv[2];
    if (command === 'preflight') await preflight(p, env);
    else if (command === 'deploy') await deploy(p, env);
    else if (command === 'status') await status(p);
    else if (command === 'prepare-registration') await prepareRegistration(p);
    else throw Error('Use preflight | deploy | status | prepare-registration');
  } finally { p.destroy(); }
}
if (require.main === module) main().catch(e => {
  console.error('NFT template operation failed: ' + (e.code || e.message?.replace(/https?:\/\/\S+/g, '<URL>').split('\n')[0]));
  process.exitCode = 1;
});
module.exports = { FACTORY, HANDLE, SAFE, BASE, factoryCalls, dependencies };
