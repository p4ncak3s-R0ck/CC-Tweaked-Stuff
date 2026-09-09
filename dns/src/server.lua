-- Authenticated Rednet DNS v2. Requires dns.lua beside this file.
-- dnsServer [modem] [directory]
-- dnsServer --user <username> <reader|admin> [directory]  (stop server first)
-- dnsServer --check [directory]
local I=require("dns")._internal
local SESSION_TTL=1800
local CHALLENGE_TTL=180
assert(type(SESSION_TTL)=="number" and SESSION_TTL%1==0 and SESSION_TTL>=1 and SESSION_TTL<=3600,"SESSION_TTL must be 1..3600")
local LOG_QUERIES=true
local DEFAULT_DIRECTORY="/"
local MAGIC_AUTH="RNAUTH\2\0"
local MAGIC_RECORDS="RNRECS\2\0"
local args={...}
local mode=args[1]
local directory=DEFAULT_DIRECTORY
if mode=="--user" then directory=args[4] or directory
elseif mode=="--check" then directory=args[2] or directory
else directory=args[2] or directory end
if shell and shell.resolve then directory=shell.resolve(directory) end
if (mode=="--user" and (#args<3 or #args>4)) or (mode=="--check" and #args>2)
    or (mode and mode:sub(1,2)=="--" and mode~="--user" and mode~="--check")
    or (mode~="--user" and mode~="--check" and #args>2) then
    error("Usage: dnsServer [modem] [directory] | --user <name> <reader|admin> [directory] | --check [directory]",0)
end
local authPath=fs.combine(directory,"auth.bin")
local recordsPath=fs.combine(directory,"records.bin")
local function validateAuth(db)
    assert(type(db)=="table" and db.version==2,"Unsupported auth database version")
    assert(I.integer(db.revision,1,4294967295),"Invalid auth database revision")
    assert(type(db.secret)=="string" and #db.secret==32,"Invalid server secret")
    assert(type(db.users)=="table","Invalid users")
    local count,admins=0,0
    for name,user in pairs(db.users) do
        assert(I.username(name) and type(user)=="table","Invalid user entry")
        assert(user.role=="reader" or user.role=="admin","Invalid user role")
        assert(type(user.salt)=="string" and #user.salt==64,"Invalid password salt")
        assert(type(user.key)=="string" and #user.key==32,"Invalid password verifier")
        assert(I.integer(user.iterations,1000,100000),"Invalid password iteration count")
        count=count+1; if user.role=="admin" then admins=admins+1 end
    end
    assert(count<=64 and admins>=1,"Auth database requires at least one admin and at most 64 users")
    return true
end
local function validateRecords(db)
    assert(type(db)=="table" and db.version==2,"Unsupported records database version")
    assert(I.integer(db.revision,1,4294967295),"Invalid records database revision")
    assert(I.array(db.records,512),"Records must be an array of at most 512 items")
    for n,r in ipairs(db.records) do db.records[n]=I.record(r) end
    return I.index(db.records)
end
local function formatFor(path)
    if path==authPath then return MAGIC_AUTH,validateAuth end
    return MAGIC_RECORDS,validateRecords
end
local function readDatabase(path,filename)
    local magic,validate=formatFor(path)
    assert(fs.getSize(filename)<=I.maxBytes+44,"Database is too large")
    local f=assert(fs.open(filename,"rb")); local bytes=f.readAll(); f.close()
    assert(type(bytes)=="string" and bytes:sub(1,#magic)==magic,"Invalid database header")
    local p=#magic+1
    local a,b,c,d=bytes:byte(p,p+3); assert(d,"Truncated database")
    local length=((a*256+b)*256+c)*256+d
    local digest=bytes:sub(p+4,p+35); local payload=bytes:sub(p+36)
    assert(#payload==length and I.equal(digest,I.sha256(payload)),"Database checksum mismatch")
    local db=I.decode(payload); validate(db); return db
end
local function loadDatabase(path,repair)
    local best,bestPath,found
    for _,filename in ipairs({path,path..".tmp",path..".bak"}) do
        if fs.exists(filename) then
            found=true
            local ok,db=pcall(readDatabase,path,filename)
            if ok and (not best or db.revision>best.revision) then best,bestPath=db,filename end
            if not ok then print("Ignoring invalid database candidate: "..filename) end
        end
    end
    if not best and found then error("No valid copy of "..path..". Restore a backup; files were preserved.",0) end
    if best and repair and bestPath~=path then
        -- Preserve the recovery source until the copy to the main path succeeds.
        if fs.exists(path) then fs.delete(path) end
        fs.copy(bestPath,path)
        readDatabase(path,path)
        print("Recovered "..path.." revision "..best.revision.." from "..bestPath)
    end
    return best,bestPath
end
local function writeDatabase(path,db)
    local magic,validate=formatFor(path)
    validate(db)
    local payload=I.encode(db)
    local bytes=magic..I.u32(#payload)..I.sha256(payload)..payload
    local temporary=path..".tmp"
    if fs.exists(temporary) then fs.delete(temporary) end
    local f=assert(fs.open(temporary,"wb"),"Cannot open temporary database")
    local ok,err=pcall(f.write,bytes)
    f.close(); assert(ok,err)
    readDatabase(path,temporary) -- Verify before rotating the previous committed copy.
    if fs.exists(path) then
        if fs.exists(path..".bak") then fs.delete(path..".bak") end
        fs.move(path,path..".bak")
    end
    fs.move(temporary,path)
end
local function passwordUser(username,role,secret)
    assert(I.username(username),"Username: 1..32 lowercase letters, digits, _ or -")
    assert(role=="reader" or role=="admin","Role must be reader or admin")
    write("Password (12+ characters): "); local password=read("*")
    write("Confirm password: "); local confirm=read("*")
    assert(password==confirm and #password>=12 and #password<=256,"Passwords must match and be 12..256 bytes")
    print("Deriving password verifier...")
    local salt=I.nonce(secret)
    return {role=role,salt=salt,iterations=I.iterations,key=I.pbkdf2(password,salt,I.iterations)}
end
local auth,authFrom=loadDatabase(authPath,mode~="--check")
local recordsDB,recordsFrom=loadDatabase(recordsPath,mode~="--check")
if mode=="--check" then
    assert(auth and recordsDB,"Both auth.bin and records.bin must exist")
    print("Valid auth revision "..auth.revision.." at "..authFrom)
    print("Valid records revision "..recordsDB.revision.." at "..recordsFrom)
    print(#recordsDB.records.." records. Both binary objects validated.")
    return
end
if not fs.exists(directory) then fs.makeDir(directory) end
local createdAuth=false
if not auth then
    if mode=="--user" then assert(args[3]=="admin","First user must be an admin") end
    print("Creating "..authPath)
    local username=args[2]
    if mode~="--user" then write("Initial admin username: "); username=read() end
    local user=passwordUser(username,"admin")
    -- Bootstrap unpredictability comes from the initial password-derived key.
    auth={version=2,revision=1,secret=I.hmac(user.key,"server-secret\0"..I.nonce()),users={[username]=user}}
    writeDatabase(authPath,auth)
    createdAuth=true
    print("Created admin "..username)
end
if not recordsDB then
    recordsDB={version=2,revision=1,records={}}
    writeDatabase(recordsPath,recordsDB)
    print("Created empty "..recordsPath)
end
if mode=="--user" then
    if not createdAuth then
        local changed=I.clone(auth)
        changed.users[args[2]]=passwordUser(args[2],args[3],auth.secret)
        changed.revision=changed.revision+1
        validateAuth(changed); writeDatabase(authPath,changed)
    end
    print("Saved user "..args[2].." with role "..args[3]..". Restart the server.")
    return
end
local index=validateRecords(recordsDB) -- Authoritative record index cached in RAM.
if mode then rednet.open(mode) else
    for _,name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name,"modem") then rednet.open(name) end
    end
end
assert(rednet.isOpen(),"Attach a modem, then restart")
print("Authenticated Rednet DNS | server ID "..os.getComputerID())
print("Records cached in RAM: "..#recordsDB.records.." | revision "..recordsDB.revision)
print("Files: "..authPath.." and "..recordsPath)
print("Ctrl+T stops. Use --user locally to create users or reset passwords.")

local sessions,pending={},{}
local fatalIO=false
local function cleanup()
    local now=os.clock()
    for id,s in pairs(sessions) do if now>=s.expires then sessions[id]=nil end end
    for id,p in pairs(pending) do if now>=p.expires then pending[id]=nil end end
end
local function count(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end
local function commit(changed,isAuth)
    local current=isAuth and auth or recordsDB
    local path=isAuth and authPath or recordsPath
    local validate=isAuth and validateAuth or validateRecords
    changed.revision=current.revision+1
    local ok,newIndex=pcall(validate,changed)
    if not ok then return nil,tostring(newIndex),"BAD_RECORDS" end
    local fits=pcall(I.encode,changed)
    if not fits then return nil,"Database size or complexity limit exceeded","LIMIT" end
    local saved,err=pcall(writeDatabase,path,changed)
    if not saved then
        fatalIO=true
        return nil,"Database save failed; server will stop. Check files before retrying.","IO_ERROR"
    end
    if isAuth then auth=changed else recordsDB,index=changed,newIndex end
    return {revision=changed.revision}
end
local function revoke(username)
    for _,s in pairs(sessions) do if s.username==username then s.revoked=true end end
    -- Invalidate in-progress logins made with the old role/credentials too.
    for sender,p in pairs(pending) do if p.username==username then pending[sender]=nil end end
end
local function process(s,op,a)
    if s.revoked or not auth.users[s.username] then return nil,"Authenticate again","AUTH_REQUIRED" end
    if op=="logout" then s.revoked=true; return true end
    if op=="lookup" then
        local q,err,code=I.question(a.type,a.name)
        if not q then return nil,err,code end
        return I.resolve(index,q.type,q.name)
    end
    if auth.users[s.username].role~="admin" then return nil,"Administrator role required","FORBIDDEN" end
    if op=="listRecords" then
        if not I.integer(a.offset,0,512) or not I.integer(a.limit,1,8) then
            return nil,"Invalid pagination","BAD_ARGUMENT"
        end
        local records={}
        for n=a.offset+1,math.min(#recordsDB.records,a.offset+a.limit) do records[#records+1]=recordsDB.records[n] end
        local nextOffset=a.offset+#records
        return {records=records,total=#recordsDB.records,revision=recordsDB.revision,
            nextOffset=nextOffset<#recordsDB.records and nextOffset or false}
    elseif op=="setRecords" then
        local q,err,code=I.question(a.type,a.name); if not q then return nil,err,code end
        if not I.array(a.records,64) then return nil,"Invalid record array","BAD_ARGUMENT" end
        local changed=I.clone(recordsDB); local records={}
        for _,r in ipairs(recordsDB.records) do
            if r.name~=q.name or r.type~=q.type then records[#records+1]=r end
        end
        for _,r in ipairs(a.records) do
            if type(r)~="table" then return nil,"Invalid record","BAD_RECORDS" end
            local ok,clean=pcall(I.record,{name=q.name,type=q.type,value=r.value,ttl=r.ttl})
            if not ok then return nil,tostring(clean),"BAD_RECORDS" end
            records[#records+1]=clean
        end
        changed.records=records
        return commit(changed)
    elseif op=="reloadRecords" then
        local ok,loaded=pcall(loadDatabase,recordsPath,true)
        if not ok or not loaded then return nil,"No valid records file to reload","IO_ERROR" end
        recordsDB,index=loaded,validateRecords(loaded)
        return {revision=recordsDB.revision,count=#recordsDB.records}
    elseif op=="listUsers" then
        local users={}
        for name,user in pairs(auth.users) do users[#users+1]={username=name,role=user.role} end
        table.sort(users,function(a,b) return a.username<b.username end)
        return users -- Never expose salts, verifiers, or the server secret here.
    elseif op=="setRole" or op=="deleteUser" then
        if not I.username(a.username) or not auth.users[a.username] then return nil,"User not found","NO_USER" end
        if op=="setRole" and a.role~="reader" and a.role~="admin" then return nil,"Invalid role","BAD_ARGUMENT" end
        local changed=I.clone(auth)
        if op=="setRole" then changed.users[a.username].role=a.role else changed.users[a.username]=nil end
        local admins=0; for _,u in pairs(changed.users) do if u.role=="admin" then admins=admins+1 end end
        if admins==0 then return nil,"Cannot remove or demote the last admin","LAST_ADMIN" end
        local result,err,code=commit(changed,true)
        if result then revoke(a.username) end
        return result,err,code
    end
    return nil,"Unknown operation","NOTIMP"
end
local function send(sender,message) rednet.send(sender,message,I.protocol) end
local function handle(sender,message)
    cleanup()
    if not I.integer(sender,0,2147483647) or type(message)~="table" then return end
    if message.kind=="hello" then
        if not I.username(message.username) or type(message.client)~="string" or #message.client~=64 then return end
        local previous=pending[sender]
        if previous and previous.client==message.client and previous.username==message.username then
            send(sender,previous.challenge); return
        end
        if previous and os.clock()-previous.created<2 then return end
        if not previous and count(pending)>=64 then return end
        local user=auth.users[message.username]
        local salt=user and user.salt or I.hex(I.hmac(auth.secret,"unknown-salt\0"..message.username))
        local iterations=user and user.iterations or I.iterations
        local nonce=I.nonce(auth.secret)
        local challenge={kind="challenge",client=message.client,nonce=nonce,salt=salt,iterations=iterations}
        pending[sender]={username=message.username,client=message.client,nonce=nonce,
            created=os.clock(),expires=os.clock()+CHALLENGE_TTL,challenge=challenge,
            key=user and user.key or I.hmac(auth.secret,"unknown-key\0"..message.username),known=user~=nil}
        send(sender,challenge)
    elseif message.kind=="proof" then
        local p=pending[sender]
        if not p or p.client~=message.client or p.nonce~=message.nonce or p.failed then return end
        if p.welcome then
            if I.equal(message.proof,p.proof) then send(sender,p.welcome) end
            return
        end
        local transcript={username=p.username,client=p.client,nonce=p.nonce,server=os.getComputerID(),
            sender=sender,salt=p.challenge.salt,iterations=p.challenge.iterations}
        local proof=I.hmac(p.key,"dns-login-v2\0"..I.encode(transcript))
        if not p.known or not I.equal(proof,message.proof) then p.failed=true; return end
        if count(sessions)>=64 then
            local oldest,expires=nil,math.huge
            for oldId,s in pairs(sessions) do
                if s.revoked and s.expires<expires then oldest,expires=oldId,s.expires end
            end
            if oldest then sessions[oldest]=nil else return end
        end
        local sameSender=0
        for _,s in pairs(sessions) do if s.sender==sender and not s.revoked then sameSender=sameSender+1 end end
        if sameSender>=8 then return end
        local c2s,s2c=I.sessionKeys(p.key,transcript)
        local id=I.nonce(auth.secret)
        sessions[id]={sender=sender,username=p.username,c2s=c2s,s2c=s2c,
            expires=os.clock()+SESSION_TTL,last=0}
        p.welcome=I.packet(s2c,{kind="welcome",client=p.client,nonce=p.nonce,session=id,
            role=auth.users[p.username].role,ttl=SESSION_TTL})
        p.proof=message.proof
        send(sender,p.welcome)
    elseif type(message.session)=="string" then
        local s=sessions[message.session]
        if not s or s.sender~=sender then return end
        local body=I.unpackPacket(s.c2s,message)
        if not body or body.kind~="request" or body.session~=message.session
            or not I.integer(body.seq,1,4294967295) or type(body.op)~="string" or #body.op>32
            or type(body.args)~="table" then return end
        if body.seq==s.last and s.lastPayload==message.payload then send(sender,s.lastReply); return end
        if body.seq~=s.last+1 then return end
        local result,err,code=process(s,body.op,body.args)
        local response={kind="response",session=body.session,seq=body.seq,op=body.op,ok=result~=nil}
        if result~=nil then response.data=result else response.error=err; response.code=code end
        local ok,reply=pcall(I.packet,s.s2c,response)
        if not ok then
            reply=I.packet(s.s2c,{kind="response",session=body.session,seq=body.seq,op=body.op,
                ok=false,error="Response exceeds the packet size limit",code="RESPONSE_TOO_LARGE"})
        end
        -- Cache before sending: retransmitting the last request never repeats a write.
        s.last,s.lastPayload,s.lastReply=body.seq,message.payload,reply
        send(sender,reply)
        if LOG_QUERIES then print(s.username.." #"..sender.." "..body.op.." "..(response.code or "OK")) end
    end
end
while true do
    local sender,message=rednet.receive(I.protocol)
    handle(sender,message)
    if fatalIO then error("Database write failed. Stopped to avoid serving uncertain state.",0) end
end
