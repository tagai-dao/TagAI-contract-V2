const fs=require('node:fs');
const path=require('node:path');
const cp=require('node:child_process');
const dotenv=require(require.resolve('dotenv',{paths:[process.cwd(),path.resolve('../tagai-api')]}));
const env={...dotenv.parse(fs.readFileSync('.env')),...process.env};
const pre=JSON.parse(fs.readFileSync('deployments/56/version18-deployment-preflight.json'));
const mode=process.argv[2];
if(!['fork','dry','broadcast'].includes(mode))throw Error('Expected fork, dry or broadcast');
let args;
if(mode==='fork'){
 Object.assign(env,{FOUNDRY_PROFILE:'fork',PUMP18_FORK_BLOCK:String(pre.blockNumber),FOUNDRY_ETH_RPC_URL:''});
 args=['test','--offline','--match-contract','Pump18DeploymentForkTest','-vv'];
}else{
 Object.assign(env,{FOUNDRY_PROFILE:'bsc_mainnet',PUMP18_OWNER:pre.targetOwner});
 args=['script','script/DeployBSCPump18.s.sol:DeployBSCPump18Script','--offline','--rpc-url',env.BSC_RPC_URL,'--sender',pre.deployer,'--slow','--with-gas-price',pre.gasPriceWei];
 if(mode==='broadcast'){
  if(fs.existsSync('deployments/56/version18.json'))throw Error('V18 record already exists; reconcile before broadcasting');
  args.push('--broadcast');
 }
}
const log=`/tmp/tiptag-v18-${mode}.log`;
const fd=fs.openSync(log,'w');
const child=cp.spawn('forge',args,{env,stdio:['ignore',fd,fd]});
child.on('error',()=>{fs.closeSync(fd);console.error('Forge launch failed; credentials suppressed');process.exitCode=1;});
child.on('exit',code=>{fs.closeSync(fd);console.log(JSON.stringify({mode,exitCode:code,log}));process.exitCode=code||0;});
