local rfs=require('rfs')
local argv={...}
local function usage()
    print('rfs-client <ID> <command> <share> <path> [local path] [--auth credentials.json]')
    print('Commands: hello, shares, list, stat, get, put, tree, history, mkdir, delete, move, restore, watch, sync')
    print('sync: <ID> sync <share> <path> <local directory> [download|upload]')
    print('move/restore: use destination path/revision as the final argument')
end
if #argv==0 or argv[1]=='--help' then usage(); return end
local auth={}
for i=#argv-1,1,-1 do
    if argv[i]=='--auth' then
        local h=assert(fs.open(argv[i+1],'r')); auth=assert(textutils.unserializeJSON(h.readAll())); h.close()
        table.remove(argv,i+1); table.remove(argv,i)
    end
end
local c=rfs.connect(argv[1],auth)
local command,share,path=argv[2],argv[3],argv[4] or ''
local function show(value,e,code)
    if not value then error((code or 'ERROR')..': '..tostring(e),0) end
    print(textutils.serializeJSON(value)); return value
end
local function progress(p) write('\r'..p.bytes..' / '..p.total..' bytes') end
if command=='hello' then show(c:hello())
elseif command=='shares' then show(c:shares())
elseif command=='list' then show(c:list(share,path))
elseif command=='stat' then show(c:stat(share,path))
elseif command=='get' then show(c:download(share,path,assert(argv[5],'Local destination required'),{progress=progress}))
elseif command=='put' then show(c:upload(share,path,assert(argv[5],'Local source required'),{progress=progress}))
elseif command=='tree' then show(c:downloadTree(share,path,assert(argv[5],'Local directory required')))
elseif command=='history' then show(c:history(share,path))
elseif command=='mkdir' then show(c:mkdir(share,path))
elseif command=='delete' then show(c:delete(share,path))
elseif command=='move' then show(c:move(share,path,assert(argv[5],'Destination path required')))
elseif command=='restore' then show(c:restore(share,path,assert(argv[5],'Revision required')))
elseif command=='sync' then show(c:sync(share,path,assert(argv[5],'Local directory required'),{direction=argv[6] or 'download'}))
elseif command=='watch' then
    local w=show(c:watch(share,path)); local cursor=w.sequence
    while true do
        local notice=c:nextEvent(2); if notice then print(textutils.serializeJSON(notice.event)) end
        local changes=show(c:changes(share,path,cursor)); cursor=changes.sequence
        if changes.gap then print('Missed changes: refresh directory listing') end
        if os.epoch('utc')/1000>w.expires-30 then c:unwatch(w.watch); w=show(c:watch(share,path)) end
    end
else usage(); error('Unknown command: '..tostring(command),0) end
