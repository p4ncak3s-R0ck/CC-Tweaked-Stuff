local U=require('rfs_common')
local C=U.crypto
local M={version='0.1.0',protocol=U.protocol,hash=U.hash}
function M.connect(target,options)
    options=options or {}
    if type(target)=='string' and target:match('^%d+$') then target=tonumber(target) end
    if type(target)=='string' then
        U.check(type(options.resolve)=='function','DNS_REQUIRED','Provide an optional hostname resolver')
        target=options.resolve(target)
    end
    U.check(C.integer(target,0,2147483647),'BAD_SERVER','Expected a computer ID or resolved hostname')
    local client={server=target,options=options,events={},token=options.token or '',secret=options.secret}
    U.check(client.token=='' or (type(client.secret)=='string' and #client.secret>=32),'BAD_TOKEN')
    if not options.transport then U.openModems() end
    function client:request(op,args)
        local body={v=1,kind='request',id=C.nonce(),client=os.getComputerID(),server=self.server,time=U.now(),op=op,args=args or {}}
        local packet=U.pack(body,self.secret,self.token)
        local function accept(peer,p)
            if peer~=self.server or type(p)~='table' or p.token~=self.token then return nil end
            local reply=U.unpack(p,self.secret)
            if not reply or reply.v~=1 or reply.server~=self.server then return nil end
            if reply.kind=='event' then
                self.events[#self.events+1]=reply; if #self.events>256 then table.remove(self.events,1) end
                return nil
            end
            if reply.kind=='response' and reply.id==body.id and reply.client==body.client and type(reply.ok)=='boolean' then return reply end
        end
        for _=1,(self.options.retries or 3) do
            local reply
            if self.options.transport then
                local p=self.options.transport(self.server,packet); reply=accept(self.server,p)
            else
                rednet.send(self.server,packet,U.protocol)
                local deadline=os.clock()+(self.options.timeout or 3)
                repeat
                    local peer,p=rednet.receive(U.protocol,math.max(0,deadline-os.clock()))
                    if peer then reply=accept(peer,p) end
                until reply or os.clock()>=deadline
            end
            if reply then
                if reply.ok then return reply.result end
                local e=reply.error or {code='BAD_RESPONSE'}; return nil,e.message or e.code,e.code
            end
        end
        return nil,'Server did not respond','TIMEOUT'
    end
    function client:must(op,args)
        local value,e,code=self:request(op,args); U.check(value,code,e); return value
    end
    function client:hello() return self:request('hello') end
    function client:shares() return self:request('shares') end
    function client:stat(share,path,options)
        options=options or {}; return self:request('stat',{share=share,path=path,revision=options.revision,ifRevision=options.ifRevision})
    end
    function client:list(share,path)
        local out,offset={},0
        repeat
            local r,e,code=self:request('list',{share=share,path=path or '',offset=offset})
            if not r then return nil,e,code end
            for _,item in ipairs(r.entries) do out[#out+1]=item end
            U.check(r.done or r.nextOffset>offset,'BAD_RESPONSE'); offset=r.nextOffset
            if r.done then return out end
        until false
    end
    function client:history(share,path)
        local out,offset={},0
        repeat
            local r,e,code=self:request('history',{share=share,path=path,offset=offset})
            if not r then return nil,e,code end
            for _,item in ipairs(r.versions) do out[#out+1]=item end
            U.check(r.done or r.nextOffset>offset,'BAD_RESPONSE'); offset=r.nextOffset
            if r.done then return out end
        until false
    end
    function client:batch(requests) return self:request('batch',{requests=requests}) end
    function client:cancel(transfer) return self:request('cancel',{transfer=transfer}) end
    function client:mkdir(share,path) return self:request('mkdir',{share=share,path=path}) end
    function client:delete(share,path,expected,recursive)
        return self:request('delete',{share=share,path=path,expected=expected,recursive=recursive==true})
    end
    function client:move(share,path,destination,expected) return self:request('move',{share=share,path=path,destination=destination,expected=expected}) end
    function client:restore(share,path,revision,expected) return self:request('restore',{share=share,path=path,revision=revision,expected=expected}) end
    function client:grant(id,expires,permissions)
        U.check(self.secret,'ACCESS_DENIED')
        local nonce=C.nonce(); local r,e,code=self:request('grant',{id=id,nonce=nonce,expires=expires,permissions=permissions})
        if not r then return nil,e,code end
        return {token=id,secret=C.hex(C.hmac(self.secret,'rfs-grant-v1\0'..id..'\0'..nonce)),expires=expires}
    end
    function client:revoke(id) return self:request('revoke',{id=id}) end
    function client:watch(share,path) return self:request('watch',{share=share,path=path or ''}) end
    function client:unwatch(watch) return self:request('unwatch',{watch=watch}) end
    function client:changes(share,path,sequence) return self:request('changes',{share=share,path=path or '',sequence=sequence}) end
    function client:nextEvent(timeout)
        if #self.events>0 then return table.remove(self.events,1) end
        if self.options.transport then return nil end
        local deadline=os.clock()+(timeout or 3)
        repeat
            local peer,p=rednet.receive(U.protocol,math.max(0,deadline-os.clock()))
            if peer==self.server and type(p)=='table' and p.token==self.token then
                local b=U.unpack(p,self.secret)
                if b and b.v==1 and b.kind=='event' and b.server==self.server then return b end
            end
        until os.clock()>=deadline
        return nil
    end
    function client:readRange(share,path,offset,length,revision)
        local t,e,code=self:request('open',{share=share,path=path,revision=revision,chunk=self.options.chunk or 4096})
        if not t then return nil,e,code end
        local ok,result=pcall(function()
            U.check(C.integer(offset,0,t.meta.size) and C.integer(length,0,U.maxFile),'BAD_REQUEST')
            local parts={}; local finish=math.min(t.meta.size,offset+length)
            while offset<finish do
                local r=self:must('read',{transfer=t.transfer,offset=offset,length=math.min(t.chunk,finish-offset)})
                U.check(r.offset==offset and type(r.data)=='string' and #r.data>0 and #r.data<=finish-offset and U.hash(r.data)==r.hash and r.revision==t.meta.revision,'HASH_MISMATCH')
                parts[#parts+1]=r.data; offset=offset+#r.data
            end
            return table.concat(parts)
        end)
        self:cancel(t.transfer)
        if not ok then local err=type(result)=='table' and result or {code='IO_ERROR',message=tostring(result)}; return nil,err.message or err.code,err.code end
        return result,t.meta
    end
    function client:download(share,path,destination,options)
        options=options or {}; local active
        local ok,result=pcall(function()
            U.check(type(destination)=='string' and destination~='','BAD_PATH')
            U.check(not fs.exists(destination) or not fs.isDir(destination),'BAD_PATH')
            local t=self:must('open',{share=share,path=path,revision=options.revision,chunk=self.options.chunk or 4096})
            active=t.transfer
            U.check(type(t.meta.hash)=='string' and C.integer(t.meta.size,0,U.maxFile) and C.integer(t.chunk,256,U.maxChunk),'BAD_RESPONSE')
            if options.hash then U.check(t.meta.hash==options.hash,'HASH_MISMATCH','Remote file differs from trusted content') end
            local part,checkpoint=destination..'.rfs-part',destination..'.rfs-resume.json'
            U.recover(checkpoint)
            local resume=U.load(checkpoint,{})
            local bytes=''
            if options.resume~=false and resume.hash==t.meta.hash and resume.revision==t.meta.revision and fs.exists(part) and fs.getSize(part)<=t.meta.size then
                bytes=U.read(part)
                if resume.offset~=#bytes or resume.partialHash~=U.hash(bytes) then bytes='' end
            end
            U.write(part,bytes)
            local started=os.clock(); local initial=#bytes
            while #bytes<t.meta.size do
                if options.cancelled and options.cancelled() then U.check(false,'CANCELLED') end
                local offset=#bytes
                local r=self:must('read',{transfer=active,offset=offset,length=math.min(t.chunk,t.meta.size-offset)})
                U.check(r.offset==offset and r.revision==t.meta.revision and type(r.data)=='string' and #r.data>0 and #r.data<=math.min(t.chunk,t.meta.size-offset) and U.hash(r.data)==r.hash,'HASH_MISMATCH')
                local h=assert(fs.open(part,'ab')); h.write(r.data); h.close(); bytes=bytes..r.data
                U.save(checkpoint,{hash=t.meta.hash,revision=t.meta.revision,offset=#bytes,partialHash=U.hash(bytes)})
                if options.progress then
                    local elapsed=math.max(os.clock()-started,0.001); local speed=(#bytes-initial)/elapsed
                    options.progress({bytes=#bytes,total=t.meta.size,speed=speed,eta=speed>0 and (t.meta.size-#bytes)/speed or 0})
                end
            end
            U.check(U.hash(bytes)==t.meta.hash and fs.getSize(part)==t.meta.size and U.hash(U.read(part))==t.meta.hash,'HASH_MISMATCH')
            U.replace(destination,part); if fs.exists(checkpoint) then fs.delete(checkpoint) end
            return t.meta
        end)
        if active then self:cancel(active) end
        if not ok then local e=type(result)=='table' and result or {code='IO_ERROR',message=tostring(result)}; return nil,e.message or e.code,e.code end
        return result
    end
    function client:upload(share,path,source,options)
        options=options or {}; local active
        local ok,result=pcall(function()
            U.check(fs.exists(source) and not fs.isDir(source) and fs.getSize(source)<=U.maxFile,'BAD_PATH')
            local bytes=U.read(source)
            local t=self:must('upload',{share=share,path=path,size=#bytes,hash=U.hash(bytes),expected=options.expected,chunk=self.options.chunk or 4096}); active=t.transfer
            U.check(C.integer(t.chunk,256,U.maxChunk),'BAD_RESPONSE')
            for offset=0,#bytes-1,t.chunk do
                if options.cancelled and options.cancelled() then U.check(false,'CANCELLED') end
                local data=bytes:sub(offset+1,offset+t.chunk)
                self:must('write',{transfer=active,offset=offset,data=data,hash=U.hash(data)})
                if options.progress then options.progress({bytes=offset+#data,total=#bytes}) end
            end
            return self:must('commit',{transfer=active})
        end)
        if active then self:cancel(active) end
        if not ok then local e=type(result)=='table' and result or {code='IO_ERROR',message=tostring(result)}; return nil,e.message or e.code,e.code end
        return result
    end
    function client:tree(share,path)
        local out={}; local function walk(remote,relative,depth)
            U.check(depth<=32 and #out<=4096,'TOO_LARGE')
            local entries,e,code=self:list(share,remote); U.check(entries,code,e)
            for _,item in ipairs(entries) do
                U.check(type(item.name)=='string' and item.name~='' and not item.name:find('/',1,true),'BAD_RESPONSE'); U.path(item.name)
                local child=remote=='' and item.name or remote..'/'..item.name
                local rel=relative=='' and item.name or relative..'/'..item.name
                out[#out+1]={path=rel,directory=item.directory,size=item.size}
                if item.directory then walk(child,rel,depth+1) end
            end
        end
        walk(path or '','',0); return out
    end
    function client:downloadTree(share,path,destination,options)
        local tree=self:tree(share,path); fs.makeDir(destination)
        for _,item in ipairs(tree) do
            local localPath=fs.combine(destination,item.path)
            if item.directory then fs.makeDir(localPath)
            else local r,e,code=self:download(share,fs.combine(path or '',item.path),localPath,options); U.check(r,code,e) end
        end
        return {files=tree}
    end
    -- One-way synchronization. Deletes are explicitly opt-in and files only.
    function client:sync(share,path,localRoot,options)
        options=options or {}; local direction=options.direction or 'download'
        U.check(direction=='download' or direction=='upload','BAD_REQUEST','Use syncTwoWay for two-way sync')
        local report={copied={},unchanged={},deleted={}}; local remote={}
        for _,item in ipairs(self:tree(share,path)) do remote[item.path]=item end
        fs.makeDir(localRoot)
        local localFiles={}; local countLocal=0; local function scan(root,rel,depth)
            U.check(depth<=32 and countLocal<4096,'TOO_LARGE')
            for _,name in ipairs(fs.list(root)) do
                local p=fs.combine(root,name); local r=rel=='' and name or rel..'/'..name
                if not name:find('%.rfs%-') then
                    countLocal=countLocal+1
                    if fs.isDir(p) then scan(p,r,depth+1) else localFiles[r]=p end
                end
            end
        end
        scan(localRoot,'',0)
        if direction=='download' then
            for rel,item in pairs(remote) do
                local p=fs.combine(localRoot,rel); local rp=fs.combine(path or '',rel)
                if item.directory then fs.makeDir(p) else
                    local meta=self:must('stat',{share=share,path=rp})
                    if localFiles[rel] and fs.getSize(p)<=U.maxFile and U.hash(U.read(p))==meta.hash then report.unchanged[#report.unchanged+1]=rel
                    else local r,e,code=self:download(share,rp,p,{revision=meta.revision,hash=meta.hash,progress=options.progress}); U.check(r,code,e); report.copied[#report.copied+1]=rel end
                end
            end
            if options.delete==true then for rel,p in pairs(localFiles) do if not remote[rel] then fs.delete(p); report.deleted[#report.deleted+1]=rel end end end
        else
            local made={}; local function ensure(parent)
                if parent=='' or made[parent] then return end
                ensure(fs.getDir(parent)); local rp=fs.combine(path or '',parent)
                local meta,e,code=self:stat(share,rp)
                if not meta and code=='NOT_FOUND' then local r,err,c=self:mkdir(share,rp); U.check(r,c,err)
                else U.check(meta and meta.directory,code or 'BAD_PATH',e) end
                made[parent]=true
            end
            for rel,p in pairs(localFiles) do
                ensure(fs.getDir(rel)); local rp=fs.combine(path or '',rel)
                local meta,e,code=self:stat(share,rp); U.check(meta or code=='NOT_FOUND',code,e)
                U.check(fs.getSize(p)<=U.maxFile,'TOO_LARGE')
                local hash=U.hash(U.read(p))
                if meta and meta.hash==hash then report.unchanged[#report.unchanged+1]=rel
                else local r,err,c=self:upload(share,rp,p,{expected=meta and meta.revision or false,progress=options.progress}); U.check(r,c,err); report.copied[#report.copied+1]=rel end
            end
            if options.delete==true then for rel,item in pairs(remote) do if not item.directory and not localFiles[rel] then
                local rp=fs.combine(path or '',rel); local meta=self:must('stat',{share=share,path=rp}); local r,e,code=self:delete(share,rp,meta.revision); U.check(r,code,e); report.deleted[#report.deleted+1]=rel
            end end end
        end
        return report
    end
    return client
end
function M.discover(timeout)
    U.openModems(); local ids={rednet.lookup(U.protocol)}; local out={}
    for _,id in ipairs(ids) do local client=M.connect(id,{timeout=timeout or 1,retries=1}); local hello=client:hello(); if hello then out[#out+1]=hello end end
    return out
end
-- Mirrors must match independently trusted content hashes; never trust mirror metadata alone.
function M.downloadMirrors(targets,share,path,destination,hash,options)
    U.check(type(hash)=='string' and #hash==64 and hash:match('^%x+$'),'BAD_HASH')
    local failures={}
    for _,target in ipairs(targets) do
        local client=M.connect(target,options); local r,e,code=client:download(share,path,destination,{hash=hash})
        if r then return r,target end; failures[#failures+1]={server=target,error=e,code=code}
    end
    return nil,failures,'MIRRORS_FAILED'
end
-- A local trusted provider handles real public-key signatures. Missing providers fail closed.
function M.verifyRelease(manifest,trustedKeys,verify)
    U.check(type(manifest)=='table' and type(manifest.payload)=='string' and type(manifest.signature)=='string' and type(manifest.keyId)=='string','BAD_MANIFEST')
    U.check(type(verify)=='function','SIGNATURE_PROVIDER_REQUIRED')
    local key=trustedKeys[manifest.keyId]; U.check(key,'UNTRUSTED_PUBLISHER')
    U.check(verify(key,manifest.payload,manifest.signature)==true,'BAD_SIGNATURE')
    local value=C.decode(manifest.payload)
    U.check(type(value)=='table' and C.array(value.files,256),'BAD_MANIFEST')
    for _,file in ipairs(value.files) do U.path(file.path); U.check(type(file.hash)=='string' and #file.hash==64 and file.hash:match('^%x+$'),'BAD_MANIFEST') end
    return value
end
function M.server(config) return require('rfs_server').new(config) end
return M
