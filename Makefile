# TagAI Contract V2 — deploy helpers
# Requires: PRIVATE_KEY in .env (forge auto-loads it)

.PHONY: deploy-rh-testnet deploy-rh-mainnet simulate-rh-testnet simulate-rh-mainnet test-rh-import-wrapper

# Shared forge script flags for RH L2 gas estimation quirks
RH_SCRIPT_FLAGS := --broadcast --slow --gas-estimate-multiplier 300 -vvv
RH_SIM_FLAGS := -vvv

deploy-rh-testnet:
	FOUNDRY_PROFILE=rh_testnet forge script script/DeployRH.s.sol:DeployRHScript $(RH_SCRIPT_FLAGS)

deploy-rh-mainnet:
	FOUNDRY_PROFILE=rh_mainnet forge script script/DeployRH.s.sol:DeployRHScript $(RH_SCRIPT_FLAGS)

# Dry-run (no broadcast)
simulate-rh-testnet:
	FOUNDRY_PROFILE=rh_testnet forge script script/DeployRH.s.sol:DeployRHScript $(RH_SIM_FLAGS)

simulate-rh-mainnet:
	FOUNDRY_PROFILE=rh_mainnet forge script script/DeployRH.s.sol:DeployRHScript $(RH_SIM_FLAGS)

# RH mainnet fork: ImportHelper + TagAISwapWrapper E2E (test/fork/RHImportWrapper.t.sol)
test-rh-import-wrapper:
	FOUNDRY_PROFILE=rh_fork RH_RPC_URL=$${RH_RPC_URL:-https://rpc.mainnet.chain.robinhood.com} FOUNDRY_ETH_RPC_URL= \
	forge test --match-contract RHImportWrapper -vvv
