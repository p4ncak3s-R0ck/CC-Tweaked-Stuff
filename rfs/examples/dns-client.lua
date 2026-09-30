-- Install dns separately with `lpm install dns`; authenticate it before this resolver.
local rfs=require('rfs')
local dns=require('dns')
-- Configure dns.setServer(ID) and dns.authenticate(user,password) in your application.
local function resolve(host)
    local records,err=dns.lookupRecord('ID',host)
    assert(records,err)
    assert(records[1] and type(records[1].value)=='number','Expected an ID record')
    return records[1].value
end
local client=rfs.connect(assert(({...})[1],'Hostname required'),{resolve=resolve})
local info,err=client:hello(); assert(info,err); print(info.name)
