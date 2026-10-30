local M=require("core")
local args={...}
local root=shell.dir()
local verbose,quiet=false,false
local filtered={}
for _,arg in ipairs(args) do
    if arg=="--verbose" or arg=="-v" then verbose=true
    elseif arg=="--quiet" or arg=="-q" then quiet=true
    else filtered[#filtered+1]=arg end
end
args=filtered
M.log.configure({level=quiet and "warn" or verbose and "debug" or "info"})
local function status(message) M.log.info("Done",message) end
local help=[=[LPM 0.2.0 - GitHub packages for CC:Tweaked
lpm init                       Create package.lua
lpm install [name[@constraint]] Install/add packages
lpm install --offline          Restore from verified local files
lpm update                     Resolve latest compatible versions
lpm remove name                Remove a direct dependency
lpm list                       Show locked versions and commits
lpm verify                     Verify installed SHA-256 hashes
lpm setup                      Make lpm available from any directory
lpm self-update [ref]          Update this LPM copy from the official source
lpm repo owner/repo [ref] [path] Set default GitHub source
lpm repo list                  Show repository search order
lpm repo add name owner/repo [ref] [path]
lpm repo remove name           Remove a repository
lpm repo default name          Set preferred repository
lpm repo order name ...        Set search priority
lpm repo use package name      Pin a package to a repository
lpm repo unuse package         Clear a package source pin
lpm repo official enable|disable
lpm help                       Show help
Global flags: --verbose (-v), --quiet (-q); quiet keeps warnings/errors.
Constraints: *, 1.2.3, ^1.2.3, ~1.2.3 (stable versions only).
No package scripts or manifests are executed during installation.]=]
local function main()
    local cmd=table.remove(args,1) or "help"
    if cmd=="help" or cmd=="--help" then print(help)
    elseif cmd=="--version" then print(M.version)
    elseif cmd=="init" then assert(#args==0,"Usage: lpm init"); M.init(root); status("Created package.lua")
    elseif cmd=="install" or cmd=="update" or cmd=="remove" then
        assert(#args<=1,"Expected at most one package")
        local offline=args[1]=="--offline"; if offline then args[1]=nil end
        assert(not offline or cmd=="install","--offline is for install")
        assert(cmd~="remove" or args[1],"Usage: lpm remove name")
        assert(cmd~="update" or not args[1],"Usage: lpm update")
        local l=M.install(root,args[1],cmd=="update",cmd=="remove",offline)
        M.log.debug("Lock","Saved .lpm/current/package.lock")
    elseif cmd=="list" then
        local l=M.lock(root); local names={}; for n in pairs(l.packages) do names[#names+1]=n end; table.sort(names)
        for _,n in ipairs(names) do local x=l.packages[n]; print(n.." "..x.version.." "..x.commit:sub(1,12).." ["..(x.repositoryName or x.repository.github).."]") end
    elseif cmd=="verify" then status("Verified "..M.verify(root).." files")
    elseif cmd=="setup" then assert(#args==0,"Usage: lpm setup"); M.setup(); status("lpm is available from any directory")
    elseif cmd=="self-update" then
        assert(#args<=1,"Usage: lpm self-update [ref]")
        local changed,version,pin=M.selfUpdate(args[1])
        M.log.debug("Self-update","Selected version "..version.." at "..pin)
        if changed then M.log.debug("Self-update","Previous copy: "..shell.getRunningProgram()..".lpm-backup") end
    elseif cmd=="repo" then
        local action=table.remove(args,1) or "list"
        if action=="list" then
            assert(#args==0,"Usage: lpm repo list")
            local sources,p=M.repositories(root)
            for i,x in ipairs(sources) do
                local r=x.repository
                print(i..". "..x.name.." "..r.github.." @ "..(r.ref or "main")..(r.path and (" /"..r.path) or ""))
            end
            for n,k in pairs(p.packageRepositories or {}) do print(n.." -> "..k) end
            return
        elseif action=="add" then assert(#args>=2 and #args<=4,"Usage: lpm repo add name owner/repo [ref] [path]")
        elseif action=="order" then assert(#args>=1,"Usage: lpm repo order name ...")
        elseif action=="use" then assert(#args==2,"Usage: lpm repo use package repository")
        elseif action=="remove" or action=="default" or action=="unuse" or action=="official" then assert(#args==1,"Expected one repository argument")
        else
            assert(action:match("^[%w_.-]+/[%w_.-]+$") and #args<=2,"Unknown repository command")
            M.configureRepository(root,"legacy","default",action,args[1],args[2])
            status("Repository configured; run lpm update"); return
        end
        if action=="order" then M.configureRepository(root,action,args)
        else M.configureRepository(root,action,table.unpack(args)) end
        status("Repositories configured; run lpm update")
    else error("Unknown command: "..cmd..". Run lpm help",0) end
end
local ok,err=pcall(main)
if not ok then
    M.log.debug("Failure",M.log.url(tostring(err)))
    M.log.error("Failed",M.log.url((tostring(err):gsub("^.-:%d+:%s*",""))))
    error("LPM command failed",0)
end
