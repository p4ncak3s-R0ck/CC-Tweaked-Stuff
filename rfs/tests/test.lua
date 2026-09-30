-- Lua 5.2 CC:Tweaked simulation: filesystem, HTTP, module loader, and shell.
local files,dirs,responses={}, {['']=true}, {}
local requests={}
local offline=false
local failure
local writeFailure
local function norm(p) return (p:gsub('^/+',''):gsub('/+$','')) end
fs={}
function fs.combine(a,b) return norm(a=='' and b or a..'/'..b) end
function fs.getDir(p) return p:match('^(.*)/[^/]+$') or '' end
function fs.getName(p) return p:match('([^/]+)$') or '' end
function fs.exists(p) p=norm(p); return files[p]~=nil or dirs[p]~=nil end
function fs.isDir(p) return dirs[norm(p)]~=nil end
function fs.makeDir(p) p=norm(p); if p=='' then return end; fs.makeDir(fs.getDir(p)); assert(not files[p],'File blocks directory'); dirs[p]=true end
function fs.delete(p)
    p=norm(p); files[p]=nil; dirs[p]=nil
    for f in pairs(files) do if f:sub(1,#p+1)==p..'/' then files[f]=nil end end
    for d in pairs(dirs) do if d:sub(1,#p+1)==p..'/' then dirs[d]=nil end end
end
function fs.move(a,b)
    a,b=norm(a),norm(b)
    if failure and b==failure then failure=nil; error('Injected rename failure') end
    assert(fs.exists(a),'Missing move source '..a); assert(not fs.exists(b),'Move destination exists '..b)
    fs.makeDir(fs.getDir(b))
    if files[a] then files[b]=files[a]; files[a]=nil; return end
    local nf,nd={},{}
    for f,v in pairs(files) do if f:sub(1,#a+1)==a..'/' then nf[b..f:sub(#a+1)]=v end end
    for d in pairs(dirs) do if d==a or d:sub(1,#a+1)==a..'/' then nd[b..d:sub(#a+1)]=true end end
    fs.delete(a); for f,v in pairs(nf) do files[f]=v end; for d in pairs(nd) do dirs[d]=true end
end
function fs.open(p,mode)
    p=norm(p); local pos=1
    if mode:sub(1,1)=='r' then
        if files[p]==nil then return nil,'Not found '..p end
        return {readAll=function() return files[p] end,close=function() end}
    end
    if writeFailure==p then writeFailure=nil; error('Injected write failure') end
    assert(dirs[fs.getDir(p)],'Parent directory missing'); if mode:sub(1,1)~='a' then files[p]='' end
    return {write=function(s) files[p]=files[p]..s end, close=function() end}
end
http={get=function(o)
    requests[#requests+1]=o.url
    if offline then return nil,'Network disabled' end
    local s=responses[o.url]
    if s==nil then return nil,'HTTP 404',{getResponseCode=function() return 404 end,close=function() end} end
    local pos=1
    return {read=function(n) if pos>#s then return nil end; local b=s:sub(pos,pos+n-1); pos=pos+#b; return b end,close=function() end}
end}
textutils={unserializeJSON=function(s) return {sha=s:match('"sha":"([^"]+)"')} end}
local shellPath='.:/rom/programs'
shell={dir=function() return 'project' end,path=function() return shellPath end,setPath=function(p) shellPath=p end,getRunningProgram=function() return 'lpm.lua' end}
local hostLoadfile=loadfile
function loadfile(p,mode,env)
    if files[norm(p)] then return load(files[norm(p)],'@'..p,mode,env) end
    return hostLoadfile(p,mode,env)
end
local hostRequire=require
function require(n)
    if n=='cc.expect' then return {expect=function(i,v,...) return v end} end
    if n~='cc.require' then return hostRequire(n) end
    if realRequireSource then return assert(load(realRequireSource,'@cc.require','t',_G))() end
    return {make=function(env,root)
        local pkg={path='?.lua;?/init.lua',loaded={},preload={}}
        local function req(mod)
            if pkg.loaded[mod]~=nil then return pkg.loaded[mod] end
            local fn=pkg.preload[mod]
            if not fn then
                for pattern in pkg.path:gmatch('[^;]+') do
                    local candidate=pattern:gsub('%?',(mod:gsub('%.','/')))
                    if candidate:sub(1,1)~='/' then candidate=fs.combine(root,candidate) end
                    if files[norm(candidate)] then fn=assert(loadfile(candidate,'t',env)); break end
                end
            end
            assert(fn,'Module not found '..mod); local v=fn(mod); if v==nil then v=true end; pkg.loaded[mod]=v; return v
        end
        return req,pkg
    end}
end
local core=assert(hostLoadfile('lpm/lpm.lua'))('__lpm_test')
local data=core.data
local function normalRun(root,args,packageName)
    local env=setmetatable({}, {__index=_G}); env._G=env
    env.require,env.package=require('cc.require').make(env,root)
    local file=packageName and (packageName..'.lua') or 'main.lua'
    return assert(loadfile(fs.combine(root,file),'t',env))(table.unpack(args or {}))
end
local tests=0
local function check(label,fn)
    fn(); tests=tests+1; print('PASS '..label)
end
local function rejected(fn)
    local ok=pcall(fn); assert(not ok,'Expected rejection')
end

textutils.serializeJSON=data.serialize
local originalJSON=textutils.unserializeJSON
textutils.unserializeJSON=function(s) if s:sub(1,1)=='{' then return originalJSON(s) end; return data.parse(s) end

function fs.getSize(p) return #(assert(files[norm(p)])) end
function fs.list(p)
    p=norm(p); local prefix=p=='' and '' or p..'/'
    local found={}
    for k in pairs(files) do if k:sub(1,#prefix)==prefix then local rel=k:sub(#prefix+1); if not rel:find('/',1,true) then found[rel]=true end end end
    for k in pairs(dirs) do if k~=p and k:sub(1,#prefix)==prefix then local rel=k:sub(#prefix+1); if not rel:find('/',1,true) then found[rel]=true end end end
    local out={}; for k in pairs(found) do out[#out+1]=k end; table.sort(out); return out
end
local now,computer=1000000,42
os.epoch=function() return now*1000 end
os.getComputerID=function() return computer end
local rfs
local tip=string.rep('a',40)
local repository={github='test/packages',ref='main'}
responses['https://api.github.com/repos/test/packages/commits/main']='{"sha":"'..tip..'"}'
local function publishPackage(name)
    local manifest=assert(hostLoadfile(name..'/manifest.lua'))()
    local base='https://raw.githubusercontent.com/test/packages/'..tip..'/'..name..'/'
    responses[base..'manifest.lua']=data.serialize(manifest)
    for source in pairs(manifest.files) do
        local h=assert(io.open(name..'/'..source,'rb')); responses[base..source]=h:read('*a'); h:close()
    end
end
check('Real LPM installation, transitive dependencies, require and direct commands',function()
    for _,name in ipairs({'rfs','rfs-client','rfs-server'}) do publishPackage(name) end
    fs.makeDir('project'); files['project/package.lua']=data.serialize({manifestVersion=1,name='project',version='0.1.0',repositories={default=repository},dependencies={['rfs-client']='*',['rfs-server']='*'}})
    local lock=core.install('project'); assert(lock.packages.rfs and core.verify('project')==6)
    files['project/main.lua']='return require("rfs")'
    rfs=normalRun('project'); assert(rfs.version=='0.1.0')
    normalRun('project',{'--help'},'rfs-client'); normalRun('project',{'--help'},'rfs-server')
end)
local secret=string.rep('a',64)
local config={state='/private',shares={public={root='/shared',public=true},restricted={root='/restricted',public=false}},tokens={owner={secret=secret,admin=true,permissions={{share='public',prefix='',operations={read=true,list=true,watch=true,write=true,delete=true}},{share='restricted',prefix='',operations={read=true,list=true,watch=true,write=true,delete=true}}}}}}
local server
computer=7; server=rfs.server(config); computer=42
local drop,alter=false,false
local function transport(_,packet)
    local body=hostRequire('rfs_crypto').decode(packet.payload)
    if body.op=='grant' then assert(body.args.secret==nil) end
    local p=server:handle(42,packet)
    if p then p=hostRequire("rfs_crypto").clone(p) end
    if drop then drop=false; return nil end
    if alter and p then alter=false; p.payload=p.payload..'X' end
    return p
end
local owner=rfs.connect(7,{token='owner',secret=secret,transport=transport,chunk=256})
local public=rfs.connect('7',{transport=transport,chunk=256})
local function put(p,s) fs.makeDir(fs.getDir(p)); files[norm(p)]=s end
local function ok(value,e,code) assert(value,tostring(code)..': '..tostring(e)); return value end
local bytes=string.rep('binary\0\255',200)
check('ID connections, optional DNS adapter, discovery metadata',function()
    assert(ok(public:hello()).server==7)
    local client=rfs.connect('files.example',{resolve=function(name) assert(name=='files.example'); return 7 end,transport=transport})
    assert(ok(client:hello()).version==1)
    rejected(function() rfs.connect('files.example',{transport=transport}) end)
end)
check('Binary chunk upload/download, progress, range reads',function()
    put('local/source',bytes); local progress=0
    local v=ok(owner:upload('public','binary.dat','local/source',{expected=false,progress=function(p) progress=p.bytes end}))
    assert(v.hash==rfs.hash(bytes) and progress==#bytes)
    ok(public:download('public','binary.dat','local/out',{progress=function(p) progress=p.bytes end}))
    assert(files['local/out']==bytes and progress==#bytes)
    assert(ok(public:readRange('public','binary.dat',17,900))==bytes:sub(18,917))
end)
check('Missing response retries mutate only once',function()
    local revision=ok(owner:stat('public','binary.dat')).revision
    drop=true; ok(owner:restore('public','binary.dat',revision))
    local history=ok(owner:history('public','binary.dat')); assert(#history==2)
end)
check('Public write rejection, private share rejection and path confinement',function()
    local result,_,code=public:upload('public','blocked','local/source'); assert(not result and code=='ACCESS_DENIED')
    result,_,code=public:stat('restricted','secret'); assert(not result and code=='ACCESS_DENIED')
    for _,p in ipairs({'../private/index.json','/private/index.json','a/../../b','a\\b','binary.dat.rfs-old'}) do
        result,_,code=owner:stat('public',p); assert(not result and code=='BAD_PATH')
    end
end)
check('Response authentication rejects tampering and retries safely',function()
    alter=true; assert(ok(owner:hello()).version==1)
    local wrong=rfs.connect(7,{token='owner',secret=string.rep('b',64),transport=transport,retries=1})
    local r,_,code=wrong:hello(); assert(not r and code=='TIMEOUT')
end)
check('Conditional reads, immutable snapshots, revision conflict',function()
    local first=ok(owner:stat('public','binary.dat'))
    assert(ok(owner:stat('public','binary.dat',{ifRevision=first.revision})).notModified)
    local t=ok(owner:request('open',{share='public',path='binary.dat',chunk=256}))
    put('local/new','changed'); ok(owner:upload('public','binary.dat','local/new',{expected=first.revision}))
    local chunk=ok(owner:request('read',{transfer=t.transfer,offset=0,length=256})); assert(chunk.data==bytes:sub(1,256))
    local r,_,code=owner:upload('public','binary.dat','local/source',{expected=first.revision}); assert(not r and code=='REVISION_CHANGED')
    ok(owner:download('public','binary.dat','local/old',{revision=first.revision})); assert(files['local/old']==bytes)
end)
check('Interrupted download resumes and validates local checkpoint',function()
    local calls=0
    local r,_,code=public:download('public','binary.dat','local/resume',{revision='1-'..rfs.hash(bytes),cancelled=function() calls=calls+1; return calls==3 end})
    assert(not r and code=='CANCELLED' and #files['local/resume.rfs-part']==512)
    ok(public:download('public','binary.dat','local/resume',{revision='1-'..rfs.hash(bytes)})); assert(files['local/resume']==bytes)
    assert(not fs.exists('local/resume.rfs-resume.json'))
end)
check('Cancellation releases transfer; transfer TTL expires',function()
    local t=ok(owner:request('open',{share='public',path='binary.dat'})); ok(owner:cancel(t.transfer))
    local r,_,code=owner:request('read',{transfer=t.transfer,offset=0}); assert(not r and code=='TRANSFER_EXPIRED')
    t=ok(owner:request('open',{share='public',path='binary.dat'})); now=now+121
    r,_,code=owner:request('read',{transfer=t.transfer,offset=0}); assert(not r and code=='TRANSFER_EXPIRED')
end)
check('Directory listings, batches, recursive download and sync',function()
    ok(owner:mkdir('public','folder')); ok(owner:upload('public','folder/item','local/source'))
    local batch=ok(public:batch({{op='stat',args={share='public',path='folder/item'}},{op='stat',args={share='public',path='missing'}}}))
    assert(batch.results[1].ok and not batch.results[2].ok)
    public:downloadTree('public','folder','local/tree'); assert(files['local/tree/item']==bytes)
    put('local/tree/keep','keep'); local report=public:sync('public','folder','local/tree')
    assert(#report.unchanged==1 and files['local/tree/keep']=='keep')
    report=public:sync('public','folder','local/tree',{delete=true}); assert(#report.deleted==1)
    put('local/tree/nested/new','new'); owner:sync('public','folder','local/tree',{direction='upload'})
    assert(files['shared/folder/nested/new']=='new')
end)
check('Watch notification, change cursor and missed-event detection',function()
    local w=ok(owner:watch('public','folder'))
    ok(owner:upload('public','folder/notify','local/source'))
    local changes=ok(owner:changes('public','folder',w.sequence)); assert(#changes.events==1)
    local found=false; for _,notice in ipairs(server.outbox) do if notice.body.watch==w.watch then found=true end end; assert(found)
    ok(owner:unwatch(w.watch))
    local old=server.index.sequence; server.index.sequence=old+300; server.index.events={{sequence=old+299,share='public',path='folder',kind='changed'}}
    assert(ok(owner:changes('public','folder',old)).gap)
end)
check('Expiring delegated tokens, scope limits, revocation; no secret on wire',function()
    local credentials=ok(owner:grant('reader',now+60,{{share='public',prefix='folder',operations={read=true,list=true}}}))
    local reader=rfs.connect(7,{token=credentials.token,secret=credentials.secret,transport=transport})
    assert(ok(reader:stat('public','folder/item')).hash==rfs.hash(bytes))
    local r,_,code=reader:stat('public','binary.dat'); assert(not r and code=='ACCESS_DENIED')
    r,_,code=reader:upload('public','folder/evil','local/source'); assert(not r and code=='ACCESS_DENIED')
    now=now+61; r,_,code=reader:hello(); assert(not r and code=='TIMEOUT')
    credentials=ok(owner:grant('reader2',now+60,{{share='public',prefix='',operations={read=true}}}))
    ok(owner:revoke('reader2')); reader=rfs.connect(7,{token='reader2',secret=credentials.secret,transport=transport,retries=1})
    assert(not reader:hello())
end)
check('Mirror hash matching and signature verification fail closed',function()
    local options={transport=transport}
    local r,_,code=rfs.downloadMirrors({7},'public','binary.dat','local/mirror',rfs.hash('wrong'),options); assert(not r and code=='MIRRORS_FAILED')
    ok(rfs.downloadMirrors({7},'public','binary.dat','local/mirror',rfs.hash('changed'),options)); assert(files['local/mirror']=='changed')
    local crypto=hostRequire('rfs_crypto'); local payload=crypto.encode({files={{path='main.lua',hash=rfs.hash('x')}}})
    rejected(function() rfs.verifyRelease({payload=payload,signature='sig',keyId='publisher'},{publisher='key'}) end)
    rejected(function() rfs.verifyRelease({payload=payload,signature='bad',keyId='publisher'},{publisher='key'},function() return false end) end)
    assert(rfs.verifyRelease({payload=payload,signature='sig',keyId='publisher'},{publisher='key'},function(key,p,s) return key=='key' and p==payload and s=='sig' end).files[1].path=='main.lua')
end)
check('Move/delete retain history and restoration creates fresh revisions',function()
    ok(owner:move('public','folder/item','folder/moved')); assert(not fs.exists('shared/folder/item'))
    ok(owner:delete('public','folder/moved')); local history=ok(owner:history('public','folder/moved')); assert(history[#history].deleted)
    local restored=ok(owner:restore('public','folder/moved',history[1].revision)); assert(restored.revision~=history[1].revision and files['shared/folder/moved']==bytes)
end)
check('Server restart preserves revisions and delegated credentials',function()
    computer=7; local restarted=rfs.server(config); computer=42
    assert(#restarted.index.paths['public/folder/moved'].versions==3)
    assert(restarted.tokens.reader and not restarted.tokens.reader2)
end)
check('Recursive directory move/delete validates child permissions before mutation',function()
    ok(owner:mkdir('public','dirtree')); ok(owner:mkdir('public','dirtree/sub')); ok(owner:upload('public','dirtree/sub/file','local/source'))
    ok(owner:move('public','dirtree','relocated')); assert(files['shared/relocated/sub/file']==bytes)
    local r,_,code=owner:delete('public','relocated'); assert(not r and code=='DIRECTORY_NOT_EMPTY')
    ok(owner:delete('public','relocated',nil,true)); assert(not fs.exists('shared/relocated'))
    assert(ok(owner:history('public','relocated/sub/file'))[2].deleted)
end)
check('Native Rednet client path receives notifications and correlated replies',function()
    peripheral={getNames=function() return {'left'} end,getType=function() return 'modem' end}
    local queue={}
    rednet={open=function() end,send=function(peer,packet,protocol)
        assert(peer==7 and protocol==rfs.protocol)
        local reply=server:handle(42,packet)
        local crypto=hostRequire('rfs_crypto')
        local event={v=1,kind='event',token='',server=7,watch='fixture',event={sequence=1}}
        queue[#queue+1]={7,{payload=crypto.encode(event),mac=false,token=''}}
        queue[#queue+1]={7,crypto.clone(reply)}
        return true
    end,receive=function() local q=table.remove(queue,1); return q and q[1],q and q[2] end}
    local network=rfs.connect(7); assert(ok(network:hello()).server==7)
    assert(network:nextEvent(0).event.sequence==1)
end)
print(tests..' RFS checks passed')
