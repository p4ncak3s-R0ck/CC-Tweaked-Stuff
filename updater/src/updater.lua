-- Single-file self updates: public DNS SRV discovery -> RFS -> client root.
local rfs=require('rfs')
local U=require('rfs_common')
local C=U.crypto
local M={version='0.1.1',service='update.server.pancakes'}
local function need(v,e) assert(v,e); return v end
local function validHash(h) return type(h)=='string' and #h==64 and h:match('^[0-9a-f]+$') end
local function message(e) return type(e)=='table' and (e.message or e.code) or tostring(e) end
-- Priority order, weighted sampling without replacement, then all resolved IDs.
function M.discover(dns,service,random)
    random=random or math.random
    local records,e=dns.lookupRecord('SRV',service or M.service); need(records,e)
    local groups,priorities={},{}
    for _,record in ipairs(records) do
        local s=record.value
        need(type(s)=='table' and s.protocol==rfs.protocol,'SRV protocol must be '..rfs.protocol)
        local priority=s.priority or 0
        need(C.integer(priority,0,65535) and C.integer(s.weight or 0,0,65535),'Invalid SRV priority/weight')
        if not groups[priority] then groups[priority]={}; priorities[#priorities+1]=priority end
        groups[priority][#groups[priority]+1]=s
    end
    table.sort(priorities)
    local ids,seen,errors={},{},{}
    for _,priority in ipairs(priorities) do
        local group=groups[priority]
        while #group>0 do
            local total=0; for _,s in ipairs(group) do total=total+(s.weight or 0) end
            local index
            if total==0 then index=random(#group) else
                local pick=random(total)
                for i,s in ipairs(group) do pick=pick-(s.weight or 0); if pick<=0 then index=i; break end end
            end
            local s=table.remove(group,index)
            local addresses,err=dns.lookupRecord('ID',s.target)
            if addresses then
                for _,a in ipairs(addresses) do
                    need(C.integer(a.value,0,2147483647),'Invalid computer ID')
                    if not seen[a.value] then ids[#ids+1]=a.value; seen[a.value]=true end
                end
            else errors[#errors+1]=s.target..': '..tostring(err) end
        end
    end
    need(#ids>0,'No update servers resolved: '..table.concat(errors,'; '))
    return ids
end
function M.new(config,dependencies)
    config=config or {}; dependencies=dependencies or {}
    local remote=config.path or 'meter.os.lua'
    U.path(remote); need(remote~='','Remote path required')
    local file=config.file or fs.getName(remote)
    need(type(file)=='string' and file:match('^[%w_-][%w_.-]*$') and not file:find('%.rfs%-'),'Expected a root filename, not a directory path')
    local destination='/'..file
    local root='/.updater/'..file
    local statePath=root..'/state.json'
    local backup=root..'/previous.lua'
    local temporary=root..'/download.lua'
    local share=config.share or 'public'
    if config.hash then need(validHash(config.hash),'Invalid pinned SHA-256') end
    local function state()
        U.recover(statePath)
        return U.load(statePath,{})
    end
    local function recover()
        U.recover(destination); U.recover(backup)
    end
    local function targets()
        local dns=dependencies.dns
        if not dns then
            dns=require('dns').new()
            dns.setServer(need(config.dnsServer,'Set dnsServer to the DNS computer ID'))
            if config.modem then need(dns.open(config.modem)) end
            dns.setAuthenticationRequired(false) -- This network explicitly uses open DNS.
        end
        dns.clearCache()
        return M.discover(dns,config.service or M.service,dependencies.random)
    end
    local function client(id) return (dependencies.connect or rfs.connect)(id,config.rfs or {}) end
    local function metadata(c)
        local m,e=c:stat(share,remote); need(m,e)
        need(not m.directory and validHash(m.hash) and C.integer(m.size,0,U.maxFile),'Invalid remote file metadata')
        if config.hash then need(m.hash==config.hash,'Remote file differs from pinned SHA-256') end
        return m
    end
    local function installedHash()
        recover()
        if fs.exists(destination) then
            need(not fs.isDir(destination),'Root destination is a directory')
            need(fs.getSize(destination)<=U.maxFile,'Installed file too large')
            return U.hash(U.read(destination))
        end
    end
    local self={destination=destination}
    function self:status()
        local s=state()
        return {file=destination,hash=installedHash(),held=s.held==true,backup=fs.exists(backup)}
    end
    function self:check()
        local ids=targets(); local errors={}
        for _,id in ipairs(ids) do
            local ok,m=pcall(function() return metadata(client(id)) end)
            if ok then return {server=id,targets=ids,meta=m,changed=installedHash()~=m.hash,held=state().held==true} end
            errors[#errors+1]=tostring(id)..': '..message(m)
        end
        error('No update server available: '..table.concat(errors,'; '),0)
    end
    function self:apply(candidate)
        candidate=candidate or self:check()
        need(type(candidate.meta)=='table' and validHash(candidate.meta.hash),'Invalid update candidate')
        local m=candidate.meta
        if config.hash then need(m.hash==config.hash,'Update differs from pinned SHA-256') end
        if installedHash()==m.hash then U.save(statePath,{}); return false,m end
        fs.makeDir(root)
        local errors,downloaded={},false
        -- Keep the selected content hash across failover: a stale mirror cannot
        -- silently substitute a different release after a partial download.
        for _,id in ipairs(candidate.targets) do
            local ok,result,e=pcall(function()
                return client(id):download(share,remote,temporary,{hash=m.hash})
            end)
            if ok and result and fs.getSize(temporary)==m.size and U.hash(U.read(temporary))==m.hash then downloaded=true; break end
            errors[#errors+1]=tostring(id)..': '..message(e or result)
        end
        need(downloaded,'Download failed: '..table.concat(errors,'; '))
        -- Syntax-check Lua without executing it. Failed updates preserve the root file.
        if file:sub(-4)=='.lua' then
            local fn,e=load(U.read(temporary),'@'..destination,'t',{})
            need(fn,'Downloaded Lua has a syntax error: '..tostring(e))
        end
        if fs.exists(destination) then
            U.write(backup..'.rfs-new',U.read(destination)); U.replace(backup,backup..'.rfs-new')
        end
        U.replace(destination,temporary)
        U.save(statePath,{hash=m.hash})
        return true,m
    end
    function self:poll()
        recover()
        -- Intentional rollback holds automatic updates until explicit apply.
        if state().held then return false,'held' end
        local c=self:check()
        if c.changed then return self:apply(c) end
        return false,'unchanged'
    end
    function self:rollback()
        recover(); need(fs.exists(backup),'No previous file available')
        U.write(temporary,U.read(backup))
        -- Save hold first, so an interruption cannot immediately reapply the update.
        U.save(statePath,{held=true})
        U.replace(destination,temporary)
        return destination
    end
    return self
end
-- Launch a managed root Lua file, checking for updates before and during its run.
function M.open(luaFilePath,options)
    options=options or {}
    need(type(options)=='table','Expected an options table')
    need(type(luaFilePath)=='string','Expected a Lua filename')
    local file=luaFilePath:gsub('^/','')
    need(file:match('^[%w_-][%w_.-]*%.lua$') and not file:find('%.rfs%-'),'Expected a root Lua filename, such as /meter.os.lua')
    local config={}
    local configPath=options.configPath
    if configPath~=false then
        configPath=configPath or '/update-config.json'
        need(type(configPath)=='string' and configPath~='','Invalid configuration path')
        U.recover(configPath)
        if fs.exists(configPath) then config=U.load(configPath) end
    end
    local configuredFile=config.file or fs.getName(config.path or 'meter.os.lua')
    if not options.path and configuredFile~=file then config.path=file end
    for key,value in pairs(options) do
        if key~='configPath' and key~='args' then config[key]=value end
    end
    config.file=file
    config.path=config.path or file
    config.interval=config.interval or 10
    -- Like `update auto`, default to activating background updates by reboot.
    -- Callers can explicitly disable either behavior in the options table.
    config.background=options.background~=false
    config.reboot=options.reboot~=false
    need(type(config.interval)=='number' and config.interval>=10 and config.interval<=86400,'interval must be 10..86400 seconds')
    local args=options.args or {}
    need(C.array(args,128),'args must be an array of at most 128 strings')
    for _,arg in ipairs(args) do need(type(arg)=='string','Program arguments must be strings') end
    local app=M.new(config)
    local function attempt()
        local ok,changed=pcall(function() return app:poll() end)
        if not ok then
            (printError or print)('Update failed: '..message(changed))
        elseif changed then print('Updated '..app.destination) end
        return ok and changed
    end
    attempt()
    need(fs.exists(app.destination),'No local program installed; update servers must be reachable for the first download')
    local function run()
        need(shell.run(app.destination,table.unpack(args)),'Program exited with an error; use update rollback if needed')
    end
    if not config.background then run() else
        parallel.waitForAny(run,function()
            while true do
                sleep(config.interval)
                if attempt() and config.reboot then os.reboot() end
            end
        end)
    end
    return true
end
return M
