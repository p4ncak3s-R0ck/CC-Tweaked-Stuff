-- Non-executing parser for: return { literal table }.
local M = {}
function M.parse(s)
    assert(type(s) == "string" and #s <= 262144, "Manifest exceeds 256 KiB")
    local p, nodes = 1, 0
    local function fail(msg) error("Data syntax at byte " .. p .. ": " .. msg, 0) end
    local function skip()
        while true do
            local _, e = s:find("^%s+", p)
            if e then p = e + 1 end
            if s:sub(p, p + 1) ~= "--" then return end
            if s:sub(p + 2, p + 3) == "[[" then
                local stop = s:find("]]", p + 4, true)
                if not stop then fail("Unclosed comment") end
                p = stop + 2
            else
                p = (s:find("\n", p + 2, true) or #s) + 1
            end
        end
    end
    local function take(c) skip(); if s:sub(p, p) ~= c then fail("Expected " .. c) end; p = p + 1 end
    local function ident()
        skip(); local v = s:match("^[_%a][_%w]*", p)
        if v then p = p + #v end
        return v
    end
    local function quoted()
        local q = s:sub(p,p); p=p+1; local out={}
        local esc={n="\n",r="\r",t="\t",a="\a",b="\b",f="\f",v="\v",["\\"]="\\",['"']='"',["'"]="'"}
        while p <= #s do
            local c=s:sub(p,p); p=p+1
            if c==q then return table.concat(out) end
            if c=="\n" or c=="\r" then fail("Newline in string") end
            if c=="\\" then
                c=s:sub(p,p); p=p+1
                if esc[c] then out[#out+1]=esc[c]
                elseif c:match("%d") then
                    local digits=c
                    for _=1,2 do local d=s:sub(p,p); if not d:match("%d") then break end; digits=digits..d; p=p+1 end
                    local n=tonumber(digits); if n>255 then fail("Escape out of range") end
                    out[#out+1]=string.char(n)
                else fail("Unsupported escape") end
            else out[#out+1]=c end
        end
        fail("Unclosed string")
    end
    local value
    value=function(depth)
        skip(); nodes=nodes+1
        if depth>24 or nodes>20000 then fail("Data too complex") end
        local c=s:sub(p,p)
        if c=='"' or c=="'" then return quoted() end
        if c=="{" then
            p=p+1; local out,seen,nextIndex={}, {},1
            skip()
            while s:sub(p,p)~="}" do
                local k,v
                if s:sub(p,p)=="[" then
                    p=p+1; k=value(depth+1); take("]"); take("="); v=value(depth+1)
                else
                    local old=p; local id=ident(); skip()
                    if id and s:sub(p,p)=="=" then p=p+1; k=id; v=value(depth+1)
                    else p=old; k=nextIndex; nextIndex=nextIndex+1; v=value(depth+1) end
                end
                if type(k)~="string" and type(k)~="number" then fail("Invalid key") end
                if seen[k] then fail("Duplicate key") end
                seen[k]=true; out[k]=v; skip()
                c=s:sub(p,p)
                if c=="," or c==";" then p=p+1; skip()
                elseif c~="}" then fail("Expected comma or closing brace") end
            end
            p=p+1; return out
        end
        local number=s:match("^-?%d+%.?%d*",p)
        if number then p=p+#number; return tonumber(number) end
        local id=ident()
        if id=="true" then return true elseif id=="false" then return false end
        fail("Expected literal, found " .. tostring(id or c))
    end
    if ident()~="return" then fail("Expected return") end
    local result=value(0); skip()
    if s:sub(p,p)==";" then p=p+1; skip() end
    if p<=#s then fail("Trailing executable content") end
    assert(type(result)=="table", "Expected returned table")
    return result
end
function M.serialize(v)
    local function emit(x,depth)
        assert(depth<=24, "Data too deep")
        if type(x)=="string" then return string.format("%q",x):gsub("\\\n","\\n") end
        if type(x)=="number" or type(x)=="boolean" then return tostring(x) end
        assert(type(x)=="table", "Unsupported data")
        local keys={}; for k in pairs(x) do keys[#keys+1]=k end
        table.sort(keys,function(a,b) if type(a)~=type(b) then return type(a)<type(b) end; return a<b end)
        local out={"{"}
        for _,k in ipairs(keys) do out[#out+1]="["..emit(k,depth+1).."]="..emit(x[k],depth+1).."," end
        out[#out+1]="}"; return table.concat(out)
    end
    return "return "..emit(v,0).."\n"
end
return M
