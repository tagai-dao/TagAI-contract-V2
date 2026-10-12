# Contract agent instructions

Inherit all workspace AGENTS.md rules, including mandatory on-chain Multicall for every batch
of contract reads. Pin dependent stages/chunks to one block and never fall back to individual RPC calls.

## RH contract source verification

- 用户已明确要求：后续 RH 合约默认使用浏览器上传 **Solidity (Standard JSON input)** 验证。
- Before RH deployment/verification work, read [docs/RH_CONTRACT_VERIFICATION.md](docs/RH_CONTRACT_VERIFICATION.md).
- Generate the JSON from the exact deployed source commit, profile and full compiler version.
  Preserve viaIR, optimizer, EVM version, remappings, libraries and metadata settings.
- `forge verify-contract --show-standard-json-input` is permitted for generating local files;
  do not default to CLI submission through Blockscout's API. Give the operator the file and browser steps.
- Record deployment, browser verification and owner activation separately. Verification does not activate a contract.
- Mark verified only after an actual success result or operator confirmation, distinguishing the evidence source.
- Never redeploy to fix browser/API verification errors, and never include credentials in a verification file.
