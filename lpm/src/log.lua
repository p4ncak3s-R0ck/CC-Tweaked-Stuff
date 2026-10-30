-- Logging is optional for library callers; the CLI enables informational output.
local M={}
local levels={error=1,warn=2,info=3,debug=4}
local threshold,sink=0,nil
function M.configure(options)
    options=options or {}
    assert(options.level==nil or levels[options.level],"Invalid log level")
    assert(options.sink==nil or type(options.sink)=="function","Invalid log sink")
    threshold=levels[options.level or "info"]; sink=options.sink
end
function M.url(url)
    return (url:gsub("[?#].*$","?..."):gsub("(https?://)[^/@]+@","%1[redacted]@"))
end
local function emit(level,phase,message)
    if levels[level]>threshold then return end
    local line="["..level:upper().."]["..phase.."] "..tostring(message):gsub("[%c]"," ")
    -- A failed display must not interrupt activation or recovery.
    if sink then pcall(sink,level,line)
    else pcall((level=="error" or level=="warn") and printError or print,line) end
end
for level in pairs(levels) do
    local key=level
    M[key]=function(phase,message) emit(key,phase,message) end
end
return M
