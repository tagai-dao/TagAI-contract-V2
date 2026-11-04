const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ethers = require(require.resolve('ethers', { paths: [process.cwd(), path.resolve('../buy-bot')] }));
const { FACTORY, HANDLE, SAFE, dependencies } = require('./index-broker-handle-templates.cjs');
const { MC, multicall, read } = require('./version18-chain.cjs');
const record = JSON.parse(fs.readFileSync('deployments/56/version13.json'));
const coder = ethers.AbiCoder.defaultAbiCoder();
const block = { number: '0x7b', hash: '0x' + '11'.repeat(32) };
const expected = [
  [read(FACTORY, 'owner'), read(FACTORY, 'pendingOwner'), read(FACTORY, 'communityFactory'),
    read(FACTORY, 'ammTemplate'), read(FACTORY, 'defaultRenderer'),
    read(FACTORY, 'platformFeeBps', [], [], ['uint16']), read(FACTORY, 'nftTemplateCount', [], [], ['uint256'])],
  [read(FACTORY, 'nftTemplateAt', ['uint256'], [0]), read(FACTORY, 'nftTemplateAt', ['uint256'], [1]),
    read(SAFE, 'getThreshold', [], [], ['uint256']), read(SAFE, 'getOwners', [], [], ['address[]']),
    read(SAFE, 'nonce', [], [], ['uint256']), read(record.Committee, 'verifyContract', ['address'], [FACTORY], ['bool'])],
];
function mockProvider(mutate) {
  let stage = 0;
  const codeTargets = [];
  return { codeTargets, get stages() { return stage; }, send: async (method, params) => {
    if (method === 'eth_getCode') {
      assert.equal(params[1], block.number); codeTargets.push(params[0]); return '0x6000';
    }
    assert.equal(method, 'eth_call'); assert.equal(params[0].to, MC); assert.equal(params[1], block.number);
    const calls = multicall.decodeFunctionData('aggregate3', params[0].data)[0];
    const descriptors = [read(MC, 'getBlockNumber', [], [], ['uint256']), ...expected[stage]];
    assert.equal(calls.length, descriptors.length);
    calls.forEach((call, i) => {
      assert.equal(call.target, ethers.getAddress(descriptors[i].target));
      assert.equal(call.callData, descriptors[i].callData); assert.equal(call.allowFailure, false);
    });
    const values = stage === 0
      ? [123, SAFE, ethers.ZeroAddress, record.CommunityFactory, record.IndexBrokerV2AMMTemplate,
        record.IndexBrokerV2Renderer, 30, 2]
      : [123, record.IndexBrokerV2BurnTemplate, record.IndexBrokerV2StakeTemplate, 2,
        [record.IndexBrokerV2Deployer, SAFE], 49, true];
    const results = descriptors.map((d, i) => [true, d.abi.encodeFunctionResult(d.name, [values[i]])]);
    mutate?.(stage, results); stage++;
    return multicall.encodeFunctionResult('aggregate3', [results]);
  } };
}
test('Factory and Safe stages use exact ordered Multicall subcalls at the same fixed block', async () => {
  const p = mockProvider(), audit = [];
  const state = await dependencies(p, block, audit);
  assert.equal(state.owner, SAFE); assert.equal(state.safe.threshold, 2n);
  assert.deepEqual(state.templates, [record.IndexBrokerV2BurnTemplate, record.IndexBrokerV2StakeTemplate]);
  assert.deepEqual(p.codeTargets, [MC, FACTORY, HANDLE]); assert.equal(p.stages, 2);
  assert.equal(audit.length, 2); audit.forEach(a => { assert.equal(a.target, MC); assert.equal(a.blockTag, block.number); });
});
test('reject a different block reported by a dependent Multicall stage', async () => {
  const p = mockProvider((stage, r) => { if (stage === 1) r[0][1] = coder.encode(['uint256'], [124]); });
  await assert.rejects(dependencies(p, block, []), /snapshot/);
});
test('reject missing required Factory/Safe data rather than falling back to direct reads', async () => {
  const p = mockProvider((stage, r) => { if (stage === 1) r[3][1] = '0x'; });
  await assert.rejects(dependencies(p, block, []), /Required Multicall result missing/);
  assert.equal(p.stages, 2);
});
test('reject a failed required Multicall child', async () => {
  const p = mockProvider((stage, r) => { if (stage === 0) r[1][0] = false; });
  await assert.rejects(dependencies(p, block, []), /Required Multicall result missing/);
  assert.equal(p.stages, 1);
});
