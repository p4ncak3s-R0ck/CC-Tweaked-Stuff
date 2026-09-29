local M={}
function M.parse(v)
    assert(type(v)=="string", "Version must be a string")
    local a,b,c=v:match("^(%d+)%.(%d+)%.(%d+)$")
    assert(a, "Expected stable major.minor.patch: "..v)
    for _,n in ipairs({a,b,c}) do assert(n=="0" or n:sub(1,1)~="0", "Leading zero in version"); assert(#n<=6,"Version component too large") end
    return {tonumber(a),tonumber(b),tonumber(c)}
end
function M.compare(a,b)
    a=M.parse(a); b=M.parse(b)
    for i=1,3 do if a[i]~=b[i] then return a[i]<b[i] and -1 or 1 end end
    return 0
end
function M.satisfies(v,r)
    assert(type(r)=="string", "Constraint must be a string")
    if r=="*" then M.parse(v); return true end
    local op,base=r:match("^([%^~])(.+)$")
    if not op then return M.compare(v,r)==0 end
    local x=M.parse(base); local upper
    if op=="~" then upper={x[1],x[2]+1,0}
    elseif x[1]>0 then upper={x[1]+1,0,0}
    elseif x[2]>0 then upper={0,x[2]+1,0}
    else upper={0,0,x[3]+1} end
    return M.compare(v,base)>=0 and M.compare(v,table.concat(upper,"."))<0
end
return M
