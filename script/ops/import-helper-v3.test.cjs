const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const ethers = require(require.resolve('ethers', { paths: [process.cwd(), path.resolve('../buy-bot')] }));
const { batch, MC, multicall } = require('./version18-chain.cjs');
const { dependencyCalls, stateCalls } = require('./import-helper-v3.cjs');
const coder = ethers.AbiCoder.defaultAbiCoder();
const helper = '0x1111111111111111111111111111111111111111';
for (const [name, descriptors] of [['dependencies', dependencyCalls()], ['deployed-state', stateCalls(helper)]]) {
  function fixture(mutator) {
    let count = 0;
    const p = { send: async (method, args) => {
      ++count;
      assert.equal(method, 'eth_call');
      assert.equal(args[0].to, MC);
      assert.equal(args[1], '0x7b');
      const calls = multicall.decodeFunctionData('aggregate3', args[0].data)[0];
      assert.equal(calls.length, descriptors.length + 1);
      assert.equal(calls[0].target, MC);
      assert.equal(calls[0].callData, multicall.encodeFunctionData('getBlockNumber'));
      const results = [[true, coder.encode(['uint256'], [123])]];
      descriptors.forEach((d, i) => {
        assert.equal(calls[i + 1].target, ethers.getAddress(d.target));
        assert.equal(calls[i + 1].callData, d.callData);
        assert.equal(calls[i + 1].allowFailure, false);
        const output = d.abi.getFunction(d.name).outputs[0];
        const value = output.type.endsWith('[]') ? [] : output.type === 'address' ? helper : 3n;
        results.push([true, d.abi.encodeFunctionResult(d.name, [value])]);
      });
      mutator?.(results);
      return multicall.encodeFunctionResult('aggregate3', [results]);
    }};
    return { p, count: () => count };
  }
  test(name + ': fixed block, exact Multicall target, ordered targets and full calldata set', async () => {
    const f = fixture(), audit = [];
    const result = await batch(f.p, 123, descriptors, audit);
    assert.equal(result.length, descriptors.length);
    assert.equal(f.count(), 1);
    assert.equal(audit[0].blockTag, '0x7b');
  });
  for (const [failure, mutate] of [['failed child', r => { r[1][0] = false; }], ['missing data', r => { r[1][1] = '0x'; }], ['wrong snapshot', r => { r[0][1] = coder.encode(['uint256'], [124]); }]]) {
    test(name + ': rejects ' + failure + ' without independent RPC fallback', async () => {
      const f = fixture(mutate);
      await assert.rejects(batch(f.p, 123, descriptors));
      assert.equal(f.count(), 1);
    });
  }
}
