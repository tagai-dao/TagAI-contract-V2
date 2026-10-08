// Read-only recovery audit. No wallet, signing or transaction submission.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
const require = createRequire(path.resolve('../tiptag-ui/package.json'));
const {encodeFunctionData,decodeFunctionData,decodeFunctionResult,encodeAbiParameters,parseAbiParameters,keccak256,getAddress}=require('viem');
const abi=JSON.parse(fs.readFileSync('out/NutboxRouter.sol/NutboxRouter.json')).abi;
const dir='deployments/4663/rh14-recovery';
const original=JSON.parse(fs.readFileSync(`${dir}/original-broadcast.json`));
const rpc=process.env.RH14_RPC_URL||'https://rpc.mainnet.chain.robinhood.com';
const check=(ok,msg)=>{if(!ok)throw Error(msg);};
function batch(calls){
 const input=calls.map(([method,params],id)=>({jsonrpc:'2.0',id,method,params}));
 const rows=JSON.parse(execFileSync('curl',['--fail-with-body','-sS','--max-time','40',rpc,'-H','Content-Type: application/json','--data-binary','@-'],{input:JSON.stringify(input),maxBuffer:4e6}));
 return input.map(({id})=>{const r=rows.find(r=>r.id===id);check(r&&!r.error,JSON.stringify(r));return r.result;});
}
const router=getAddress(original.transactions[0].contractAddress);
const deployer=getAddress(original.transactions[0].transaction.from);
const [chain,block,nonce,pending,code]=batch([['eth_chainId',[]],['eth_blockNumber',[]],['eth_getTransactionCount',[deployer,'latest']],['eth_getTransactionCount',[deployer,'pending']],['eth_getCode',[router,'latest']]]);
check(BigInt(chain)===4663n,'wrong chain');check(nonce===pending,'pending transactions exist');check(BigInt(nonce)===332n,'deployer nonce changed; re-audit recovery');check(code!=='0x','router missing');
function read(fn,args=[]){return ['eth_call',[{to:router,data:encodeFunctionData({abi,functionName:fn,args})},block]];}
const [owner]=batch([read('owner')]);check(decodeFunctionResult({abi,functionName:'owner',data:owner})===deployer,'wrong owner');
const poolTx=original.transactions.filter(t=>t.function==='addPricePool(uint8,bytes)');
const routeTx=original.transactions.filter(t=>t.function==='addRoute(address,address,bytes32[])');
const routes=routeTx.map(t=>{const {args}=decodeFunctionData({abi,data:t.transaction.input});return {tokenIn:args[0],tokenOut:args[1],poolIds:args[2]};});
// Source pool IDs are the first references of each stock route plus the hub.
const ids=[...new Set(routes.flatMap(r=>r.poolIds))];
const poolsBySource=new Map();
for(let i=0;i<ids.length;i+=24){const chunk=ids.slice(i,i+24);const responses=batch(chunk.map(id=>read('pricePool',[id])));responses.forEach((data,j)=>{const [enabled,,token0,token1,sourceType,sourceData]=decodeFunctionResult({abi,functionName:'pricePool',data});check(enabled,'missing already-confirmed pool');poolsBySource.set(sourceData.toLowerCase(),{token0,token1,sourceType,sourceData});});}
const pools=poolTx.map(t=>{const {args}=decodeFunctionData({abi,data:t.transaction.input});const p=poolsBySource.get(args[1].toLowerCase());check(p&&p.sourceType===args[0],'pool source differs from broadcast');return p;});
const routeState=[];
for(let i=0;i<routes.length;i+=24){const chunk=routes.slice(i,i+24);const responses=batch(chunk.map(r=>read('hasRoute',[r.tokenIn,r.tokenOut])));responses.forEach((data,j)=>routeState.push(decodeFunctionResult({abi,functionName:'hasRoute',data})));}
const checks=[];
routes.forEach((r,i)=>{if(routeState[i]){checks.push({fn:'routePoolCount',args:[r.tokenIn,r.tokenOut],expected:BigInt(r.poolIds.length)});r.poolIds.forEach((id,j)=>checks.push({fn:'routePoolAt',args:[r.tokenIn,r.tokenOut,BigInt(j)],expected:id}));}});
for(let i=0;i<checks.length;i+=24){const chunk=checks.slice(i,i+24);const responses=batch(chunk.map(c=>read(c.fn,c.args)));responses.forEach((data,j)=>check(decodeFunctionResult({abi,functionName:chunk[j].fn,data})===chunk[j].expected,'existing route differs from broadcast'));}
const remainingAddresses=original.transactions.filter(t=>t.transactionType==='CREATE'||t.transactionType==='CREATE2').slice(1).map(t=>t.contractAddress);
const codes=batch(remainingAddresses.map(a=>['eth_getCode',[a,block]]));check(codes.every(c=>c==='0x'),'a downstream contract is already deployed');
const types=parseAbiParameters('(address token0,address token1,uint8 sourceType,bytes sourceData)[],(address tokenIn,address tokenOut,bytes32[] poolIds)[]');
const configHash=keccak256(encodeAbiParameters(types,[pools,routes]));
const report={chainId:4663,router,deployer,expectedNonce:332,routerCodeHash:keccak256(code),configHash,auditedBlock:parseInt(block,16),confirmedTransactions:original.receipts.length,configuredPools:pools.length,configuredRoutes:routeState.filter(Boolean).length,missingRoutes:routes.filter((_,i)=>!routeState[i]),originalBroadcast:'original-broadcast.json',checkedAt:new Date().toISOString()};
fs.writeFileSync(`${dir}/plan.json`,JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify({router,nonce:report.expectedNonce,pools:report.configuredPools,routes:report.configuredRoutes,missingRoutes:report.missingRoutes.length,configHash},null,2));
