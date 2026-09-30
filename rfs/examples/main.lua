local rfs=require('rfs')
local server=tonumber(({...})[1]) or 7
local client=rfs.connect(server)
local info,err=client:hello(); assert(info,err)
print(info.name)
local entries,err=client:list('public',''); assert(entries,err)
for _,entry in ipairs(entries) do print(entry.name,entry.size) end
