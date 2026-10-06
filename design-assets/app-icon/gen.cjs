// Writes light.svg, dark.svg and tinted.svg: the 3D thought-bubble app icon. Run: node gen.cjs
const fs=require('fs');
const SW=3,R='stroke-linecap="round" stroke-linejoin="round"';
const f2=n=>+n.toFixed(2),rad=x=>x*Math.PI/180;
const YAW=24,FOCAL=60,DEPTH=20,FIT=70;

// Bubble outline in face coords: body 5..29 x 7..34, corner radius 4, tail tip at (8.5,38).
function bubblePoly(){
 const x0=5,x1=29,y0=7,y1=34,r=4,tl=9,tr=14,tx=8.5,ty=38,pts=[];
 const arc=(cx,cy,a0,a1)=>{for(let i=0;i<=8;i++){const t=rad(a0+(a1-a0)*i/8);pts.push([cx+r*Math.cos(t),cy+r*Math.sin(t)]);}};
 arc(x1-r,y0+r,-90,0);arc(x1-r,y1-r,0,90);pts.push([tr,y1],[tx,ty],[tl,y1]);
 arc(x0+r,y1-r,90,180);arc(x0+r,y0+r,180,270);
 return pts.filter((p,i)=>i===0||Math.hypot(p[0]-pts[i-1][0],p[1]-pts[i-1][1])>1e-6);
}

// Turn the face YAW degrees about the vertical axis through (17,23), viewed by a perspective camera.
const P=([x,y],z=0)=>{const c=Math.cos(rad(YAW)),s=Math.sin(rad(YAW)),X=x-17,Y=y-23,
 xr=X*c+z*s,zr=-X*s+z*c,k=FOCAL/(FOCAL+zr);return {x:xr*k,y:Y*k};};
const pathOf=(ps,close)=>'M'+ps.map(p=>`${f2(p.x)} ${f2(p.y)}`).join('L')+(close?'Z':'');

function icon({bg,face,ink}){
 const poly=bubblePoly(),front=poly.map(p=>P(p)),back=poly.map(p=>P(p,DEPTH));
 // one subpath per polygon, all wound the same way so the nonzero fill is their union
 const area=q=>q.reduce((s,p,i)=>{const n=q[(i+1)%q.length];return s+p.x*n.y-n.x*p.y;},0);
 const wound=q=>area(q)<0?[...q].reverse():q;
 const sides=[back,...poly.map((_,i)=>{const j=(i+1)%poly.length;
  return [front[i],front[j],back[j],back[i]];})].map(q=>pathOf(wound(q),true)).join('');
 const loop=[];for(let i=0;i<=40;i++){const t=rad(-50+275*i/40);loop.push(P([17+5.4*Math.cos(t),19+5.4*Math.sin(t)]));}
 const te=rad(225),ex=17+5.4*Math.cos(te),ey=19+5.4*Math.sin(te),tdx=-Math.sin(te),tdy=Math.cos(te),nx=Math.cos(te),ny=Math.sin(te);
 const head=[[ex+nx*3.2,ey+ny*3.2],[ex+tdx*3.8,ey+tdy*3.8],[ex-nx*3.2,ey-ny*3.2]].map(p=>P(p));
 const all=[...front,...back],xs=all.map(p=>p.x),ys=all.map(p=>p.y),pad=SW/2;
 const X0=Math.min(...xs)-pad,X1=Math.max(...xs)+pad,Y0=Math.min(...ys)-pad,Y1=Math.max(...ys)+pad,sc=FIT/Math.max(X1-X0,Y1-Y0);
 return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="1024" height="1024"><rect width="100" height="100" fill="${bg}"/><g transform="translate(50 50) scale(${f2(sc)}) translate(${f2(-(X0+X1)/2)} ${f2(-(Y0+Y1)/2)})">`
  +`<path d="${sides}" fill="${ink}" stroke="${ink}" stroke-width="${SW}" ${R}/>`
  +`<path d="${pathOf(front,true)}" fill="${face}" stroke="${ink}" stroke-width="${SW}" ${R}/>`
  +`<path d="${pathOf(loop)}" fill="none" stroke="${ink}" stroke-width="3.2" ${R}/>`
  +`<path d="${pathOf(head,true)}" fill="${ink}" stroke="${ink}" stroke-width="1.2" stroke-linejoin="round"/>`
  +`<path d="${pathOf([P([11,29]),P([23,29])])}" fill="none" stroke="${ink}" stroke-width="${SW}" ${R}/>`
  +`</g></svg>`;
}

const PALETTES={
 light:{bg:'#FFFFFF',face:'#FFFFFF',ink:'#15171C'},
 dark:{bg:'#0E0F13',face:'#1A1C22',ink:'#E9EBF2'},
 tinted:{bg:'#000000',face:'#262626',ink:'#FFFFFF'}};
for(const [m,p] of Object.entries(PALETTES))fs.writeFileSync(`${__dirname}/${m}.svg`,icon(p));
