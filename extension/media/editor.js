(function(){
const vscode=acquireVsCodeApi();
const pending=new Map();
let rpcId=1;
let editor,currentFile='',tabs=[];
const FT_EXT={
  ts:'🔷',tsx:'🎨',js:'🟨',jsx:'🎨',json:'{ }',zig:'⚡',rs:'🦀',go:'🔷',py:'🐍',
  c:'⚙️',cpp:'⚙️',h:'📦',hpp:'📦',md:'📝',html:'🌐',css:'🎨',toml:'⚙️',
  yaml:'⚙️',yml:'⚙️',lock:'🔒',gitignore:'💻',svg:'🖼',png:'🖼',jpg:'🖼',
  wasm:'🧪',sh:'>_',bash:'>_'};

function rpc(method,params){
  return new Promise((resolve,reject)=>{
    const id=rpcId++;pending.set(id,{resolve,reject});
    vscode.postMessage({type:'rpc',method,params,id});
    setTimeout(()=>{if(pending.has(id)){pending.delete(id);reject(new Error('timeout: '+method))}},30000);
  });
}

window.addEventListener('message',e=>{
  const m=e.data;
  if(m.type==='rpc-result'){
    const p=pending.get(m.id);
    if(p){pending.delete(m.id);m.error?p.reject(new Error(m.error)):p.resolve(m.result);}
  }
  if(m.type==='daemon-status'){
    const el=document.getElementById('status-daemon');
    el.style.color=m.ok?'#89d185':'#f48771';
    el.title=m.ok?'Daemon connected':'Daemon not running';
    if(!m.ok) notify('Daemon not running — build with: zig build -Doptimize=ReleaseSafe','warn');
  }
});

function notify(msg,type='info'){
  const el=document.createElement('div');el.className='toast '+type;el.textContent=msg;
  document.getElementById('notify').appendChild(el);
  setTimeout(()=>{el.style.opacity='0';el.style.transition='opacity .3s';setTimeout(()=>el.remove(),300)},3500);
}

/* === Context menu === */
let ctxMenu=null;
function hideCtx(){if(ctxMenu){ctxMenu.remove();ctxMenu=null}}
document.addEventListener('click',hideCtx);
function showCtx(x,y,items){
  hideCtx();ctxMenu=document.createElement('div');ctxMenu.className='ctx-menu';
  ctxMenu.style.left=x+'px';ctxMenu.style.top=y+'px';
  items.forEach(it=>{
    if(it.sep){const s=document.createElement('div');s.className='ctx-sep';ctxMenu.appendChild(s);return}
    const d=document.createElement('div');d.className='ctx-item'+(it.danger?' danger':'');d.textContent=it.label;
    d.onclick=()=>{it.action();hideCtx()};d.onmouseenter=()=>d.style.background='#094771';
    d.onmouseleave=()=>d.style.background='';ctxMenu.appendChild(d);
  });
  document.body.appendChild(ctxMenu);
}

/* === Inline input (replaces blocking prompt()) === */
function inlineInput(anchorEl,placeholder,callback){
  const existing=document.getElementById('wizp-inline-input');
  if(existing)existing.remove();
  const wrap=document.createElement('div');
  wrap.id='wizp-inline-input';
  wrap.style.cssText='position:absolute;z-index:300;background:#1e1e1e;border:1px solid #007acc;border-radius:4px;padding:4px;box-shadow:0 4px 12px rgba(0,0,0,.5)';
  const inp=document.createElement('input');
  inp.type='text';inp.placeholder=placeholder;
  inp.style.cssText='background:#3c3c3c;border:1px solid #555;color:#ccc;padding:4px 8px;border-radius:3px;outline:none;font-size:12px;width:200px';
  wrap.appendChild(inp);
  document.body.appendChild(wrap);
  const rect=anchorEl.getBoundingClientRect();
  wrap.style.left=rect.left+'px';wrap.style.top=(rect.bottom+4)+'px';
  inp.focus();
  const cleanup=()=>{wrap.remove();document.removeEventListener('mousedown',outsideClick)};
  const outsideClick=e=>{if(!wrap.contains(e.target))cleanup()};
  setTimeout(()=>document.addEventListener('mousedown',outsideClick),0);
  inp.onkeydown=e=>{
    if(e.key==='Enter'){const v=inp.value.trim();cleanup();if(v)callback(v)}
    if(e.key==='Escape'){cleanup()}
  };
}

/* === File tree === */
let ftPath='.';
const ftBtns=document.getElementById('sidebar-header');
function mkBtn(label,title,action){
  const b=document.createElement('button');b.textContent=label;b.title=title;
  b.onclick=e=>{e.stopPropagation();action()};ftBtns.appendChild(b);
}
mkBtn('+','New File',()=>newFtFile());
mkBtn('📁','New Folder',()=>newFtDir());
mkBtn('↻','Refresh',refreshFt);
mkBtn('⚙','Settings',toggleSettings);
mkBtn('⊞','Plugins',togglePlugins);

function getFileIcon(name,isDir){
  if(isDir)return'📁';
  const ext=name.split('.').pop().toLowerCase();
  return FT_EXT[ext]||(name.startsWith('.')?'⚙️':'📄');
}

async function refreshFt(){
  try{
    const res=await rpc('file/list',{path:ftPath});
    if(!res?.files)return;
    res.files.sort((a,b)=>{if(a.kind!==b.kind)return a.kind==='directory'?-1:1;return a.name.localeCompare(b.name)});
    const c=document.getElementById('file-tree');
    const parts=ftPath.split('/').filter(Boolean);
    
    const frag=document.createDocumentFragment();
    
    if(ftPath!=='.'&&parts.length>0){
      const upDiv=document.createElement('div');
      upDiv.className='ft-item';
      upDiv.dataset.kind='up';
      
      const iconSpan=document.createElement('span');
      iconSpan.className='icon';
      iconSpan.textContent='↑';
      upDiv.appendChild(iconSpan);
      
      upDiv.appendChild(document.createTextNode(' ..'));
      
      upDiv.onclick=()=>{
        const p=parts.slice(0,-1).join('/');
        ftPath=p.length===0?'.':p;
        refreshFt();
      };
      frag.appendChild(upDiv);
    }
    
    const rootDiv=document.createElement('div');
    rootDiv.className='ft-item';
    rootDiv.dataset.kind='root';
    
    const rootIconSpan=document.createElement('span');
    rootIconSpan.className='icon';
    rootIconSpan.textContent='📂';
    rootDiv.appendChild(rootIconSpan);
    
    rootDiv.appendChild(document.createTextNode(' ' + (ftPath==='.'?'Workspace':ftPath.split('/').pop())));
    
    rootDiv.onclick=()=>{
      ftPath='.';
      refreshFt();
    };
    frag.appendChild(rootDiv);
    
    res.files.forEach(f=>{
      const itemDiv=document.createElement('div');
      itemDiv.className='ft-item';
      itemDiv.dataset.path=f.path;
      itemDiv.dataset.kind=f.kind;
      itemDiv.title=f.path;
      
      const iconSpan=document.createElement('span');
      iconSpan.className='icon';
      iconSpan.textContent=getFileIcon(f.name,f.kind==='directory');
      itemDiv.appendChild(iconSpan);
      
      itemDiv.appendChild(document.createTextNode(' ' + f.name));
      
      itemDiv.onclick=()=>{
        if(f.kind==='directory'){
          ftPath=f.path;
          refreshFt();
        } else {
          openFile(f.path);
        }
      };
      
      itemDiv.oncontextmenu=e=>{
        e.preventDefault();e.stopPropagation();
        if(f.kind==='directory') showCtx(e.clientX,e.clientY,[
          {label:'New File...',action:()=>newFtFile(f.path)},
          {label:'New Folder...',action:()=>newFtDir(f.path)},
          {sep:true},{label:'Rename...',action:()=>renameFt(f.path)},
          {label:'Delete',action:()=>deleteFt(f.path),danger:true},
        ]);
        else showCtx(e.clientX,e.clientY,[
          {label:'Open',action:()=>openFile(f.path)},
          {sep:true},{label:'Rename...',action:()=>renameFt(f.path)},
          {label:'Delete',action:()=>deleteFt(f.path),danger:true},
        ]);
      };
      
      frag.appendChild(itemDiv);
    });
    
    c.replaceChildren(frag);
  }catch(e){notify('File tree: '+e.message,'error')}
}

function newFtFile(parent){
  const p=parent||ftPath;
  const btn=ftBtns.querySelector('button');
  inlineInput(btn||document.body,'New file name',async name=>{
    try{await rpc('file/create',{path:p==='.'?name:p+'/'+name});notify('Created '+name,'info');refreshFt()}
    catch(e){notify(e.message,'error')}
  });
}

function newFtDir(parent){
  const p=parent||ftPath;
  const btn=ftBtns.querySelector('button');
  inlineInput(btn||document.body,'New folder name',async name=>{
    try{await rpc('file/mkdir',{path:p==='.'?name:p+'/'+name});notify('Created '+name+'/','info');refreshFt()}
    catch(e){notify(e.message,'error')}
  });
}

async function renameFt(path){
  const el=document.querySelector(`.ft-item[data-path="${path}"]`);
  inlineInput(el||document.body,'Rename to',async name=>{
    try{
      const parts=path.split('/');parts[parts.length-1]=name;
      await rpc('file/rename',{path,newPath:parts.join('/')});notify('Renamed to '+name,'info');refreshFt()
    }catch(e){notify(e.message,'error')}
  });
}

async function deleteFt(path){
  showCtx(200,200,[
    {label:'Confirm delete "'+path.split('/').pop()+'"?',action:()=>{},danger:true},
    {sep:true},
    {label:'Yes, delete',action:async()=>{
      try{await rpc('file/delete',{path});notify('Deleted','info');refreshFt()}catch(e){notify(e.message,'error')}
    },danger:true},
    {label:'Cancel',action:()=>{}},
  ]);
}

/* === Tabs === */
function renderTabs(){
  const bar=document.getElementById('tabs');
  bar.innerHTML=tabs.map(t=>`<div class="tab ${t.path===currentFile?'active':''}" data-path="${t.path}">
    <span>${t.path.split('/').pop()}</span>
    ${t.dirty?'<span class="dirty">●</span>':''}
    <span class="close" data-path="${t.path}">×</span>
  </div>`).join('');
  bar.querySelectorAll('.tab').forEach(el=>{el.onclick=()=>{const p=el.dataset.path;if(p!==currentFile)switchTab(p)}});
  bar.querySelectorAll('.close').forEach(el=>{el.onclick=e=>{e.stopPropagation();closeTab(el.dataset.path)}});
}

function addTab(path){
  if(tabs.find(t=>t.path===path))return;
  const ext=path.split('.').pop()||'';
  const lm={ts:'typescript',tsx:'typescriptreact',js:'javascript',jsx:'javascriptreact',zig:'zig',rs:'rust',go:'go',py:'python',c:'c',cpp:'cpp',h:'c',hpp:'cpp',md:'markdown',html:'html',css:'css',json:'json',toml:'toml',yaml:'yaml',yml:'yaml',sh:'shell',bash:'shell'};
  tabs.push({path,lang:lm[ext]||'plaintext',dirty:false});
  renderTabs();
}

function closeTab(path){
  tabs=tabs.filter(t=>t.path!==path);renderTabs();
  if(tabs.length>0&&path===currentFile){const t=tabs[tabs.length-1];switchTab(t.path)}
  else if(tabs.length===0){currentFile='';editor?.setModel(null);updateStatus('[No Name]','plaintext')}
}

async function switchTab(path){
  if(path===currentFile)return;
  if(currentFile&&editor){try{await rpc('file/save',{path:currentFile,content:editor.getValue()})}catch{}}
  try{
    const res=await rpc('file/open',{path});
    if(res?.content!==undefined){
      const monaco=window.monaco;
      const uri=monaco.Uri.parse('file://'+path);
      let model=monaco.editor.getModel(uri);
      if(!model)model=monaco.editor.createModel(res.content,res.language||'plaintext',uri);
      editor.setModel(model);currentFile=path;
      const tab=tabs.find(t=>t.path===path);if(tab)tab.dirty=false;
      renderTabs();updateStatus(path.split('/').pop(),res.language||'plaintext');
      setTimeout(pullDiagnostics,500);
    }
  }catch(e){notify('Switch failed: '+e.message,'error')}
}

function updateStatus(file,lang){
  document.getElementById('status-file').textContent=file;
  document.getElementById('status-lang').textContent=lang;
}

/* === Editor setup === */
const MONACO_BASE = 'https://cdn.jsdelivr.net/npm/monaco-editor@0.55.0/min/vs';
require.config({paths:{vs:MONACO_BASE}});
window.MonacoEnvironment = {
  getWorkerUrl: function (moduleId, label) {
    const workerUrlMap = {
      json: '/language/json/json.worker.js',
      css: '/language/css/css.worker.js',
      html: '/language/html/html.worker.js',
      typescript: '/language/typescript/ts.worker.js',
      javascript: '/language/typescript/ts.worker.js'
    };
    const path = workerUrlMap[label] || '/editor/editor.worker.js';
    const url = MONACO_BASE + path;
    return `data:text/javascript;charset=utf-8,${encodeURIComponent(`importScripts('${url}');`)}`;
  }
};
require(['vs/editor/editor.main'],()=>{
  const monaco=window.monaco;
  monaco.editor.defineTheme('wizp-dark',{
    base:'vs-dark',inherit:true,
    rules:[
      {token:'comment',foreground:'6A9955'},{token:'keyword',foreground:'569CD6'},
      {token:'string',foreground:'CE9178'},{token:'number',foreground:'B5CEA8'},
      {token:'type',foreground:'4EC9B0'},{token:'function',foreground:'DCDCAA'},
      {token:'variable',foreground:'9CDCFE'},
    ],
    colors:{'editor.background':'#1E1E1E','editor.foreground':'#D4D4D4','editor.lineHighlightBackground':'#2A2D2E','editor.selectionBackground':'#264F78','editorCursor.foreground':'#FFFFFF','editorLineNumber.foreground':'#858585'}
  });

  editor=monaco.editor.create(document.getElementById('editor'),{
    value:'// WIZP Editor — ready.\n',language:'plaintext',theme:'wizp-dark',
    fontSize:14,fontFamily:"'JetBrains Mono','Fira Code',monospace",
    minimap:{enabled:true},scrollBeyondLastLine:false,automaticLayout:true,
    tabSize:4,folding:true,bracketPairColorization:{enabled:true},
  });

  // LSP completion
  monaco.languages.registerCompletionItemProvider('*',{
    triggerCharacters:['.',':',' '],
    async provideCompletionItems(model,position){
      try{const r=await rpc('lsp/completion',{uri:'file://'+currentFile,line:position.lineNumber-1,col:position.column-1});
      if(r?.items){const items=JSON.parse(r.items);return {suggestions:items.map(i=>({label:i.label,kind:i.kind||1,detail:i.detail,insertText:i.insertText||i.label,range:{startLineNumber:position.lineNumber,startColumn:position.column,endLineNumber:position.lineNumber,endColumn:position.column}}))}}}catch{}
      return {suggestions:[]};
    }
  });

  // Hover
  monaco.languages.registerHoverProvider('*',{
    async provideHover(model,position){
      try{const r=await rpc('lsp/hover',{uri:'file://'+currentFile,line:position.lineNumber-1,col:position.column-1});
      if(r?.text)return {contents:[{value:r.text}]}}catch{}
      return null;
    }
  });

  // Diagnostics polling
  let diagTimer;
  async function pullDiagnostics(){
    if(!currentFile)return;
    try{
      const r=await rpc('lsp/diagnostics',{uri:'file://'+currentFile});
      if(r?.diagnostics){
        const diags=typeof r.diagnostics==='string'?JSON.parse(r.diagnostics):r.diagnostics;
        const model=editor.getModel();
        if(model){
          monaco.editor.setModelMarkers(model,'lsp',diags.map(d=>({
            severity:d.severity===1?monaco.MarkerSeverity.Error:d.severity===2?monaco.MarkerSeverity.Warning:d.severity===3?monaco.MarkerSeverity.Info:monaco.MarkerSeverity.Hint,
            startLineNumber:d.range?.start?.line||d.line||1,startColumn:d.range?.start?.character||d.col||1,
            endLineNumber:d.range?.end?.line||d.line||1,endColumn:d.range?.end?.character||(d.col||1)+1,
            message:d.message||'',source:d.source||'LSP',
          })));
          const el=document.getElementById('status-diag');
          if(el)el.textContent=diags.length>0?'⚠ '+diags.length:'✔ 0';
        }
      }
    }catch{}
  }
  editor.onDidChangeModelContent(()=>{clearTimeout(diagTimer);diagTimer=setTimeout(pullDiagnostics,800)});

  // Keybindings
  editor.addCommand(monaco.KeyMod.CtrlCmd|monaco.KeyCode.KeyS,saveFile);
  editor.addCommand(monaco.KeyMod.CtrlCmd|monaco.KeyCode.KeyW,()=>{if(currentFile)closeTab(currentFile)});
  editor.addCommand(monaco.KeyMod.CtrlCmd|monaco.KeyCode.Tab,()=>{
    const idx=tabs.findIndex(t=>t.path===currentFile);
    const next=tabs[(idx+1)%tabs.length];if(next)switchTab(next.path);
  });

  document.getElementById('btn-term').onclick=toggleTerminal;
  refreshFt();
  notify('WIZP Editor ready','info');
});

async function openFile(path){
  if(!path){
    const btn=document.getElementById('btn-term');
    inlineInput(btn||document.body,'Open file path',p=>{if(p)openFile(p)});
    return;
  }
  try{
    const res=await rpc('file/open',{path});
    if(res?.content!==undefined){
      const monaco=window.monaco;
      const uri=monaco.Uri.parse('file://'+path);
      let model=monaco.editor.getModel(uri);
      if(!model)model=monaco.editor.createModel(res.content,res.language||'plaintext',uri);
      else model.setValue(res.content);
      editor.setModel(model);currentFile=path;addTab(path);
      updateStatus(path.split('/').pop(),res.language||'plaintext');
      setTimeout(pullDiagnostics,500);
    }
  }catch(e){notify('Open failed: '+e.message,'error')}
}

async function saveFile(){
  if(!currentFile){notify('No file open','warn');return}
  try{
    await rpc('file/save',{path:currentFile,content:editor.getValue()});
    const tab=tabs.find(t=>t.path===currentFile);if(tab)tab.dirty=false;
    renderTabs();notify('Saved: '+currentFile.split('/').pop(),'info');
  }catch(e){notify('Save failed: '+e.message,'error')}
}

let termVisible=false;
function toggleTerminal(){
  termVisible=!termVisible;
  document.getElementById('panel').classList.toggle('active',termVisible);
  document.getElementById('btn-term').style.fontWeight=termVisible?'bold':'normal';
}

/* === Settings Panel === */
function toggleSettings(){
  const existing=document.getElementById('wizp-settings');
  if(existing){existing.remove();return}
  const p=document.createElement('div');p.id='wizp-settings';
  p.style.cssText='position:fixed;left:50%;top:50%;transform:translate(-50%,-50%);width:480px;max-width:90vw;max-height:80vh;background:#1e1e1e;border:1px solid #3c3c3c;border-radius:6px;z-index:200;box-shadow:0 8px 24px rgba(0,0,0,.5);overflow-y:auto;';
  p.innerHTML=`<div style="padding:12px;border-bottom:1px solid #3c3c3c;display:flex;justify-content:space-between;align-items:center">
    <b style="color:#ccc">Settings</b><button id="wizp-set-close" style="background:none;border:none;color:#888;cursor:pointer;font-size:16px">✕</button></div>
  <div style="padding:12px">
    <div style="margin-bottom:12px"><label style="color:#ccc;font-size:12px;display:block;margin-bottom:4px">Theme</label>
    <select id="set-theme" style="width:100%;padding:6px;background:#3c3c3c;border:1px solid #555;color:#ccc;border-radius:4px">
      <option value="wizp-dark">WIZP Dark</option><option value="vs-dark">VS Dark</option><option value="vs">VS Light</option><option value="hc-black">High Contrast</option></select></div>
    <div style="margin-bottom:12px"><label style="color:#ccc;font-size:12px;display:block;margin-bottom:4px">Font Size</label>
    <input id="set-fontsize" type="number" value="14" min="8" max="40" style="width:100%;padding:6px;background:#3c3c3c;border:1px solid #555;color:#ccc;border-radius:4px"></div>
    <div style="margin-bottom:12px"><label style="color:#ccc;font-size:12px;display:block;margin-bottom:4px">Tab Size</label>
    <input id="set-tabsize" type="number" value="4" min="1" max="16" style="width:100%;padding:6px;background:#3c3c3c;border:1px solid #555;color:#ccc;border-radius:4px"></div>
    <div style="margin-bottom:12px"><label style="color:#ccc;font-size:12px;display:flex;align-items:center;gap:8px">
    <input id="set-minimap" type="checkbox" checked style="accent-color:#0e639c"> Minimap</label></div>
    <div style="border-top:1px solid #3c3c3c;padding-top:12px;display:flex;gap:8px">
    <button id="set-save" style="padding:6px 16px;background:#0e639c;color:#fff;border:none;border-radius:3px;cursor:pointer;flex:1">Save</button>
    <button id="set-reset" style="padding:6px 16px;background:#444;color:#ccc;border:none;border-radius:3px;cursor:pointer">Reset</button></div></div>`;
  document.body.appendChild(p);
  document.getElementById('wizp-set-close').onclick=()=>p.remove();
  document.getElementById('set-save').onclick=()=>{
    const theme=document.getElementById('set-theme').value;
    const fs=parseInt(document.getElementById('set-fontsize').value)||14;
    const ts=parseInt(document.getElementById('set-tabsize').value)||4;
    const mm=document.getElementById('set-minimap').checked;
    window.monaco?.editor.setTheme(theme);
    editor?.updateOptions({fontSize:fs,tabSize:ts,minimap:{enabled:mm}});
    localStorage.setItem('wizp-settings',JSON.stringify({theme,fs,ts,mm}));
    notify('Settings saved','info');p.remove();
  };
  document.getElementById('set-reset').onclick=()=>{localStorage.removeItem('wizp-settings');notify('Reset — reload to apply','info');p.remove()};
  try{const s=JSON.parse(localStorage.getItem('wizp-settings')||'{}');
  if(s.theme)document.getElementById('set-theme').value=s.theme;
  if(s.fs)document.getElementById('set-fontsize').value=s.fs;
  if(s.ts)document.getElementById('set-tabsize').value=s.ts;
  if(s.mm!==undefined)document.getElementById('set-minimap').checked=s.mm;}catch{}
}

/* === Plugin Marketplace === */
function togglePlugins(){
  const existing=document.getElementById('wizp-plugins');
  if(existing){existing.remove();return}
  const p=document.createElement('div');p.id='wizp-plugins';
  p.style.cssText='position:fixed;right:0;top:0;width:340px;height:100%;background:#1e1e1e;border-left:1px solid #3c3c3c;z-index:200;overflow-y:auto;padding:12px;';
  p.innerHTML=`<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
    <b style="color:#ccc">Plugin Hub</b><button id="wizp-plug-close" style="background:none;border:none;color:#888;cursor:pointer;font-size:16px">✕</button></div>
    <input id="plug-search" type="text" placeholder="Search OpenVSX..." style="width:100%;padding:6px 8px;background:#3c3c3c;border:1px solid #555;color:#ccc;border-radius:4px;margin-bottom:8px">
    <div id="plug-results" style="font-size:12px"></div>`;
  document.body.appendChild(p);
  document.getElementById('wizp-plug-close').onclick=()=>p.remove();
  let timer;
  document.getElementById('plug-search').oninput=e=>{
    clearTimeout(timer);timer=setTimeout(async()=>{
      const q=e.target.value;if(q.length<2)return;
      try{
        const res=await fetch(`https://open-vsx.org/api/-/search?query=${encodeURIComponent(q)}&size=10&sortBy=relevance`);
        const data=await res.json();
        const el=document.getElementById('plug-results');
        el.innerHTML=(data.extensions||[]).map(ext=>`
          <div style="padding:8px 4px;border-bottom:1px solid #333;display:flex;align-items:flex-start;gap:8px">
            ${ext.files?.icon?`<img src="https://open-vsx.org/api/${ext.namespace}/${ext.name}/${ext.version}/file/${ext.files.icon}" width="24" height="24" style="border-radius:3px">`:'<div style="width:24px;height:24px;background:#444;border-radius:3px"></div>'}
            <div style="flex:1;min-width:0">
              <div style="color:#4fc1ff;font-weight:bold;font-size:12px">${ext.displayName||ext.name}</div>
              <div style="color:#888;font-size:10px">${ext.namespace}.${ext.name} • ${(ext.downloadCount||0).toLocaleString()} downloads</div>
              <div style="color:#666;font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${(ext.description||'').substring(0,80)}</div>
            </div>
            <button data-ns="${ext.namespace}" data-name="${ext.name}" style="padding:4px 10px;background:#0e639c;color:#fff;border:none;border-radius:3px;cursor:pointer;font-size:11px;white-space:nowrap">Details</button>
          </div>`).join('')||'<div style="color:#666;padding:10px">No results</div>';
        el.querySelectorAll('button').forEach(btn=>{
          btn.onclick=()=>{
            const ns=btn.dataset.ns,nm=btn.dataset.name;
            vscode.postMessage({type:'open-url',url:`https://open-vsx.org/extension/${ns}/${nm}`});
          };
        });
      }catch(e){notify('Search failed: '+e.message,'error')}
    },400);
  };
}

// Expose
window.wizpOpenFile=openFile;
window.wizpSaveFile=saveFile;
})();
