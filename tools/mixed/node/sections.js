const fs=require('fs');const b=fs.readFileSync(process.argv[2]);let i=8;const names={0:'custom',1:'type',2:'import',3:'function',4:'table',5:'memory',6:'global',7:'export',8:'start',9:'elem',10:'code',11:'data',12:'datacount'};
function uleb(){let r=0,s=0,x;do{x=b[i++];r+=(x&0x7f)*2**s;s+=7}while(x&0x80);return r}
const out=[];while(i<b.length){const id=b[i++];const sz=uleb();let nm=names[id];if(id===0){const j=i;const n=uleb();nm='custom:'+b.slice(i,i+n).toString();i=j}out.push(nm+' '+(sz/1048576).toFixed(2)+'MB');i+=sz}console.log(out.join(' | '))
