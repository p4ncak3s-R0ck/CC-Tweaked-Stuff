local updater=require('updater')
local U=require('rfs_common')
local argv={...}
local command=argv[1]
if not command or command=='--help' then
    print('update init <DNS computer ID> [share]')
    print('update <pull|check|status|rollback|watch|run> [config.json] [program arguments...]')
    print('Default file: /meter.os.lua; service: update.server.pancakes; open DNS')
    return
end
local defaultConfig='/update-config.json'
if command=='init' then
    local id=tonumber(argv[2]); assert(id and id>=0 and id<=2147483647 and id%1==0,'DNS computer ID required')
    assert(not fs.exists(defaultConfig),'Configuration already exists; edit '..defaultConfig)
    U.write(defaultConfig,textutils.serializeJSON({dnsServer=id,service=updater.service,share=argv[3] or 'public',path='meter.os.lua',file='meter.os.lua',interval=300,background=true,reboot=false}))
    print('Created '..defaultConfig); return
end
local configPath=argv[2] or defaultConfig
local config=assert(U.load(configPath),'Run update init <DNS computer ID> first')
local app=updater.new(config)
local interval=config.interval or 300
assert(type(interval)=='number' and interval>=10 and interval<=86400,'interval must be 10..86400 seconds')
local function attempt()
    local ok,changed=pcall(function() return app:poll() end)
    if not ok then printError(type(changed)=='table' and (changed.message or changed.code) or tostring(changed))
    elseif changed then print('Updated '..app.destination) end
    return ok and changed
end
if command=='status' then print(textutils.serializeJSON(app:status()))
elseif command=='check' then
    local c=app:check(); print(textutils.serializeJSON({file=app.destination,hash=c.meta.hash,size=c.meta.size,changed=c.changed,held=c.held,server=c.server}))
elseif command=='pull' or command=='apply' then
    local changed=app:apply(); print((changed and 'Updated ' or 'Already current: ')..app.destination)
elseif command=='rollback' then print('Restored '..app:rollback()..'; automatic updates held until update pull')
elseif command=='watch' then
    while true do if attempt() and config.reboot==true then os.reboot() end; sleep(interval) end
elseif command=='run' then
    attempt() -- Continue with the previous local file if the network is unavailable.
    assert(fs.exists(app.destination),'No local program installed; run update pull while servers are reachable')
    local function run()
        assert(shell.run(app.destination,table.unpack(argv,3)),'Program exited with an error; use update rollback if needed')
    end
    if config.background==false then run() else
        parallel.waitForAny(run,function()
            while true do sleep(interval); if attempt() and config.reboot==true then os.reboot() end end
        end)
    end
else error('Unknown command: '..tostring(command),0) end
