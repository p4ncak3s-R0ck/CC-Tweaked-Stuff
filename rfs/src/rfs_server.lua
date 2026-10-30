local U = require('rfs_common')
local C = U.crypto
local M = {}
local function count(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end
local function ident(s) return type(s)=='string' and #s<=64 and s:match('^[%w_-]+$') end
function M.new(config)
    U.check(type(config)=='table' and type(config.shares)=='table','BAD_CONFIG')
    local S={config=config, state=config.state or '/.rfs', transfers={}, cache={}, watches={}, outbox={}}
    S.id=os.getComputerID()
    U.path(S.state:gsub('^/',''))
    fs.makeDir(S.state)
    U.recover(fs.combine(S.state,'index.json'))
    S.index=U.load(fs.combine(S.state,'index.json'),{paths={},sequence=0,events={}})
    S.tokens=U.load(fs.combine(S.state,'tokens.json'),{})
    for id,t in pairs(config.tokens or {}) do S.tokens[id]=t end
    for id,t in pairs(S.tokens) do
        U.check(ident(id) and type(t.secret)=='string' and #t.secret>=32 and type(t.permissions)=='table','BAD_CONFIG','Tokens require 32+ byte secrets and permissions')
    end
    local roots={}
    local stateRoot=fs.combine(S.state,'')
    for name,share in pairs(config.shares) do
        U.check(ident(name) and type(share.root)=='string','BAD_CONFIG')
        local root=fs.combine(share.root,'')
        U.check(root~='' and not U.within(stateRoot,root) and not U.within(root,stateRoot),'BAD_CONFIG','Share and private state roots must be separate')
        for _,old in ipairs(roots) do U.check(not U.within(root,old) and not U.within(old,root),'BAD_CONFIG','Shares must not overlap') end
        roots[#roots+1]=root; share.root=root; fs.makeDir(root)
    end
    function S:save() U.save(fs.combine(self.state,'index.json'),self.index) end
    function S:location(share,path)
        U.check(ident(share) and self.config.shares[share],'NOT_FOUND','Unknown share')
        U.path(path)
        -- Recovery suffixes are reserved; never allow access to staging or backups.
        U.check(not path:find('%.rfs%-old') and not path:find('%.rfs%-new'),'BAD_PATH')
        return fs.combine(self.config.shares[share].root,path)
    end
    function S:allowed(token,share,path,op)
        self:location(share,path)
        if not token then
            local public=self.config.shares[share].public
            return public==true and (op=='read' or op=='list' or op=='watch')
        end
        if token.expires and token.expires<=U.now() then return false end
        for _,p in ipairs(token.permissions) do
            if p.share==share and U.within(path,p.prefix or '') and (p.operations or {})[op]==true then return true end
        end
        return false
    end
    function S:permit(token,share,path,op) U.check(self:allowed(token,share,path,op),'ACCESS_DENIED') end
    function S:event(share,path,kind,revision)
        self.index.sequence=self.index.sequence+1
        local e={sequence=self.index.sequence,share=share,path=path,kind=kind,revision=revision or ''}
        self.index.events[#self.index.events+1]=e
        if #self.index.events>256 then table.remove(self.index.events,1) end
        for _,w in pairs(self.watches) do
            local token=w.token~='' and self.tokens[w.token] or nil
            if w.expires>U.now() and w.share==share and U.within(path,w.path) and self:allowed(token,share,path,'watch') then
                self.outbox[#self.outbox+1]={peer=w.peer,token=w.token,body={v=1,kind='event',server=self.id,watch=w.id,event=e}}
                if #self.outbox>256 then table.remove(self.outbox,1) end
            end
        end
    end
    function S:record(share,path,bytes,force)
        local key=share..'/'..path
        local item=self.index.paths[key] or {generation=0,versions={}}
        local hash=bytes and U.hash(bytes) or false
        if not force and item.current and item.current.hash==hash then return item.current end
        item.generation=item.generation+1
        local rev=tostring(item.generation)..'-'..(hash or 'deleted')
        local v={revision=rev,hash=hash,size=bytes and #bytes or 0,deleted=not bytes,time=U.now()}
        if bytes then
            local object=fs.combine(self.state,'objects/'..hash)
            if not fs.exists(object) then U.write(object,bytes) end
        end
        item.current=v; item.versions[#item.versions+1]=v; self.index.paths[key]=item
        self:event(share,path,bytes and 'changed' or 'deleted',rev); self:save(); return v
    end
    function S:stat(share,path,revision)
        local disk=self:location(share,path); U.recover(disk)
        if revision then
            local item=self.index.paths[share..'/'..path]
            for _,v in ipairs(item and item.versions or {}) do if v.revision==revision then return v end end
            U.check(false,'NOT_FOUND','Revision not found')
        end
        if not fs.exists(disk) then
            local old=self.index.paths[share..'/'..path]
            if old and old.current and not old.current.deleted then self:record(share,path,nil) end
            U.check(false,'NOT_FOUND')
        end
        if fs.isDir(disk) then return {directory=true,size=0} end
        U.check(fs.getSize(disk)<=U.maxFile,'TOO_LARGE')
        return self:record(share,path,U.read(disk))
    end
    function S:publish(share,path,bytes,expected,force)
        local disk=self:location(share,path)
        U.check(path~='' and not (fs.exists(disk) and fs.isDir(disk)),'BAD_PATH')
        local current=fs.exists(disk) and self:stat(share,path).revision or false
        U.check(expected==nil or expected==current,'REVISION_CHANGED')
        U.check(#bytes<=U.maxFile,'TOO_LARGE')
        U.write(disk..'.rfs-new',bytes); U.replace(disk,disk..'.rfs-new')
        return self:record(share,path,bytes,force)
    end
    function S:expire()
        local now=U.now()
        for id,t in pairs(self.transfers) do if t.expires<=now then self.transfers[id]=nil end end
        for id,t in pairs(self.watches) do if t.expires<=now then self.watches[id]=nil end end
        for id,t in pairs(self.cache) do if t.expires<=now then self.cache[id]=nil end end
    end
    function S:transfer(peer,token,args,kind)
        local t=self.transfers[args.transfer]
        U.check(t and t.peer==peer and t.token==token and t.kind==kind and t.expires>U.now(),'TRANSFER_EXPIRED')
        t.expires=U.now()+120; return t
    end
    function S:operate(peer,tokenId,a,op)
        local token=tokenId~='' and self.tokens[tokenId] or nil
        if op=='hello' then
            return {name=self.config.name or 'File server',server=self.id,version=1,maxChunk=U.maxChunk,maxFile=U.maxFile,
                capabilities={list=true,stat=true,read=true,upload=true,range=true,batch=true,history=true,restore=true,watch=true,changes=true,manage=true,tokens=true}}
        end
        if op=='shares' then
            local out={}; for name in pairs(self.config.shares) do if self:allowed(token,name,'','list') then out[#out+1]=name end end
            table.sort(out); return {shares=out}
        end
        if op=='batch' then
            U.check(C.array(a.requests,32),'BAD_REQUEST'); local out={}
            for _,r in ipairs(a.requests) do
                U.check(type(r)=='table' and (r.op=='stat' or r.op=='list'),'BAD_REQUEST','Batch supports stat/list')
                local ok,result=pcall(self.operate,self,peer,tokenId,r.args or {},r.op)
                out[#out+1]=ok and {ok=true,result=result} or {ok=false,error=type(result)=='table' and result or {code='IO_ERROR'}}
            end
            return {results=out}
        end
        if op=='cancel' then
            local t=self.transfers[a.transfer]
            if t then U.check(t.peer==peer and t.token==tokenId,'ACCESS_DENIED'); self.transfers[a.transfer]=nil end
            return {cancelled=true}
        end
        if op=='unwatch' then
            local w=self.watches[a.watch]; if w then U.check(w.peer==peer and w.token==tokenId,'ACCESS_DENIED'); self.watches[a.watch]=nil end
            return {cancelled=true}
        end
        if op=='grant' or op=='revoke' then
            U.check(token and token.admin==true,'ACCESS_DENIED')
            U.check(ident(a.id) and a.id~=tokenId,'BAD_REQUEST')
            U.check(not (self.config.tokens or {})[a.id],'ACCESS_DENIED','Configured tokens cannot be changed remotely')
            if op=='revoke' then self.tokens[a.id]=nil else
                U.check(not self.tokens[a.id] and type(a.nonce)=='string' and #a.nonce==64 and a.nonce:match('^%x+$'),'BAD_REQUEST')
                U.check(C.integer(a.expires,U.now()+1,U.now()+86400) and (not token.expires or a.expires<=token.expires),'BAD_REQUEST')
                U.check(C.array(a.permissions,32),'BAD_REQUEST')
                for _,p in ipairs(a.permissions) do
                    U.check(type(p)=='table' and type(p.operations)=='table','BAD_REQUEST'); U.path(p.prefix or '')
                    for perm,enabled in pairs(p.operations) do U.check(enabled==true and self:allowed(token,p.share,p.prefix or '',perm),'ACCESS_DENIED') end
                end
                self.tokens[a.id]={secret=C.hex(C.hmac(token.secret,'rfs-grant-v1\0'..a.id..'\0'..a.nonce)),expires=a.expires,permissions=a.permissions}
            end
            local persisted={}; for id,t in pairs(self.tokens) do if not (self.config.tokens or {})[id] then persisted[id]=t end end
            U.save(fs.combine(self.state,'tokens.json'),persisted); return {changed=true}
        end
        if op=='read' or op=='write' or op=='commit' then
            local t=self:transfer(peer,tokenId,a,op=='read' and 'read' or 'write')
            self:permit(token,t.share,t.path,op=='read' and 'read' or 'write')
            if op=='read' then
                U.check(C.integer(a.offset,0,t.meta.size),'BAD_REQUEST')
                U.check(C.integer(a.length or t.chunk,1,t.chunk),'BAD_REQUEST')
                local bytes=U.read(fs.combine(self.state,'objects/'..t.meta.hash))
                local data=bytes:sub(a.offset+1,math.min(t.meta.size,a.offset+(a.length or t.chunk)))
                return {offset=a.offset,data=data,hash=U.hash(data),revision=t.meta.revision,eof=a.offset+#data==t.meta.size}
            elseif op=='write' then
                U.check(C.integer(a.offset,0,t.size) and type(a.data)=='string' and #a.data<=t.chunk and a.offset+#a.data<=t.size,'BAD_REQUEST')
                U.check(a.offset%t.chunk==0 and #a.data==math.min(t.chunk,t.size-a.offset),'BAD_REQUEST')
                U.check(a.hash==U.hash(a.data),'HASH_MISMATCH')
                t.parts[a.offset]=a.data; return {received=#a.data}
            end
            local parts={}; for offset=0,t.size-1,t.chunk do U.check(t.parts[offset],'INCOMPLETE'); parts[#parts+1]=t.parts[offset] end
            local bytes=table.concat(parts); U.check(U.hash(bytes)==t.hash,'HASH_MISMATCH')
            local meta=self:publish(t.share,t.path,bytes,t.expected)
            self.transfers[a.transfer]=nil; return meta
        end
        U.check(type(a.share)=='string' and type(a.path or '')=='string','BAD_REQUEST')
        local share,path=a.share,a.path or ''
        local permission=({list='list',stat='read',open='read',history='read',upload='write',restore='write',mkdir='write',delete='delete',move='write',watch='watch',changes='watch'})[op]
        U.check(permission,'UNSUPPORTED'); self:permit(token,share,path,permission)
        local disk=self:location(share,path)
        if op=='stat' then
            local meta=self:stat(share,path,a.revision)
            if a.ifRevision and a.ifRevision==meta.revision then return {notModified=true,revision=meta.revision} end
            return meta
        elseif op=='list' then
            U.check(fs.exists(disk) and fs.isDir(disk),'NOT_FOUND')
            U.check(C.integer(a.offset or 0,0,2147483647),'BAD_REQUEST')
            local names=fs.list(disk); table.sort(names); local out={}; local visible={}
            for _,name in ipairs(names) do
                local child=path=='' and name or path..'/'..name
                if not name:find('%.rfs%-old') and not name:find('%.rfs%-new') and self:allowed(token,share,child,'list') then visible[#visible+1]=name end
            end
            local offset=a.offset or 0
            for i=offset+1,math.min(#visible,offset+64) do
                local name=visible[i]; local child=fs.combine(disk,name)
                out[#out+1]={name=name,directory=fs.isDir(child),size=fs.isDir(child) and 0 or fs.getSize(child)}
            end
            return {entries=out,nextOffset=offset+#out,done=offset+#out>=#visible}
        elseif op=='open' or op=='upload' then
            U.check(count(self.transfers)<16,'SERVER_BUSY'); local chunk=a.chunk or 4096
            U.check(C.integer(chunk,256,U.maxChunk),'BAD_REQUEST')
            local id=C.nonce(); local t={peer=peer,token=tokenId,share=share,path=path,expires=U.now()+120,chunk=chunk}
            if op=='open' then
                t.kind='read'; t.meta=self:stat(share,path,a.revision)
                U.check(not t.meta.directory and not t.meta.deleted,'NOT_FOUND')
            else
                U.check(path~='' and C.integer(a.size,0,U.maxFile) and type(a.hash)=='string' and #a.hash==64 and a.hash:match('^%x+$'),'BAD_REQUEST')
                t.kind='write'; t.parts={}; t.size=a.size; t.hash=a.hash; t.expected=a.expected
            end
            self.transfers[id]=t; return {transfer=id,chunk=chunk,meta=t.meta or false}
        elseif op=='history' then
            local ok,e=pcall(self.stat,self,share,path); if not ok and (type(e)~='table' or e.code~='NOT_FOUND') then error(e,0) end
            local item=self.index.paths[share..'/'..path]; local all=item and item.versions or {}
            U.check(C.integer(a.offset or 0,0,2147483647),'BAD_REQUEST'); local out={}; local offset=a.offset or 0
            for i=offset+1,math.min(#all,offset+64) do out[#out+1]=all[i] end
            return {versions=out,nextOffset=offset+#out,done=offset+#out>=#all}
        elseif op=='restore' then
            self:permit(token,share,path,'read'); local meta=self:stat(share,path,a.revision)
            U.check(not meta.deleted,'NOT_FOUND'); return self:publish(share,path,U.read(fs.combine(self.state,'objects/'..meta.hash)),a.expected,true)
        elseif op=='mkdir' then
            U.check(not fs.exists(disk),'ALREADY_EXISTS'); fs.makeDir(disk); self:event(share,path,'mkdir'); self:save(); return {created=true}
        elseif op=='delete' or op=='move' then
            U.check(path~='' and fs.exists(disk),'BAD_PATH')
            local directory=fs.isDir(disk)
            if directory and op=='delete' then U.check(a.recursive==true or #fs.list(disk)==0,'DIRECTORY_NOT_EMPTY') end
            local target
            if op=='move' then
                U.path(a.destination); U.check(a.destination~='' and not U.within(a.destination,path),'BAD_PATH')
                target=self:location(share,a.destination); U.check(not fs.exists(target),'ALREADY_EXISTS')
            end
            local all={}; local function collect(relative,depth)
                U.check(depth<=32 and #all<4096,'TOO_LARGE')
                self:permit(token,share,relative,'delete')
                local source=self:location(share,relative)
                local suffix=relative:sub(#path+1)
                local destination=op=='move' and a.destination..suffix or nil
                if destination then self:permit(token,share,destination,'write') end
                local entry={path=relative,destination=destination,directory=fs.isDir(source)}
                if not entry.directory then
                    entry.meta=self:stat(share,relative)
                    if relative==path then U.check(not a.expected or a.expected==entry.meta.revision,'REVISION_CHANGED') end
                end
                all[#all+1]=entry
                if entry.directory then for _,name in ipairs(fs.list(source)) do
                    U.check(not name:find('%.rfs%-old') and not name:find('%.rfs%-new'),'SERVER_BUSY','Pending file recovery in directory')
                    collect(relative..'/'..name,depth+1)
                end end
            end
            collect(path,0)
            if op=='move' then fs.makeDir(fs.getDir(target)); fs.move(disk,target) else fs.delete(disk) end
            for _,entry in ipairs(all) do
                if entry.directory then
                    self:event(share,entry.path,'deleted')
                    if entry.destination then self:event(share,entry.destination,'mkdir') end
                else
                    if entry.destination then self:record(share,entry.destination,U.read(self:location(share,entry.destination)),true) end
                    self:record(share,entry.path,nil)
                end
            end
            self:save(); return op=='move' and {moved=true} or {deleted=true}
        elseif op=='watch' then
            U.check(count(self.watches)<64,'SERVER_BUSY'); local id=C.nonce()
            self.watches[id]={id=id,peer=peer,token=tokenId,share=share,path=path,expires=U.now()+300}
            return {watch=id,sequence=self.index.sequence,expires=U.now()+300}
        elseif op=='changes' then
            U.check(C.integer(a.sequence or 0,0,self.index.sequence),'BAD_REQUEST')
            local first=self.index.events[1]; local gap=first and (a.sequence or 0)<first.sequence-1 or false
            local out={}; for _,e in ipairs(self.index.events) do
                if e.sequence>(a.sequence or 0) and e.share==share and U.within(e.path,path) and self:allowed(token,share,e.path,'watch') then out[#out+1]=e end
            end
            -- Bound reply size even if all 256 paths are long.
            while #out>64 do table.remove(out) end
            return {events=out,gap=gap,sequence=#out==64 and out[#out].sequence or self.index.sequence}
        end
    end
    function S:handle(peer,packet)
        self:expire()
        if type(packet)~='table' or type(packet.token)~='string' then return nil end
        local tokenId=packet.token; local token=tokenId~='' and self.tokens[tokenId] or nil
        if tokenId~='' and (not token or (token.expires and token.expires<=U.now())) then return nil end
        local b=U.unpack(packet,token and token.secret)
        if not b or b.v~=1 or b.kind~='request' or type(b.id)~='string' or #b.id>128 or b.client~=peer or b.server~=self.id or type(b.op)~='string' or type(b.args)~='table' or not C.integer(b.time,0,4294967295) or math.abs(U.now()-b.time)>60 then return nil end
        local cacheId=tostring(peer)..':'..tokenId..':'..b.id
        local old=self.cache[cacheId]
        if old then if old.payload==packet.payload then return old.reply end; return nil end
        local result,ok
        if count(self.cache)>=256 then ok=false; result={code='SERVER_BUSY',message='Retry cache full'}
        else ok,result=pcall(self.operate,self,peer,tokenId,b.args,b.op) end
        local body={v=1,kind='response',id=b.id,client=peer,server=self.id,ok=ok}
        if ok then body.result=result else body.error=type(result)=='table' and result or {code='IO_ERROR',message='Server filesystem operation failed'} end
        local packed,reply=pcall(U.pack,body,token and token.secret,tokenId)
        if not packed then
            body.ok=false; body.result=nil; body.error={code='TOO_LARGE',message='Response exceeds packet limit'}
            reply=U.pack(body,token and token.secret,tokenId)
        end
        if count(self.cache)<256 then self.cache[cacheId]={payload=packet.payload,reply=reply,expires=U.now()+120} end
        return reply
    end
    function S:run()
        U.openModems(); rednet.host(U.protocol,self.config.name or ('rfs-'..self.id))
        while true do
            local peer,p=rednet.receive(U.protocol,1)
            if peer then local reply=self:handle(peer,p); if reply then rednet.send(peer,reply,U.protocol) end end
            for _,notice in ipairs(self.outbox) do
                local t=notice.token~='' and self.tokens[notice.token] or nil
                if notice.token=='' or (t and (not t.expires or t.expires>U.now())) then rednet.send(notice.peer,U.pack(notice.body,t and t.secret,notice.token),U.protocol) end
            end
            self.outbox={}; self:expire()
        end
    end
    return S
end
return M
