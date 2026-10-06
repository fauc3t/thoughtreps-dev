const fs=require('fs');
const SW=3,R='stroke-linecap="round" stroke-linejoin="round"';
const s=(c,w)=>`stroke="${c}" stroke-width="${w||SW}" ${R}`;
const f2=n=>+n.toFixed(2);
function arrow(cx,cy,r,a0,a1,col,w,h,hw){const P=d=>{const t=d*Math.PI/180;return[f2(cx+r*Math.cos(t)),f2(cy+r*Math.sin(t))]};
 const s0=P(a0),e=P(a1),t=a1*Math.PI/180,tx=-Math.sin(t),ty=Math.cos(t),nx=Math.cos(t),ny=Math.sin(t);
 const tip=[f2(e[0]+tx*h),f2(e[1]+ty*h)],b1=[f2(e[0]+nx*hw),f2(e[1]+ny*hw)],b2=[f2(e[0]-nx*hw),f2(e[1]-ny*hw)];
 return `<path d="M${s0}A${r} ${r} 0 ${a1-a0>180?1:0} 1 ${e}" fill="none" stroke="${col}" stroke-width="${w}" stroke-linecap="round"/><path d="M${b1}L${tip}L${b2}Z" fill="${col}" stroke="${col}" stroke-width="1.2" stroke-linejoin="round"/>`;}
const draw=p=>`<rect x="9" y="4" width="22" height="24" rx="4" transform="rotate(9 20 16)" fill="${p.note2}" ${s(p.ink)}/><rect x="5" y="9" width="24" height="25" rx="4" fill="${p.note}" ${s(p.ink)}/>`+arrow(17,19,5.4,-50,225,p.ink,3.2,3.8,3.2)+`<path d="M11 29h12" fill="none" ${s(p.ink)}/>`;
const P={
 light:{bg:'#FFFFFF',note:'#FFFFFF',note2:'#E3E5EA',ink:'#15171C'},
 dark:{bg:'#0E0F13',note:'#1A1C22',note2:'#2E313A',ink:'#E9EBF2'},
 tinted:{bg:'#000000',note:'#262626',note2:'#4A4A4A',ink:'#FFFFFF'}};
for(const [m,p] of Object.entries(P)){
 const svg=`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="1024" height="1024"><rect width="100" height="100" fill="${p.bg}"/><g transform="translate(50 50) scale(2.02) translate(-19.3 -19)">${draw(p)}</g></svg>`;
 fs.writeFileSync(m+'.svg',svg);
 fs.writeFileSync(m+'.html',`<!doctype html><style>html,body{margin:0;background:${p.bg}}svg{display:block}</style>${svg}`);
}
