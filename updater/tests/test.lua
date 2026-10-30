-- Appended to rfs/tests/test.lua to reuse its local CC filesystem and transport.
local updater=hostRequire('updater')
local U=hostRequire('rfs_common')
local dnsCalls={}
local dnsOffline=false
local dnsFixture={clearCache=function() end,lookupRecord=function(kind,name)
    dnsCalls[#dnsCalls+1]={kind,name}
    if dnsOffline then return nil,'offline' end
    if kind=='SRV' then
        assert(name=='update.server.pancakes')
        return {
            {value={target='primary.pancakes',protocol=rfs.protocol,priority=0,weight=10}},
            {value={target='backup.pancakes',protocol=rfs.protocol,priority=10,weight=1}},
        }
    end
    if name=='primary.pancakes' then return {{value=0},{value=8}} end
    return {{value=7}} -- Includes computer ID zero, which is valid.
end}
local configUpdate={dnsServer=42,path='meter.os.lua'}
local connectionOrder={}
local failDownload=false
local deps={dns=dnsFixture,random=function() return 1 end,connect=function(id)
    connectionOrder[#connectionOrder+1]=id
    if id==0 or id==8 then return {stat=function() return nil,'offline','TIMEOUT' end,
        download=function() return nil,'offline','TIMEOUT' end} end
    local c=rfs.connect(7,{transport=transport,chunk=256})
    if failDownload then c.download=function() return nil,'connection lost','TIMEOUT' end end
    return c
end}
local app=updater.new(configUpdate,deps)
local old='return "original"\n'
local new='return "updated"\n'
check('Updater LPM install, transitive DNS/RFS dependencies and command loader',function()
    for _,n in ipairs({'dns','updater','update'}) do publishPackage(n) end
    fs.makeDir('updater-project')
    put('updater-project/package.lua',data.serialize({manifestVersion=1,name='updater-project',version='0.1.0',repositories={default=repository},dependencies={update='*'}}))
    local lock=core.install('updater-project')
    assert(lock.packages.dns and lock.packages.rfs and lock.packages.updater and lock.packages.update)
    normalRun('updater-project',{'--help'},'update')
    put('updater-project/main.lua','return type(require("updater").open)')
    assert(normalRun('updater-project')=='function')
end)
check('SRV priority ordering, multiple ID records, failover and direct root install',function()
    put('shared/meter.os.lua',old)
    local candidate=app:check()
    assert(candidate.server==7 and candidate.changed)
    assert(table.concat(candidate.targets,',')=='0,8,7')
    assert(dnsCalls[1][1]=='SRV' and dnsCalls[1][2]=='update.server.pancakes')
    assert(app:apply(candidate)); assert(U.read('/meter.os.lua')==old)
    assert(not app:check().changed and not app:apply())
end)
check('Changed file replaces root and preserves previous bytes for rollback',function()
    put('shared/meter.os.lua',new)
    assert(app:poll()); assert(U.read('/meter.os.lua')==new)
    assert(U.read('/.updater/meter.os.lua/previous.lua')==old)
    assert(app:status().hash==rfs.hash(new))
end)
check('Rollback holds automatic updates, explicit pull resumes',function()
    app:rollback(); assert(U.read('/meter.os.lua')==old)
    dnsOffline=true; local changed,reason=app:poll(); assert(not changed and reason=='held'); dnsOffline=false
    assert(app:apply()); assert(U.read('/meter.os.lua')==new and not app:status().held)
end)
check('Network failure and malformed Lua preserve the working root file',function()
    put('shared/meter.os.lua','this is not lua ???')
    rejected(function() app:apply() end); assert(U.read('/meter.os.lua')==new)
    put('shared/meter.os.lua','return "next"')
    failDownload=true; rejected(function() app:apply() end); failDownload=false
    assert(U.read('/meter.os.lua')==new)
    dnsOffline=true; rejected(function() app:check() end); dnsOffline=false
    assert(U.read('/meter.os.lua')==new)
end)
check('Pinned hash rejects changed server content',function()
    local pinned=updater.new({dnsServer=42,hash=rfs.hash(new)},deps)
    rejected(function() pinned:check() end)
end)
check('Failed activation rename recovers current root and can retry',function()
    failure='meter.os.lua'
    rejected(function() app:apply() end)
    assert(U.read('/meter.os.lua')==new)
    assert(app:apply()); assert(U.read('/meter.os.lua')=='return "next"')
end)
check('Restart recovers a root file interrupted between rotation moves',function()
    fs.move('/meter.os.lua','/meter.os.lua.rfs-old')
    local restarted=updater.new(configUpdate,deps)
    assert(restarted:status().hash==rfs.hash('return "next"'))
    assert(fs.exists('/meter.os.lua') and not fs.exists('/meter.os.lua.rfs-old'))
end)
check('Public DNS setup requires no username or password',function()
    local publicOptIn,selected=false,nil
    local original=package.loaded.dns
    package.loaded.dns={new=function() return {
        setServer=function(id) selected=id end,
        setAuthenticationRequired=function(required) publicOptIn=required==false end,
        clearCache=dnsFixture.clearCache,lookupRecord=dnsFixture.lookupRecord,
    } end}
    local publicApp=updater.new(configUpdate,{connect=deps.connect,random=deps.random})
    publicApp:check(); assert(publicOptIn and selected==42)
    package.loaded.dns=original
end)
check('Weighted services stay inside their priority tier; missing targets fail over',function()
    local calls={}
    local ids=updater.discover({lookupRecord=function(kind,name)
        if kind=='SRV' then return {
            {value={target='zero',protocol=rfs.protocol,priority=0,weight=0}},
            {value={target='weighted',protocol=rfs.protocol,priority=0,weight=4}},
            {value={target='later',protocol=rfs.protocol,priority=1,weight=65535}},
        } end
        calls[#calls+1]=name
        if name=='weighted' then return nil,'missing target' end
        return {{value=name=='zero' and 0 or 7}}
    end},nil,function() return 1 end)
    assert(table.concat(calls,',')=='weighted,zero,later')
    assert(table.concat(ids,',')=='0,7')
end)
check('Path traversal and root directories are rejected',function()
    rejected(function() updater.new({file='../startup.lua'},deps) end)
    rejected(function() updater.new({path='../secret'},deps) end)
    rejected(function() updater.new({file='/meter.os.lua'},deps) end)
end)
check('New updater configurations use a ten-second interval',function()
    normalRun('updater-project',{'init','42'},'update')
    local config=U.load('/update-config.json')
    assert(config.interval==10 and config.path=='meter.os.lua' and config.file=='meter.os.lua')
end)
check('Auto launcher starts Meter OS and forwards arguments',function()
    local invoked,polls=false,0
    put('auto-test.json',textutils.serializeJSON({dnsServer=42,reboot=false,background=false}))
    local h=assert(io.open('update/main.lua','r')); local source=h:read('*a'); h:close()
    local env=setmetatable({require=function(name)
        if name=='updater' then return {new=function(c)
            assert(c.reboot==true and c.background==true)
            return {destination='/meter.os.lua',poll=function() polls=polls+1; return false end}
        end} end
        return hostRequire(name)
    end,shell={run=function(path,arg) assert(path=='/meter.os.lua' and arg=='hello'); invoked=true; return true end},
        parallel={waitForAny=function(run,watch) run() end}}, {__index=_G})
    assert(load(source,'@update/main.lua','t',env))('auto','auto-test.json','hello')
    assert(invoked and polls==1)
end)
check('Auto launcher waits ten seconds per check and reboots only for changed content',function()
    local polls,waits,rebooted=0,0,false
    local h=assert(io.open('update/main.lua','r')); local source=h:read('*a'); h:close()
    local env=setmetatable({require=function(name)
        if name=='updater' then return {new=function() return {destination='/meter.os.lua',poll=function() polls=polls+1; return polls==3 end} end} end
        return hostRequire(name)
    end, sleep=function(seconds) assert(seconds==10); waits=waits+1; assert(not rebooted) end,
        os={reboot=function() rebooted=true; error('TEST_REBOOT') end},
        parallel={waitForAny=function(run,watch) watch() end}}, {__index=_G})
    local success,err=pcall(assert(load(source,'@update/main.lua','t',env)),'auto','auto-test.json')
    assert(not success and tostring(err):find('TEST_REBOOT') and rebooted and polls==3 and waits==2)
end)

local function withLauncher(fixtures,fn)
    local names={'shell','parallel','sleep','os','printError'}
    local saved={}; for _,name in ipairs(names) do saved[name]=_G[name] end
    local original=updater.new
    updater.new=fixtures.new
    for _,name in ipairs(names) do if fixtures[name]~=nil then _G[name]=fixtures[name] end end
    local success,err=pcall(fn)
    updater.new=original
    for _,name in ipairs(names) do _G[name]=saved[name] end
    assert(success,err)
end
check('open API reads config, launches root Lua and forwards arguments',function()
    local polled,ran=false,false
    withLauncher({new=function(c)
        assert(c.dnsServer==42 and c.file=='meter.os.lua' and c.path=='meter.os.lua' and c.interval==10)
        assert(c.background==false and c.reboot==true)
        return {destination='/meter.os.lua',poll=function() polled=true; return false end}
    end,shell={run=function(path,arg) assert(path=='/meter.os.lua' and arg=='left'); ran=true; return true end}},function()
        assert(updater.open('/meter.os.lua',{background=false,args={'left'}}))
    end)
    assert(polled and ran)
end)
check('open API reports offline checks but launches the existing local copy',function()
    local reported,ran=false,false
    withLauncher({new=function(c)
        assert(c.dnsServer==99 and c.path=='apps/meter.os.lua' and c.interval==20)
        return {destination='/meter.os.lua',poll=function() error('offline') end}
    end,printError=function(e) assert(e:find('offline')); reported=true end,
    shell={run=function() ran=true; return true end}},function()
        assert(updater.open('meter.os.lua',{configPath=false,dnsServer=99,path='apps/meter.os.lua',interval=20,background=false,reboot=false}))
    end)
    assert(reported and ran)
end)
check('open API polls at ten seconds and reboots only when background content changes',function()
    local polls,waits,rebooted=0,0,false
    withLauncher({new=function(c)
        assert(c.background and c.reboot and c.interval==10)
        return {destination='/meter.os.lua',poll=function() polls=polls+1; return polls==3 end}
    end,sleep=function(t) assert(t==10); waits=waits+1 end,
    parallel={waitForAny=function(run,watch) watch() end},
    os=setmetatable({reboot=function() rebooted=true; error('TEST_REBOOT') end},{__index=os})},function()
        local success,err=pcall(updater.open,'meter.os.lua')
        assert(not success and tostring(err):find('TEST_REBOOT'))
    end)
    assert(polls==3 and waits==2 and rebooted)
end)
check('open API rejects unsafe filenames, bad options, and missing initial installs',function()
    rejected(function() updater.open('../bad.lua') end)
    rejected(function() updater.open('folder/bad.lua') end)
    rejected(function() updater.open('meter.os.lua',{interval=0}) end)
    rejected(function() updater.open('meter.os.lua',{args={true}}) end)
    withLauncher({new=function(c)
        assert(c.file=='missing.lua' and c.path=='missing.lua')
        return {destination='/missing.lua',poll=function() return false end}
    end,shell={run=function() error('Must not launch a missing file') end}},function()
        rejected(function() updater.open('missing.lua') end)
    end)
end)

print('All updater checks passed ('..tests..' total checks including RFS)')
