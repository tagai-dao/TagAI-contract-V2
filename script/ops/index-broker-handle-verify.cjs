// Freeze the exact Standard JSON inputs and retain independent BscScan verification evidence.
const fs = require('node:fs');
const cp = require('node:child_process');
const path = require('node:path');
const crypto = require('node:crypto');
const dotenv = require(require.resolve('dotenv', { paths: [process.cwd(), path.resolve('../tagai-api')] }));
const { BASE } = require('./index-broker-handle-templates.cjs');
const env = { ...dotenv.parse(fs.readFileSync('.env')), ...process.env, FOUNDRY_PROFILE: 'bsc_mainnet', FOUNDRY_ETH_RPC_URL: '' };
const dir = BASE + '-verification';
const sha = data => crypto.createHash('sha256').update(data).digest('hex');
const write = (file, value) => fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
const assert = (value, message) => { if (!value) throw Error(message); };
const safeLog = text => {
  for (const key of ['PRIVATE_KEY_MAIN', 'ETHERSCAN_API_KEY', 'BSCSCAN_API_KEY', 'BSC_RPC_URL']) {
    if (env[key]) text = text.split(env[key]).join('<REDACTED>');
  }
  return text;
};
async function main() {
  const mode = process.argv[2] || 'export';
  assert(mode === 'export' || mode === 'verify', 'Use export | verify');
  const deployment = JSON.parse(fs.readFileSync(BASE + '.json'));
  for (const [file, hash] of Object.entries(deployment.sourceHashes)) {
    assert(sha(fs.readFileSync(file)) === hash, 'Deployed source changed: ' + file);
  }
  fs.mkdirSync(dir, { recursive: true });
  const manifest = { chainId: 56, factory: deployment.factory, generatedAt: new Date().toISOString(),
    sourceCommit: deployment.sourceCommit, sourceState: deployment.sourceState,
    method: 'Foundry Solidity Standard JSON / Etherscan V2 API (BscScan, chain 56)',
    authorization: 'User explicitly authorized publication of both templates and compiler information on 2026-11-04 in this chat.', contracts: [] };
  for (const template of deployment.templates) {
    const fqn = 'src/nutbox/dapps/index-broker-nft/IndexBrokerNFT.sol:' + template.name;
    const args = ['verify-contract', template.address, fqn, '--chain', '56', '--compiler-version', template.compiler,
      '--num-of-optimizations', '100'];
    // Local export/recompile makes no network requests and proves both bytecodes exactly match.
    const art = JSON.parse(fs.readFileSync(`out/IndexBrokerNFT.sol/${template.name}.json`));
    const metadata = typeof art.metadata === 'string' ? JSON.parse(art.metadata) : art.metadata;
    const settings = structuredClone(metadata.settings);
    delete settings.compilationTarget;
    const target = 'src/nutbox/dapps/index-broker-nft/IndexBrokerNFT.sol';
    settings.outputSelection = { [target]: { [template.name]: ['evm.bytecode.object', 'evm.deployedBytecode.object'] } };
    const input = { language: 'Solidity', sources: Object.fromEntries(Object.keys(metadata.sources)
      .map(file => [file, { content: fs.readFileSync(file, 'utf8') }])), settings }, hashes = {};
    const solc = path.join(require('node:os').homedir(), 'Library/Application Support/svm/0.8.26/solc-0.8.26');
    const compiler = cp.spawnSync(solc, ['--version'], { encoding: 'utf8' });
    assert(compiler.status === 0 && compiler.stdout.includes(template.compiler), 'Local compiler version mismatch');
    const compiled = cp.spawnSync(solc, ['--standard-json'], { input: JSON.stringify(input), encoding: 'utf8', maxBuffer: 30 * 1024 * 1024 });
    assert(compiled.status === 0, 'Local Standard JSON compilation failed');
    const output = JSON.parse(compiled.stdout), contract = output.contracts?.[target]?.[template.name];
    assert(!output.errors?.some(e => e.severity === 'error') && contract, 'Standard JSON compiler errors');
    assert('0x' + contract.evm.bytecode.object === art.bytecode.object, 'Standard JSON creation bytecode mismatch');
    assert('0x' + contract.evm.deployedBytecode.object === art.deployedBytecode.object, 'Standard JSON runtime bytecode mismatch');
    assert(input.settings.viaIR && input.settings.optimizer.runs === 100 && input.settings.evmVersion === 'cancun', 'Compiler settings changed');
    for (const [file, source] of Object.entries(input.sources)) {
      assert(fs.readFileSync(file, 'utf8') === source.content, 'Export differs from checkout: ' + file);
      hashes[file] = sha(source.content);
    }
    const standardJson = `${dir}/${template.name}.standard-json.json`;
    const serialized = JSON.stringify(input, null, 2) + '\n';
    fs.writeFileSync(standardJson, serialized);
    const item = { name: template.name, address: template.address, fqn, compiler: template.compiler, settings: input.settings,
      standardJson, standardJsonSha256: sha(serialized), sourceHashes: hashes, constructorArgs: '',
      locallyRecompiledBytecodesMatch: true, status: 'exported' };
    manifest.contracts.push(item); write(dir + '/manifest.json', manifest);
    if (mode === 'export') continue;
    const result = await new Promise((resolve, reject) => {
      const child = cp.spawn('forge', [...args, '--verifier', 'etherscan', '--skip-is-verified-check', '--watch', '--retries', '4', '--delay', '5'],
        { env, stdio: ['ignore', 'pipe', 'pipe'] });
      let output = '';
      child.stdout.on('data', data => output += data); child.stderr.on('data', data => output += data);
      child.on('error', reject); child.on('close', code => resolve({ code, output: safeLog(output) }));
    });
    fs.writeFileSync(`${dir}/${template.name}.verification.log`, result.output);
    item.cliExitCode = result.code; write(dir + '/manifest.json', manifest);
    const url = new URL('https://api.etherscan.io/v2/api');
    url.search = new URLSearchParams({ chainid: '56', module: 'contract', action: 'getsourcecode',
      address: template.address, apikey: env.ETHERSCAN_API_KEY || env.BSCSCAN_API_KEY || '' });
    const response = await fetch(url, { signal: AbortSignal.timeout(30000) });
    assert(response.ok, 'Explorer result unavailable');
    const data = await response.json(), record = data.result?.[0];
    assert(data.status === '1' && record?.SourceCode && record.ContractName === template.name, 'Explorer did not confirm verification: ' + template.name);
    assert(record.CompilerVersion.includes(template.compiler) && record.OptimizationUsed === '1' && record.Runs === '100'
      && record.EVMVersion === 'cancun' && !record.SimilarMatch && !record.ConstructorArguments, 'Exact explorer compiler/constructor mismatch');
    const publicInput = JSON.parse(record.SourceCode.startsWith('{{') ? record.SourceCode.slice(1, -1) : record.SourceCode);
    const publicSettings = publicInput.settings;
    assert(publicSettings.viaIR === true && publicSettings.optimizer.enabled === true && publicSettings.optimizer.runs === 100
      && publicSettings.evmVersion === 'cancun' && publicSettings.metadata?.bytecodeHash === 'ipfs', 'Published compiler settings mismatch');
    for (const [file, hash] of Object.entries(hashes)) {
      assert(typeof publicInput.sources?.[file]?.content === 'string' && sha(publicInput.sources[file].content) === hash,
        'Published source mismatch: ' + file);
    }
    item.publicCompilerSettings = publicSettings;
    item.publishedSourceFilesMatch = true;
    item.publishedSourceFileCount = Object.keys(publicInput.sources).length;
    item.publicSourceCheckedAt = new Date().toISOString();
    item.status = 'verified'; item.verifiedAt = new Date().toISOString();
    item.explorer = 'https://bscscan.com/address/' + template.address + '#code';
    item.resultSource = { provider: 'Etherscan V2 API / BscScan', action: 'getsourcecode', chainId: 56 };
    item.explorerRecord = Object.fromEntries(['ContractName', 'CompilerVersion', 'OptimizationUsed', 'Runs', 'EVMVersion', 'SimilarMatch', 'ConstructorArguments'].map(k => [k, record[k]]));
    item.explorerSourceSha256 = sha(record.SourceCode); write(dir + '/manifest.json', manifest);
    console.log(JSON.stringify({ status: 'verified', name: template.name, address: template.address, explorer: item.explorer }));
  }
  manifest.status = manifest.contracts.every(c => c.status === 'verified') ? 'verified' : 'exported';
  write(dir + '/manifest.json', manifest);
  deployment.sourceVerification = { status: manifest.status, manifest: dir + '/manifest.json', method: manifest.method };
  write(BASE + '.json', deployment);
}
main().catch(error => { console.error(safeLog('Template verification failed: ' + (error.code || error.message))); process.exitCode = 1; });
