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
local sourceDefinitions=assert(hostLoadfile('official-repositories.lua'))()
local official=sourceDefinitions.official
local selfSource=sourceDefinitions.selfUpdate
local function otherPublish(r,n,v,dependencies)
    responses['https://api.github.com/repos/'..r.github..'/commits/'..r.ref]='{"sha":"'..tip..'"}'
    local prefix='https://raw.githubusercontent.com/'..r.github..'/'..tip..'/'..(r.path and r.path..'/' or '')..n..'/'
    responses[prefix..'manifest.lua']=data.serialize({manifestVersion=1,name=n,version=v,type='library',files={['main.lua']='init.lua'},dependencies=dependencies or {}})
    responses[prefix..'main.lua']='return {}'
end
check('New projects enable the built-in official repository',function()
    files,dirs={}, {['']=true}; fs.makeDir('project'); core.init('project')
    local sources,p=core.repositories('project')
    assert(#sources==1 and sources[1].name=='official' and p.defaultRepository=='official')
    otherPublish(official,'official-tool','1.0.0')
    local l=core.install('project','official-tool')
    assert(l.packages['official-tool'].repositoryName=='official')
end)
check('Automatic search resolves dependencies across repositories and subpaths',function()
    setup({private='*'})
    local extra={github='other/packages',ref='dev',path='packages'}
    otherPublish(extra,'private','1.0.0',{plain='*',['official-tool']='*'})
    core.configureRepository('project','add','extra',extra.github,extra.ref,extra.path)
    local l=core.install('project')
    assert(l.packages.private.repositoryName=='extra' and l.packages.plain.repositoryName=='default')
    assert(l.packages['official-tool'].repositoryName=='official')
    local before=#requests; core.install('project',nil,false,false,true); assert(#requests==before)
end)
check('Priority order and explicit pins resolve duplicate names deterministically',function()
    setup({plain='*'})
    otherPublish({github='other/packages',ref='main'},'plain','9.0.0')
    core.configureRepository('project','add','extra','other/packages')
    assert(core.install('project').packages.plain.version=='1.2.3')
    core.configureRepository('project','order',{'extra','default'})
    assert(core.install('project',nil,true).packages.plain.version=='9.0.0')
    core.configureRepository('project','use','plain','default')
    assert(core.install('project',nil,true).packages.plain.version=='1.2.3')
    core.configureRepository('project','unuse','plain')
    assert(core.install('project',nil,true).packages.plain.version=='9.0.0')
end)
check('Incompatible versions in the first source never select another publisher',function()
    setup({plain='9.0.0'})
    core.configureRepository('project','add','extra','other/packages')
    local before=files['project/package.lua']
    rejected(function() core.install('project') end)
    assert(files['project/package.lua']==before and not fs.exists('project/.lpm/current'))
end)
check('Pinned missing packages never fall through to other sources',function()
    setup({plain='*'}); core.configureRepository('project','use','plain','official')
    rejected(function() core.install('project') end)
end)
check('Repository validation preserves configuration on invalid edits',function()
    setup()
    local before=files['project/package.lua']
    for _,f in ipairs({
        function() core.configureRepository('project','add','official','evil/packages') end,
        function() core.configureRepository('project','add','extra','other/packages','main','../escape') end,
        function() core.configureRepository('project','default','unknown') end,
        function() core.configureRepository('project','order',{'default','default'}) end,
        function() core.configureRepository('project','use','plain','unknown') end,
    }) do rejected(f); assert(files['project/package.lua']==before) end
    core.configureRepository('project','use','plain','default')
    rejected(function() core.configureRepository('project','remove','default') end)
end)
check('Disable official source prevents requests; missing package reports failure',function()
    setup({missing='*'}); core.configureRepository('project','official','disable')
    local before=#requests
    rejected(function() core.install('project') end)
    for i=before+1,#requests do assert(not requests[i]:find(official.github,1,true)) end
    core.configureRepository('project','official','enable')
    assert(#core.repositories('project')==2)
end)
check('HTTP failures and malformed manifests do not trigger fallback',function()
    setup({plain='*'})
    local before=#requests; local saved=http.get
    http.get=function(o)
        if o.url==raw(tip,'plain/index.lua') then return nil,'HTTP 500',{getResponseCode=function() return 500 end,close=function() end} end
        return saved(o)
    end
    rejected(function() core.install('project') end); http.get=saved
    local url=raw(tip,'plain/manifest.lua'); local original=responses[url]; responses[url]='not a manifest'
    rejected(function() core.install('project') end); responses[url]=original
end)
check('CLI manages repositories and preserves legacy syntax',function()
    setup(); local cli=assert(hostLoadfile('lpm.lua'))
    cli('repo','add','extra','other/packages'); cli('repo','default','extra')
    cli('repo','order','extra','default'); cli('repo','use','plain','extra')
    cli('repo','list'); cli('repo','unuse','plain'); cli('repo','default','default')
    cli('repo','remove','extra'); cli('repo','official','disable'); cli('repo','official','enable')
    cli('repo','test/packages','main')
    assert(core.install('project','plain').packages.plain.repositoryName=='default')
end)
local remoteURL='https://cdn.example.com/code.lua?version=1&format=raw'
local helperURL='https://cdn.example.com:443/helpers.lua'
local remoteCode='return {remote=true}'
local function proxyManifest(mapping,hashes)
    return data.serialize({manifestVersion=1,name='proxy',version='1.0.0',type='library',
        files=mapping or {[remoteURL]='init.lua',[helperURL]='helper.lua',['local.lua']='local.lua'},
        hashes=hashes,modules={example='init.lua'},dependencies={plain='*'}})
end
responses[remoteURL]=remoteCode
responses[helperURL]='return {helper=true}'
responses[raw(tip,'proxy/local.lua')]='return {localFile=true}'
check('Official definitions live in a separate file and are bundled unchanged',function()
    local definitions=assert(hostLoadfile('official-repositories.lua'))()
    setup(); local sources=core.repositories('project')
    assert(data.serialize(sources[#sources].repository)==data.serialize(definitions.official))
end)
check('Proxy manifests mix HTTPS URLs, relative files, aliases and dependencies',function()
    responses[raw(tip,'proxy/manifest.lua')]=proxyManifest(nil,{[remoteURL]=core.sha256(remoteCode)})
    setup({proxy='*'}); local l=core.install('project')
    assert(l.packages.proxy.hashes['init.lua']==core.sha256(remoteCode))
    assert(l.packages.plain and files['project/.lpm/current/packages/proxy/local.lua'])
    files['project/main.lua']='return require("example").remote'
    assert(normalRun('project',{})==true and core.verify('project')==4)
    local before=#requests; offline=true
    core.install('project',nil,false,false,true); assert(#requests==before); offline=false
end)
check('Changed upstream proxy bytes fail locked restores and preserve state',function()
    local dest='project/.lpm/current/packages/proxy/init.lua'
    files[dest]=nil
    local locked=files['project/.lpm/current/package.lock']; local before=files['project/package.lua']
    responses[remoteURL]='changed upstream'
    rejected(function() core.install('project') end)
    assert(files['project/.lpm/current/package.lock']==locked and files['project/package.lua']==before)
    responses[remoteURL]=remoteCode; core.install('project')
    assert(files[dest]==remoteCode)
end)
check('Proxy publisher hashes and missing remote files fail before activation',function()
    for _,hash in ipairs({string.rep('0',64),core.sha256(remoteCode)}) do
        setup({proxy='*'}); responses[raw(tip,'proxy/manifest.lua')]=proxyManifest({[remoteURL]='init.lua'},{[remoteURL]=hash})
        local saved=responses[remoteURL]; if hash==core.sha256(remoteCode) then responses[remoteURL]=nil end
        rejected(function() core.install('project') end)
        assert(not fs.exists('project/.lpm/current')); responses[remoteURL]=saved
    end
end)
check('Unsafe URLs, remote destinations and duplicate targets are rejected',function()
    local invalid={'http://cdn.example.com/a.lua','file:///tmp/a.lua','https:///a.lua',
        'https://user:password@cdn.example.com/a.lua','https://cdn.example.com/a.lua#fragment',
        'https://cdn.example.com/a b.lua','https://cdn.example.com:0/a.lua','https://cdn.example.com:99999/a.lua',
        'https://cdn.example.com:/a.lua'}
    for _,src in ipairs(invalid) do
        setup({proxy='*'}); responses[raw(tip,'proxy/manifest.lua')]=proxyManifest({[src]='init.lua'})
        rejected(function() core.install('project') end); assert(not fs.exists('project/.lpm/current'))
    end
    for _,mapping in ipairs({{[remoteURL]='../escape.lua'},{[remoteURL]='https://example.com/out.lua'},
        {[remoteURL]='same.lua',[helperURL]='same.lua'}}) do
        setup({proxy='*'}); responses[raw(tip,'proxy/manifest.lua')]=proxyManifest(mapping)
        rejected(function() core.install('project') end)
    end
end)
check('Proxy downloads keep the existing file size limit',function()
    setup({proxy='*'}); responses[raw(tip,'proxy/manifest.lua')]=proxyManifest({[remoteURL]='init.lua'})
    responses[remoteURL]=string.rep('a',1048577)
    rejected(function() core.install('project') end); assert(not fs.exists('project/.lpm/current'))
    responses[remoteURL]=remoteCode
end)
local selfTip=string.rep('d',40)
local selfPrefix='https://raw.githubusercontent.com/'..selfSource.github..'/'..selfTip..'/'
local oldBundle='-- LPM 0.2.0. Generated by tools/build.py.\nreturn "old"\n'
local newBundle='-- LPM 0.2.0. Generated by tools/build.py.\nreturn "new"\n'
local function prepareSelf(bytes,version)
    files,dirs={}, {['']=true}; fs.makeDir('bin'); files['bin/lpm.lua']=oldBundle
    shell.getRunningProgram=function() return '/bin/lpm.lua' end
    responses['https://api.github.com/repos/'..selfSource.github..'/commits/main']='{"sha":"'..selfTip..'"}'
    responses[selfPrefix..'manifest.lua']=data.serialize({manifestVersion=1,name='lpm',version=version or '0.2.0',type='application',entry='lpm.lua',files={['lpm.lua']='lpm.lua'}})
    responses[selfPrefix..'lpm.lua']=bytes or newBundle
end
check('Self-update works without a project and backs up the invoked copy',function()
    prepareSelf(); local changed,v,pin=core.selfUpdate()
    assert(changed and v=='0.2.0' and pin==selfTip)
    assert(files['bin/lpm.lua']==newBundle and files['bin/lpm.lua.lpm-backup']==oldBundle)
    assert(not fs.exists('bin/lpm.lua.lpm-new') and not fs.exists('project/package.lua'))
    assert(not core.selfUpdate()) -- Identical downloads do not rewrite files or backups.
end)
check('Self-update accepts newer versions and rotates its managed backup',function()
    prepareSelf(); core.selfUpdate()
    local nextBundle='-- LPM 0.3.0. Generated by tools/build.py.\nreturn "next"\n'
    responses[selfPrefix..'lpm.lua']=nextBundle
    local m=data.parse(responses[selfPrefix..'manifest.lua']); m.version='0.3.0'; m.hashes={['lpm.lua']=core.sha256(nextBundle)}
    responses[selfPrefix..'manifest.lua']=data.serialize(m)
    local changed,v=core.selfUpdate()
    assert(changed and v=='0.3.0' and files['bin/lpm.lua']==nextBundle)
    assert(files['bin/lpm.lua.lpm-backup']==newBundle)
end)
check('Self-update validates syntax, identity, versions, hashes and HTTP failures',function()
    local cases={
        {bytes='not LPM'},
        {bytes='-- LPM 0.2.0. Generated by tools/build.py.\ninvalid ! lua'},
        {bytes=newBundle,version='0.3.0'},
        {bytes=oldBundle,version='0.1.0'},
        {bytes=newBundle,hash=string.rep('0',64)},
        {missing=true},
    }
    for _,case in ipairs(cases) do
        prepareSelf(case.bytes,case.version)
        if case.hash then
            local m=data.parse(responses[selfPrefix..'manifest.lua']); m.hashes={['lpm.lua']=case.hash}
            responses[selfPrefix..'manifest.lua']=data.serialize(m)
        end
        if case.missing then responses[selfPrefix..'lpm.lua']=nil end
        rejected(function() core.selfUpdate() end)
        assert(files['bin/lpm.lua']==oldBundle and not fs.exists('bin/lpm.lua.lpm-new'))
    end
end)
check('Self-update restores the original on staging and activation failures',function()
    prepareSelf(); writeFailure='bin/lpm.lua.lpm-new'
    rejected(function() core.selfUpdate() end); assert(files['bin/lpm.lua']==oldBundle)
    prepareSelf(); failure='bin/lpm.lua'
    rejected(function() core.selfUpdate() end)
    assert(files['bin/lpm.lua']==oldBundle and not fs.exists('bin/lpm.lua.lpm-new'))
end)
check('Self-update protects unrelated running scripts, staging and backup files',function()
    prepareSelf(); files['bin/lpm.lua']='my application'
    rejected(function() core.selfUpdate() end); assert(files['bin/lpm.lua']=='my application')
    for _,suffix in ipairs({'.lpm-new','.lpm-backup'}) do
        prepareSelf(); files['bin/lpm.lua'..suffix]='mine'
        rejected(function() core.selfUpdate() end)
        assert(files['bin/lpm.lua']==oldBundle and files['bin/lpm.lua'..suffix]=='mine')
    end
end)
check('Self-update accepts an explicit ref and never executes downloaded code',function()
    prepareSelf(); responses[selfPrefix..'lpm.lua']='-- LPM 0.2.0. Generated by tools/build.py.\nerror("DO NOT EXECUTE")\n'
    local cli=assert(hostLoadfile('lpm.lua'))
    cli('self-update',selfTip)
    assert(files['bin/lpm.lua']:find('DO NOT EXECUTE',1,true))
    rejected(function() cli('self-update','main','extra') end)
end)
local function hasLog(lines,fragment)
    for _,line in ipairs(lines) do if line:find(fragment,1,true) then return true end end
    return false
end
check('Install logs expose plans, real file progress, verification and reuse counts',function()
    setup({plain='*'}); local lines={}
    core.log.configure({level='debug',sink=function(level,line) lines[#lines+1]=line end})
    core.install('project')
    assert(hasLog(lines,'[INFO][Search] plain in default'))
    assert(hasLog(lines,'[INFO][Plan] Install plain 1.2.3'))
    assert(hasLog(lines,'[INFO][Download] (1/1) plain/init.lua'))
    assert(hasLog(lines,'[DEBUG][Verify] (1/1) plain/init.lua SHA-256 OK'))
    assert(hasLog(lines,'1 downloaded, 0 reused'))
    lines={}; core.install('project',nil,false,false,true)
    assert(hasLog(lines,'[INFO][Lock] Restoring exact versions'))
    assert(hasLog(lines,'0 downloaded, 1 reused'))
    assert(not hasLog(lines,'[INFO][Download]'))
    core.log.configure({level='error'})
end)
check('Failed activation logs rollback and never reports success',function()
    setup({plain='*'}); core.install('project'); local lines={}
    core.log.configure({level='info',sink=function(level,line) lines[#lines+1]=line end})
    failure='project/.lpm/current'; rejected(function() core.install('project') end)
    assert(hasLog(lines,'[WARN][Rollback]') and hasLog(lines,'[INFO][Recovery] Previous package state restored'))
    assert(not hasLog(lines,'[INFO][Done]'))
    core.log.configure({level='error'})
end)
check('Proxy URL diagnostics redact queries and credentials',function()
    assert(core.log.url('https://user:secret@example.com/a?token=secret')=='https://[redacted]@example.com/a?...')
    setup({proxy='*'}); responses[raw(tip,'proxy/manifest.lua')]=proxyManifest({[remoteURL]='init.lua'})
    local lines={}; core.log.configure({level='debug',sink=function(level,line) lines[#lines+1]=line end})
    core.install('project')
    assert(hasLog(lines,'[INFO][Download] (') and hasLog(lines,'(proxy)'))
    assert(hasLog(lines,'https://cdn.example.com/code.lua?...'))
    assert(not hasLog(lines,'version=1&format=raw'))
    core.log.configure({level='error'})
end)
check('A broken logging sink cannot interrupt package activation',function()
    setup({plain='*'}); core.log.configure({level='debug',sink=function() error('display failure') end})
    core.install('project'); assert(core.verify('project')==1)
    core.log.configure({level='error'})
end)
local function captureCLI(...)
    local output,errors={},{}
    local oldPrint,oldError=print,printError
    print=function(line) output[#output+1]=tostring(line) end
    printError=function(line) errors[#errors+1]=tostring(line) end
    local ok,problem=pcall(assert(hostLoadfile('lpm.lua')),...)
    print,printError=oldPrint,oldError
    return ok,output,errors,problem
end
check('CLI defaults to progress; verbose adds diagnostics and quiet preserves results',function()
    setup({plain='*'}); local ok,lines=captureCLI('install')
    assert(ok and hasLog(lines,'[INFO][Done]') and not hasLog(lines,'[DEBUG]'))
    ok,lines=captureCLI('--verbose','install','--offline')
    assert(ok and hasLog(lines,'[DEBUG][Cache]'))
    ok,lines=captureCLI('install','--offline','-q')
    assert(ok and #lines==0)
    ok,lines=captureCLI('-q','list')
    assert(ok and hasLog(lines,'plain 1.2.3'))
    local errors; ok,lines,errors=captureCLI('--quiet','install','plain@9.0.0')
    assert(not ok and #errors>0 and hasLog(errors,'[ERROR][Failed]'))
end)
local function standalone(n,kind,code,dependencies)
    return '--[=[lpm\n'..data.serialize({manifestVersion=1,name=n,version='1.0.0',type=kind,dependencies=dependencies or {}})..'\n]=]\n'..code
end
local soloURL=raw(tip,'solo.lua')
check('Standalone library installs from repository root without executing discovery code',function()
    setup({solo='*'})
    responses[soloURL]=standalone('solo','library','return {ok=true}')
    local before=#requests; local l=core.install('project')
    assert(l.packages.solo.base=='' and l.packages.solo.manifest.files['solo.lua']=='solo.lua')
    local downloads=0; for i=before+1,#requests do if requests[i]==soloURL then downloads=downloads+1 end end
    assert(downloads==1,'Standalone code was fetched more than once')
    files['project/main.lua']='return require("solo").ok'; assert(normalRun('project',{})==true)
    assert(core.verify('project')==1)
    before=#requests; core.install('project',nil,false,false,true); assert(#requests==before)
    core.lock('project') -- Empty root base remains valid on locked restores.
end)
check('Standalone applications support arguments, dependencies, repository paths and pins',function()
    setup({solo='*'}); core.configureRepository('project','add','nested','other/standalone','main','packages')
    core.configureRepository('project','use','solo','nested')
    responses['https://api.github.com/repos/other/standalone/commits/main']='{"sha":"'..tip..'"}'
    local url='https://raw.githubusercontent.com/other/standalone/'..tip..'/packages/solo.lua'
    responses[url]=standalone('solo','application','return ...',{plain='*'})
    local l=core.install('project'); assert(l.packages.solo.base=='packages' and l.packages.plain)
    assert(normalRun('project',{'argument'},'solo')=='argument')
    core.install('project',nil,false,false,true)
end)
check('Standalone corrupt files restore only from locked matching bytes',function()
    setup({solo='*'}); local bytes=standalone('solo','library','return {}'); responses[soloURL]=bytes
    core.install('project'); files['project/.lpm/current/packages/solo/solo.lua']='corrupt'
    rejected(function() core.install('project',nil,false,false,true) end)
    responses[soloURL]=bytes..'-- changed\n'
    rejected(function() core.install('project') end)
    responses[soloURL]=bytes; core.install('project'); assert(core.verify('project')==1)
end)
check('Malformed standalone metadata cannot run code or select other files',function()
    for _,bytes in ipairs({
        'error("not metadata")',
        '--[=[lpm\nreturn {name=os.getComputerID()}\n]=]\nreturn {}',
        standalone('different','library','return {}'),
        '--[=[lpm\nreturn {manifestVersion=1,name="solo",version="1.0.0",type="library",files={}}\n]=]\nreturn {}',
        '--[=[lpm\nreturn {manifestVersion=1,name="solo",version="1.0.0",type="library",hashes={}}\n]=]\nreturn {}',
        '--[=[lpm\nreturn {manifestVersion=1,name="solo",version="1.0.0",type="application",entry="../outside"}\n]=]\nreturn {}',
    }) do
        setup({solo='*'}); responses[soloURL]=bytes
        rejected(function() core.install('project') end); assert(not fs.exists('project/.lpm/current'))
    end
end)
check('Folder manifests take precedence over standalone files in the same source',function()
    setup({plain='*'}); responses[raw(tip,'plain.lua')]='malformed standalone'
    assert(core.install('project').packages.plain.version=='1.2.3')
end)
check('Standalone size limits and missing packages preserve existing project files',function()
    setup({solo='*'}); responses[soloURL]=string.rep('a',1048577)
    rejected(function() core.install('project') end); assert(not fs.exists('project/.lpm/current'))
    responses[soloURL]=nil; rejected(function() core.install('project') end)
end)
check('Root-level proxy manifests install without a directory',function()
    setup({rootproxy='*'})
    local url='https://upstream.example.com/module.lua'
    responses[url]='return {proxy=true}'
    responses[raw(tip,'rootproxy.lua')]=data.serialize({manifestVersion=1,name='rootproxy',version='1.0.0',type='library',files={[url]='init.lua'},dependencies={plain='*'}})
    local l=core.install('project'); assert(l.packages.rootproxy.base=='' and l.packages.plain)
    files['project/main.lua']='return require("rootproxy").proxy'; assert(normalRun('project',{})==true)
    local before=#requests; core.install('project',nil,false,false,true); assert(#requests==before)
end)
check('Legacy official configuration resolves new sources without rewriting metadata',function()
    setup({['official-tool']='*'})
    local p=data.parse(files['project/package.lua']); p.repositories={official={github='p4ncak3s-R0ck/CC-Tweaked-Stuff',ref='main'}}
    files['project/package.lua']=data.serialize(p)
    local l=core.install('project')
    assert(l.packages['official-tool'].repository.github==official.github)
    assert(data.parse(files['project/package.lua']).repositories.official.github=='p4ncak3s-R0ck/CC-Tweaked-Stuff')
    local before=#requests; core.install('project',nil,false,false,true); assert(#requests==before)
    assert(selfSource.github~=official.github,'Self-updates must remain independent of the package registry')
end)
check('Commit resolution requests SHA-only responses even for large commits',function()
    setup({plain='*'})
    local saved=http.get; local saw=false
    http.get=function(o)
        if o.url=='https://api.github.com/repos/test/packages/commits/main' then
            assert(o.headers.Accept=='application/vnd.github.sha','Commit lookup downloaded full JSON/diff')
            saw=true; local body=tip..'\n'; local sent=false
            return {read=function() if sent then return nil end; sent=true; return body end,close=function() end}
        end
        return saved(o)
    end
    local ok,problem=pcall(core.install,'project'); http.get=saved
    assert(ok,problem); assert(saw)
end)
check('Self-update checks the repository root before the legacy directory',function()
    prepareSelf()
    local rootPrefix='https://raw.githubusercontent.com/'..selfSource.github..'/'..selfTip..'/'
    responses[rootPrefix..'manifest.lua']=responses[selfPrefix..'manifest.lua']
    responses[rootPrefix..'lpm.lua']=newBundle
    local before=#requests
    assert(core.selfUpdate())
    for i=before+1,#requests do assert(requests[i]~=rootPrefix..'lpm/manifest.lua','Root update used the obsolete nested layout') end
    responses[rootPrefix..'manifest.lua']=nil; responses[rootPrefix..'lpm.lua']=nil
end)
check('Self-update supports explicitly selected historical nested layouts',function()
    prepareSelf()
    local nested=selfPrefix..'lpm/'
    responses[nested..'manifest.lua']=responses[selfPrefix..'manifest.lua']
    responses[nested..'lpm.lua']=newBundle
    responses[selfPrefix..'manifest.lua']=nil
    assert(core.selfUpdate(selfTip))
    assert(files['bin/lpm.lua']==newBundle)
    responses[nested..'manifest.lua']=nil; responses[nested..'lpm.lua']=nil
end)
check('Root self-update HTTP errors never fall through to stale nested metadata',function()
    prepareSelf(); local saved=http.get; local fallback=false
    http.get=function(o)
        if o.url==selfPrefix..'manifest.lua' then return nil,'HTTP 500',{getResponseCode=function() return 500 end,close=function() end} end
        if o.url==selfPrefix..'lpm/manifest.lua' then fallback=true end
        return saved(o)
    end
    local ok=pcall(core.selfUpdate); http.get=saved
    assert(not ok and not fallback and files['bin/lpm.lua']==oldBundle)
end)
print(tests..' test groups passed')
