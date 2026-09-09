-- Example CC:Tweaked record editor. Install beside dns.lua on an admin computer.
-- Uses only the public DNS API; every edit is authorized again by the server.
local HELP = [[DNS record editor
Usage: dnsRecords --server <id> [options]
  -s, --server <id>      DNS server computer ID (required)
  -m, --modem <name>     Modem to open (default: all attached modems)
  -u, --username <name>  Admin username (otherwise prompted)
      --timeout <s>     Per-attempt timeout: >0..60 (default: 3)
      --retries <n>     Additional attempts: 0..5 (default: 1)
  -h, --help            Show help

Passwords are always prompted and masked. Reader accounts cannot edit.
List records, then edit a name/type set: add, change, or remove individual
entries before confirming a save. Other records in the set are preserved.
Supports ID, CNAME, PTR, TXT, and SRV. Blank fields keep displayed defaults.
Concurrent changes produce CONFLICT instead of overwriting another editor.
]]

local function parseOptions(args)
    local options, seen = {}, {}
    local aliases =
        { ["-s"] = "--server", ["-m"] = "--modem", ["-u"] = "--username", ["-h"] = "--help" }
    local keys = {
        ["--server"] = "server",
        ["--modem"] = "modem",
        ["--username"] = "username",
        ["--timeout"] = "timeout",
        ["--retries"] = "retries",
    }
    local i = 1
    while i <= #args do
        local flag, value = args[i]:match("^(%-%-[^=]+)=(.*)$")
        flag = aliases[flag or args[i]] or flag or args[i]
        if flag == "--help" and value == nil then
            options.help = true
        else
            local key = keys[flag]
            assert(key, "Unknown option: " .. flag .. ". Use --help.")
            assert(not seen[key], "Repeated option: " .. flag)
            seen[key] = true
            if value == nil then
                i = i + 1
                value = args[i]
            end
            assert(
                value and value:find("%S") and value:sub(1, 1) ~= "-",
                "Missing value for " .. flag
            )
            if key == "server" or key == "timeout" or key == "retries" then
                value = assert(tonumber(value), "Expected a number for " .. flag)
            end
            options[key] = value
        end
        i = i + 1
    end
    return options
end

local options = parseOptions({ ... })
if options.help then
    textutils.pagedPrint(HELP)
    return
end
assert(options.server ~= nil, "Use dnsRecords --server <id>. See --help.")
local dns = require("dns").new()
dns.setServer(options.server)
if options.timeout then
    dns.setTimeout(options.timeout)
end
if options.retries then
    dns.setRetries(options.retries)
end
assert(dns.open(options.modem))
-- Intentionally never opts into unsigned/public lookups.

local function prompt(label, default)
    write(label .. (default ~= nil and " [" .. tostring(default) .. "]" or "") .. ": ")
    local value = read()
    if value == "" and default ~= nil then
        return tostring(default)
    end
    return value
end

local function confirm(label)
    return prompt(label .. " (y/N)"):lower() == "y"
end

local function number(label, default, lo, hi)
    while true do
        local value = tonumber(prompt(label, default))
        if value and value >= lo and value <= hi and value % 1 == 0 then
            return value
        end
        print("Enter an integer from " .. lo .. " through " .. hi .. ".")
    end
end

local function showError(err, code)
    print((code or "ERROR") .. ": " .. tostring(err))
    if code == "TIMEOUT" then
        print("The save may have succeeded. Log in and inspect records before retrying.")
    elseif code == "CONFLICT" then
        print("Another edit changed the database. Reopen the set and reapply your changes.")
    end
end

local function login()
    local username = options.username or prompt("Admin username")
    write("Password: ")
    local password = read("*")
    local ok, roleOrError, code = dns.authenticate(username, password)
    password = nil
    if not ok then
        showError(roleOrError, code)
        return false
    end
    if roleOrError ~= "admin" then
        print("An admin account is required. Reader accounts cannot edit records.")
        dns.logout()
        return false
    end
    return true
end

-- Load a consistent snapshot without using lookupRecord (which follows aliases
-- and reduces TTLs). Retain the revision for an atomic compare-and-save check.
local function snapshot()
    local records, revision, offset = {}, nil, 0
    repeat
        local page, err, code = dns.admin.listRecords(offset, 8)
        if not page then
            showError(err, code)
            return
        end
        if revision and revision ~= page.revision then
            showError("Database changed while listing records", "CONFLICT")
            return
        end
        revision = page.revision
        for _, record in ipairs(page.records) do
            records[#records + 1] = record
        end
        offset = page.nextOffset
    until offset == false
    return records, revision
end

local function describe(record)
    return textutils.serialize(record, { compact = true })
end

local function listRecords()
    local records, revision = snapshot()
    if not records then
        return
    end
    local lines = { "Revision " .. revision .. " | " .. #records .. " records" }
    for i, record in ipairs(records) do
        lines[#lines + 1] = i .. ". " .. describe(record)
    end
    textutils.pagedPrint(table.concat(lines, "\n"))
end

local function editValue(kind, old)
    if kind == "ID" then
        return number("Computer ID", old, 0, 2147483647)
    elseif kind == "CNAME" or kind == "PTR" then
        return prompt("Target name", old)
    elseif kind == "TXT" then
        if old ~= nil then
            print("Current TXT: " .. textutils.serialize(old))
            if not confirm("Change TXT value?") then
                return old
            end
        end
        return prompt("TXT value (empty allowed)")
    else -- SRV
        old = old or {}
        return {
            target = prompt("Target name", old.target),
            protocol = prompt("Rednet protocol", old.protocol),
            priority = number("Priority", old.priority or 0, 0, 65535),
            weight = number("Weight", old.weight or 0, 0, 65535),
        }
    end
end

local function editEntry(kind, old)
    old = old or {}
    return {
        value = editValue(kind, old.value),
        ttl = number("TTL seconds", old.ttl or 300, 0, 604800),
    }
end

local function editSet()
    local kind = prompt("Type (ID/CNAME/PTR/TXT/SRV)", "ID"):upper()
    if not ({ ID = true, CNAME = true, PTR = true, TXT = true, SRV = true })[kind] then
        print("Unsupported record type.")
        return
    end
    local name = prompt(kind == "PTR" and "Computer ID to reverse-resolve" or "Record name")
        :lower()
        :gsub("%.$", "")
    if kind == "PTR" and name:match("^%d+$") and tonumber(name) <= 2147483647 then
        name = string.format("%.0f", tonumber(name))
    end
    local records, revision = snapshot()
    if not records then
        return
    end
    local entries = {}
    for _, record in ipairs(records) do
        if record.type == kind and record.name == name then
            entries[#entries + 1] = { value = record.value, ttl = record.ttl }
        end
    end
    local dirty = false
    while true do
        local lines = { kind .. " " .. name .. " | base revision " .. revision }
        for i, entry in ipairs(entries) do
            lines[#lines + 1] = i .. ". " .. describe(entry)
        end
        if #entries == 0 then
            lines[#lines + 1] = "(empty set)"
        end
        textutils.pagedPrint(table.concat(lines, "\n"))
        local choice = prompt("[a]dd [e]dit [r]emove [s]ave [c]ancel"):lower()
        if choice == "c" then
            return
        elseif choice == "a" then
            if #entries >= 64 or (kind == "CNAME" and #entries >= 1) then
                print("Record count limit reached for this set.")
            else
                entries[#entries + 1] = editEntry(kind)
                dirty = true
            end
        elseif choice == "e" or choice == "r" then
            if #entries == 0 then
                print("No entries yet.")
            else
                local i = number("Entry number", nil, 1, #entries)
                if choice == "r" then
                    table.remove(entries, i)
                else
                    entries[i] = editEntry(kind, entries[i])
                end
                dirty = true
            end
        elseif choice == "s" then
            if not dirty then
                print("No changes to save.")
                return
            end
            local label = #entries == 0 and "DELETE this entire name/type set?"
                or "Save this complete name/type set?"
            if confirm(label) then
                local saved, err, code = dns.admin.setRecords(kind, name, entries, revision)
                if saved then
                    print("Saved revision " .. saved.revision)
                    return
                end
                showError(err, code)
                if code ~= "BAD_RECORDS" and code ~= "BAD_ARGUMENT" then
                    return
                end
            end
        end
    end
end

local function main()
    print("DNS admin record editor | server #" .. options.server)
    if not login() then
        return
    end
    while true do
        local choice = prompt("[l]ist records [e]dit/add set [q]uit"):lower()
        if choice == "q" then
            return
        end
        if not dns.isAuthenticated() and not login() then
            return
        end
        if choice == "l" then
            listRecords()
        elseif choice == "e" then
            editSet()
        end
    end
end

-- Best-effort logout on normal exit, errors, and Ctrl+T. Never close modems that
-- another program may be sharing. An unreachable server expires the session.
local ok, err = pcall(main)
pcall(dns.logout)
if not ok then
    error(err, 0)
end
