local data, semver, sha256 = require("data"), require("semver"), require("sha256")
local log=require("log")
local M={version="0.2.0",log=log}
local builtins=require("official-repositories")
local OFFICIAL=builtins.official
local LEGACY={github="p4ncak3s-R0ck/CC-Tweaked-Stuff",ref="main"}
local function legacyRepository(r)
    return (r.github==LEGACY.github or r.github==builtins.selfUpdate.github) and (r.ref or "main")=="main" and (not r.path or r.path=="")
end
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
-- HTTPS keys are remote file sources; destinations always remain relative paths.
local function source(src)
    if type(src)=="string" and src:sub(1,8)=="https://" then
        assert(#src<=2048 and not src:find("[%c%s]") and not src:find("#",1,true),"Invalid HTTPS source URL")
        local authority=src:match("^https://([^/?]+)")
        assert(authority and not authority:find("@",1,true),"HTTPS source requires a host without credentials")
        local host,port=authority:match("^([%w.-]+):(%d+)$")
        if not host then host=authority; assert(not host:find(":",1,true),"Invalid HTTPS source host or port") end
        assert(host:match("^[%w]") and host:match("[%w]$") and not host:find("[^%w.-]"),"Invalid HTTPS source host")
        if port then assert(tonumber(port)>=1 and tonumber(port)<=65535,"Invalid HTTPS source port") end
        return src
    end
    return path(src)
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
        source(src); path(dst); count=count+1; assert(count<=256,"Too many files")
        assert(not targets[dst],"Duplicate install target"); targets[dst]=true
    end
    for a in pairs(targets) do for b in pairs(targets) do assert(a==b or b:sub(1,#a+1)~=a.."/","File/directory target collision") end end
    if m.entry then path(m.entry); assert(targets[m.entry],"entry must be an installed file") end
    if m.modules then for mod,target in pairs(m.modules) do assert(type(mod)=="string" and mod:match("^[%a_][%w_.-]*$"),"Invalid module alias"); path(target); assert(targets[target],"Module target not installed") end end
    return m
end
-- A standalone package is valid Lua with a non-executing metadata comment.
local function singleManifest(bytes,n)
    local header=bytes:match("^%s*%-%-%[=%[lpm%s*\n(.-)\n%]=%]")
    if not header then return manifest(data.parse(bytes),n) end
    local m=data.parse(header)
    assert(m.files==nil,"Single-file metadata must not declare files")
    assert(m.hashes==nil,"Single-file metadata cannot hash its own containing file")
    m.files={[n..".lua"]=n..".lua"}
    if m.type=="application" then m.entry=m.entry or n..".lua" end
    return manifest(m,n)
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
    log.debug("HTTP","GET "..log.url(url))
    local h,e,failed=http.get({url=url,binary=true,headers={['User-Agent']='CC-LPM/0.1'}})
    if not h then
        local code=failed and failed.getResponseCode(); if failed then failed.close() end
        if optional and code==404 then log.debug("HTTP","404 (optional metadata absent)"); return nil end
        error("Download failed"..(code and (" (HTTP "..code..")") or "")..": "..log.url(url)..": "..log.url(tostring(e)),0)
    end
    local chunks,total={},0
    while true do
        local s=h.read(8192); if not s or s=="" then break end
        total=total+#s; if total>limit then h.close(); error("Download too large: "..url,0) end
        chunks[#chunks+1]=s
    end
    h.close(); log.debug("HTTP","Received "..total.." bytes"); return table.concat(chunks)
end
local function commit(r)
    if r.ref and #r.ref==40 and r.ref:match("^%x+$") then return r.ref:lower() end
    local url="https://api.github.com/repos/"..r.github.."/commits/"..encode(r.ref or "main")
    log.info("Repository","Resolving "..r.github.." @ "..(r.ref or "main"))
    local response=textutils.unserializeJSON(download(url,262144))
    assert(type(response)=="table" and type(response.sha)=="string" and #response.sha==40 and response.sha:match("^%x+$"),"GitHub returned invalid commit")
    log.debug("Repository","Pinned "..r.github.." to "..response.sha:lower())
    return response.sha:lower()
end
local function raw(r,ref,p) return "https://raw.githubusercontent.com/"..r.github.."/"..ref.."/"..p end
local function base(r,n) return (r.path and r.path~="" and r.path.."/" or "")..name(n) end
local function validateProject(p)
    assert(p.manifestVersion==1,"Unsupported project schema"); name(p.name); semver.parse(p.version)
    deps(p.dependencies or {}); p.dependencies=p.dependencies or {}
    p.repositories=p.repositories or {default=clone(LEGACY)}
    for k,r in pairs(p.repositories) do
        name(k); repo(r)
        if k=="official" then assert(data.serialize(r)==data.serialize(OFFICIAL) or legacyRepository(r),"official is a reserved repository; use another name") end
    end
    assert(p.officialRepository==nil or type(p.officialRepository)=="boolean","officialRepository must be boolean")
    local function exists(k) name(k); if k=="official" then return p.officialRepository~=false end; return p.repositories[k] end
    if p.defaultRepository then assert(exists(p.defaultRepository),"Unknown default repository") end
    if p.repositoryOrder then
        assert(type(p.repositoryOrder)=="table","repositoryOrder must be a list")
        local seen={}
        for i,k in pairs(p.repositoryOrder) do
            assert(type(i)=="number" and i>=1 and i%1==0 and i<=#p.repositoryOrder,"repositoryOrder must be a dense list")
            assert(exists(k) and not seen[k],"Unknown or duplicate ordered repository"); seen[k]=true
        end
    end
    if p.packageRepositories then
        assert(type(p.packageRepositories)=="table","packageRepositories must be a table")
        for n,k in pairs(p.packageRepositories) do name(n); assert(exists(k),"Unknown repository "..tostring(k)) end
    end
    if p.entry then path(p.entry) end
    return p
end
local function project(root) return validateProject(data.parse(read(fs.combine(root,"package.lua")))) end
local function repositorySources(p,n)
    local sources,seen={},{}
    local function add(k)
        if not k or seen[k] or (k=="official" and p.officialRepository==false) then return end
        local r=p.repositories[k] or (k=="official" and OFFICIAL)
        assert(r,"Unknown repository "..tostring(k))
        if k=="official" or legacyRepository(r) then r=OFFICIAL end
        seen[k]=true; sources[#sources+1]={name=k,repository=r}
    end
    if p.packageRepositories and p.packageRepositories[n] then
        add(p.packageRepositories[n]); assert(#sources>0,"Package repository is disabled"); return sources
    end
    for _,k in ipairs(p.repositoryOrder or {}) do add(k) end
    add(p.defaultRepository or (p.repositories.default and "default"))
    for _,k in ipairs(sorted(p.repositories)) do if k~="official" then add(k) end end
    add("official")
    return sources
end
local function recover(root)
    local dir=fs.combine(root,".lpm"); local journal=fs.combine(dir,"transaction.lua")
    if not fs.exists(journal) then return end
    log.warn("Recovery","Restoring interrupted package transaction")
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
    log.info("Recovery","Previous package state restored")
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
        assert(type(x.base)=="string","Invalid locked package base")
        if x.base~="" then path(x.base) end
        assert(type(x.hashes)=="table","Missing hashes")
        for _,dst in pairs(x.manifest.files) do assert(type(x.hashes[dst])=="string" and #x.hashes[dst]==64 and x.hashes[dst]:match("^%x+$"),"Missing file hash") end
        for dep,r in pairs(x.manifest.dependencies or {}) do assert(l.packages[dep] and semver.satisfies(l.packages[dep].version,r),"Broken locked dependency") end
    end
    for n,r in pairs(p.dependencies) do assert(l.packages[n] and semver.satisfies(l.packages[n].version,r),"Missing locked dependency") end
    return l
end
local function resolve(p,prefetched)
    local cache,pins={},{}
    local function candidates(n)
        if cache[n] then return cache[n] end
        local result={}
        for _,source in ipairs(repositorySources(p,n)) do
            log.info("Search",n.." in "..source.name)
            local r=source.repository; local key=data.serialize(r)
            pins[key]=pins[key] or commit(r); local tip=pins[key]; local bp=base(r,n)
            local indexText=download(raw(r,tip,bp.."/index.lua"),262144,true)
            local manifestText,singleText,singleBase,singleURL
            if not indexText then manifestText=download(raw(r,tip,bp.."/manifest.lua"),262144,true) end
            if not indexText and not manifestText then
                singleBase=r.path or ""
                singleURL=raw(r,tip,(singleBase~="" and singleBase.."/" or "")..n..".lua")
                singleText=download(singleURL,MAX_FILE,true)
            end
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
            elseif manifestText then
                local m=manifest(data.parse(manifestText),n)
                result[1]={version=m.version,commit=tip,base=bp,repository=clone(r),manifest=m}
            elseif singleText then
                local m=singleManifest(singleText,n)
                prefetched.total=prefetched.total+#singleText
                assert(prefetched.total<=MAX_TOTAL,"Single-file discovery exceeds 8 MiB")
                prefetched.files[singleURL]=singleText
                log.info("Download",n..".lua (single-file package, "..#singleText.." bytes)")
                result[1]={version=m.version,commit=tip,base=singleBase,repository=clone(r),manifest=m}
            end
            if indexText or manifestText or singleText then
                for _,c in ipairs(result) do c.repositoryName=source.name end
                log.debug("Resolve","Found "..#result.." candidate version(s) for "..n.." in "..source.name)
                cache[n]=result; return result
            end
        end
        error("Package not found in configured repositories: "..n.."; check lpm repo list and package source pins",0)
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
                log.debug("Resolve","Trying "..missing.." "..c.version)
                if not c.manifest then c.manifest=manifest(data.parse(download(raw(c.repository,c.commit,c.base.."/manifest.lua"),262144)),missing) end
                assert(c.manifest.version==c.version,"Index version differs from manifest")
                local nextChosen,nextReq=clone(chosen),clone(requirements); nextChosen[missing]=clone(c)
                for dep,r in pairs(c.manifest.dependencies or {}) do nextReq[dep]=nextReq[dep] or {}; table.insert(nextReq[dep],r) end
                local answer=solve(nextChosen,nextReq); if answer then return answer end
                log.debug("Resolve","Backtracking from "..missing.." "..c.version)
            end
        end
    end
    local req={}; for n,r in pairs(p.dependencies) do req[n]={r} end
    return assert(solve({},req),"Incompatible dependency constraints; no valid version set")
end
function M.init(root)
    assert(not fs.exists(fs.combine(root,"package.lua")),"package.lua already exists")
    local n=fs.getName(root):lower():gsub("[^a-z0-9_-]","-"); if not n:match("^[a-z]") then n="project-"..n end
    write(fs.combine(root,"package.lua"),data.serialize({manifestVersion=1,name=n,version="0.1.0",type="application",entry="main.lua",repositories={official=clone(OFFICIAL)},defaultRepository="official",dependencies={}}))
end
-- Repository edits invalidate the project hash; the next update resolves new sources.
function M.repositories(root)
    recover(root); local p=project(root)
    return repositorySources(p),p
end
function M.configureRepository(root,action,key,value,ref,pth)
    recover(root); local p=project(root)
    if action=="add" or action=="legacy" then
        name(key); assert(key~="official","official is reserved")
        p.repositories[key]=repo({github=value,ref=ref or "main",path=pth})
        if action=="legacy" then p.defaultRepository="default" end
    elseif action=="remove" then
        assert(key~="official","Use lpm repo official disable")
        assert(p.repositories[key],"Unknown repository")
        assert(p.defaultRepository~=key,"Select another default repository first")
        for _,k in pairs(p.packageRepositories or {}) do assert(k~=key,"Repository is assigned to a package") end
        p.repositories[key]=nil
        if p.repositoryOrder then
            local order={}; for _,k in ipairs(p.repositoryOrder) do if k~=key then order[#order+1]=k end end
            p.repositoryOrder=order
        end
    elseif action=="default" then p.defaultRepository=name(key)
    elseif action=="order" then p.repositoryOrder=key
    elseif action=="use" then
        name(key); name(value); p.packageRepositories=p.packageRepositories or {}; p.packageRepositories[key]=value
    elseif action=="unuse" then name(key); if p.packageRepositories then p.packageRepositories[key]=nil end
    elseif action=="official" then
        assert(key=="enable" or key=="disable","Usage: lpm repo official enable|disable")
        p.officialRepository=key=="enable"
        if key=="disable" then
            if p.defaultRepository=="official" then p.defaultRepository=nil end
            if p.repositoryOrder then
                local order={}; for _,k in ipairs(p.repositoryOrder) do if k~="official" then order[#order+1]=k end end
                p.repositoryOrder=order
            end
        end
    else error("Unknown repository action") end
    -- Validate before replacing the user's configuration.
    validateProject(p)
    local candidate=data.serialize(p)
    write(fs.combine(root,"package.lua"),candidate)
    return p
end
function M.install(root,spec,update,remove,offline)
    local started=os.clock()
    log.info("Start",(remove and "Removing dependency" or update and "Updating dependencies" or "Installing dependencies")..(offline and " (offline)" or ""))
    recover(root); local p=project(root)
    if spec then
        local n,r=spec:match("^([^@]+)@(.+)$"); n=n or spec; name(n)
        if remove then assert(p.dependencies[n],"Not a direct dependency"); p.dependencies[n]=nil
        else r=r or "*"; semver.satisfies("0.0.0",r); p.dependencies[n]=r end
    end
    local dir=fs.combine(root,".lpm"); local current=fs.combine(dir,"current"); local lockPath=fs.combine(current,"package.lock")
    local l
    local prefetched={files={},total=0}
    if not spec and not update and fs.exists(lockPath) then
        log.info("Lock","Restoring exact versions from package.lock")
        l=validateLock(p,data.parse(read(lockPath)))
    else
        assert(not offline,"Offline install requires a matching lockfile")
        log.info("Resolve","Resolving direct and transitive dependencies")
        l={lockVersion=1,projectHash=sha256(data.serialize(p)),packages=resolve(p,prefetched)}
    end
    local previous=fs.exists(lockPath) and data.parse(read(lockPath)).packages or {}
    local packageCount,fileCount,removed=0,0,0
    for _,n in ipairs(sorted(l.packages)) do
        local x=l.packages[n]; packageCount=packageCount+1
        for _ in pairs(x.manifest.files) do fileCount=fileCount+1 end
        local old=previous[n]
        local action=not old and "Install" or (old.version~=x.version or old.commit~=x.commit or data.serialize(old.repository)~=data.serialize(x.repository)) and "Update" or "Restore"
        log.info("Plan",action.." "..n.." "..(old and old.version~=x.version and (old.version.." -> ") or "")..x.version.." ["..(x.repositoryName or x.repository.github).." "..x.commit:sub(1,12).."]")
    end
    for _,n in ipairs(sorted(previous)) do if not l.packages[n] then removed=removed+1; log.info("Plan","Remove "..n.." "..previous[n].version) end end
    log.info("Plan",packageCount.." package(s), "..fileCount.." file(s), "..removed.." removal(s)")
    local stage=fs.combine(dir,"stage"); if fs.exists(stage) then fs.delete(stage) end; fs.makeDir(stage)
    local total,fetched,reused,position=0,0,0,0
    local ok,err=pcall(function()
        for _,n in ipairs(sorted(l.packages)) do
            local x=l.packages[n]; local previousHashes=x.hashes; x.hashes={}
            for _,src in ipairs(sorted(x.manifest.files)) do
                local dst=x.manifest.files[src]; local bytes
                position=position+1
                local label="("..position.."/"..fileCount..") "..n.."/"..dst
                local existing=fs.combine(current,"packages/"..n.."/"..dst)
                if previousHashes and fs.exists(existing) then
                    local old=read(existing); if sha256(old)==previousHashes[dst] then bytes=old; reused=reused+1; log.debug("Cache",label.." verified locally")
                    else log.warn("Cache",n.."/"..dst.." is corrupt; fetching a fresh copy") end
                end
                if not bytes then
                    assert(not offline,"Offline file unavailable or corrupt: "..n.."/"..dst)
                    local url=src:sub(1,8)=="https://" and src or raw(x.repository,x.commit,(x.base~="" and x.base.."/" or "")..src)
                    if prefetched.files[url] then
                        bytes=prefetched.files[url]; prefetched.files[url]=nil
                        log.info("Stage",label.." (downloaded during single-file discovery)")
                    else
                        log.info("Download",label..(src:sub(1,8)=="https://" and " (proxy)" or ""))
                        bytes=download(url,MAX_FILE)
                    end
                    fetched=fetched+1
                end
                total=total+#bytes; assert(total<=MAX_TOTAL,"Install exceeds 8 MiB")
                local hash=sha256(bytes); if previousHashes then assert(hash==previousHashes[dst],"SHA-256 mismatch: "..n.."/"..dst) end
                if x.manifest.hashes and x.manifest.hashes[src] then assert(hash==x.manifest.hashes[src],"Manifest hash mismatch") end
                log.debug("Verify",label.." SHA-256 OK ("..#bytes.." bytes)")
                x.hashes[dst]=hash; write(fs.combine(stage,"packages/"..n.."/"..dst),bytes)
            end
        end
        log.info("Verify","Hashed "..fileCount.." file(s); checked available lock and publisher hashes")
        log.info("Activate","Committing package files, module loaders and lockfile")
        activate(root,p,l,stage)
    end)
    if not ok then
        log.warn("Rollback","Installation failed; restoring previous state")
        recover(root); if fs.exists(stage) then fs.delete(stage) end
        log.info("Rollback","Previous installation retained")
        error(err,0)
    end
    log.info("Done",string.format("%d package(s), %d file(s), %d downloaded, %d reused, %d removed; %d bytes staged in %.2fs",packageCount,fileCount,fetched,reused,removed,total,os.clock()-started))
    return l
end
function M.lock(root)
    recover(root); local p=project(root)
    return validateLock(p,data.parse(read(fs.combine(root,".lpm/current/package.lock")))),p
end
function M.verify(root)
    log.info("Verify","Checking installed files and generated loaders")
    local l=M.lock(root); local count=0
    for n,x in pairs(l.packages) do for dst,hash in pairs(x.hashes) do
        assert(sha256(read(fs.combine(root,".lpm/current/packages/"..n.."/"..dst)))==hash,"Corrupt file: "..n.."/"..dst); count=count+1
    end end
    for dst,hash in pairs(l.exports or {}) do
        path(dst); assert(sha256(read(fs.combine(root,dst)))==hash,"Edited module loader: "..dst)
    end
    return count
end
local function bundleVersion(bytes)
    local v=bytes:match("^%-%- LPM (%d+%.%d+%.%d+)%. Generated by tools/build%.py%.\n")
    assert(v,"Expected a generated LPM bundle")
    semver.parse(v); return v
end
function M.selfUpdate(ref)
    -- Always update the invoked copy, independent of the current project.
    local target=shell.getRunningProgram()
    assert(type(target)=="string" and fs.exists(target) and not fs.isDir(target),"Cannot locate running LPM script")
    log.info("Self-update","Checking official LPM source for "..target)
    local original=read(target); bundleVersion(original)
    local r=clone(builtins.selfUpdate); if ref then r.ref=ref end; repo(r)
    local pin=commit(r); local bp=base(r,"lpm")
    local m=manifest(data.parse(download(raw(r,pin,bp.."/manifest.lua"),262144)),"lpm")
    assert(m.type=="application" and m.entry=="lpm.lua","Official LPM manifest must identify lpm.lua")
    assert(semver.compare(m.version,M.version)>=0,"Refusing to downgrade LPM")
    local src
    for from,to in pairs(m.files) do if to=="lpm.lua" then src=from end end
    assert(src,"Official LPM manifest is missing lpm.lua")
    log.info("Self-update","Downloading LPM "..m.version.." at "..pin:sub(1,12))
    local bytes=download(src:sub(1,8)=="https://" and src or raw(r,pin,bp.."/"..src),MAX_FILE)
    assert(bundleVersion(bytes)==m.version,"LPM bundle version differs from manifest")
    if m.hashes and m.hashes[src] then assert(sha256(bytes)==m.hashes[src],"LPM manifest hash mismatch") end
    local fn,err=load(bytes,"@lpm-self-update","t",{})
    assert(fn,"Downloaded LPM is invalid Lua: "..tostring(err)) -- Compile only; never execute the download here.
    log.info("Verify","LPM header, version, Lua syntax and available checksum validated")
    if bytes==original then log.info("Self-update","Already current; no files changed"); return false,m.version,pin end
    local pending,backup=target..".lpm-new",target..".lpm-backup"
    assert(not fs.exists(pending),"Update staging file already exists: "..pending)
    if fs.exists(backup) then
        assert(not fs.isDir(backup),"Update backup is a directory")
        bundleVersion(read(backup)) -- Preserve unrelated files occupying the backup name.
    end
    local moved=false
    local ok,problem=pcall(function()
        log.info("Self-update","Staging "..#bytes.." bytes; backup: "..backup)
        write(pending,bytes); assert(read(pending)==bytes,"LPM staging verification failed")
        assert(read(target)==original,"Running LPM changed during update")
        if fs.exists(backup) then fs.delete(backup) end
        fs.move(target,backup); moved=true
        fs.move(pending,target)
        assert(read(target)==bytes,"LPM replacement verification failed")
    end)
    if not ok then
        log.warn("Rollback","Self-update failed; preserving previous LPM script")
        if moved then
            if fs.exists(target) then fs.delete(target) end
            fs.move(backup,target)
        end
        if fs.exists(pending) then fs.delete(pending) end
        error(problem,0)
    end
    log.info("Done","Updated LPM to "..m.version.."; next invocation uses the new script")
    return true,m.version,pin
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
