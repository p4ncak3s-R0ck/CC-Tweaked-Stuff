local rfs=require('rfs')
local args={...}
if #args==0 or args[1]=='--help' then
    print('rfs-server init [config.json] [shared directory]')
    print('rfs-server [config.json]')
    print('Edit the JSON configuration locally to add scoped tokens.')
    return
end
if args[1]=='init' then
    local path=args[2] or 'rfs-config.json'
    assert(not fs.exists(path),'Configuration already exists')
    local root=args[3] or '/shared'; fs.makeDir(root)
    local config={name='files-'..os.getComputerID(),state='/.rfs',shares={public={root=root,public=true}},tokens={}}
    local h=assert(fs.open(path,'w')); h.write(textutils.serializeJSON(config)); h.close()
    print('Created '..path..'; start with rfs-server '..path)
    return
end
local h=assert(fs.open(args[1],'r'),'Configuration not found')
local config=assert(textutils.unserializeJSON(h.readAll()),'Invalid configuration'); h.close()
local server=rfs.server(config)
print('File server '..os.getComputerID()..' ('..rfs.protocol..')')
server:run()
