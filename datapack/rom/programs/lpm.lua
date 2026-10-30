-- Fallback for custom shells that have not added /bin to their search path.
local target=require("lpm_bootstrap").ensure()
-- shell.run sets getRunningProgram to the writable copy, including for self-update.
if not shell.run(target,...) then error("LPM command failed",0) end
