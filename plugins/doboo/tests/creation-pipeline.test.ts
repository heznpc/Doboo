import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { deflateSync } from 'node:zlib';
import { characterReference } from '../src/character-library.js';
import { createCreationPipeline } from '../src/creation-pipeline.js';
import { crc32 } from '../../../character-kit/png.mjs';
import { serializeCharacter } from '../../../character-kit/model.mjs';
const seed=JSON.parse(await readFile(new URL('../../../Characters/doboo.doboo.json',import.meta.url),'utf8'));
const hash=(x:Buffer|string)=>createHash('sha256').update(x).digest('hex');
function emptyV2(){
  const chunk=(name:string,data:Buffer)=>{const n=Buffer.from(name),h=Buffer.alloc(4),c=Buffer.alloc(4);h.writeUInt32BE(data.length);c.writeUInt32BE(crc32(Buffer.concat([n,data])));return Buffer.concat([h,n,data,c]);};
  const h=Buffer.alloc(13);h.writeUInt32BE(1536);h.writeUInt32BE(2288,4);h[8]=8;h[9]=6;
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',h),chunk('IDAT',deflateSync(Buffer.alloc(2288*(1536*4+1)))),chunk('IEND',Buffer.alloc(0))]);
}
// Fixtures isolate lifecycle mechanics. They are NOT production quality reports or real host proof.
async function fixture(root:string,version=1,activate=false){
  const id=randomUUID(),path=join(root,'creation',id),atlas=emptyV2();await mkdir(join(path,'final'),{recursive:true});
  const pack={...structuredClone(seed),version,appearance:{renderer:'spritesheet',tint:'#FF8F62',sprite:{layout:'pets-v2',mimeType:'image/png',base64:atlas.toString('base64')},watch:{renderer:'native-doboo',tint:'#FF8F62'}}};
  const bytes=serializeCharacter(pack);
  await writeFile(join(path,'final','spritesheet-extended.png'),atlas);await writeFile(join(path,'character.doboo.json'),bytes);
  await writeFile(join(path,'imagegen-jobs.json'),JSON.stringify({jobs:[]}));
  await writeFile(join(path,'run.json'),JSON.stringify({id,character:pack,brief:'fixture only',style:'clay',skillDirectory:'unused',phase:'validated',reviews:{},artifacts:{},stages:[],validatedPack:pack,atlasSHA256:hash(atlas),packSHA256:hash(bytes),pets:{step:'inspect',activate}}));
  return {id,path,pack,bytes,atlas,activate};
}
async function harness(fn:(root:string,p:ReturnType<typeof createCreationPipeline>)=>Promise<void>){const root=await mkdtemp(join(tmpdir(),'doboo-creation-'));try{await fn(root,createCreationPipeline(root));}finally{await rm(root,{recursive:true,force:true});}}
async function accept(p:ReturnType<typeof createCreationPipeline>,id:string,body:any){const action:any=await p.nextPetAction(id);await p.recordPetResponse(id,action.id,{structuredContent:body});return action;}
async function published(p:ReturnType<typeof createCreationPipeline>,f:Awaited<ReturnType<typeof fixture>>){
  await accept(p,f.id,{pets:[],active_pet_id:'previous-pet'});
  await accept(p,f.id,{valid:true,sprite_version:2});await accept(p,f.id,{upload:{upload_session_id:'fixture-session'}});
  const action=await accept(p,f.id,{pet:{id:'fixture-stable-pet',is_custom:true,name:f.pack.name,description:f.pack.description}});
  const active=f.activate?'fixture-stable-pet':'previous-pet';
  if(f.activate)assert.equal((await accept(p,f.id,{active_pet_id:active})).tool,'select_pet');
  else assert.equal((await p.nextPetAction(f.id) as any).tool,'list_pets');
  await accept(p,f.id,{pets:[],cursor:'page-two',active_pet_id:active});
  const next:any=await p.nextPetAction(f.id);assert.equal(next.arguments.cursor,'page-two');
  await accept(p,f.id,{pets:[{id:'fixture-stable-pet',is_custom:true,name:f.pack.name,description:f.pack.description}],cursor:null,active_pet_id:active});
  await accept(p,f.id,{pet_id:'fixture-stable-pet',spritesheet_url:'https://example.invalid/fixture.png'});
  await p.verifyPetDownload(f.id,join(f.path,'final','spritesheet-extended.png'));return action;
}
test('lifecycle updates the same stable pet and refuses stale Watch receipt',()=>harness(async(root,p)=>{
  const one=await fixture(root);assert.equal((await published(p,one)).tool,'create_pet');
  assert.equal((await p.status(one.id)).deliveryConfirmed,false);
  const two=await fixture(root,2);const action=await published(p,two);assert.equal(action.tool,'update_pet');assert.equal(action.arguments.pet_id,'fixture-stable-pet');
  const receipt=join(root,'receipt.json');const data={characterID:two.pack.id,version:1,sha256:hash(two.bytes),definitionSHA256:characterReference(two.pack as any).digest,result:'imported',selected:true};await writeFile(receipt,JSON.stringify(data));
  await assert.rejects(()=>p.recordWatchReceipt(two.id,receipt),/exact revision/);
  data.version=2;data.selected=false;await writeFile(receipt,JSON.stringify(data));await assert.rejects(()=>p.recordWatchReceipt(two.id,receipt));
  data.selected=true;await writeFile(receipt,JSON.stringify(data));const result=await p.recordWatchReceipt(two.id,receipt);assert.equal(result.deliveryConfirmed,true);assert.match(result.watch!.confirmation,/host-reported/);
}));
test('unknown outcomes reuse the action and session; error receipts do not advance',()=>harness(async(root,p)=>{
  const f=await fixture(root);await accept(p,f.id,{pets:[],active_pet_id:'previous-pet'});const first:any=await p.nextPetAction(f.id);assert.deepEqual(await p.nextPetAction(f.id),first);
  await assert.rejects(()=>p.recordPetResponse(f.id,randomUUID(),{valid:true,sprite_version:2}),/mismatched/);
  await assert.rejects(()=>p.recordPetResponse(f.id,first.id,{isError:true}),/failed/);
  assert.equal((await p.status(f.id)).pets.step,'validate');
  await accept(p,f.id,{valid:true,sprite_version:2});await accept(p,f.id,{upload:{upload_session_id:'same-session'}});
  const publish:any=await p.nextPetAction(f.id);assert.deepEqual(await p.nextPetAction(f.id),publish);assert.equal(publish.arguments.upload_session_id,'same-session');
  await assert.rejects(()=>p.recordPetResponse(f.id,publish.id,{pet:{id:'built-in',is_custom:false}}));
}));
test('changed encoded bytes cannot advance an already validated run',()=>harness(async(root,p)=>{
  const f=await fixture(root);await writeFile(join(f.path,'final','spritesheet-extended.png'),'tampered');await assert.rejects(()=>p.nextPetAction(f.id),/bytes changed/);
}));
test('v1 preflight and missing quality gates cannot become v2 publication',()=>harness(async(root,p)=>{
  const f=await fixture(root);await accept(p,f.id,{pets:[],active_pet_id:'previous-pet'});const action:any=await p.nextPetAction(f.id);await assert.rejects(()=>p.recordPetResponse(f.id,action.id,{valid:true,sprite_version:1}),/v2/);
  const path=join(f.path,'run.json');const r=JSON.parse(await readFile(path,'utf8'));delete r.atlasSHA256;await writeFile(path,JSON.stringify(r));await assert.rejects(()=>p.nextPetAction(f.id),/quality gates/);
}));

test('two creation runs cannot create duplicate pets while the first outcome is unknown',()=>harness(async(root,p)=>{
  const first=await fixture(root),second=await fixture(root,2);
  for(const f of [first,second]){await accept(p,f.id,{pets:[],active_pet_id:'previous-pet'});await accept(p,f.id,{valid:true,sprite_version:2});await accept(p,f.id,{upload:{upload_session_id:'fixture-'+f.id}});}
  const pending:any=await p.nextPetAction(first.id);assert.equal(pending.tool,'create_pet');
  await assert.rejects(()=>p.nextPetAction(second.id),/Another publication is pending/);
  assert.deepEqual(await p.nextPetAction(first.id),pending);
}));

test('activation happens only when requested',()=>harness(async(root,p)=>{
  const f=await fixture(root,1,true);await published(p,f);
  assert.equal((await p.status(f.id)).pets.activate,true);
}));

test('publication detects a changed active selection without silently restoring it',()=>harness(async(root,p)=>{
  const f=await fixture(root);
  await accept(p,f.id,{pets:[],active_pet_id:'previous-pet'});
  await accept(p,f.id,{valid:true,sprite_version:2});await accept(p,f.id,{upload:{upload_session_id:'fixture-session'}});
  await accept(p,f.id,{pet:{id:'fixture-stable-pet',is_custom:true,name:f.pack.name,description:f.pack.description}});
  const action:any=await p.nextPetAction(f.id);assert.equal(action.tool,'list_pets');
  await assert.rejects(()=>p.recordPetResponse(f.id,action.id,{pets:[{id:'fixture-stable-pet',is_custom:true,name:f.pack.name,description:f.pack.description}],active_pet_id:'changed-elsewhere'}),/Active Pet changed/);
  assert.deepEqual(await p.nextPetAction(f.id),action);
}));

test('invalid reference inputs fail before creating a partial production run',()=>harness(async(root,p)=>{
  await assert.rejects(()=>p.prepare(seed,'Valid identity brief','clay',Array(6).fill('/missing.png')),/At most five/);
  await assert.rejects(()=>readFile(join(root,'creation')),/ENOENT/);
  await assert.rejects(()=>p.prepare(seed,'Valid identity brief','clay',[join(root,'missing.png')]),/ENOENT/);
}));

test('repair invalidates old direction verdicts even when replacement artwork fails',()=>harness(async(root,p)=>{
  const f=await fixture(root);
  const run=JSON.parse(await readFile(join(f.path,'run.json'),'utf8'));
  Object.assign(run,{phase:'artwork',reviews:{base:'Approved fixture',idle:'Approved fixture'},artifacts:{base:'old',idle:'old'},stages:['standard-rows','cardinals','look-row-9','assemble-v2']});
  await writeFile(join(f.path,'run.json'),JSON.stringify(run));
  await writeFile(join(f.path,'imagegen-jobs.json'),JSON.stringify({jobs:[{id:'base',depends_on:[],prompt_file:'prompt.md',input_images:[],output_path:'base.png'},{id:'idle',depends_on:['base'],prompt_file:'prompt.md',input_images:[],output_path:'idle.png'}]}));
  await writeFile(join(f.path,'prompt.md'),'fixture prompt');
  await mkdir(join(f.path,'qa'));
  for(const name of ['direction-semantics.json','pet-quality.json'])await writeFile(join(f.path,'qa',name),'old verdict');
  const bad=join(f.path,'invalid.png');await writeFile(bad,'not PNG');
  await assert.rejects(()=>p.supplyArtwork(f.id,'base',bad,'The replacement needs new visual inspection.'),/encoded PNG/);
  for(const name of ['direction-semantics.json','pet-quality.json'])await assert.rejects(()=>readFile(join(f.path,'qa',name)),/ENOENT/);
  const status=await p.status(f.id);assert.deepEqual(status.reviewedJobs,[]);assert.deepEqual(status.stages,[]);
}));

test('source art is decoded and snapshotted; edits retain original runs and reference roles',()=>harness(async(root)=>{
  const skill=join(root,'fixture-skill');await mkdir(join(skill,'scripts'),{recursive:true});
  await writeFile(join(skill,'scripts','prepare_pet_run.py'),`import sys,json,pathlib
p=pathlib.Path(sys.argv[sys.argv.index('--output-dir')+1]); (p/'references').mkdir(); (p/'decoded').mkdir()
(p/'prompt.md').write_text('fixture-only visual request')
(p/'imagegen-jobs.json').write_text(json.dumps({'jobs':[{'id':'base','depends_on':[],'prompt_file':'prompt.md','input_images':[],'output_path':'decoded/base.png'},{'id':'look-row-10','depends_on':['base'],'prompt_file':'prompt.md','input_images':[{'path':str(i)+'.png','role':'derived continuity reference'} for i in range(4)],'output_path':'decoded/look10.png'}]}))
`);
  const p=createCreationPipeline(root,{...process.env,DOBOO_PETS_SKILL_DIR:skill});
  const source=join(root,'user-drawing.wrong-extension'),bytes=emptyV2();await writeFile(source,bytes);
  const first=await p.prepare(seed,'Preserve the round shape; change the clay texture.','clay',[source]);
  assert.equal(first.sourceImages[0].mimeType,'image/png');assert.equal(first.sourceImages[0].sha256,hash(bytes));
  await writeFile(source,'user edited their source file after import');
  assert.deepEqual(await readFile(first.readyJobs[0].input_images[0].path),bytes);
  const art=join(root,'fixture-art.png');await writeFile(art,bytes);
  await p.supplyArtwork(first.runId,'base',art,'Fixture lifecycle test only, not actual visual approval.');
  const edit=await p.revise(first.runId,seed,'Change only the mouth; keep the peach color and oval eyes.');
  assert.equal(edit.parentRunId,first.runId);
  assert.deepEqual(edit.sourceImages.map(s=>s.role),['identity-reference','edit-target']);
  assert.match(edit.readyJobs[0].input_images.at(-1).role,/edit target/);
  assert.deepEqual((await p.status(first.runId)).reviewedJobs,['base']);
  assert.deepEqual(edit.reviewedJobs,[]);
  const jobs=JSON.parse(await readFile(join(edit.runDirectory,'imagegen-jobs.json'),'utf8'));
  assert.ok(jobs.jobs.every((job:any)=>job.input_images.length<=5));
  assert.equal(jobs.jobs[1].input_images.at(-1).path,'references/source-board.png');
  assert.ok((await readFile(join(edit.runDirectory,'references/source-board.png'))).length>0);
  const five=await p.prepare(seed,'Five identity references.','clay',Array(5).fill(art));
  await p.supplyArtwork(five.runId,'base',art,'Fixture base used only to exercise retained source-image capacity.');
  const six=await p.revise(five.runId,seed,'Edit while retaining all five references.');
  assert.equal(six.sourceImages.length,6);
  assert.equal(six.sourceImages.filter(s=>s.role==='edit-target').length,1);
  assert.ok(six.readyJobs.every((job:any)=>job.input_images.length<=5));
  await assert.rejects(()=>p.revise(first.runId,{...seed,id:'different-character'},'change'),/preserve the character ID/);
  const bad=join(root,'fake.png');await writeFile(bad,Buffer.concat([bytes.subarray(0,8),Buffer.from('broken')]));
  await assert.rejects(()=>p.prepare(seed,'fixture','clay',[bad]),/corrupt/);
  await writeFile(bad,'not image bytes');await assert.rejects(()=>p.prepare(seed,'fixture','clay',[bad]),/PNG, JPEG, or WebP/);
}));

test('nonvisual revision reuses verified art but requires real update and clears Watch receipts',()=>harness(async(root,p)=>{
  const one=await fixture(root);await published(p,one);
  const pack={...one.pack,version:2,description:'An edited description with the same appearance.'};
  const next=await p.reviseDetails(one.id,pack);
  assert.equal(next.parentRunId,one.id);assert.equal(next.phase,'validated');assert.equal(next.pets.step,'inspect');assert.equal(next.watch,null);
  assert.deepEqual(await readFile(join(next.runDirectory,'final','spritesheet-extended.png')),one.atlas);
  await accept(p,next.runId,{pets:[],active_pet_id:'previous-pet'});
  const action:any=await p.nextPetAction(next.runId);assert.equal(action.tool,'update_pet');assert.equal(action.arguments.pet_id,'fixture-stable-pet');assert.equal(action.arguments.updates.description,pack.description);assert.equal(action.arguments.updates.upload_session_id,undefined);
  await p.recordPetResponse(next.runId,action.id,{pet:{id:'fixture-stable-pet',is_custom:true,name:pack.name,description:pack.description}});
  await accept(p,next.runId,{pets:[{id:'fixture-stable-pet',is_custom:true,name:pack.name,description:pack.description}],active_pet_id:'previous-pet'});
  assert.equal((await p.status(next.runId)).phase,'published');
  await assert.rejects(()=>p.reviseDetails(one.id,{...pack,appearance:{...pack.appearance,tint:'#111111'}}),/Appearance changed/);
  await assert.rejects(()=>p.reviseDetails(one.id,one.pack),/higher version/);
}));

test('motion revision retains unchanged source art but cannot inherit publication approval',()=>harness(async(root,p)=>{
  const one=await fixture(root);await published(p,one);
  for(const entry of ['decoded','references','prompts','qa'])await mkdir(join(one.path,entry));
  await writeFile(join(one.path,'decoded','idle.png'),one.atlas);
  await writeFile(join(one.path,'prompts','waving.md'),'Fixture waving request.');
  await writeFile(join(one.path,'pet_request.json'),'{}');
  await writeFile(join(one.path,'qa','pet-quality.json'),'old approval');
  await writeFile(join(one.path,'imagegen-jobs.json'),JSON.stringify({jobs:[{id:'waving',depends_on:['base'],prompt_file:'prompts/waving.md',input_images:[],output_path:'decoded/waving.png'}]}));
  const path=join(one.path,'run.json'),run=JSON.parse(await readFile(path,'utf8'));
  run.reviews={base:'Original base',idle:'Original idle',waving:'Original waving'};run.artifacts={idle:hash(one.atlas),waving:'old'};
  await writeFile(path,JSON.stringify(run));
  await assert.rejects(()=>p.reviseMotion(one.id,1,'waving','Raise both arms.'),/higher version/);
  await assert.rejects(()=>p.reviseMotion(one.id,2,'look-row-9','change'),/full customization/);
  const next=await p.reviseMotion(one.id,2,'waving','Raise both arms.');
  assert.equal(next.parentRunId,one.id);assert.equal(next.phase,'artwork');assert.equal(next.pets.step,'inspect');
  assert.deepEqual(next.reviewedJobs,['base','idle']);assert.deepEqual(next.stages,[]);
  assert.equal(next.readyJobs[0].id,'waving');assert.match(next.readyJobs[0].prompt,/Raise both arms/);
  assert.deepEqual(await readFile(join(next.runDirectory,'decoded','idle.png')),one.atlas);
  await assert.rejects(()=>readFile(join(next.runDirectory,'qa','pet-quality.json')),/ENOENT/);
  await assert.rejects(()=>p.nextPetAction(next.runId),/quality gates/);
  assert.equal((await p.status(one.id)).phase,'published');
}));

test('metadata-only publication rejects an old appearance after a newer visual revision',()=>harness(async(root,p)=>{
  const one=await fixture(root);await published(p,one);
  const next=await p.reviseDetails(one.id,{...one.pack,version:3,description:'Requested metadata change.'});
  // Model a newer visual publication while this details revision was pending.
  const path=join(root,'creation','bindings',one.pack.id+'.json');
  const binding=JSON.parse(await readFile(path,'utf8'));binding.version=2;binding.atlasSHA256='different-current-artwork';
  await writeFile(path,JSON.stringify(binding));
  await accept(p,next.runId,{pets:[],active_pet_id:'previous-pet'});
  await assert.rejects(()=>p.nextPetAction(next.runId),/current Pet artwork differs/);
  assert.equal((await p.status(next.runId)).pets.step,'publish');
}));
