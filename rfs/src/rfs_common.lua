local C = require("rfs_crypto")
local M = { protocol = "rednet-files-v1", version = 1, maxFile = 1048576, maxChunk = 8192 }
M.crypto = C
function M.check(test, code, message)
    if not test then error({code=code, message=message or code}, 0) end
end
function M.path(p)
    M.check(type(p)=="string" and #p<=240 and not p:find("[%z\1-\31\\:]"), "BAD_PATH")
    M.check(p:sub(1,1)~="/" and not p:find("//",1,true), "BAD_PATH")
    for part in p:gmatch("[^/]+") do M.check(part~="." and part~="..", "BAD_PATH") end
    M.check(p=="" or p:sub(-1)~="/", "BAD_PATH")
    return p
end
function M.within(path, prefix) return prefix=="" or path==prefix or path:sub(1,#prefix+1)==prefix.."/" end
function M.now() return math.floor(os.epoch("utc")/1000) end
function M.read(p)
    local h,e=fs.open(p,"rb"); M.check(h,"IO_ERROR",e)
    local s=h.readAll(); h.close(); return s
end
function M.write(p,s)
    fs.makeDir(fs.getDir(p)); local h,e=fs.open(p,"wb"); M.check(h,"IO_ERROR",e)
    h.write(s); h.close()
end
function M.load(p, default)
    if not fs.exists(p) then return default end
    local v=textutils.unserializeJSON(M.read(p)); M.check(type(v)=="table","BAD_CONFIG"); return v
end
-- Recoverable replacement, including restart between the two moves.
function M.recover(p)
    if fs.exists(p..".rfs-old") then
        if not fs.exists(p) then fs.move(p..".rfs-old",p) else fs.delete(p..".rfs-old") end
    end
end
function M.replace(p, temp)
    M.recover(p)
    if fs.exists(p) then fs.move(p,p..".rfs-old") end
    local ok,e=pcall(fs.move,temp,p)
    if not ok then M.recover(p); error(e,0) end
    if fs.exists(p..".rfs-old") then fs.delete(p..".rfs-old") end
end
function M.save(p,v)
    M.recover(p); M.write(p..".rfs-new",textutils.serializeJSON(v)); M.replace(p,p..".rfs-new")
end
function M.hash(s) return C.hex(C.sha256(s)) end
function M.pack(body,key,token)
    body.token=token or ""
    local payload=C.encode(body)
    M.check(#payload<=60000,"TOO_LARGE")
    return {payload=payload, mac=key and C.hmac(key,payload) or false, token=token or ""}
end
function M.unpack(packet,key)
    if type(packet)~="table" or type(packet.payload)~="string" or #packet.payload>60000 then return nil end
    if key and not C.equal(packet.mac,C.hmac(key,packet.payload)) then return nil end
    local ok,b=pcall(C.decode,packet.payload); return ok and type(b)=="table" and b.token==packet.token and b or nil
end
function M.openModems()
    local found=false
    for _,name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name)=="modem" then rednet.open(name); found=true end
    end
    M.check(found,"NO_MODEM","Attach a wired or wireless modem")
end
return M
