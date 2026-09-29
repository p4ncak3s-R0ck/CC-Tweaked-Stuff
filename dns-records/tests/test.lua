local internal=assert(load(DNS_SOURCE))()._internal
local function copy(v)
    if type(v)~='table' then return v end
    local t={}; for k,x in pairs(v) do t[k]=copy(x) end; return t
end
local function serialize(v)
    if type(v)~='table' then return tostring(v) end
    local parts={}; for k,x in pairs(v) do parts[#parts+1]=tostring(k)..'='..serialize(x) end
    table.sort(parts); return '{'..table.concat(parts,',')..'}'
end
local function run(inputs,settings,args)
    settings=settings or {}; args=args or {'--server','42','--username','admin'}
    local records=copy(settings.records or {}); local queue=copy(inputs); local output={}; local writes={}; local revision=10
    local authenticated=false; local loggedOut=0; local masked=0; local pages=0; local authCalls=0
    local dns={admin={}}
    dns.setServer=function(id) assert(id==42,'Bad server') end
    dns.setTimeout=function(n) assert(n>0 and n<=60) end
    dns.setRetries=function(n) assert(n>=0 and n<=5 and n%1==0) end
    dns.open=function(n) return true end
    dns.authenticate=function(username,password)
        authCalls=authCalls+1; assert(password=='secret','Bad test password')
        if settings.authFailure then return nil,'Rejected','AUTH_FAILED' end
        authenticated=true; return true,settings.role or 'admin'
    end
    dns.logout=function() loggedOut=loggedOut+1; authenticated=false; return true end
    dns.isAuthenticated=function() return authenticated end
    dns.admin.listRecords=function(offset,limit)
        pages=pages+1; local result={}
        for i=offset+1,math.min(offset+limit,#records) do result[#result+1]=copy(records[i]) end
        return {records=result,revision=settings.paginationConflict and pages>1 and 11 or revision,nextOffset=offset+#result<#records and offset+#result or false}
    end
    dns.admin.setRecords=function(kind,name,entries,expected)
        assert(authenticated and (settings.role or 'admin')=='admin','Unauthorized call')
        assert(expected==revision,'Missing optimistic revision')
        if settings.saveFailure then return nil,'Injected failure',settings.saveFailure end
        local proposed={}; for _,r in ipairs(records) do if r.type~=kind or r.name~=name then proposed[#proposed+1]=r end end
        for _,e in ipairs(entries) do proposed[#proposed+1]=internal.record({type=kind,name=name,value=e.value,ttl=e.ttl}) end
        internal.index(proposed)
        records=proposed; revision=revision+1; writes[#writes+1]={kind=kind,name=name,entries=copy(entries),expected=expected}
        return {revision=revision}
    end
    local env=setmetatable({},{__index=_G}); env._G=env
    env.require=function(n) assert(n=='dns'); return {new=function() return dns end} end
    env.write=function(s) output[#output+1]=s end
    env.print=function(s) output[#output+1]=tostring(s) end
    env.read=function(mask)
        if mask then assert(mask=='*'); masked=masked+1 end
        assert(#queue>0,'Unexpected prompt '..table.concat(output,'\n'))
        local v=table.remove(queue,1); if v=='<terminate>' then error('Terminated') end; return v
    end
    env.textutils={serialize=serialize,pagedPrint=function(s) output[#output+1]=s end}
    local ok,err=pcall(assert(load(EDITOR_SOURCE,'@dns-records','t',env)),table.unpack(args))
    assert(#queue==0,'Unused scripted inputs')
    return {ok=ok,error=err,records=records,writes=writes,output=table.concat(output,'\n'),loggedOut=loggedOut,masked=masked,authCalls=authCalls}
end
local count=0
local function test(label,fn) fn(); count=count+1; print('PASS '..label) end
test('Help requires neither DNS login nor password',function()
    local r=run({},nil,{'--help'}); assert(r.ok and r.authCalls==0 and r.output:find('dns%-records'))
end)
test('Interactive connection and masked password',function()
    local r=run({'42','admin','secret','q'},nil,{}); assert(r.ok and r.masked==1 and r.loggedOut==1)
end)
local examples={
    ID={input={'17'},value=17,name='storage.base'},
    CNAME={input={'storage.base'},value='storage.base',name='alias.base'},
    PTR={input={'storage.base'},value='storage.base',name='17',query='017'},
    TXT={input={''},value='',name='metadata.base'},
    SRV={input={'broker.base','rednet-mq-v1','10','100'},value={target='broker.base',protocol='rednet-mq-v1',priority=10,weight=100},name='_mq.base'},
}
for kind,example in pairs(examples) do
    test('Add '..kind..' record with guarded save',function()
        local input={'secret','e',kind,example.query or example.name,'a'}
        for _,v in ipairs(example.input) do input[#input+1]=v end
        for _,v in ipairs({'300','s','y','q'}) do input[#input+1]=v end
        local r=run(input); assert(r.ok and #r.writes==1 and r.writes[1].expected==10)
        local record=r.records[1]; assert(record.name==example.name and serialize(record.value)==serialize(example.value))
    end)
end
test('Edit one entry preserves others and unrelated sets',function()
    local original={{type='ID',name='storage.base',value=17,ttl=300},{type='ID',name='storage.base',value=18,ttl=300},{type='TXT',name='other.base',value='keep',ttl=300}}
    local r=run({'secret','e','ID','storage.base','e','1','19','','s','y','q'},{records=original})
    assert(r.ok and #r.records==3 and #r.writes[1].entries==2)
    assert(r.writes[1].entries[1].value==19 and r.writes[1].entries[2].value==18)
    assert(r.records[1].value=='keep')
end)
test('Remove final entry deletes set after confirmation',function()
    local r=run({'secret','e','ID','storage.base','r','1','s','y','q'},{records={{type='ID',name='storage.base',value=17,ttl=300}}})
    assert(r.ok and #r.records==0 and r.output:find('DELETE',1,true))
end)
test('Cancel and declined save cause no mutation',function()
    local r=run({'secret','e','ID','storage.base','a','17','300','s','n','c','q'})
    assert(r.ok and #r.writes==0)
end)
test('Find uses literal case-insensitive matching',function()
    local records={{type='TXT',name='match.base',value='Needle.[x]',ttl=300},{type='TXT',name='hidden.base',value='other',ttl=300}}
    local r=run({'secret','f','NEEDLE.[x]','q'},{records=records})
    assert(r.ok and r.output:find('match.base',1,true) and not r.output:find('hidden.base',1,true))
end)
test('Reader and failed authentication are rejected',function()
    local r=run({'secret'},{role='reader'}); assert(r.ok and #r.writes==0 and r.loggedOut>=1)
    r=run({'secret'},{authFailure=true}); assert(r.ok and #r.writes==0 and r.output:find('AUTH_FAILED',1,true))
end)
test('Revision conflict does not overwrite records',function()
    local r=run({'secret','e','ID','storage.base','a','17','300','s','y','q'},{saveFailure='CONFLICT'})
    assert(r.ok and #r.writes==0 and r.output:find('reapply',1,true))
end)
test('Pagination revision changes reject inconsistent snapshot',function()
    local records={}; for i=1,9 do records[i]={type='ID',name='host'..i..'.base',value=i,ttl=300} end
    local r=run({'secret','l','q'},{records=records,paginationConflict=true})
    assert(r.ok and #r.writes==0 and r.output:find('CONFLICT',1,true))
end)
test('Timeout reports uncertain save without retry',function()
    local r=run({'secret','e','ID','storage.base','a','17','300','s','y','q'},{saveFailure='TIMEOUT'})
    assert(r.ok and #r.writes==0 and r.output:find('may have succeeded',1,true))
end)
test('Termination logs out before propagating error',function()
    local r=run({'secret','<terminate>'}); assert(not r.ok and r.loggedOut==1)
end)
test('Invalid flags and numeric bounds fail',function()
    local r=run({},nil,{'--unknown'}); assert(not r.ok and r.authCalls==0)
    r=run({},nil,{'--server','42','--timeout','61'}); assert(not r.ok and r.authCalls==0)
end)
print(count..' editor test groups passed')
