local bootstrap=assert(hostLoadfile('datapack/rom/modules/main/lpm_bootstrap.lua'))()
local checks=0
local function check(label,fn) fn(); checks=checks+1; print('PASS '..label) end
local function rejected(fn) local ok=pcall(fn); assert(not ok,'Expected rejection') end
local function reset()
    files,dirs={}, {['']=true}
    fs.makeDir('rom/lpm'); files['rom/lpm/lpm.lua']=DATAPACK_BUNDLE
    shellPath='.:/rom/programs'; failure=nil; writeFailure=nil
end
check('First boot installs the exact bundle offline and adds /bin once',function()
    reset(); local before=#requests
    assert(bootstrap.ensure()=='/bin/lpm.lua')
    assert(files['bin/lpm.lua']==DATAPACK_BUNDLE and #requests==before)
    assert(shell.path()=='/bin:.:/rom/programs')
    bootstrap.ensure(); assert(shell.path()=='/bin:.:/rom/programs')
    assert(not fs.exists('bin/lpm.lua.datapack-new'))
    assert(files['rom/lpm/lpm.lua']==DATAPACK_BUNDLE)
end)
check('Existing local updates and startup programs are preserved',function()
    reset(); fs.makeDir('bin'); files['bin/lpm.lua']='-- LPM newer custom build\nreturn true'
    files['startup.lua']='my application'
    bootstrap.ensure()
    assert(files['bin/lpm.lua']=='-- LPM newer custom build\nreturn true')
    assert(files['startup.lua']=='my application' and not fs.exists('startup/lpm-path.lua'))
end)
check('Unrelated files and stale staging data are not overwritten',function()
    reset(); fs.makeDir('bin'); files['bin/lpm.lua']='user script'
    rejected(bootstrap.ensure); assert(files['bin/lpm.lua']=='user script')
    reset(); files['bin']='user file'; rejected(bootstrap.ensure); assert(files['bin']=='user file')
    reset(); fs.makeDir('bin'); files['bin/lpm.lua.datapack-new']='user data'
    rejected(bootstrap.ensure); assert(files['bin/lpm.lua.datapack-new']=='user data')
end)
check('Failed writes and activation never leave a partial installed copy',function()
    reset(); writeFailure='bin/lpm.lua.datapack-new'; rejected(bootstrap.ensure)
    assert(not fs.exists('bin/lpm.lua') and not fs.exists('bin/lpm.lua.datapack-new'))
    reset(); failure='bin/lpm.lua'; rejected(bootstrap.ensure)
    assert(not fs.exists('bin/lpm.lua') and not fs.exists('bin/lpm.lua.datapack-new'))
    bootstrap.ensure(); assert(files['bin/lpm.lua']==DATAPACK_BUNDLE)
end)
check('Invalid ROM payloads are rejected and payload code is never run at boot',function()
    reset(); files['rom/lpm/lpm.lua']='broken'; rejected(bootstrap.ensure)
    reset(); files['rom/lpm/lpm.lua']='-- LPM test\ninvalid !'; rejected(bootstrap.ensure)
    reset(); files['rom/lpm/lpm.lua']='-- LPM test\nerror("must not execute at boot")'
    bootstrap.ensure(); assert(files['bin/lpm.lua']:find('must not execute',1,true))
end)
local environment=setmetatable({require=function(n) assert(n=='lpm_bootstrap'); return bootstrap end},{__index=_G})
check('Autorun reports installation errors without aborting other startup work',function()
    reset(); files['bin']='blocked'; local warning
    environment.printError=function(s) warning=s end
    assert(hostLoadfile('datapack/rom/autorun/lpm.lua','t',environment))()
    assert(warning and warning:find('LPM datapack:',1,true))
end)
check('ROM launcher delegates arguments to the writable copy',function()
    reset(); local target,args
    shell.run=function(p,...) target=p; args={...}; return true end
    assert(hostLoadfile('datapack/rom/programs/lpm.lua','t',environment))('self-update','main')
    assert(target=='/bin/lpm.lua' and args[1]=='self-update' and args[2]=='main')
    assert(files['bin/lpm.lua']==DATAPACK_BUNDLE)
    shell.run=function() return false end
    rejected(function() assert(hostLoadfile('datapack/rom/programs/lpm.lua','t',environment))('bad-command') end)
end)
print(checks..' datapack bootstrap checks passed')
