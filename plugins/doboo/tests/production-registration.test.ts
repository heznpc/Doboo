import test from 'node:test';
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir,homedir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
const exec=promisify(execFile);
test('shared registration aligns landing without erasing flight or fitting poses independently',async()=>{
  let python='';for(const p of [process.env.DOBOO_PYTHON,'python3',join(homedir(),'.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3')].filter(Boolean) as string[]){try{await exec(p,['-c','from PIL import Image']);python=p;break;}catch{}}
  assert.ok(python,'production requires installed Python/Pillow');
  const root=await mkdtemp(join(tmpdir(),'doboo-registration-'));
  try{await exec(python,['-c',`
import importlib.util,pathlib,sys,json
from PIL import Image,ImageDraw
p=pathlib.Path(sys.argv[1]); (p/'qa/frames/idle').mkdir(parents=True); (p/'qa/frames/jumping').mkdir()
# Synthetic geometry fixtures only; never used as pet artwork.
for state,ys in [('idle',[30,30]),('jumping',[40,10,40])]:
 for n,y in enumerate(ys):
  im=Image.new('RGBA',(192,208)); ImageDraw.Draw(im).rectangle((20,y,170,y+150),fill=(220,120,60,255)); im.save(p/'qa/frames'/state/(str(n)+'.png'))
spec=importlib.util.spec_from_file_location('production',sys.argv[2]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);m.register_standard_frames(p)
idle=Image.open(p/'qa/frames/idle/0.png').getbbox();jump=[Image.open(p/'qa/frames/jumping'/f'{n}.png').getbbox() for n in range(3)]
assert idle[3]==jump[0][3]==jump[2][3]==200
assert jump[1][3]<jump[0][3]-20
assert len({(b[2]-b[0],b[3]-b[1]) for b in [idle,*jump]})==1
assert all(b[0]>=0 and b[1]>=0 and b[2]<=192 and b[3]<=208 for b in [idle,*jump])
`,root,fileURLToPath(new URL('../scripts/pets-production.py',import.meta.url))]);}finally{await rm(root,{recursive:true,force:true});}
});
