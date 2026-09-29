local M=require("core")
local args={...}
local root=shell.dir()
local help=[=[LPM 0.1.0 - GitHub packages for CC:Tweaked
lpm init                       Create package.lua
lpm install [name[@constraint]] Install/add packages
lpm install --offline          Restore from verified local files
lpm update                     Resolve latest compatible versions
lpm remove name                Remove a direct dependency
lpm list                       Show locked versions and commits
lpm verify                     Verify installed SHA-256 hashes
lpm setup                      Make lpm available from any directory
lpm repo owner/repo [ref] [path] Set default GitHub source
lpm help                       Show help
Constraints: *, 1.2.3, ^1.2.3, ~1.2.3 (stable versions only).
No package scripts or manifests are executed during installation.]=]
local function main()
    local cmd=table.remove(args,1) or "help"
    if cmd=="help" or cmd=="--help" then print(help)
    elseif cmd=="--version" then print(M.version)
    elseif cmd=="init" then assert(#args==0,"Usage: lpm init"); M.init(root); print("Created package.lua")
    elseif cmd=="install" or cmd=="update" or cmd=="remove" then
        assert(#args<=1,"Expected at most one package")
        local offline=args[1]=="--offline"; if offline then args[1]=nil end
        assert(not offline or cmd=="install","--offline is for install")
        assert(cmd~="remove" or args[1],"Usage: lpm remove name")
        assert(cmd~="update" or not args[1],"Usage: lpm update")
        local l=M.install(root,args[1],cmd=="update",cmd=="remove",offline)
        local count=0; for _ in pairs(l.packages) do count=count+1 end
        print("Installed "..count.." packages. Lockfile: .lpm/current/package.lock")
    elseif cmd=="list" then
        local l=M.lock(root); local names={}; for n in pairs(l.packages) do names[#names+1]=n end; table.sort(names)
        for _,n in ipairs(names) do local x=l.packages[n]; print(n.." "..x.version.." "..x.commit:sub(1,12)) end
    elseif cmd=="verify" then print("Verified "..M.verify(root).." files")
    elseif cmd=="setup" then assert(#args==0,"Usage: lpm setup"); M.setup(); print("lpm is available from any directory")
    elseif cmd=="repo" then
        assert(#args>=1 and #args<=3,"Usage: lpm repo owner/repo [ref] [path]")
        assert(args[1]:match("^[%w_.-]+/[%w_.-]+$"),"Invalid owner/repo")
        local pth=fs.combine(root,"package.lua"); local h=assert(fs.open(pth,"r")); local p=M.data.parse(h.readAll()); h.close()
        p.repositories=p.repositories or {}; p.repositories.default={github=args[1],ref=args[2] or "main",path=args[3]}
        h=assert(fs.open(pth,"w")); h.write(M.data.serialize(p)); h.close(); print("Repository configured; run lpm update")
    else error("Unknown command: "..cmd..". Run lpm help",0) end
end
local ok,err=pcall(main)
if not ok then printError("lpm: "..tostring(err)); error("LPM command failed",0) end
