import { App } from '@modelcontextprotocol/ext-apps';
const app=new App({name:'Doboo gallery',version:'0.2.1'},{});
const el=(id:string)=>document.getElementById(id)!;
let local=false;
const status=(text:string)=>{el('status').textContent=text;};
async function call(name:string,args:Record<string,unknown>={}){
  const result=await app.callServerTool({name,arguments:args});
  if(result.isError)throw new Error(result.content.filter(x=>x.type==='text').map(x=>(x as {text:string}).text).join('\n'));
  return result;
}
async function action(fn:()=>Promise<void>){try{await fn();}catch(e){status(e instanceof Error?e.message:String(e));}}
function button(label:string,fn:()=>Promise<void>){const b=document.createElement('button');b.textContent=label;b.onclick=()=>action(async()=>{b.disabled=true;try{await fn();}finally{b.disabled=false;}});return b;}
async function applyCharacter(id:string,version:number){
  // Only a deliberate click creates a request in the current conversation.
  // Author-supplied descriptions never become a user instruction.
  const sent=await app.sendMessage({role:'user',content:[{type:'text',text:`Doboo character_context 도구로 보관함의 ${id}@${version}을 읽고 이 대화에서 해당 캐릭터의 말투와 성격을 적용해 주세요. 다른 기기나 대화로의 적용, 별도 에이전트 설치는 이번 요청에 포함하지 않습니다.`}]});
  if(sent.isError)throw new Error('이 호스트가 적용 요청을 받지 못했습니다. 채팅에서 캐릭터 ID로 적용을 요청해 주세요.');
  status('이 대화에 캐릭터 적용을 요청했습니다. 실제 응답에서 적용 결과를 확인할 수 있습니다.');
}
function render(data:any){
  const root=el('cards');root.replaceChildren();el('detail').hidden=true;
  for(const c of data.characters??[]){
    const card=document.createElement('article'),title=document.createElement('h2'),by=document.createElement('p'),description=document.createElement('p'),actions=document.createElement('div');
    title.textContent=c.name;by.className='byline';by.textContent=`${c.creatorName??c.creator} · v${c.version}`;description.textContent=c.description;actions.className='actions';
    if(!local){
      actions.append(button('자세히',async()=>{
        const r=await call('inspect_character',{id:c.id,version:c.version,creatorId:c.creatorId});
        const details=r.structuredContent as any;
        el('detail').hidden=false;el('detailTitle').textContent=c.name;
        el('detailText').textContent=[details.identity.backstory,`말투: ${details.identity.voice}`,`성격: ${details.personality.traits.join(', ')}`,...details.personality.instructions].filter(Boolean).join('\n\n');
        const sprite=(r._meta as any)?.sprite;const canvas=el('sprite') as HTMLCanvasElement;canvas.hidden=!sprite;
        if(sprite){const image=new Image();image.onload=()=>{const ctx=canvas.getContext('2d')!;ctx.clearRect(0,0,192,208);ctx.drawImage(image,0,0,192,208,0,0,192,208);};image.src=`data:image/png;base64,${sprite.base64}`;}
      }));
      actions.append(button('내 캐릭터로 받기',async()=>{const r=await call('adopt_character',{id:c.id,version:c.version,creatorId:c.creatorId});const data=r.structuredContent as any;status(`${c.name} v${c.version}을 보관함에 받았습니다.${data.receiptRecorded?'':' 갤러리 수신 기록은 재시도가 필요합니다.'} ‘내 캐릭터’에서 이 대화에 적용할 수 있습니다.`);}));
    }else{
      actions.append(button('이 대화에서 쓰기',()=>applyCharacter(c.id,c.version)));
      actions.append(button('갤러리에 공유',async()=>{if(!confirm(`${c.name} v${c.version}을 연결된 갤러리 이용자에게 공유할까요?`))return;await call('publish_character',{id:c.id});status(`${c.name}을 공유 갤러리에 게시했습니다.`);}));
    }
    card.append(title,by,description,actions);root.append(card);
  }
  status(data.characters?.length?`${local?'내 캐릭터':'공유 캐릭터'} ${data.characters.length}개`:local?'아직 가져온 캐릭터가 없습니다.':'다른 제작자의 캐릭터가 없습니다. 공유 카탈로그에 게시된 캐릭터가 표시됩니다.');
}
async function refresh(){const r=await call(local?'list_library':'search_characters',local?{}:{query:(el('query') as HTMLInputElement).value,excludeOwn:true});render(r.structuredContent);}
el('search').onsubmit=e=>{e.preventDefault();action(refresh);};
el('discover').onclick=()=>action(async()=>{local=false;el('search').hidden=false;await refresh();});
el('library').onclick=()=>action(async()=>{local=true;el('search').hidden=true;await refresh();});
app.ontoolresult=result=>{if(result.structuredContent&&typeof result.structuredContent==='object'&&'characters'in result.structuredContent)render(result.structuredContent);};
await action(async()=>{await app.connect();await refresh();});
