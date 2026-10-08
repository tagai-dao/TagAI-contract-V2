#!/usr/bin/env python3
"""Read-only snapshot of the Uniswap RH stocks catalog and pools (no keys/broadcast).
Uniswap interface client-data-api 0.0.250: ListRwas + data.v2.ListPools.
All pagination cursors are followed, including empty pages with a cursor.
"""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import time

BASE = 'https://entry-gateway.backend-prod.api.uniswap.org'
QUOTES = ['0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73', '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168']

def request(method, payload):
    for attempt in range(4):
        proc = subprocess.run(['curl', '--fail-with-body', '-sS', '--max-time', '40',
            BASE + '/' + method, '-H', 'Content-Type: application/json',
            '-H', 'Connect-Protocol-Version: 1', '--data-binary', '@-'],
            input=json.dumps(payload), text=True, capture_output=True)
        if proc.returncode == 0:
            result = json.loads(proc.stdout)
            if not any(k in result for k in ('error', 'errorCode', 'code')):
                return result
        if attempt == 3:
            raise RuntimeError(f'{method}: {proc.stdout[:300]} {proc.stderr[:100]}')
        time.sleep(10 * (attempt + 1))


def fetch(destination):
    destination.mkdir(parents=True, exist_ok=True)
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    catalog = request('data.v1.DataApiService/ListRwas', {'chainIds': [4663]})
    assert catalog.get('rwas'), 'empty stock catalog'
    (destination / 'uniswap-rwas.json').write_text(json.dumps(catalog, indent=2) + '\n')
    pools, cursors = {}, set()
    cursor = None
    for page in range(200):
        payload = {'chainIds': [4663], 'sort': {'orderBy': 'POOLS_ORDER_BY_TVL'},
            'filter': {'applyTopLevelFilters': False, 'includeSpam': False,
                'tokenFilter': {'tokens': QUOTES, 'logicalOperator': 'POOL_TOKEN_LOGICAL_OPERATOR_OR'},
                'statsFilter': {'tvl': {'min': 50000}}}, 'page': {'pageSize': 100}}
        if cursor:
            payload['page']['pageToken'] = cursor
        data = request('data.v2.DataApiService/ListPools', payload)
        (destination / f'uniswap-pools-{page:03}.json').write_text(json.dumps(data, indent=2) + '\n')
        for row in data.get('pools', []):
            pool = row['pool']
            assert pool['chainId'] == 4663
            pools[pool['poolId'].lower()] = row
        cursor = data.get('page', {}).get('nextPageToken')
        print(f'page {page}: {len(data.get("pools", []))} rows; unique {len(pools)}', flush=True)
        if not cursor:
            break
        if cursor in cursors:
            raise RuntimeError('repeated pagination cursor')
        cursors.add(cursor)
        time.sleep(0.3)
    else:
        raise RuntimeError('pagination incomplete')
    snapshot = {'chainId': 4663, 'startedAt': started,
        'completedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'catalogSource': BASE + '/data.v1.DataApiService/ListRwas',
        'poolSource': BASE + '/data.v2.DataApiService/ListPools',
        'pageUrl': 'https://app.uniswap.org/explore/tokens/robinhood?category=stocks',
        'minPoolTvlUsdExclusive': 50000, 'quoteAssets': QUOTES,
        'poolPageCount': page + 1, 'paginationComplete': True,
        'stocks': [r for r in catalog['rwas'] if 'RWA_CATEGORY_STOCKS' in r.get('categories', [])],
        'pools': list(pools.values())}
    (destination.parent / 'snapshot.json').write_text(json.dumps(snapshot, indent=2) + '\n')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=Path('deployments/4663/rh14-stocks/raw'))
    fetch(parser.parse_args().out)
