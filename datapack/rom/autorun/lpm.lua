-- Runs independently of each computer's existing startup program.
local ok,err=pcall(function() require("lpm_bootstrap").ensure() end)
if not ok then printError("LPM datapack: "..tostring(err)) end
