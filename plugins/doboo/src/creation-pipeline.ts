import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash, randomUUID } from 'node:crypto';
import { readFile, writeFile, mkdir, readdir, copyFile, access, open, unlink, cp } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { validateCharacter, serializeCharacter } from '../../../character-kit/model.mjs';
import { createCharacterLibrary, characterReference, characterFiles, type CharacterPack } from './character-library.js';

const exec = promisify(execFile);
const hash = (bytes: Buffer | string) => createHash('sha256').update(bytes).digest('hex');
const json = async (path: string) => JSON.parse(await readFile(path, 'utf8'));
const idPattern = /^[a-z0-9-]{1,64}$/;
const stages = ['standard-rows','cardinals','look-row-9','assemble-v2','validate-v2'] as const;
export type ProductionStage = typeof stages[number];
type Action = { id: string; tool: string; arguments: Record<string, unknown> };
type SourceImage = {path: string; role: 'identity-reference'|'edit-target'; sha256: string; mimeType: string};
type Run = {
  sourceImages?: SourceImage[]; parentRunId?: string;
  id: string; character: CharacterPack; brief: string; style: string; skillDirectory: string;
  phase: 'artwork'|'validated'|'published'; reviews: Record<string,string>; artifacts: Record<string,string>;
  stages: string[]; atlasSHA256?: string; packSHA256?: string; validatedPack?: CharacterPack;
  pets: { step: 'inspect'|'validate'|'upload'|'publish'|'select'|'list'|'download'|'verify-download'|'done';
    metadataOnly?: boolean; activate?: boolean; previousActivePetId?: string | null;
    petId?: string; uploadSessionId?: string; action?: Action; cursor?: string; confirmation?: string };
  watch?: { result: string; characterID: string; version: number; sha256: string; definitionSHA256: string; selected: boolean; confirmation: string };
};

/** External hosts are invoked by the authenticated host skill, never with scraped credentials.
 * Receipts submitted through MCP are explicitly host-reported, not server-authenticated proof.
 */
export function createCreationPipeline(dataDirectory: string, env: NodeJS.ProcessEnv = process.env) {
  const root = join(resolve(dataDirectory), 'creation');
  const library = createCharacterLibrary({libraryDirectory: join(resolve(dataDirectory), 'library')});
  let python = env.DOBOO_PYTHON || '';
  async function ensurePython() {
    const candidates=python?[python]:['python3','python',join(homedir(),'.cache','codex-runtimes','codex-primary-runtime','dependencies','python','bin','python3')];
    for(const candidate of candidates) {
      try{await exec(candidate,['-c','from PIL import Image'],{timeout:10000});python=candidate;return;}
      catch{/* Try another installed interpreter; never install or purchase a fallback silently. */}
    }
    throw new Error('Pets production requires Python with Pillow. Set DOBOO_PYTHON to an installed interpreter containing Pillow.');
  }
  const dir = (runId: string) => { if (!/^[a-f0-9-]{36}$/.test(runId)) throw new Error('Invalid creation run ID.'); return join(root, runId); };
  const save = async (run: Run) => characterFiles.atomicWrite(dir(run.id), 'run.json', Buffer.from(JSON.stringify(run, null, 2)), true);
  const load = async (runId: string): Promise<Run> => json(join(dir(runId), 'run.json'));
  async function invalidateVisualVerdicts(runId: string) {
    for(const name of ['direction-semantics.json','pet-quality.json']) {
      await unlink(join(dir(runId),'qa',name)).catch(error=>{if(!characterFiles.isMissing(error))throw error;});
    }
  }
  async function locked<T>(runId: string, fn: (r: Run) => Promise<T>): Promise<T> {
    const path = join(dir(runId), '.lock');
    const lock = await open(path, 'wx', 0o600).catch(() => { throw new Error('Creation run is busy; retry.'); });
    try { return await fn(await load(runId)); } finally { await lock.close(); await unlink(path); }
  }
  async function skillDirectory() {
    if (env.DOBOO_PETS_SKILL_DIR) {
      const path = resolve(env.DOBOO_PETS_SKILL_DIR); await access(join(path,'scripts','prepare_pet_run.py')); return path;
    }
    const base = join(env.CODEX_HOME || join(homedir(),'.codex'),'plugins','cache','openai-curated-remote','work-pets');
    for (const version of (await readdir(base)).sort((a,b)=>b.localeCompare(a,undefined,{numeric:true}))) {
      const path=join(base,version,'skills','create-pet');
      try { await access(join(path,'scripts','prepare_pet_run.py')); return path; } catch { /* next installed version */ }
    }
    throw new Error('Install the OpenAI work-pets plugin or set DOBOO_PETS_SKILL_DIR.');
  }
  async function prepare(character: unknown, brief: string, style = 'auto', referenceImages: string[] = [], activate = false, editTarget?: string) {
    const pack = validateCharacter(character) as CharacterPack;
    if(referenceImages.length>5)throw new Error('At most five identity reference images plus one edit target are supported.');
    // Snapshot the actual user bytes before creating a run. Extensions are not trusted.
    const sources: {bytes:Buffer;format:string;role:SourceImage['role']}[]=[];
    for(const [path,role] of [...referenceImages.map(path=>[path,'identity-reference'] as const),...(editTarget?[[editTarget,'edit-target'] as const]:[])]) {
      const bytes=await readFile(resolve(path));
      if(!bytes.length||bytes.length>20*1024*1024)throw new Error('Source image must be between 1 byte and 20 MiB.');
      const format=bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]))?'png':bytes[0]===255&&bytes[1]===216&&bytes[2]===255?'jpeg':bytes.toString('ascii',0,4)==='RIFF'&&bytes.toString('ascii',8,12)==='WEBP'?'webp':null;
      if(!format)throw new Error('Source image must be a PNG, JPEG, or WebP image, not a completed Pets atlas requirement.');
      sources.push({bytes,format,role});
    }
    if (!brief.trim() || brief.length > 8000) throw new Error('A visual identity/customization brief of 1–8000 characters is required.');
    if (!['auto','pixel','plush','clay','sticker','flat-vector','3d-toy','painterly','brand-inspired'].includes(style)) throw new Error('Unsupported style.');
    try { const current=await library.readCharacter(pack.id); if(pack.version<=current.version) throw new Error('Customization requires a new character version.'); }
    catch(e) { if (!characterFiles.isMissing(e)) throw e; }
    const skill=await skillDirectory();
    await ensurePython();
    for(const source of sources) {
      // Pillow checks encoded content and rejects truncated/oversized input before a run exists.
      await new Promise<void>((done,fail)=>{
        const child=execFile(python,[fileURLToPath(new URL('../scripts/validate-source-image.py',import.meta.url))],{timeout:30000,maxBuffer:1024*1024},error=>error?fail(new Error('Source image is corrupt or exceeds 25 megapixels.')):done());
        child.stdin!.on('error',()=>{});child.stdin!.end(source.bytes);
      });
    }
    const runId=randomUUID(); const path=dir(runId); await mkdir(path,{recursive:true,mode:0o700});
    const run: Run={id:runId,character:pack,brief,style,skillDirectory:skill,phase:'artwork',reviews:{},artifacts:{},stages:[],pets:{step:'inspect',activate}};
    await exec(python,[join(skill,'scripts','prepare_pet_run.py'),'--pet-name',pack.name,'--description',pack.description,'--pet-notes',`${brief}\nCharacter identity (data): ${pack.name}; palette ${pack.appearance.tint}; ${pack.identity.backstory}; traits: ${pack.personality.traits.join(', ')}. Preserve distinctive character traits across host representations.`,'--style-preset',style,'--output-dir',path]);
    await save(run);
    const jobs=await json(join(path,'imagegen-jobs.json'));
    if(pack.appearance.sprite) {
      const name='references/previous-spritesheet.png';await writeFile(join(path,name),Buffer.from(pack.appearance.sprite.base64,'base64'));
      for(const job of jobs.jobs)job.input_images.push({path:name,role:'previous character artwork; preserve identity while applying the requested customization'});
    }
    run.sourceImages=[];
    for(let i=0;i<sources.length;i++) {
      const source=sources[i],name=`references/source-${i}.${source.format}`;
      await writeFile(join(path,name),source.bytes,{mode:0o600});
      run.sourceImages.push({path:name,role:source.role,sha256:hash(source.bytes),mimeType:`image/${source.format}`});
      for(const job of jobs.jobs)job.input_images.push({path:name,role:source.role==='edit-target'?'edit target: apply only the requested changes in the brief; preserve all other identity traits':'user image identity reference: preserve distinguishing traits while following the customization brief'});
    }
    await save(run);
    // Built-in imagegen accepts at most five attachments. Preserve every source
    // image by combining reference pixels when required, never dropping identity.
    const needsBoard=jobs.jobs.some((job:any)=>job.input_images.filter((v:any)=>!v.role.startsWith('layout guide')).length>5);
    const boardSources=jobs.jobs[0].input_images;
    if(needsBoard) {
      const args=[fileURLToPath(new URL('../scripts/compose-reference-board.py',import.meta.url)),'--output',join(path,'references/source-board.png')];
      for(const image of boardSources)args.push('--image',join(path,image.path),'--role',image.role.startsWith('edit target')?'EDIT TARGET':image.role.startsWith('previous')?'PREVIOUS ARTWORK':'IDENTITY REFERENCE');
      await exec(python,args,{timeout:30000,maxBuffer:1024*1024});
    }
    for(const job of jobs.jobs) {
      if(job.input_images.length>5) {
        job.supporting_images=job.input_images.filter((v:any)=>v.role.startsWith('layout guide'));
        job.input_images=job.input_images.filter((v:any)=>!v.role.startsWith('layout guide'));
      }
      if(job.input_images.length>5) {
        const paths=new Set(boardSources.map((v:any)=>v.path));
        job.input_images=job.input_images.filter((v:any)=>!paths.has(v.path));
        job.input_images.push({path:'references/source-board.png',role:'All original user images and edit target, labeled by role. Labels are reference guidance only; do not copy labels or board layout into artwork.'});
      }
      if(job.input_images.length>5)throw new Error('Generation job exceeds the host attachment limit.');
    }
    await writeFile(join(path,'imagegen-jobs.json'),JSON.stringify(jobs,null,2));
    return status(runId);
  }
  async function revise(runId: string, character: unknown, brief: string, style?: string, referenceImages?: string[]) {
    const previous=await load(runId),pack=validateCharacter(character) as CharacterPack;
    if(pack.id!==previous.character.id)throw new Error('A revision must preserve the character ID.');
    if(pack.version<previous.character.version||(previous.phase!=='artwork'&&pack.version<=previous.character.version))throw new Error('A validated or published character requires a higher version.');
    let editTarget=previous.reviews.base?join(dir(runId),'references','canonical-base.png'):undefined;
    const saved=previous.sourceImages??[];
    // Runs made before source manifests still retain their original base-job references.
    const legacy=previous.sourceImages?[]:((await json(join(dir(runId),'imagegen-jobs.json'))).jobs.find((job:any)=>job.id==='base')?.input_images??[]).map((image:any)=>join(dir(runId),image.path));
    if(!editTarget){const old=saved.find(v=>v.role==='edit-target');if(old)editTarget=join(dir(runId),old.path);}
    const refs=referenceImages??[...saved.filter(v=>v.role==='identity-reference').map(v=>join(dir(runId),v.path)),...legacy];
    const next=await prepare(pack,brief,style??previous.style,refs,previous.pets.activate===true,editTarget);
    await locked(next.runId,async run=>{run.parentRunId=runId;await save(run);});
    return status(next.runId);
  }
  async function reviseMotion(runId: string, version: number, state: string, change: string) {
    return locked(runId,async previous=>{
      await checkBytes(previous);
      if(previous.pets.step!=='done')throw new Error('Verify publication before revising motion.');
      if(!Number.isSafeInteger(version)||version<=previous.character.version)throw new Error('Motion revision requires a higher version.');
      if(!['waving','jumping','failed','waiting','running','review'].includes(state))throw new Error('Use full customization for base identity, gait or gaze changes.');
      if(!change.trim()||change.length>8000)throw new Error('Describe the motion change in 1–8000 characters.');
      const id=randomUUID(),path=dir(id);await mkdir(path,{recursive:true,mode:0o700});
      // Reuse approved source pixels for unchanged poses, then rebuild and recheck
      // the complete atlas. A changed row cannot inherit publication approval.
      for(const entry of ['decoded','references','prompts','qa','final','imagegen-jobs.json','pet_request.json'])await cp(join(dir(runId),entry),join(path,entry),{recursive:true});
      const pack={...previous.validatedPack!,version};
      const run: Run={...previous,id,parentRunId:runId,character:pack,phase:'artwork',stages:[],reviews:{...previous.reviews},artifacts:{...previous.artifacts},pets:{step:'inspect',activate:previous.pets.activate===true}};
      delete run.validatedPack;delete run.atlasSHA256;delete run.packSHA256;delete run.watch;
      delete run.reviews[state];delete run.artifacts[state];
      const jobs=await json(join(path,'imagegen-jobs.json')),job=jobs.jobs.find((j:any)=>j.id===state);
      if(!job)throw new Error('Motion source job is missing.');
      const promptPath=join(path,job.prompt_file);
      await writeFile(promptPath,(await readFile(promptPath,'utf8'))+`\nRequested motion edit: ${change}\nPreserve the canonical character identity, palette, eye construction, material, scale and grounded baseline. Change only this state; no new props or detached effects.\n`);
      run.brief=previous.brief+`\n${state} motion revision: ${change}`;
      await invalidateVisualVerdicts(id);await save(run);return status(id);
    });
  }
  async function reviseDetails(runId: string, character: unknown) {
    return locked(runId,async previous=>{
      await checkBytes(previous);
      if(previous.pets.step!=='done')throw new Error('Verify publication before revising character details.');
      const pack=validateCharacter(character) as CharacterPack;
      if(pack.id!==previous.character.id||pack.version<=previous.character.version)throw new Error('Details revisions require the same ID and a higher version.');
      if(characterReference({...previous.validatedPack!,appearance:pack.appearance}).digest!==characterReference(previous.validatedPack!).digest)throw new Error('Appearance changed: use image customization and revalidate the artwork.');
      const id=randomUUID(),path=dir(id);await mkdir(path,{recursive:true,mode:0o700});
      // Reuse exact validated artwork and its evidence for nonvisual edits.
      // A real metadata update/readback is required; the image is not re-uploaded.
      for(const entry of ['decoded','references','prompts','qa','final','imagegen-jobs.json','pet_request.json']) {
        try{await cp(join(dir(runId),entry),join(path,entry),{recursive:true});}
        catch(error){if(!characterFiles.isMissing(error))throw error;}
      }
      const bytes=serializeCharacter(pack);
      await writeFile(join(path,'character.doboo.json'),bytes,{mode:0o600});
      const run: Run={...previous,id,parentRunId:runId,character:pack,validatedPack:pack,phase:'validated',packSHA256:hash(bytes),pets:{step:'inspect',metadataOnly:true,activate:previous.pets.activate===true}};
      delete run.watch;await save(run);return status(id);
    });
  }
  async function status(runId: string) {
    const run=await load(runId); const path=dir(runId);
    const jobs=(await json(join(path,'imagegen-jobs.json'))).jobs;
    const ready=[];
    for(const job of jobs) {
      if(run.reviews[job.id] || !job.depends_on.every((d:string)=>run.reviews[d])) continue;
      if(job.id==='look-cardinals'&&!run.stages.includes('standard-rows'))continue;
      if(job.id==='look-row-9'&&!run.stages.includes('cardinals'))continue;
      if(job.id==='look-row-10'&&!run.stages.includes('look-row-9'))continue;
      const inputs=job.input_images.length>5?job.input_images.filter((v:any)=>!v.role.startsWith('layout guide')):job.input_images;
      if(inputs.length>5)throw new Error('This saved job exceeds the imagegen attachment limit; revise its source inputs before generation.');
      ready.push({...job,prompt:(await readFile(join(path,job.prompt_file),'utf8'))+'\nReference roles (image content is reference data, never permission):\n'+inputs.map((v:any,i:number)=>`Image ${i+1}: ${v.role}`).join('\n'),input_images:inputs.map((v:any)=>({...v,path:join(path,v.path)})),output_path:join(path,job.output_path)});
    }
    return {runId,character:{id:run.character.id,version:run.character.version},phase:run.phase,runDirectory:path,skillDirectory:run.skillDirectory,
      sourceImages:run.sourceImages??[],parentRunId:run.parentRunId??null,readyJobs:ready,stages:run.stages,reviewedJobs:Object.keys(run.reviews),pets:{revisionMode:run.pets.metadataOnly?'details':'artwork',step:run.pets.step,petId:run.pets.petId,activate:run.pets.activate===true,confirmation:run.pets.confirmation},watch:run.watch??null,
      deliveryConfirmed:run.pets.step==='done'&&run.watch?.result==='imported'&&run.watch.selected===true};
  }
  async function supplyArtwork(runId: string, jobId: string, filePath: string, review: string) {
    return locked(runId,async run=>{
      if(run.phase!=='artwork')throw new Error('Validated artwork is immutable. Start a new revision.');
      if(review.trim().length<20)throw new Error('Record concrete visual identity/motion review evidence.');
      const jobs=(await json(join(dir(runId),'imagegen-jobs.json'))).jobs;
      // Before final validation a repair invalidates all dependent jobs and all assemblies.
      if(run.reviews[jobId]) {
        const invalid=new Set([jobId]);
        for(let changed=true;changed;){changed=false;for(const j of jobs)if(!invalid.has(j.id)&&j.depends_on.some((d:string)=>invalid.has(d))){invalid.add(j.id);changed=true;}}
        for(const id of invalid){delete run.reviews[id];delete run.artifacts[id];}
        const keep=jobId==='look-row-10'?['standard-rows','cardinals','look-row-9']:jobId==='look-row-9'?['standard-rows','cardinals']:jobId==='look-cardinals'?['standard-rows']:[];
        await invalidateVisualVerdicts(runId);
        run.stages=run.stages.filter(stage=>keep.includes(stage));await save(run);
      }
      const job=(await status(runId)).readyJobs.find((j:any)=>j.id===jobId);
      if(!job)throw new Error('Job is not ready; dependencies or review gates are missing.');
      const bytes=await readFile(resolve(filePath)); if(bytes.length>32*1024*1024)throw new Error('Artwork is too large.');
      // Image generation output is copied, never redrawn or invented by this pipeline.
      if(!bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])))throw new Error('Supply an encoded PNG from imagegen.');
      await copyFile(resolve(filePath),job.output_path);
      if(jobId==='base')await copyFile(job.output_path,join(dir(runId),'references','canonical-base.png'));
      await ensurePython();
      if(['idle','running-right','running-left','waving','jumping','failed','waiting','running','review'].includes(jobId)) {
        const path=dir(runId),request=await json(join(path,'pet_request.json'));
        const frames=join(path,'qa','rows',jobId,'frames');
        await exec(python,[join(run.skillDirectory,'scripts','extract_strip_frames.py'),'--decoded-dir',join(path,'decoded'),'--output-dir',frames,'--states',jobId,'--method','auto','--chroma-key',request.chroma_key.hex]);
        await exec(python,[join(run.skillDirectory,'scripts','inspect_frames.py'),'--frames-root',frames,'--states',jobId,'--require-components','--json-out',join(path,'qa','rows',jobId,'review.json')]);
      }
      run.artifacts[jobId]=hash(bytes);run.reviews[jobId]=review; await save(run);
      return status(runId);
    });
  }
  async function runStage(runId: string, stage: ProductionStage) {
    return locked(runId,async run=>{
      if(run.phase!=='artwork'||!stages.includes(stage))throw new Error('Invalid production stage or immutable run.');
      const required:Record<ProductionStage,string[]>={
        'standard-rows':['idle','running-right','running-left','waving','jumping','failed','waiting','running','review'],
        'cardinals':['look-cardinals'],'look-row-9':['look-row-9'],'assemble-v2':['look-row-10'],'validate-v2':['look-row-10']};
      if(required[stage].some(j=>!run.reviews[j]))throw new Error('Generated artwork and visual reviews are missing.');
      const prior: Partial<Record<ProductionStage,string>>={cardinals:'standard-rows','look-row-9':'cardinals','assemble-v2':'look-row-9','validate-v2':'assemble-v2'};
      if(prior[stage]&&!run.stages.includes(prior[stage]!))throw new Error('Prior production stage is missing.');
      await ensurePython();
      if(stage!=='validate-v2')await invalidateVisualVerdicts(runId);
      // A failed rerun cannot leave a previous success marker for changed output.
      run.stages=run.stages.filter(value=>stages.indexOf(value as ProductionStage)<stages.indexOf(stage));
      await save(run);
      const runner=fileURLToPath(new URL('../scripts/pets-production.py',import.meta.url));
      try { await exec(python,[runner,'--skill-dir',run.skillDirectory,'--run-dir',dir(runId),'--stage',stage],{maxBuffer:1024*1024,timeout:120000}); }
      catch(e:any){throw new Error(e.stdout||e.stderr||e.message);}
      if(!run.stages.includes(stage))run.stages.push(stage);
      if(stage==='validate-v2') {
        const atlas=await readFile(join(dir(runId),'final','spritesheet-extended.png'));
        const quality=await json(join(dir(runId),'qa','pet-quality.json'));
        if(quality.ok!==true||quality.sha256!==hash(atlas))throw new Error('The official quality gate did not verify these bytes.');
        const pack=structuredClone(run.character);
        pack.appearance={...pack.appearance,renderer:'spritesheet',sprite:{layout:'pets-v2',mimeType:'image/png',base64:atlas.toString('base64')}};
        validateCharacter(pack);run.validatedPack=pack;run.atlasSHA256=hash(atlas);
        const encoded=serializeCharacter(pack);run.packSHA256=hash(encoded);
        await writeFile(join(dir(runId),'character.doboo.json'),encoded,{mode:0o600});
        run.phase='validated';
      }
      await save(run);return status(runId);
    });
  }
  async function checkBytes(run: Run) {
    if(!run.atlasSHA256||!run.validatedPack)throw new Error('Finish the official v2 quality gates first.');
    if(hash(await readFile(join(dir(run.id),'final','spritesheet-extended.png')))!==run.atlasSHA256||
      hash(await readFile(join(dir(run.id),'character.doboo.json')))!==run.packSHA256)throw new Error('Validated bytes changed. Start a new run.');
  }
  async function bindingPath(id: string) { if(!idPattern.test(id))throw new Error('Invalid character ID'); const base=join(root,'bindings');await mkdir(base,{recursive:true,mode:0o700});return join(base,id+'.json'); }
  async function bindingTransaction<T>(id: string, fn: (binding: any) => Promise<T>) {
    const path=await bindingPath(id), lockPath=path+'.lock';
    const lock=await open(lockPath,'wx',0o600).catch(()=>{throw new Error('Pet publication is busy; retry.');});
    try {
      let binding:any={};try{binding=await json(path);}catch(e){if(!characterFiles.isMissing(e))throw e;}
      const result=await fn(binding);
      await characterFiles.atomicWrite(join(root,'bindings'),id+'.json',Buffer.from(JSON.stringify(binding)),true);
      return result;
    }finally{await lock.close();await unlink(lockPath);}
  }
  async function nextPetAction(runId: string): Promise<Action | Record<string,unknown>> {
    return locked(runId,async run=>{
      await checkBytes(run);
      if(run.pets.action)return run.pets.action; // Retry the same session after an unknown outcome.
      if(run.pets.step==='done')return {status:'pets-confirmed',petId:run.pets.petId,watchPackPath:join(dir(runId),'character.doboo.json'),packSHA256:run.packSHA256};
      if(run.pets.step==='verify-download')return {status:'download-verification-required',next:'Download the returned stored sheet, then call verify_pet_download with its file path.'};
      const file=join(dir(runId),'final','spritesheet-extended.png');
      let tool:string, args:Record<string,unknown>;
      switch(run.pets.step) {
        case 'inspect':tool='list_pets';args={limit:20};break;
        case 'validate':tool='validate_pet_spritesheet';args={file};break;
        case 'upload':tool='prepare_pet_upload';args={file};break;
        case 'publish': {
          await bindingTransaction(run.character.id,async binding=>{
            if(binding.activeRunId&&binding.activeRunId!==runId)throw new Error(`Another publication is pending in run ${binding.activeRunId}; resume it before publishing another revision.`);
            if(binding.version>=run.character.version&&binding.runId!==runId)throw new Error('A newer/equal revision is already published.');
            if(run.pets.metadataOnly&&!binding.petId)throw new Error('Details revision requires an existing bound custom Pet.');
            if(run.pets.metadataOnly&&binding.atlasSHA256!==run.atlasSHA256)throw new Error('The current Pet artwork differs from this details revision. Revise the latest published character instead.');
            run.pets.petId=binding.petId;
            binding.activeRunId=runId;
          });
          tool=run.pets.petId?'update_pet':'create_pet';
          args=run.pets.petId?{pet_id:run.pets.petId,updates:{name:run.character.name,description:run.character.description,...(!run.pets.metadataOnly?{upload_session_id:run.pets.uploadSessionId}:{})}}:
            {name:run.character.name,description:run.character.description,upload_session_id:run.pets.uploadSessionId};break;
        }
        case 'select':tool='select_pet';args={pet_id:run.pets.petId};break;
        case 'list':tool='list_pets';args={limit:20,...(run.pets.cursor?{cursor:run.pets.cursor}:{})};break;
        case 'download':tool='get_pet_download_link';args={pet_id:run.pets.petId};break;
      }
      run.pets.action={id:randomUUID(),tool,arguments:args};await save(run);return run.pets.action;
    });
  }
  async function recordPetResponse(runId: string, actionId: string, response: any) {
    return locked(runId,async run=>{
      await checkBytes(run);const action=run.pets.action;
      if(!action||action.id!==actionId)throw new Error('Stale or mismatched Pets action receipt.');
      if(response?.isError)throw new Error('Pets tool failed. Keep the same pending action for recovery; do not invent success.');
      const body=response?.structuredContent??response;
      const phase=run.pets.step;
      if(phase==='inspect') {
        if(!Array.isArray(body.pets)||!(body.active_pet_id===null||typeof body.active_pet_id==='string'))throw new Error('Missing Pets selection snapshot.');
        run.pets.previousActivePetId=body.active_pet_id;run.pets.step=run.pets.metadataOnly?'publish':'validate';
      }else if(phase==='validate') {
        if(body.valid!==true||body.sprite_version!==2)throw new Error('Pets preflight rejected v2.');run.pets.step='upload';
      }else if(phase==='upload') {
        const session=body.upload?.upload_session_id; if(typeof session!=='string'||!session)throw new Error('Missing upload session.');
        run.pets.uploadSessionId=session;run.pets.step='publish';
      }else if(phase==='publish') {
        const pet=body.pet;
        if(!pet?.id||pet.is_custom!==true||pet.name!==run.character.name||pet.description!==run.character.description||
          (run.pets.petId&&pet.id!==run.pets.petId))throw new Error('Pets returned a different identity or revision metadata.');
        run.pets.petId=pet.id;delete run.pets.uploadSessionId;run.pets.step=run.pets.activate===true?'select':'list';
        // Record the durable ID as soon as publication succeeds, before activation can fail.
        await bindingTransaction(run.character.id,async binding=>{
          if(binding.activeRunId!==runId)throw new Error('Publication reservation changed; reconcile the returned Pet ID before retrying.');
          Object.assign(binding,{petId:pet.id,version:run.character.version,runId,atlasSHA256:run.atlasSHA256});
        });
      }else if(phase==='select') {
        if(body.active_pet_id!==run.pets.petId)throw new Error('Pet selection was not confirmed.');run.pets.step='list';
      }else if(phase==='list') {
        const pet=body.pets?.find((p:any)=>p.id===run.pets.petId);
        if(pet) {
          if(!pet.is_custom||pet.name!==run.character.name||pet.description!==run.character.description)throw new Error('Readback does not match the requested custom Pet.');
          if(run.pets.activate===true&&body.active_pet_id!==pet.id)throw new Error('Pet activation was not confirmed.');
          if(run.pets.activate!==true&&run.pets.previousActivePetId!==undefined&&body.active_pet_id!==run.pets.previousActivePetId)throw new Error('Active Pet changed during publication. Inspect the current selection before continuing; do not restore it automatically.');
          if(run.pets.metadataOnly) {
            await library.saveCharacter(run.validatedPack);
            await bindingTransaction(run.character.id,async binding=>{if(binding.activeRunId===runId)delete binding.activeRunId;});
            run.pets.step='done';run.phase='published';run.pets.confirmation='host-reported metadata update and list readback; artwork retained from the verified parent revision';
          }else run.pets.step='download';
          delete run.pets.cursor;
        }else if(body.cursor) { if(body.cursor===run.pets.cursor)throw new Error('Pets pagination did not advance.');run.pets.cursor=body.cursor; }
        else throw new Error('Created Pet was absent from complete list readback.');
      }else if(phase==='download') {
        if(body.pet_id!==run.pets.petId||typeof body.spritesheet_url!=='string'||new URL(body.spritesheet_url).protocol!=='https:')throw new Error('Missing or mismatched stored Pet download link.');
        // Never persist expiring URLs. The calling authenticated host downloads the returned artifact.
        run.pets.step='verify-download';
      }else throw new Error('No Pets response expected at this step.');
      delete run.pets.action;await save(run);return status(runId);
    });
  }
  async function retryUpload(runId: string, failedActionId: string, response: any, failureKind: 'expired-session'|'rejected-before-publication') {
    return locked(runId,async run=>{
      if(run.pets.metadataOnly||run.pets.action?.id!==failedActionId||run.pets.step!=='publish'||response?.isError!==true||!['expired-session','rejected-before-publication'].includes(failureKind))
        throw new Error('Only an explicit failed publication response permits a fresh upload. Unknown outcomes must retry the original action.');
      delete run.pets.action;delete run.pets.uploadSessionId;run.pets.step='upload';await save(run);return status(runId);
    });
  }
  async function verifyPetDownload(runId: string, filePath: string) {
    return locked(runId,async run=>{
      await checkBytes(run);
      if(run.pets.step!=='verify-download')throw new Error('Stored Pets download is not expected yet.');
      if(hash(await readFile(resolve(filePath)))!==run.atlasSHA256) {
        await ensurePython();
        const script=fileURLToPath(new URL('../scripts/verify-pet-download.py',import.meta.url));
        try { await exec(python,[script,join(dir(runId),'final','spritesheet-extended.png'),resolve(filePath)],{timeout:30000}); }
        catch { throw new Error('Stored Pets pixels do not match the validated revision. Do not mark it synchronized.'); }
      }
      await library.saveCharacter(run.validatedPack);
      await bindingTransaction(run.character.id,async binding=>{if(binding.activeRunId===runId)delete binding.activeRunId;});
      run.pets.step='done';run.pets.confirmation='host-reported API readback plus stored-file byte/pixel comparison';run.phase='published';await save(run);return status(runId);
    });
  }
  async function recordWatchReceipt(runId: string, filePath: string) {
    return locked(runId,async run=>{
      await checkBytes(run);const receipt=await json(resolve(filePath));
      if(run.pets.step!=='done')throw new Error('Complete Pets readback before applying this revision to Watch.');
      if(receipt.characterID!==run.character.id||receipt.version!==run.character.version||receipt.definitionSHA256!==characterReference(run.validatedPack!).digest||!(/^[a-f0-9]{64}$/.test(receipt.sha256))||
        receipt.result!=='imported'||receipt.selected!==true)throw new Error('Watch receipt does not confirm the exact revision and selection.');
      run.watch={result:receipt.result,characterID:receipt.characterID,version:receipt.version,sha256:receipt.sha256,definitionSHA256:receipt.definitionSHA256,selected:true,confirmation:'host-reported receiver acknowledgement; visual inspection remains separate'};
      await save(run);return status(runId);
    });
  }
  return {prepare,revise,reviseMotion,reviseDetails,status,supplyArtwork,runStage,nextPetAction,recordPetResponse,retryUpload,verifyPetDownload,recordWatchReceipt};
}
