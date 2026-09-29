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
    assert(dirs[fs.getDir(p)],'Parent directory missing'); files[p]=''
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
local core=assert(hostLoadfile('lpm.lua'))('__lpm_test')
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
check('SHA-256 vectors',function()
    assert(core.sha256('')=='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
    assert(core.sha256('abc')=='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
    assert(core.sha256(string.rep('a',1000000))=='cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0')
end)
check('Safe parser, comments, escaping, roundtrip',function()
    local v=data.parse('-- hi\nreturn {name="a", -- comment\n ["key"]=false, items={1,2}, str="x\\n\\065"};')
    assert(v.str=='x\nA' and v.key==false and v.items[2]==2)
    local a={s='x\n"\\\0',v=false,n=3}; assert(data.parse(data.serialize(a)).s==a.s)
end)
check('Executable manifests and duplicate keys rejected',function()
    for _,s in ipairs({'return {a=os.getComputerID()}','while true do end','return {}; shell.run("x")','return {x=1,x=2}','return {x=function() end}','return {x=(1+2)}','return {x=nil}'}) do rejected(function() data.parse(s) end) end
end)
check('Semver caret/tilde/zero-major bounds',function()
    local s=core.semver.satisfies
    assert(s('1.9.0','^1.2.3') and not s('2.0.0','^1.2.3'))
    assert(s('0.2.9','^0.2.3') and not s('0.3.0','^0.2.3'))
    assert(s('0.0.3','^0.0.3') and not s('0.0.4','^0.0.3'))
    assert(s('1.2.9','~1.2.3') and not s('1.3.0','~1.2.3'))
    rejected(function() s('1.0.0','>=1.0.0') end)
end)
local tip=string.rep('a',40); local old=string.rep('b',40); local newest=string.rep('c',40)
local repository={github='test/packages',ref='main'}
local function raw(ref,p) return 'https://raw.githubusercontent.com/test/packages/'..ref..'/'..p end
responses['https://api.github.com/repos/test/packages/commits/main']='{"sha":"'..tip..'"}'
local function publish(n,v,ref,dependencies,code)
    responses[raw(ref,n..'/manifest.lua')]=data.serialize({manifestVersion=1,name=n,version=v,type='library',files={['src/init.lua']='init.lua'},dependencies=dependencies or {}})
    responses[raw(ref,n..'/src/init.lua')]=code or 'return {version="'..v..'"}'
end
local function index(n,vs) responses[raw(tip,n..'/index.lua')]=data.serialize({indexVersion=1,versions=vs}) end
local function setup(dependencies)
    files,dirs={}, {['']=true}; fs.makeDir('project')
    files['project/package.lua']=data.serialize({manifestVersion=1,name='project',version='0.1.0',type='application',entry='main.lua',repositories={default=repository},dependencies=dependencies or {}})
    files['project/main.lua']='local a=require("alpha"); return a.version, ...'
end
publish('alpha','1.0.0',old,{shared='^1.0.0'})
publish('alpha','2.0.0',newest,{shared='^2.0.0'})
publish('beta','1.0.0',tip,{shared='^1.0.0'})
publish('shared','1.0.0',old)
publish('shared','2.0.0',newest)
index('alpha',{['1.0.0']={ref=old},['2.0.0']={ref=newest}})
index('shared',{['1.0.0']={ref=old},['2.0.0']={ref=newest}})
check('Backtracking resolves transitive conflict',function()
    setup({alpha='*',beta='*'}); local l=core.install('project')
    assert(l.packages.alpha.version=='1.0.0' and l.packages.shared.version=='1.0.0')
    assert(core.verify('project')==3)
end)
check('Normal program resolves installed modules and forwards arguments',function()
    local version,arg=normalRun('project',{'hello'}); assert(version=='1.0.0' and arg=='hello')
end)
check('Normal program loads project-relative modules',function()
    files['project/helper.lua']='return {ok=true}'
    files['project/main.lua']='return require("helper").ok'
    assert(normalRun('project',{})==true)
    files['project/main.lua']='local a=require("alpha"); return a.version, ...'
end)
check('Locked reinstall pins commits and hashes',function()
    local before=#requests; core.install('project'); assert(#requests==before)
    local l=core.lock('project'); assert(l.packages.alpha.commit==old)
end)
check('Offline restoration and corruption detection',function()
    offline=true; core.install('project',nil,false,false,true)
    local p='project/.lpm/current/packages/alpha/init.lua'; local original=files[p]; files[p]='tampered'
    rejected(function() core.verify('project') end)
    rejected(function() core.install('project',nil,false,false,true) end)
    assert(files[p]=='tampered'); files[p]=original; offline=false
end)
check('Download mismatch preserves installed state',function()
    local p='project/.lpm/current/packages/alpha/init.lua'; local original=files[p]; files[p]=nil
    local url=raw(old,'alpha/src/init.lua'); local response=responses[url]; responses[url]='modified'
    local lock=files['project/.lpm/current/package.lock']; rejected(function() core.install('project') end)
    assert(files['project/.lpm/current/package.lock']==lock)
    responses[url]=response; files[p]=original
end)
check('Failed activation rolls back package and files',function()
    local before=files['project/package.lua']; local locked=files['project/.lpm/current/package.lock']
    failure='project/.lpm/current'; rejected(function() core.install('project','shared@1.0.0') end)
    assert(files['project/package.lua']==before and files['project/.lpm/current/package.lock']==locked)
    assert(not fs.exists('project/.lpm/transaction.lua'))
end)
check('Restart recovers interrupted transaction',function()
    local before=files['project/package.lua']; local locked=files['project/.lpm/current/package.lock']
    fs.move('project/.lpm/current','project/.lpm/previous')
    fs.move('project/package.lua','project/.lpm/previous-package.lua')
    files['project/.lpm/transaction.lua']=data.serialize({hadState=true,hadProject=true})
    fs.makeDir('project/.lpm/current'); files['project/package.lua']='partial'
    core.lock('project')
    assert(files['project/package.lua']==before and files['project/.lpm/current/package.lock']==locked)
end)
check('Add and remove direct dependency',function()
    core.install('project','shared@1.0.0'); assert(data.parse(files['project/package.lua']).dependencies.shared=='1.0.0')
    core.install('project','shared',false,true); assert(data.parse(files['project/package.lua']).dependencies.shared==nil)
    assert(core.lock('project').packages.shared) -- still required transitively
end)
check('Unsatisfiable resolution leaves project untouched',function()
    local before=files['project/package.lua']; rejected(function() core.install('project','shared@2.0.0') end)
    assert(files['project/package.lua']==before)
end)
check('Manifest-only repositories and module aliases',function()
    publish('plain','1.2.3',tip,{},'return {ok=true}')
    local m=data.parse(responses[raw(tip,'plain/manifest.lua')]); m.modules={utility='init.lua'}
    responses[raw(tip,'plain/manifest.lua')]=data.serialize(m)
    setup({plain='^1.0.0'}); core.install('project'); files['project/main.lua']='return require("utility").ok'
    assert(normalRun('project',{})==true)
end)
check('Traversal and target collisions rejected',function()
    local url=raw(tip,'plain/manifest.lua'); local original=responses[url]
    for _,mapping in ipairs({{['../outside']='x.lua'},{['safe.lua']='../outside'},{['a']='x',['b']='x/y'}}) do
        local m=data.parse(original); m.files=mapping; responses[url]=data.serialize(m); setup({plain='*'})
        rejected(function() core.install('project') end); assert(not fs.exists('outside'))
    end
    responses[url]=original
end)
check('Missing HTTP and stale lock errors',function()
    setup({plain='*'}); core.install('project'); local before=files['project/package.lua']
    local p=data.parse(before); p.dependencies.plain='2.0.0'; files['project/package.lua']=data.serialize(p)
    rejected(function() core.install('project') end)
    files['project/package.lua']=before; local saved=http; http=nil
    rejected(function() core.install('project',nil,true) end); http=saved
end)
check('Installed application entry and arguments',function()
    local n='tool'; publish(n,'1.0.0',tip,{},'return ...')
    local m=data.parse(responses[raw(tip,n..'/manifest.lua')]); m.type='application'; m.entry='init.lua'
    responses[raw(tip,n..'/manifest.lua')]=data.serialize(m)
    setup({tool='*'}); core.install('project'); assert(normalRun('project',{'argument'},'tool')=='argument')
end)
check('CLI init, install, list, verify and failure exit',function()
    files,dirs={}, {['']=true}; fs.makeDir('project')
    printError=function(s) end
    local cli=assert(hostLoadfile('lpm.lua'))
    cli('init'); cli('repo','test/packages','main'); cli('install','tool'); cli('list'); cli('verify'); assert(normalRun('project',{'argument'},'tool')=='argument')
    rejected(function() cli('install','missing') end)
end)
check('Existing project files are never overwritten',function()
 setup({alpha='1.0.0'})
 files['project/alpha.lua']='user data'
 rejected(function() core.install('project') end)
 assert(files['project/alpha.lua']=='user data' and not fs.exists('project/.lpm/current'))
end)
check('Edited generated loaders are protected',function()
 setup({alpha='1.0.0'}); core.install('project')
 files['project/alpha.lua']='edited'
 rejected(function() core.install('project') end)
 assert(files['project/alpha.lua']=='edited')
end)
check('Failed module export restores old loaders',function()
 setup({alpha='1.0.0'}); core.install('project')
 local before=files['project/alpha.lua']; local locked=files['project/.lpm/current/package.lock']
 writeFailure='project/alpha.lua'; rejected(function() core.install('project') end)
 assert(files['project/alpha.lua']==before and files['project/.lpm/current/package.lock']==locked)
end)
check('Removing dependencies cleans only managed loaders',function()
 setup({plain='*'}); core.install('project'); files['project/unrelated.lua']='mine'
 core.install('project','plain',false,true)
 assert(not fs.exists('project/plain.lua') and not fs.exists('project/utility.lua'))
 assert(files['project/unrelated.lua']=='mine')
end)
check('Setup installs the bare command and persistent shell path',function()
 files['lpm.lua']='-- LPM test bundle'
 core.setup(); assert(files['bin/lpm.lua']==files['lpm.lua'])
 assert(shell.path():find('/bin:',1,true)==1)
 shellPath='.:/rom/programs'; assert(load(files['startup/lpm-path.lua']))()
 assert(shell.path():find('/bin:',1,true)==1)
 rejected(function() assert(hostLoadfile('lpm.lua'))('run') end)
end)
print(tests..' test groups passed')
