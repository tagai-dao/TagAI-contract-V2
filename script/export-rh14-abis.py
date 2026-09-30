#!/usr/bin/env python3
"""Export the compiled RH V14 public ABIs. Run forge build first."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAMES = (
    "RHPumpV14", "RHTokenV14", "RHSwapHookV14", "NutboxRouter",
    "TagAITradeRouter", "TagAILiquidityRouter", "TagAIBuybackRouter",
    "TradeCuration", "TradeCurationFactory",
)

def main():
    artifacts = {}
    for name in NAMES:
        artifact = ROOT / "out" / f"{name}.sol" / f"{name}.json"
        artifacts[name] = json.loads(artifact.read_text())["abi"]
    target = ROOT / "abis" / "rh-version14"
    target.mkdir(parents=True, exist_ok=True)
    for name, abi in artifacts.items():
        (target / f"{name}.json").write_text(json.dumps(abi, ensure_ascii=False, indent=2) + "\n")
    print(f"Exported {len(artifacts)} ABIs to {target}")

if __name__ == "__main__":
    main()
