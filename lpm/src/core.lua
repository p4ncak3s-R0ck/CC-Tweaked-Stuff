local data, semver, sha256 = require("data"), require("semver"), require("sha256")
local M={version="0.1.0"}
local MAX_FILE, MAX_TOTAL = 1048576, 8388608
local function sorted(t) local a={}; for k in pairs(t) do a[#a+1]=k end; table.sort(a); return a end
local function name(n)
    assert(type(n)=="string" and #n<=64 and n:match("^[a-z][a-z0-9_-]*$"), "Invalid package name: "..tostring(n)); return n
end
local function path(p)
    assert(type(p)=="string" and #p>0 and #p<=240 and not p:find("[^%w_./%-]"), "Invalid package path")
    assert(p:sub(1,1)~="/" and p:sub(-1)~="/" and not p:find("//",1,true),"Path must be relative")
    for part in p:gmatch("[^/]+") do assert(part~="." and part~="..", "Path traversal rejected") end
    return p
end
local function deps(d)
    assert(type(d)=="table", "dependencies must be a table")
    for n,r in pairs(d) do name(n); semver.satisfies("0.0.0",r) end
    return d
end
local function repo(r)
    assert(type(r)=="table" and type(r.github)=="string", "Expected GitHub repository")
    assert(r.github:match("^[%w_.-]+/[%w_.-]+$"), "Invalid owner/repo")
    assert(type(r.ref or "main")=="string" and # (r.ref or "main")<=160, "Invalid repository ref")
    if r.path and r.path~="" then path(r.path) end
    return r
end
local function manifest(m,n)
    assert(m.manifestVersion==1 and m.name==n,"Manifest name or schema mismatch")
    semver.parse(m.version)
    assert(m.type=="library" or m.type=="application", "Unknown package type")
    deps(m.dependencies or {})
    assert(type(m.files)=="table" and next(m.files), "Manifest must list files")
    local targets={}; local count=0
    for src,dst in pairs(m.files) do
        path(src); path(dst); count=count+1; assert(count<=256,"Too many files")
        assert(not targets[dst],"Duplicate install target"); targets[dst]=true
    end
    for a in pairs(targets) do for b in pairs(targets) do assert(a==b or b:sub(1,#a+1)~=a.."/","File/directory target collision") end end
    if m.entry then path(m.entry); assert(targets[m.entry],"entry must be an installed file") end
    if m.modules then for mod,target in pairs(m.modules) do assert(type(mod)=="string" and mod:match("^[%a_][%w_.-]*$"),"Invalid module alias"); path(target); assert(targets[target],"Module target not installed") end end
    return m
end
local function read(p)
    local h,e=fs.open(p,"rb"); assert(h,e or ("Cannot read "..p)); local s=h.readAll(); h.close(); return s
end
local function write(p,s)
    fs.makeDir(fs.getDir(p)); local h,e=fs.open(p,"wb"); assert(h,e or ("Cannot write "..p)); h.write(s); h.close()
end
local function clone(x) return data.parse(data.serialize(x)) end
local function encode(s) return (s:gsub("[^%w_.~-]",function(c) return string.format("%%%02X",c:byte()) end)) end
local function download(url,limit,optional)
    assert(http and http.get,"HTTP must be enabled")
    local h,e,failed=http.get({url=url,binary=true,headers={['User-Agent']='CC-LPM/0.1'}})
    if not h then
        local code=failed and failed.getResponseCode(); if failed then failed.close() end
        if optional and code==404 then return nil end
        error("Download failed: "..url..": "..tostring(e),0)
    end
    local chunks,total={},0
    while true do
        local s=h.read(8192); if not s or s=="" then break end
        total=total+#s; if total>limit then h.close(); error("Download too large: "..url,0) end
        chunks[#chunks+1]=s
    end
    h.close(); return table.concat(chunks)
end
local function commit(r)
    if r.ref and #r.ref==40 and r.ref:match("^%x+$") then return r.ref:lower() end
    local url="https://api.github.com/repos/"..r.github.."/commits/"..encode(r.ref or "main")
    local response=textutils.unserializeJSON(download(url,262144))
    assert(type(response)=="table" and type(response.sha)=="string" and #response.sha==40 and response.sha:match("^%x+$"),"GitHub returned invalid commit")
    return response.sha:lower()
end
local function raw(r,ref,p) return "https://raw.githubusercontent.com/"..r.github.."/"..ref.."/"..p end
local function base(r,n) return (r.path and r.path~="" and r.path.."/" or "")..name(n) end
local function project(root)
    local p=data.parse(read(fs.combine(root,"package.lua")))
    assert(p.manifestVersion==1,"Unsupported project schema"); name(p.name); semver.parse(p.version)
    deps(p.dependencies or {}); p.dependencies=p.dependencies or {}
    p.repositories=p.repositories or {default={github="p4ncak3s-R0ck/CC-Tweaked-Stuff",ref="main"}}
    assert(p.repositories.default,"repositories.default required")
    for k,r in pairs(p.repositories) do name(k); repo(r) end
    if p.entry then path(p.entry) end
    return p
end
local function repository(p,n)
    local key=p.packageRepositories and p.packageRepositories[n] or "default"
    return assert(p.repositories[key],"Unknown repository "..tostring(key))
end
local function recover(root)
    local dir=fs.combine(root,".lpm"); local journal=fs.combine(dir,"transaction.lua")
    if not fs.exists(journal) then return end
    local j=data.parse(read(journal)); assert(type(j.hadState)=="boolean" and type(j.hadProject)=="boolean","Invalid recovery journal")
    local current,backup=fs.combine(dir,"current"),fs.combine(dir,"previous")
    local pkg,oldpkg=fs.combine(root,"package.lua"),fs.combine(dir,"previous-package.lua")
    if fs.exists(backup) then if fs.exists(current) then fs.delete(current) end; fs.move(backup,current)
    elseif not j.hadState and fs.exists(current) then fs.delete(current) end
    if fs.exists(oldpkg) then if fs.exists(pkg) then fs.delete(pkg) end; fs.move(oldpkg,pkg)
    elseif not j.hadProject and fs.exists(pkg) then fs.delete(pkg) end
    for dst,original in pairs(j.exports or {}) do
        path(dst); assert(dst~="package.lua" and dst:sub(1,5)~=".lpm/","Invalid recovery export")
        local target=fs.combine(root,dst)
        if original==false then if fs.exists(target) then fs.delete(target) end
        else assert(type(original)=="string","Invalid recovery content"); write(target,original) end
    end
    fs.delete(journal)
end
local function exports(root,lock)
    local out={}
    local function add(dst,n,target)
        path(dst)
        assert(dst~="package.lua" and dst:sub(1,5)~=".lpm/", "Reserved export path")
        local source="/"..fs.combine(root,".lpm/current/packages/"..n.."/"..target)
        local code="-- Managed by lpm. Do not edit.\nlocal fn, err = loadfile("..string.format("%q",source)..", \"t\", _ENV)\nassert(fn, err)\nreturn fn(...)\n"
        assert(not out[dst] or out[dst]==code,"Conflicting package export: "..dst)
        out[dst]=code
    end
    for _,n in ipairs(sorted(lock.packages)) do
        local m=lock.packages[n].manifest
        for _,target in pairs(m.files) do
            if target=="init.lua" then if m.type=="library" then add(n..".lua",n,target) end
            elseif target:sub(-4)==".lua" then add(target,n,target) end
        end
        for mod,target in pairs(m.modules or {}) do add(mod:gsub("%.","/")..".lua",n,target) end
        if m.type=="application" and m.entry then add(n..".lua",n,m.entry) end
    end
    local count=0
    for a in pairs(out) do
        count=count+1; assert(count<=512,"Too many exported modules")
        for b in pairs(out) do assert(a==b or b:sub(1,#a+1)~=a.."/","Export file/directory collision") end
    end
    return out
end
local function activate(root,p,lock,stage)
    local dir=fs.combine(root,".lpm"); local current=fs.combine(dir,"current")
    local backup=fs.combine(dir,"previous"); local oldpkg=fs.combine(dir,"previous-package.lua")
    if fs.exists(backup) then fs.delete(backup) end; if fs.exists(oldpkg) then fs.delete(oldpkg) end
    local exposed=exports(root,lock); local previous={}
    if fs.exists(fs.combine(current,"package.lock")) then previous=data.parse(read(fs.combine(current,"package.lock"))).exports or {} end
    local undo={}
    for dst in pairs(previous) do path(dst); undo[dst]=false end
    for dst in pairs(exposed) do undo[dst]=false end
    for dst in pairs(undo) do
        local target=fs.combine(root,dst)
        if fs.exists(target) then
            assert(not fs.isDir(target),"Directory blocks package module: "..dst)
            local content=read(target)
            assert(previous[dst] and sha256(content)==previous[dst],"Refusing to overwrite existing or edited file: "..dst)
            undo[dst]=content
        end
        local parent=fs.getDir(target)
        while parent~="" do assert(not fs.exists(parent) or fs.isDir(parent),"File blocks module directory: "..parent); parent=fs.getDir(parent) end
    end
    lock.exports={}; for dst,code in pairs(exposed) do lock.exports[dst]=sha256(code) end
    write(fs.combine(stage,"package.lock"),data.serialize(lock))
    write(fs.combine(dir,"next-package.lua"),data.serialize(p))
    local journal=data.serialize({hadState=fs.exists(current),hadProject=fs.exists(fs.combine(root,"package.lua")),exports=undo})
    assert(#journal<=262144,"Recovery journal exceeds metadata limit")
    write(fs.combine(dir,"transaction.tmp"),journal)
    assert(read(fs.combine(dir,"transaction.tmp"))==journal,"Journal write failed")
    fs.move(fs.combine(dir,"transaction.tmp"),fs.combine(dir,"transaction.lua"))
    if fs.exists(current) then fs.move(current,backup) end
    fs.move(fs.combine(root,"package.lua"),oldpkg)
    fs.move(stage,current)
    fs.move(fs.combine(dir,"next-package.lua"),fs.combine(root,"package.lua"))
    for dst in pairs(undo) do
        local target=fs.combine(root,dst)
        if exposed[dst] then write(target,exposed[dst]) elseif fs.exists(target) then fs.delete(target) end
    end
    fs.delete(fs.combine(dir,"transaction.lua")) -- Commit point; backups can now be cleaned.
    if fs.exists(backup) then fs.delete(backup) end; if fs.exists(oldpkg) then fs.delete(oldpkg) end
end
local function validateLock(p,l)
    assert(l.lockVersion==1 and l.projectHash==sha256(data.serialize(p)),"Lockfile does not match package.lua; run lpm update")
    assert(type(l.packages)=="table","Invalid lockfile")
    for n,x in pairs(l.packages) do
        name(n); repo(x.repository); manifest(x.manifest,n)
        assert(x.version==x.manifest.version,"Invalid locked version")
        assert(type(x.commit)=="string" and #x.commit==40 and x.commit:match("^%x+$"),"Invalid locked commit")
        path(x.base); assert(type(x.hashes)=="table","Missing hashes")
        for _,dst in pairs(x.manifest.files) do assert(type(x.hashes[dst])=="string" and #x.hashes[dst]==64 and x.hashes[dst]:match("^%x+$"),"Missing file hash") end
        for dep,r in pairs(x.manifest.dependencies or {}) do assert(l.packages[dep] and semver.satisfies(l.packages[dep].version,r),"Broken locked dependency") end
    end
    for n,r in pairs(p.dependencies) do assert(l.packages[n] and semver.satisfies(l.packages[n].version,r),"Missing locked dependency") end
    return l
end
local function resolve(p)
    local cache,pins={},{}
    local function candidates(n)
        if cache[n] then return cache[n] end
        local r=repository(p,n); local key=data.serialize(r)
        pins[key]=pins[key] or commit(r); local tip=pins[key]; local bp=base(r,n)
        local indexText=download(raw(r,tip,bp.."/index.lua"),262144,true)
        local result={}
        if indexText then
            local idx=data.parse(indexText); assert(idx.indexVersion==1 and type(idx.versions)=="table","Invalid package index")
            local count=0
            for v,entry in pairs(idx.versions) do
                semver.parse(v); assert(type(entry)=="table" and type(entry.ref)=="string" and #entry.ref==40 and entry.ref:match("^%x+$"),"Index versions must pin full commits")
                if entry.path then path(entry.path) end
                count=count+1; assert(count<=128,"Too many package versions")
                result[#result+1]={version=v,commit=entry.ref:lower(),base=entry.path or bp,repository=clone(r)}
            end
            table.sort(result,function(a,b) return semver.compare(a.version,b.version)>0 end)
        else
            local m=manifest(data.parse(download(raw(r,tip,bp.."/manifest.lua"),262144)),n)
            result[1]={version=m.version,commit=tip,base=bp,repository=clone(r),manifest=m}
        end
        cache[n]=result; return result
    end
    local budget=0
    local function solve(chosen,requirements)
        budget=budget+1; assert(budget<=4096,"Dependency resolution exceeded search limit")
        for n,rs in pairs(requirements) do
            if chosen[n] then for _,r in ipairs(rs) do if not semver.satisfies(chosen[n].version,r) then return nil end end end
        end
        local missing
        for _,n in ipairs(sorted(requirements)) do if not chosen[n] then missing=n; break end end
        if not missing then return chosen end
        local count=0; for _ in pairs(requirements) do count=count+1 end; assert(count<=64,"Too many dependencies")
        for _,c in ipairs(candidates(missing)) do
            local fits=true; for _,r in ipairs(requirements[missing]) do if not semver.satisfies(c.version,r) then fits=false end end
            if fits then
                if not c.manifest then c.manifest=manifest(data.parse(download(raw(c.repository,c.commit,c.base.."/manifest.lua"),262144)),missing) end
                assert(c.manifest.version==c.version,"Index version differs from manifest")
                local nextChosen,nextReq=clone(chosen),clone(requirements); nextChosen[missing]=clone(c)
                for dep,r in pairs(c.manifest.dependencies or {}) do nextReq[dep]=nextReq[dep] or {}; table.insert(nextReq[dep],r) end
                local answer=solve(nextChosen,nextReq); if answer then return answer end
            end
        end
    end
    local req={}; for n,r in pairs(p.dependencies) do req[n]={r} end
    return assert(solve({},req),"Incompatible dependency constraints; no valid version set")
end
function M.init(root)
    assert(not fs.exists(fs.combine(root,"package.lua")),"package.lua already exists")
    local n=fs.getName(root):lower():gsub("[^a-z0-9_-]","-"); if not n:match("^[a-z]") then n="project-"..n end
    write(fs.combine(root,"package.lua"),data.serialize({manifestVersion=1,name=n,version="0.1.0",type="application",entry="main.lua",repositories={default={github="p4ncak3s-R0ck/CC-Tweaked-Stuff",ref="main"}},dependencies={}}))
end
function M.install(root,spec,update,remove,offline)
    recover(root); local p=project(root)
    if spec then
        local n,r=spec:match("^([^@]+)@(.+)$"); n=n or spec; name(n)
        if remove then assert(p.dependencies[n],"Not a direct dependency"); p.dependencies[n]=nil
        else r=r or "*"; semver.satisfies("0.0.0",r); p.dependencies[n]=r end
    end
    local dir=fs.combine(root,".lpm"); local current=fs.combine(dir,"current"); local lockPath=fs.combine(current,"package.lock")
    local l
    if not spec and not update and fs.exists(lockPath) then l=validateLock(p,data.parse(read(lockPath)))
    else assert(not offline,"Offline install requires a matching lockfile"); l={lockVersion=1,projectHash=sha256(data.serialize(p)),packages=resolve(p)} end
    local stage=fs.combine(dir,"stage"); if fs.exists(stage) then fs.delete(stage) end; fs.makeDir(stage)
    local total=0
    local ok,err=pcall(function()
        for _,n in ipairs(sorted(l.packages)) do
            local x=l.packages[n]; local previousHashes=x.hashes; x.hashes={}
            for _,src in ipairs(sorted(x.manifest.files)) do
                local dst=x.manifest.files[src]; local bytes
                local existing=fs.combine(current,"packages/"..n.."/"..dst)
                if previousHashes and fs.exists(existing) then
                    local old=read(existing); if sha256(old)==previousHashes[dst] then bytes=old end
                end
                if not bytes then assert(not offline,"Offline file unavailable or corrupt: "..n.."/"..dst); bytes=download(raw(x.repository,x.commit,x.base.."/"..src),MAX_FILE) end
                total=total+#bytes; assert(total<=MAX_TOTAL,"Install exceeds 8 MiB")
                local hash=sha256(bytes); if previousHashes then assert(hash==previousHashes[dst],"SHA-256 mismatch: "..n.."/"..dst) end
                if x.manifest.hashes and x.manifest.hashes[src] then assert(hash==x.manifest.hashes[src],"Manifest hash mismatch") end
                x.hashes[dst]=hash; write(fs.combine(stage,"packages/"..n.."/"..dst),bytes)
            end
        end
        activate(root,p,l,stage)
    end)
    if not ok then recover(root); if fs.exists(stage) then fs.delete(stage) end; error(err,0) end
    return l
end
function M.lock(root)
    recover(root); local p=project(root)
    return validateLock(p,data.parse(read(fs.combine(root,".lpm/current/package.lock")))),p
end
function M.verify(root)
    local l=M.lock(root); local count=0
    for n,x in pairs(l.packages) do for dst,hash in pairs(x.hashes) do
        assert(sha256(read(fs.combine(root,".lpm/current/packages/"..n.."/"..dst)))==hash,"Corrupt file: "..n.."/"..dst); count=count+1
    end end
    for dst,hash in pairs(l.exports or {}) do
        path(dst); assert(sha256(read(fs.combine(root,dst)))==hash,"Edited module loader: "..dst)
    end
    return count
end
function M.setup()
    local startup="startup/lpm-path.lua"
    assert(not fs.exists("startup") or fs.isDir("startup"),"/startup is a file; add /bin to your startup shell path manually")
    local boot='-- Managed package command path\nif shell then shell.setPath("/bin:" .. shell.path()) end\n'
    if fs.exists(startup) then assert(read(startup)==boot,"Existing startup/lpm-path.lua is not managed by lpm") end
    local source=read(shell.getRunningProgram())
    if fs.exists("bin/lpm.lua") then assert(read("bin/lpm.lua"):find("-- LPM ",1,true)==1,"Existing /bin/lpm.lua is not managed by lpm") end
    write("bin/lpm.lua",source); write(startup,boot)
    shell.setPath("/bin:"..shell.path())
end
M.data=data; M.semver=semver; M.sha256=sha256
return M
