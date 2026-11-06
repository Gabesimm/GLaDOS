import {chromium} from 'file:///<ULTRON_ROOT>/node/node_modules/openclaw/node_modules/playwright-core/index.mjs';
import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import vm from 'node:vm';
import {fileURLToPath} from 'node:url';
const root=path.dirname(fileURLToPath(import.meta.url));
let route;
const backend=await fs.readFile(path.join(root,'index.js'),'utf8');
const backendBody=backend.replace(/^import .*;$/gm,'').replace('const __dirname = path.dirname(fileURLToPath(import.meta.url));','const __dirname = pluginDir;').replace('export default defineFeaturePlugin','const plugin = defineFeaturePlugin');
vm.runInNewContext(backendBody+';plugin.setup(api);',{fs:await import('node:fs'),path,pluginDir:root,URL,defineFeaturePlugin:x=>x,defineFeatureContract:x=>x,api:{registerHttpRoute:r=>{route=r}}});
const errors=[],responses=[];
const server=http.createServer(async(req,res)=>{try{
if(req.url.startsWith('/glados-3d-scene/models/')){await route.handler(req,res);return}
if(req.url==='/favicon.ico'){res.writeHead(204);res.end();return}
if(req.url==='/'){res.setHeader('Content-Type','text/html');res.end('<html><body style="margin:0"><div id="app" style="height:100vh"></div></body></html>');return}
const p=req.url.split('?')[0];let data=await fs.readFile(path.join(root,p));
if(p==='/dist/control-ui/index.js')data=Buffer.from(data.toString().replace('  const clock = new THREE.Clock();','  window.__sceneTest = { scene, camera, renderer, rig, coreMeshes, controls };\n  const clock = new THREE.Clock();'));
res.setHeader('Content-Type',p.endsWith('.js')?'text/javascript':'application/octet-stream');res.end(data);
}catch(e){res.writeHead(404);res.end('not found')}}).listen(0,'127.0.0.1');
await new Promise(resolve=>server.listening ? resolve() : server.once('listening',resolve));
let browser;
try{
const origin='http://127.0.0.1:'+server.address().port;
browser=await chromium.launch({executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
const page=await browser.newPage({viewport:{width:1440,height:900}});
page.on('pageerror',e=>errors.push(e.message));page.on('console',m=>{if(m.type()==='error')errors.push(m.text())});
page.on('response',r=>{if(r.url().includes('.glb'))responses.push({file:r.url().split('/').pop(),status:r.status(),type:r.headers()['content-type']})});
await page.goto(origin);
await page.evaluate(async()=>{const {default:plugin}=await import('/dist/control-ui/index.js');plugin.activate({ui:{registerReplacement:(_,def)=>{window.mount=def.mount;return()=>{}}}});window.handle=await window.mount(document.querySelector('#app'),{mountDefault(panel){panel.textContent='Built-in chat panel';panel.style.color='#ccc';return{dispose(){}}}})});
await page.waitForFunction(()=>window.__sceneTest?.scene.getObjectByName('Packed chamber room')&&Object.keys(window.__sceneTest.coreMeshes).length===5,{},{timeout:120000});
const before=await page.evaluate(()=>window.__sceneTest.rig.Head0_JNT.obj.quaternion.toArray());
await page.getByRole('button',{name:'talking',exact:true}).click();
await page.waitForTimeout(1000);
await page.getByRole('button',{name:'variant2',exact:true}).click();
const stats=await page.evaluate(()=>{
const t=window.__sceneTest;const room=t.scene.getObjectByName('Packed chamber room');let meshes=0,textured=0;room.traverse(o=>{if(o.isMesh){meshes++;if(o.material.map)textured++}});
return{meshes,textured,roomPosition:room.position.toArray(),roomScale:room.scale.x,headQuaternion:t.rig.Head0_JNT.obj.quaternion.toArray(),selectedCore:Object.entries(t.coreMeshes).filter(([n,o])=>o.visible).map(([n])=>n),render:t.renderer.info.render,memory:t.renderer.info.memory,camera:t.camera.position.toArray()};
});
await page.screenshot({path:path.join(root,'room-runtime.png')});
await page.getByRole('button',{name:'idle',exact:true}).click();
const denied=await fetch(origin+'/glados-3d-scene/models/not-allowed.glb');
if(denied.status!==404)throw Error('Allowlist failed');
if(before.every((n,i)=>n===stats.headQuaternion[i]))throw Error('Bone animation did not advance');
if(stats.selectedCore.join()!=='variant2')throw Error('Core switching failed');
if(errors.length)throw Error(errors.join('\n'));
if(responses.length!==7||responses.some(r=>r.status!==200||r.type!=='model/gltf-binary'))throw Error('Asset delivery failed');
await page.evaluate(()=>window.handle.dispose());
const result={pass:true,routeAuth:route.auth,allowlist404:denied.status,responses,stats,boneAnimationAdvanced:true,coreSwitchPassed:true,errors};
await fs.writeFile(path.join(root,'room-verification.json'),JSON.stringify(result,null,2));
console.log(JSON.stringify(result,null,2));
}finally{await browser?.close();server.close()}
