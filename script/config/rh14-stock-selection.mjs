// Shared deterministic pool policy; no network or filesystem access.
const zero = '0x0000000000000000000000000000000000000000';
export function eligiblePool(row, address, weth, usdg) {
  const p=row.pool, pair=[p.token0.address.toLowerCase(),p.token1.address.toLowerCase()];
  return p.chainId===4663 && pair.includes(address.toLowerCase()) && pair.some(t=>[weth.toLowerCase(),usdg.toLowerCase()].includes(t))
    && Number.isFinite(row.stats?.tvl) && row.stats.tvl>50000
    && ['PROTOCOL_VERSION_V3','PROTOCOL_VERSION_V4'].includes(p.protocolVersion)
    && (p.hookAddress||zero).toLowerCase()===zero && !p.isDynamicFee
    && Number.isInteger(p.feeTier) && p.feeTier>=0 && p.feeTier<50000 && BigInt(p.liquidity||0)>0n;
}
