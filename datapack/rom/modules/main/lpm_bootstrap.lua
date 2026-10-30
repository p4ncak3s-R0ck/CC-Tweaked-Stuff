-- Install once from the server ROM; existing local copies keep their own updates.
local M={}
local target,payload,stage="/bin/lpm.lua","/rom/lpm/lpm.lua","/bin/lpm.lua.datapack-new"
local function read(p)
    local h,e=fs.open(p,"rb"); assert(h,e or ("Cannot read "..p))
    local bytes=h.readAll(); h.close(); return bytes
end
local function onPath()
    if not shell then return end
    local paths={"/bin"}
    for part in shell.path():gmatch("[^:]+") do if part~="/bin" then paths[#paths+1]=part end end
    shell.setPath(table.concat(paths,":"))
end
function M.ensure()
    if fs.exists(target) then
        assert(not fs.isDir(target),"/bin/lpm.lua is a directory")
        assert(read(target):find("-- LPM ",1,true)==1,"Existing /bin/lpm.lua is not managed by LPM; preserving it")
        onPath(); return target
    end
    assert(not fs.exists("/bin") or fs.isDir("/bin"),"/bin is a file; cannot install LPM")
    assert(not fs.exists(stage),"Staging file already exists: "..stage)
    local bytes=read(payload)
    assert(bytes:find("-- LPM ",1,true)==1,"Invalid bundled LPM header")
    local compiled,problem=load(bytes,"@"..payload,"t",{})
    assert(compiled,"Invalid bundled LPM Lua: "..tostring(problem))
    fs.makeDir("/bin")
    local ok,err=pcall(function()
        local h,e=fs.open(stage,"wb"); assert(h,e or "Cannot stage LPM")
        h.write(bytes); h.close()
        assert(read(stage)==bytes,"LPM staging verification failed")
        assert(not fs.exists(target),"LPM was installed by another process")
        fs.move(stage,target)
    end)
    if not ok then
        if fs.exists(stage) then fs.delete(stage) end
        error(err,0)
    end
    onPath(); return target
end
return M
