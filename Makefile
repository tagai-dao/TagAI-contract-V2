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
RH_BLOCKSCOUT_API := https://robinhoodchain.blockscout.com/api/

.PHONY: test-rh-import-helper-v2 simulate-rh-import-helper-v2 deploy-rh-import-helper-v2 verify-rh-import-helper-v2

test-rh-import-helper-v2:
	FOUNDRY_ETH_RPC_URL='' forge test --match-contract 'ImportHelper(V2)?Test' -vv
	node --test script/verify-rh-import-helper-v2.test.mjs

# One new Helper only. Registrar activation is a separate owner transaction.
simulate-rh-import-helper-v2:
	FOUNDRY_PROFILE=rh_mainnet forge script script/DeployRHImportHelperV2.s.sol:DeployRHImportHelperV2 --rpc-url $(RH_MAINNET_RPC) $(RH_SIM_FLAGS)

deploy-rh-import-helper-v2:
	FOUNDRY_PROFILE=rh_mainnet forge script script/DeployRHImportHelperV2.s.sol:DeployRHImportHelperV2 --rpc-url $(RH_MAINNET_RPC) $(RH_SCRIPT_FLAGS)

verify-rh-import-helper-v2:
	@test -n "$(HELPER)" || (echo "Need HELPER=actual deployed address"; exit 1)
	FOUNDRY_PROFILE=rh_mainnet forge verify-contract $(HELPER) src/helper/ImportHelperV2.sol:ImportHelperV2 \
		--chain 4663 --rpc-url $(RH_MAINNET_RPC) --verifier blockscout --verifier-url $(RH_BLOCKSCOUT_API) \
		--constructor-args $$(cast abi-encode "constructor(address,address,address,address,address)" \
		0x24328DccA1bA54EeE82e2993F021802e64290486 0x73cb7A6Ad01686659F72011eb952fBa53fe6212B \
		0x7B0ddC305C32AAEbabc0FE372a4460e9903e95D0 0x3DC52C69C3C8be568372E16d50E9F3FEc796610c \
		0x53e65DE68A0eB7f3662579F44Eb9849Ae5cA44ab) --watch

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

# Usage: make verify-nft-mining-factory-mainnet FACTORY=0x... TEMPLATE=0x... RENDERER=0x...
verify-nft-mining-factory-mainnet:
	@test -n "$(FACTORY)" -a -n "$(TEMPLATE)" -a -n "$(RENDERER)" || (echo "Need FACTORY= TEMPLATE= RENDERER="; exit 1)
	forge verify-contract $(FACTORY) src/nutbox/dapps/nft-mining/NFTMiningPoolFactory.sol:NFTMiningPoolFactory \
		--chain 4663 --rpc-url $(RH_MAINNET_RPC) \
		--verifier blockscout --verifier-url $(RH_BLOCKSCOUT_API) \
		--constructor-args $$(cast abi-encode "constructor(address)" 0x24328DccA1bA54EeE82e2993F021802e64290486) \
		--watch
	forge verify-contract $(TEMPLATE) src/nutbox/dapps/nft-mining/NFTMiningPool.sol:NFTMiningPool \
		--chain 4663 --rpc-url $(RH_MAINNET_RPC) \
		--verifier blockscout --verifier-url $(RH_BLOCKSCOUT_API) \
		--watch
	forge verify-contract $(RENDERER) src/nutbox/dapps/nft-mining/NFTMiningRenderer.sol:NFTMiningRenderer \
		--chain 4663 --rpc-url $(RH_MAINNET_RPC) \
		--verifier blockscout --verifier-url $(RH_BLOCKSCOUT_API) \
		--watch

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
