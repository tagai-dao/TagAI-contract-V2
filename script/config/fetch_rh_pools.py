#!/usr/bin/env python3
"""Fetch RH Uniswap V2/V3/V4 pools for CoinGecko-verified Robinhood tokenized stocks.

Rules (see docs/superpowers/specs/2026-08-29-rh-v11-router-basket-v3-design.md):
  - coingecko_coin_id contains "robinhood-tokenized-stock" (or WETH/USDG hub)
  - dex in uniswap-v2/v3/v4-robinhood
  - other side is USDG or WETH
  - pool_fee_percentage < 5
  - pick max reserve_in_usd

Usage:
  python3 script/config/fetch_rh_pools.py
"""
from __future__ import annotations

import json
import sys
import time
import urllib.parse
import urllib.request

BASE = "https://api.geckoterminal.com/api/v2"
NETWORK = "robinhood"
USDG = "0x5fc5360d0400a0fd4f2af552add042d716f1d168"
WETH = "0x0bd7d308f8e1639fab988df18a8011f41eacad73"
ALLOWED_DEX = {
    "uniswap-v2-robinhood": "V2",
    "uniswap-v3-robinhood": "V3",
    "uniswap-v4-robinhood": "V4",
}
# Official tokenized stocks to query (CoinGecko platforms.robinhood).
TOKENS = {
    "NVDA": "0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec",
    "SPY": "0x117cc2133c37b721f49de2a7a74833232b3b4c0c",
    "SPCX": "0x4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea",
    "GME": "0x1b0e319c6a659f002271b69db8a7df2f911c153e",
    "AAPL": "0xaf3d76f1834a1d425780943c99ea8a608f8a93f9",
    "TSLA": "0x322f0929c4625ed5bad873c95208d54e1c003b2d",
    "AMZN": "0x12f190a9f9d7d37a250758b26824b97ce941bf54",
    "MSFT": "0xe93237c50d904957cf27e7b1133b510c669c2e74",
    "QQQ": "0xd5f3879160bc7c32ebb4dc785f8a4f505888de68",
    "BABA": "0xad25ac6c84d497db898fa1e8387bf6af3532a1c4",
}

UA = {"Accept": "application/json", "User-Agent": "tagai-rh-pool-fetch/1.0"}


def get(url: str) -> dict:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def dex_id(pool: dict) -> str:
    rel = (pool.get("relationships") or {}).get("dex") or {}
    return ((rel.get("data") or {}).get("id")) or ""


def fee_pct(pool: dict) -> float:
    raw = (pool.get("attributes") or {}).get("pool_fee_percentage")
    try:
        return float(raw)
    except (TypeError, ValueError):
        return 0.0


def reserve(pool: dict) -> float:
    try:
        return float((pool.get("attributes") or {}).get("reserve_in_usd") or 0)
    except (TypeError, ValueError):
        return 0.0


def other_is_quote(name: str) -> bool:
    upper = name.upper()
    return "USDG" in upper or "WETH" in upper


def best_pool(token: str) -> dict | None:
    url = f"{BASE}/networks/{NETWORK}/tokens/{token}/pools?page=1"
    data = get(url)
    candidates = []
    for pool in data.get("data") or []:
        dex = dex_id(pool)
        if dex not in ALLOWED_DEX:
            continue
        attrs = pool.get("attributes") or {}
        name = attrs.get("name") or ""
        if not other_is_quote(name):
            continue
        if fee_pct(pool) >= 5:
            continue
        candidates.append(
            {
                "symbol_pool": name,
                "dex": ALLOWED_DEX[dex],
                "pool": (pool.get("id") or "").split("_", 1)[-1],
                "fee_pct": fee_pct(pool),
                "reserve_usd": reserve(pool),
            }
        )
    if not candidates:
        return None
    return max(candidates, key=lambda x: x["reserve_usd"])


def main() -> int:
    out = {
        "hub": {
            "name": "USDG / WETH 0.01%",
            "dex": "V3",
            "pool": "0x52e65b17fb6e5ba00ed806f37afcd2daa50271ca",
            "fee_pct": 0.01,
        },
        "assets": {},
        "skipped": [],
    }
    for symbol, addr in TOKENS.items():
        try:
            picked = best_pool(addr)
        except Exception as exc:
            out["skipped"].append({"symbol": symbol, "token": addr, "reason": str(exc)})
            time.sleep(1.2)
            continue
        time.sleep(1.2)
        if picked is None:
            out["skipped"].append({"symbol": symbol, "token": addr, "reason": "no qualifying pool"})
            continue
        out["assets"][symbol] = {"token": addr, **picked}
    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
