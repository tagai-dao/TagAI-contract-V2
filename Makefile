# TagAI Contract V2 — deploy helpers
# Requires: PRIVATE_KEY in .env (forge auto-loads it)

.PHONY: deploy-rh-testnet deploy-rh-mainnet simulate-rh-testnet simulate-rh-mainnet \
	deploy-nft-mining-factory-mainnet simulate-nft-mining-factory-mainnet \
	deploy-basket-tvl-mining-mainnet simulate-basket-tvl-mining-mainnet \
	verify-nft-mining-factory-mainnet test-rh-import-wrapper

# Shared forge script flags for RH L2 gas estimation quirks
RH_SCRIPT_FLAGS := --broadcast --slow --gas-estimate-multiplier 300 -vvv
RH_SIM_FLAGS := -vvv
RH_MAINNET_RPC := https://rpc.mainnet.chain.robinhood.com

.PHONY: test-rh-import-helper-v2 simulate-rh-import-helper-v2 deploy-rh-import-helper-v2 verify-rh-import-helper-v2

test-rh-import-helper-v2:
	FOUNDRY_ETH_RPC_URL='' forge test --match-contract 'ImportHelper(V2)?Test' -vv
	node --test script/verify-rh-import-helper-v2.test.mjs

# One new Helper only. Registrar activation is a separate owner transaction.
simulate-rh-import-helper-v2:
	FOUNDRY_PROFILE=rh_mainnet forge script script/DeployRHImportHelperV2.s.sol:DeployRHImportHelperV2 --rpc-url $(RH_MAINNET_RPC) $(RH_SIM_FLAGS)

deploy-rh-import-helper-v2:
	FOUNDRY_PROFILE=rh_mainnet forge script script/DeployRHImportHelperV2.s.sol:DeployRHImportHelperV2 --rpc-url $(RH_MAINNET_RPC) $(RH_SCRIPT_FLAGS)

# RH verification defaults to browser-uploaded Standard JSON (see docs/RH_CONTRACT_VERIFICATION.md).
verify-rh-import-helper-v2:
	@test -n "$(HELPER)" || (echo "Need HELPER=actual deployed address"; exit 1)
	FOUNDRY_PROFILE=rh_mainnet forge verify-contract $(HELPER) src/helper/ImportHelperV2.sol:ImportHelperV2 \
		--chain 4663 --compiler-version v0.8.26+commit.8a97fa7a --show-standard-json-input \
		> deployments/4663/import-helper-v2-standard-input.json
	@echo "Upload deployments/4663/import-helper-v2-standard-input.json using Solidity (Standard JSON input), compiler v0.8.26+commit.8a97fa7a, MIT."
	@echo "https://robinhoodchain.blockscout.com/address/$(HELPER)/contract-verification"

deploy-rh-testnet:
	FOUNDRY_PROFILE=rh_testnet forge script script/DeployRH.s.sol:DeployRHScript $(RH_SCRIPT_FLAGS)

deploy-rh-mainnet:
	@echo "Disabled: full-stack RH mainnet deploy would replace the v9 Nutbox/IPShare stack."
	@echo "Use the audited incremental v11 deployment sequence documented in README.md."
	@false

# Additive: NFTMiningPoolFactory only (no Committee whitelist)
simulate-nft-mining-factory-mainnet:
	FOUNDRY_PROFILE=rh_mainnet forge script script/DeployNFTMiningFactory.s.sol:DeployNFTMiningFactoryScript $(RH_SIM_FLAGS)

deploy-nft-mining-factory-mainnet:
	FOUNDRY_PROFILE=rh_mainnet forge script script/DeployNFTMiningFactory.s.sol:DeployNFTMiningFactoryScript $(RH_SCRIPT_FLAGS)

# Additive: Basket TVL mining factory + parent/child templates (no Committee whitelist)
simulate-basket-tvl-mining-mainnet:
	FOUNDRY_PROFILE=rh_mainnet forge script script/DeployBasketTVLMiningFactory.s.sol:DeployBasketTVLMiningFactoryScript $(RH_SIM_FLAGS)

deploy-basket-tvl-mining-mainnet:
	FOUNDRY_PROFILE=rh_mainnet forge script script/DeployBasketTVLMiningFactory.s.sol:DeployBasketTVLMiningFactoryScript $(RH_SCRIPT_FLAGS)

# Export browser verification inputs from the matching deployed source/profile.
# Usage: make verify-nft-mining-factory-mainnet FACTORY=0x... TEMPLATE=0x... RENDERER=0x...
verify-nft-mining-factory-mainnet:
	@test -n "$(FACTORY)" -a -n "$(TEMPLATE)" -a -n "$(RENDERER)" || (echo "Need FACTORY= TEMPLATE= RENDERER="; exit 1)
	FOUNDRY_PROFILE=rh_mainnet forge verify-contract $(FACTORY) src/nutbox/dapps/nft-mining/NFTMiningPoolFactory.sol:NFTMiningPoolFactory \
		--chain 4663 --compiler-version v0.8.26+commit.8a97fa7a --show-standard-json-input \
		> deployments/4663/nft-mining-factory-standard-input.json
	FOUNDRY_PROFILE=rh_mainnet forge verify-contract $(TEMPLATE) src/nutbox/dapps/nft-mining/NFTMiningPool.sol:NFTMiningPool \
		--chain 4663 --compiler-version v0.8.26+commit.8a97fa7a --show-standard-json-input \
		> deployments/4663/nft-mining-pool-standard-input.json
	FOUNDRY_PROFILE=rh_mainnet forge verify-contract $(RENDERER) src/nutbox/dapps/nft-mining/NFTMiningRenderer.sol:NFTMiningRenderer \
		--chain 4663 --compiler-version v0.8.26+commit.8a97fa7a --show-standard-json-input \
		> deployments/4663/nft-mining-renderer-standard-input.json
	@echo "Upload each Standard JSON to the matching address page; see docs/RH_CONTRACT_VERIFICATION.md."

# Dry-run (no broadcast)
simulate-rh-testnet:
	FOUNDRY_PROFILE=rh_testnet forge script script/DeployRH.s.sol:DeployRHScript $(RH_SIM_FLAGS)

simulate-rh-mainnet:
	@echo "Disabled: use the incremental v11 scripts for RH mainnet simulation."
	@false

# RH mainnet fork: ImportHelper + TagAISwapWrapper E2E (test/fork/RHImportWrapper.t.sol)
test-rh-import-wrapper:
	FOUNDRY_PROFILE=rh_fork RH_RPC_URL=$${RH_RPC_URL:-https://rpc.mainnet.chain.robinhood.com} FOUNDRY_ETH_RPC_URL= \
	forge test --match-contract RHImportWrapper -vvv
