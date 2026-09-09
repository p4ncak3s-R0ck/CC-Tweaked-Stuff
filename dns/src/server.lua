-- Authenticated Rednet DNS v2 for CC:Tweaked.
-- Only dependency: dns.lua beside this file. Run dnsServer --help for usage.

-- Configuration and command-line options ---------------------------------------
-- Precedence: built-in defaults < config file < command-line options.
-- Config is a serialized table (data only), never executed as Lua code.
local DEFAULT_CONFIG_PATH = "/dns-server.cfg"
local DEFAULTS = {
    directory = "/",
    modem = false, -- false opens all attached modems; a string selects one.
    sessionTTL = 1800,
    challengeTTL = 180,
    logQueries = true,
    AuthenticationRequired = true, -- Public lookups only when explicitly disabled.
    readOnly = false, -- Blocks record edits/reloads, even for admins.
    maxSessions = 64,
    maxSessionsPerComputer = 8,
    maxPendingChallenges = 64,
    loginCooldown = 2,
    publicQueryLimit = 20, -- Global unsigned requests/second; excess is dropped.
}

local HELP = [[Authenticated Rednet DNS

Usage:
  dnsServer [options]
  dnsServer --user <name> <reader|admin> [options]
  dnsServer --check [options]
  dnsServer --init-config [options]

Options:
  -h, --help              Show this help and exit
  -c, --config <path>     Config file (default: /dns-server.cfg)
  -d, --directory <path>  Database directory (default: /)
  -m, --modem <name>      Open a specific modem
      --all-modems       Open all attached modems (default)
      --session-ttl <s>  Session lifetime: 1..3600 seconds (default: 1800)
      --challenge-ttl <s> Login challenge: 1..3600 seconds (default: 180)
      --log-queries      Enable request logging (default)
      --no-log-queries   Disable request logging
      --authentication-required [true|false]
                         Require login for lookups (default: true)
      --AuthenticationRequired [true|false]
                         Alias for --authentication-required
      --no-authentication-required
                         Allow unsigned public lookups, NOT record edits
      --read-only        Block record edits/reloads, including admin edits
      --no-read-only     Allow authenticated admins to edit (default)
      --max-sessions <n> Total sessions: 1..64 (default: 64)
      --max-sessions-per-computer <n>
                         Sessions per computer: 1..8 (default: 8)
      --max-pending-challenges <n>
                         Pending logins: 1..64 (default: 64)
      --login-cooldown <s> New login throttle: 0..60 seconds (default: 2)
      --public-query-limit <n>
                         Unsigned requests/second: 1..1000 (default: 20)
      --check            Validate databases without changing files
      --user <name> <role>
                         Create/reset a user locally; stop server first
      --init-config      Write config and exit; never overwrite a file

Value options accept --option=value or --option value.
Defaults < config < flags. Missing default config uses built-in defaults;
an explicitly selected config must exist (except with --init-config).
Relative paths resolve from the shell's current directory.
Config changes require a restart. Passwords are prompted, not stored in config.

Config fields (all optional; unknown fields are rejected):
  directory, modem, sessionTTL, challengeTTL, logQueries,
  AuthenticationRequired, readOnly, maxSessions, maxSessionsPerComputer,
  maxPendingChallenges, loginCooldown, publicQueryLimit
Public replies are unsigned/spoofable. Clients must explicitly opt in with
  dns.setAuthenticationRequired(false)
An initial admin is still required, even with public lookups enabled.
Record editing ALWAYS requires an authenticated admin; no flag bypasses this.
Set modem = false to open all modems, or modem = "back" to select one.
TTLs are seconds; allow enough challenge time for slow password derivation.

Examples:
  dnsServer --init-config --modem back --directory /dns-data
  dnsServer
  dnsServer -c /other.cfg --no-log-queries
  dnsServer --user robot reader -d /dns-data
  dnsServer --check -d /dns-data

Legacy commands still work:
  dnsServer [modem] [directory]
  dnsServer --user <name> <role> [directory]
  dnsServer --check [directory]
Use -- to end flag parsing before positional paths or modem names.
]]

local function optionError(message)
    error(message .. "\nRun dnsServer --help for usage.", 0)
end

local function nonempty(value)
    return type(value) == "string" and value:find("%S") ~= nil
end

local numberRanges = {
    sessionTTL = { 1, 3600 },
    challengeTTL = { 1, 3600 },
    maxSessions = { 1, 64 },
    maxSessionsPerComputer = { 1, 8 },
    maxPendingChallenges = { 1, 64 },
    loginCooldown = { 0, 60 },
    publicQueryLimit = { 1, 1000 },
}
local function boolean(value)
    return type(value) == "boolean"
end

local validators = {
    directory = nonempty,
    modem = function(value)
        return value == false or nonempty(value)
    end,
    logQueries = boolean,
    AuthenticationRequired = boolean,
    readOnly = boolean,
}
local settingHints = {
    directory = "a nonempty path",
    modem = "false (all modems) or a nonempty modem name",
    logQueries = "true or false",
    AuthenticationRequired = "true or false",
    readOnly = "true or false",
}
for key, range in pairs(numberRanges) do
    local lo, hi = range[1], range[2]
    validators[key] = function(value)
        return type(value) == "number" and value >= lo and value <= hi and value % 1 == 0
    end
    settingHints[key] = "an integer from " .. lo .. " through " .. hi
end

local function validateSettings(settings, source)
    if type(settings) ~= "table" then
        optionError(source .. ": expected a config table")
    end
    for key, value in pairs(settings) do
        local validate = validators[key]
        if not validate then
            optionError(source .. ": unknown setting " .. tostring(key))
        end
        if not validate(value) then
            optionError(source .. ": " .. key .. " must be " .. settingHints[key])
        end
    end
end

local function parseOptions(args)
    local options = { mode = "serve", configPath = DEFAULT_CONFIG_PATH, overrides = {} }
    local positional, seen = {}, {}
    local aliases = {
        ["-h"] = "--help",
        ["-c"] = "--config",
        ["-d"] = "--directory",
        ["-m"] = "--modem",
        ["--AuthenticationRequired"] = "--authentication-required",
    }
    local valueOptions = {
        ["--config"] = "configPath",
        ["--directory"] = "directory",
        ["--modem"] = "modem",
        ["--session-ttl"] = "sessionTTL",
        ["--challenge-ttl"] = "challengeTTL",
        ["--max-sessions"] = "maxSessions",
        ["--max-sessions-per-computer"] = "maxSessionsPerComputer",
        ["--max-pending-challenges"] = "maxPendingChallenges",
        ["--login-cooldown"] = "loginCooldown",
        ["--public-query-limit"] = "publicQueryLimit",
    }

    local function claim(key)
        if seen[key] then
            optionError("Repeated or conflicting option: " .. key)
        end
        seen[key] = true
    end
    local function override(key, value)
        claim(key)
        options.overrides[key] = value
    end
    local function setMode(mode)
        claim("command (--user, --check, or --init-config)")
        options.mode = mode
    end

    local i, flags = 1, true
    local function nextValue(flag)
        i = i + 1
        local value = args[i]
        if not nonempty(value) or value:sub(1, 1) == "-" then
            optionError("Missing value for " .. flag .. " (use = for values starting with '-')")
        end
        return value
    end

    while i <= #args do
        local arg = args[i]
        if flags and arg == "--" then
            flags = false
        elseif flags and arg:sub(1, 1) == "-" then
            local flag, inline = arg:match("^(%-%-[^=]+)=(.*)$")
            flag = aliases[flag or arg] or flag or arg
            local key = valueOptions[flag]
            if key then
                local value = inline
                if value == nil then
                    value = nextValue(flag)
                end
                if not nonempty(value) then
                    optionError("Missing value for " .. flag)
                end
                if key == "configPath" then
                    claim(key)
                    options.configPath, options.explicitConfig = value, true
                else
                    if numberRanges[key] then
                        value = tonumber(value)
                        if not validators[key](value) then
                            optionError(flag .. " must be " .. settingHints[key])
                        end
                    end
                    override(key, value)
                end
            elseif flag == "--authentication-required" then
                local value = inline
                if value == nil and (args[i + 1] == "true" or args[i + 1] == "false") then
                    i = i + 1
                    value = args[i]
                end
                if value ~= nil and value ~= "true" and value ~= "false" then
                    optionError(flag .. " expects true or false")
                end
                override("AuthenticationRequired", value ~= "false")
            else
                if inline ~= nil then
                    optionError(flag .. " does not accept an inline value")
                end
                if flag == "--help" then
                    options.help = true
                elseif flag == "--all-modems" then
                    override("modem", false)
                elseif flag == "--log-queries" then
                    override("logQueries", true)
                elseif flag == "--no-log-queries" then
                    override("logQueries", false)
                elseif flag == "--no-authentication-required" then
                    override("AuthenticationRequired", false)
                elseif flag == "--read-only" then
                    override("readOnly", true)
                elseif flag == "--no-read-only" then
                    override("readOnly", false)
                elseif flag == "--check" then
                    setMode("check")
                elseif flag == "--init-config" then
                    setMode("init-config")
                elseif flag == "--user" then
                    setMode("user")
                    options.username = nextValue(flag)
                    options.role = nextValue(flag)
                else
                    optionError("Unknown option: " .. flag)
                end
            end
        else
            positional[#positional + 1] = arg
        end
        i = i + 1
    end

    -- Preserve legacy positional invocations, but reject ambiguous duplicates.
    local maxPositional = options.mode == "serve" and 2 or 1
    if options.mode == "init-config" then
        maxPositional = 0
    end
    if #positional > maxPositional then
        optionError("Too many positional arguments")
    end
    if options.mode == "serve" then
        if positional[1] then
            override("modem", positional[1])
        end
        if positional[2] then
            override("directory", positional[2])
        end
    elseif positional[1] then
        override("directory", positional[1])
    end
    validateSettings(options.overrides, "Command line")
    return options
end

local function resolvePath(path)
    if shell and shell.resolve then
        -- CC:Tweaked returns root-relative paths without a leading slash, and
        -- represents root as "". Persist explicit absolute paths so configs
        -- round-trip and keep pointing at the same data from any working dir.
        local resolved = shell.resolve(path)
        return resolved:sub(1, 1) == "/" and resolved or "/" .. resolved
    end
    return path
end

local function loadSettings(options)
    local settings = {}
    for key, value in pairs(DEFAULTS) do
        settings[key] = value
    end
    local path = resolvePath(options.configPath)
    options.configPath = path

    if options.mode == "init-config" then
        if fs.exists(path) then
            optionError("Refusing to overwrite config: " .. path)
        end
    elseif fs.exists(path) then
        if fs.isDir(path) then
            optionError("Config path is a directory: " .. path)
        end
        if fs.getSize(path) > 65536 then
            optionError("Config exceeds 64 KiB: " .. path)
        end
        local file, err = fs.open(path, "r")
        if not file then
            optionError("Cannot read config " .. path .. ": " .. tostring(err))
        end
        local contents = file.readAll()
        file.close()
        local ok, loaded = pcall(textutils.unserialize, contents)
        if not ok or type(loaded) ~= "table" then
            optionError("Invalid config table: " .. path)
        end
        -- Older --init-config versions serialized CC's root as an empty path.
        -- Migrate it in memory without rewriting the user's config file.
        if loaded.directory == "" then
            loaded.directory = "/"
        end
        validateSettings(loaded, path)
        for key, value in pairs(loaded) do
            settings[key] = value
        end
    elseif options.explicitConfig then
        optionError("Config not found: " .. path .. ". Create it with --init-config.")
    end

    for key, value in pairs(options.overrides) do
        settings[key] = value
    end
    settings.directory = resolvePath(settings.directory)
    return settings
end

local options = parseOptions({ ... })
if options.help then
    if textutils and textutils.pagedPrint then
        textutils.pagedPrint(HELP)
    else
        print(HELP)
    end
    return
end
local config = loadSettings(options)
if options.mode == "init-config" then
    local parent = fs.getDir(options.configPath)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
    local file, err = fs.open(options.configPath, "w")
    if not file then
        optionError("Cannot create config: " .. tostring(err))
    end
    local ok, writeError = pcall(file.write, textutils.serialize(config))
    file.close()
    if not ok then
        error("Cannot write config: " .. tostring(writeError), 0)
    end
    print("Created " .. options.configPath)
    print("Edit it to change settings. Load it with --config " .. options.configPath .. ".")
    return
end

local I = require("dns")._internal
if options.mode == "user" then
    if not I.username(options.username) then
        optionError("Username: 1..32 lowercase letters, digits, _ or -")
    end
    if options.role ~= "reader" and options.role ~= "admin" then
        optionError("Role must be reader or admin")
    end
end
local directory = config.directory
local authPath = fs.combine(directory, "auth.bin")
local recordsPath = fs.combine(directory, "records.bin")
local MAGIC_AUTH = "RNAUTH\2\0"
local MAGIC_RECORDS = "RNRECS\2\0"

-- Binary database validation, recovery, and atomic saves ------------------------
local function validateAuth(db)
    assert(type(db) == "table" and db.version == 2, "Unsupported auth database version")
    assert(I.integer(db.revision, 1, 4294967295), "Invalid auth database revision")
    assert(type(db.secret) == "string" and #db.secret == 32, "Invalid server secret")
    assert(type(db.users) == "table", "Invalid users")
    local count, admins = 0, 0
    for name, user in pairs(db.users) do
        assert(I.username(name) and type(user) == "table", "Invalid user entry")
        assert(user.role == "reader" or user.role == "admin", "Invalid user role")
        assert(type(user.salt) == "string" and #user.salt == 64, "Invalid password salt")
        assert(type(user.key) == "string" and #user.key == 32, "Invalid password verifier")
        assert(I.integer(user.iterations, 1000, 100000), "Invalid password iteration count")
        count = count + 1
        if user.role == "admin" then
            admins = admins + 1
        end
    end
    assert(
        count <= 64 and admins >= 1,
        "Auth database requires at least one admin and at most 64 users"
    )
    return true
end
local function validateRecords(db)
    assert(type(db) == "table" and db.version == 2, "Unsupported records database version")
    assert(I.integer(db.revision, 1, 4294967295), "Invalid records database revision")
    assert(I.array(db.records, 512), "Records must be an array of at most 512 items")
    for n, r in ipairs(db.records) do
        db.records[n] = I.record(r)
    end
    return I.index(db.records)
end
local function formatFor(path)
    if path == authPath then
        return MAGIC_AUTH, validateAuth
    end
    return MAGIC_RECORDS, validateRecords
end
local function readDatabase(path, filename)
    local magic, validate = formatFor(path)
    assert(fs.getSize(filename) <= I.maxBytes + 44, "Database is too large")
    local f = assert(fs.open(filename, "rb"))
    local bytes = f.readAll()
    f.close()
    assert(type(bytes) == "string" and bytes:sub(1, #magic) == magic, "Invalid database header")
    local p = #magic + 1
    local a, b, c, d = bytes:byte(p, p + 3)
    assert(d, "Truncated database")
    local length = ((a * 256 + b) * 256 + c) * 256 + d
    local digest = bytes:sub(p + 4, p + 35)
    local payload = bytes:sub(p + 36)
    assert(#payload == length and I.equal(digest, I.sha256(payload)), "Database checksum mismatch")
    local db = I.decode(payload)
    validate(db)
    return db
end
local function loadDatabase(path, repair)
    local best, bestPath, found
    for _, filename in ipairs({ path, path .. ".tmp", path .. ".bak" }) do
        if fs.exists(filename) then
            found = true
            local ok, db = pcall(readDatabase, path, filename)
            if ok and (not best or db.revision > best.revision) then
                best, bestPath = db, filename
            end
            if not ok then
                print("Ignoring invalid database candidate: " .. filename)
            end
        end
    end
    if not best and found then
        error("No valid copy of " .. path .. ". Restore a backup; files were preserved.", 0)
    end
    if best and repair and bestPath ~= path then
        -- Preserve the recovery source until the copy to the main path succeeds.
        if fs.exists(path) then
            fs.delete(path)
        end
        fs.copy(bestPath, path)
        readDatabase(path, path)
        print("Recovered " .. path .. " revision " .. best.revision .. " from " .. bestPath)
    end
    return best, bestPath
end
local function writeDatabase(path, db)
    local magic, validate = formatFor(path)
    validate(db)
    local payload = I.encode(db)
    local bytes = magic .. I.u32(#payload) .. I.sha256(payload) .. payload
    local temporary = path .. ".tmp"
    if fs.exists(temporary) then
        fs.delete(temporary)
    end
    local f = assert(fs.open(temporary, "wb"), "Cannot open temporary database")
    local ok, err = pcall(f.write, bytes)
    f.close()
    assert(ok, err)
    readDatabase(path, temporary) -- Verify before rotating the previous committed copy.
    if fs.exists(path) then
        if fs.exists(path .. ".bak") then
            fs.delete(path .. ".bak")
        end
        fs.move(path, path .. ".bak")
    end
    fs.move(temporary, path)
end
local function passwordUser(username, role, secret)
    assert(I.username(username), "Username: 1..32 lowercase letters, digits, _ or -")
    assert(role == "reader" or role == "admin", "Role must be reader or admin")
    write("Password (12+ characters): ")
    local password = read("*")
    write("Confirm password: ")
    local confirm = read("*")
    assert(
        password == confirm and #password >= 12 and #password <= 256,
        "Passwords must match and be 12..256 bytes"
    )
    print("Deriving password verifier...")
    local salt = I.nonce(secret)
    return {
        role = role,
        salt = salt,
        iterations = I.iterations,
        key = I.pbkdf2(password, salt, I.iterations),
    }
end
-- Offline commands and first-run provisioning ---------------------------------
local auth, authFrom = loadDatabase(authPath, options.mode ~= "check")
local recordsDB, recordsFrom = loadDatabase(recordsPath, options.mode ~= "check")
if options.mode == "check" then
    assert(auth and recordsDB, "Both auth.bin and records.bin must exist")
    print("Valid auth revision " .. auth.revision .. " at " .. authFrom)
    print("Valid records revision " .. recordsDB.revision .. " at " .. recordsFrom)
    print(#recordsDB.records .. " records. Both binary objects validated.")
    return
end
if not fs.exists(directory) then
    fs.makeDir(directory)
end
local createdAuth = false
if not auth then
    if options.mode == "user" then
        assert(options.role == "admin", "First user must be an admin")
    end
    print("Creating " .. authPath)
    local username = options.username
    if options.mode ~= "user" then
        write("Initial admin username: ")
        username = read()
    end
    local user = passwordUser(username, "admin")
    -- Bootstrap unpredictability comes from the initial password-derived key.
    auth = {
        version = 2,
        revision = 1,
        secret = I.hmac(user.key, "server-secret\0" .. I.nonce()),
        users = { [username] = user },
    }
    writeDatabase(authPath, auth)
    createdAuth = true
    print("Created admin " .. username)
end
if not recordsDB then
    recordsDB = { version = 2, revision = 1, records = {} }
    writeDatabase(recordsPath, recordsDB)
    print("Created empty " .. recordsPath)
end
if options.mode == "user" then
    if not createdAuth then
        local changed = I.clone(auth)
        changed.users[options.username] = passwordUser(options.username, options.role, auth.secret)
        changed.revision = changed.revision + 1
        validateAuth(changed)
        writeDatabase(authPath, changed)
    end
    print(
        "Saved user "
            .. options.username
            .. " with role "
            .. options.role
            .. ". Restart the server."
    )
    return
end
-- Network startup and in-memory session state ---------------------------------
local index = validateRecords(recordsDB) -- Authoritative record index cached in RAM.
if config.modem then
    rednet.open(config.modem)
else
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            rednet.open(name)
        end
    end
end
assert(rednet.isOpen(), "Attach a modem, then restart")
print("Authenticated Rednet DNS | server ID " .. os.getComputerID())
print("Records cached in RAM: " .. #recordsDB.records .. " | revision " .. recordsDB.revision)
print("Files: " .. authPath .. " and " .. recordsPath)
print("Lookup authentication required: " .. tostring(config.AuthenticationRequired))
print(
    "Record edits: " .. (config.readOnly and "disabled (read-only)" or "authenticated admins only")
)
if not config.AuthenticationRequired then
    print("WARNING: Public lookup replies are unsigned and can be spoofed.")
end
print("Ctrl+T stops. Use --user locally to create users or reset passwords.")

local sessions, pending = {}, {}
local fatalIO = false
local function cleanup()
    local now = os.clock()
    for id, s in pairs(sessions) do
        if now >= s.expires then
            sessions[id] = nil
        end
    end
    for id, p in pairs(pending) do
        if now >= p.expires then
            pending[id] = nil
        end
    end
end
local function count(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end
local function commit(changed, isAuth)
    local current = isAuth and auth or recordsDB
    local path = isAuth and authPath or recordsPath
    local validate = isAuth and validateAuth or validateRecords
    changed.revision = current.revision + 1
    local ok, newIndex = pcall(validate, changed)
    if not ok then
        return nil, tostring(newIndex), "BAD_RECORDS"
    end
    local fits = pcall(I.encode, changed)
    if not fits then
        return nil, "Database size or complexity limit exceeded", "LIMIT"
    end
    local saved, err = pcall(writeDatabase, path, changed)
    if not saved then
        fatalIO = true
        return nil,
            "Database save failed; server will stop. Check files before retrying.",
            "IO_ERROR"
    end
    if isAuth then
        auth = changed
    else
        recordsDB, index = changed, newIndex
    end
    return { revision = changed.revision }
end
local function revoke(username)
    for _, s in pairs(sessions) do
        if s.username == username then
            s.revoked = true
        end
    end
    -- Invalidate in-progress logins made with the old role/credentials too.
    for sender, p in pairs(pending) do
        if p.username == username then
            pending[sender] = nil
        end
    end
end
-- Authenticated operations: readers may look up; admins may mutate. ------------
local function process(s, op, a)
    if s.revoked or not auth.users[s.username] then
        return nil, "Authenticate again", "AUTH_REQUIRED"
    end
    if op == "logout" then
        s.revoked = true
        return true
    end
    if op == "lookup" then
        local q, err, code = I.question(a.type, a.name)
        if not q then
            return nil, err, code
        end
        return I.resolve(index, q.type, q.name)
    end
    if auth.users[s.username].role ~= "admin" then
        return nil, "Administrator role required", "FORBIDDEN"
    end
    if config.readOnly and (op == "setRecords" or op == "reloadRecords") then
        return nil, "Record changes are disabled by read-only mode", "READ_ONLY"
    end
    if op == "listRecords" then
        if not I.integer(a.offset, 0, 512) or not I.integer(a.limit, 1, 8) then
            return nil, "Invalid pagination", "BAD_ARGUMENT"
        end
        local records = {}
        for n = a.offset + 1, math.min(#recordsDB.records, a.offset + a.limit) do
            records[#records + 1] = recordsDB.records[n]
        end
        local nextOffset = a.offset + #records
        return {
            records = records,
            total = #recordsDB.records,
            revision = recordsDB.revision,
            nextOffset = nextOffset < #recordsDB.records and nextOffset or false,
        }
    elseif op == "setRecords" then
        -- Optional optimistic concurrency guard used by the example editor.
        if a.expectedRevision ~= nil then
            if not I.integer(a.expectedRevision, 1, 4294967295) then
                return nil, "Invalid expected revision", "BAD_ARGUMENT"
            end
            if a.expectedRevision ~= recordsDB.revision then
                return nil, "Records changed; reload before saving", "CONFLICT"
            end
        end
        local q, err, code = I.question(a.type, a.name)
        if not q then
            return nil, err, code
        end
        if not I.array(a.records, 64) then
            return nil, "Invalid record array", "BAD_ARGUMENT"
        end
        local changed = I.clone(recordsDB)
        local records = {}
        for _, r in ipairs(recordsDB.records) do
            if r.name ~= q.name or r.type ~= q.type then
                records[#records + 1] = r
            end
        end
        for _, r in ipairs(a.records) do
            if type(r) ~= "table" then
                return nil, "Invalid record", "BAD_RECORDS"
            end
            local ok, clean =
                pcall(I.record, { name = q.name, type = q.type, value = r.value, ttl = r.ttl })
            if not ok then
                return nil, tostring(clean), "BAD_RECORDS"
            end
            records[#records + 1] = clean
        end
        changed.records = records
        return commit(changed)
    elseif op == "reloadRecords" then
        local ok, loaded = pcall(loadDatabase, recordsPath, true)
        if not ok or not loaded then
            return nil, "No valid records file to reload", "IO_ERROR"
        end
        recordsDB, index = loaded, validateRecords(loaded)
        return { revision = recordsDB.revision, count = #recordsDB.records }
    elseif op == "listUsers" then
        local users = {}
        for name, user in pairs(auth.users) do
            users[#users + 1] = { username = name, role = user.role }
        end
        table.sort(users, function(a, b)
            return a.username < b.username
        end)
        return users -- Never expose salts, verifiers, or the server secret here.
    elseif op == "setRole" or op == "deleteUser" then
        if not I.username(a.username) or not auth.users[a.username] then
            return nil, "User not found", "NO_USER"
        end
        if op == "setRole" and a.role ~= "reader" and a.role ~= "admin" then
            return nil, "Invalid role", "BAD_ARGUMENT"
        end
        local changed = I.clone(auth)
        if op == "setRole" then
            changed.users[a.username].role = a.role
        else
            changed.users[a.username] = nil
        end
        local admins = 0
        for _, u in pairs(changed.users) do
            if u.role == "admin" then
                admins = admins + 1
            end
        end
        if admins == 0 then
            return nil, "Cannot remove or demote the last admin", "LAST_ADMIN"
        end
        local result, err, code = commit(changed, true)
        if result then
            revoke(a.username)
        end
        return result, err, code
    end
    return nil, "Unknown operation", "NOTIMP"
end
-- Login handshake and sequenced, authenticated request handling ----------------
local function send(sender, message)
    rednet.send(sender, message, I.protocol)
end
-- Public traffic has a separate, lookup-only path. It NEVER calls process().
-- Global rate limiting bounds work without allocating per-sender state.
local publicWindow, publicCount = 0, 0
local function handlePublic(sender, message)
    if type(message.id) ~= "string" or #message.id ~= 64 or not message.id:match("^[0-9a-f]+$") then
        return
    end
    local now = os.clock()
    if now - publicWindow >= 1 then
        publicWindow, publicCount = now, 0
    end
    if publicCount >= config.publicQueryLimit then
        return
    end
    publicCount = publicCount + 1

    local response = { kind = "public_response", id = message.id, ok = false }
    local records, err, code
    if message.op ~= "lookup" then
        err, code = "Administrator authentication required for this operation", "FORBIDDEN"
    elseif config.AuthenticationRequired then
        err, code = "This server requires authentication for lookups", "AUTH_REQUIRED"
    elseif type(message.args) ~= "table" then
        err, code = "Expected lookup arguments", "BAD_ARGUMENT"
    else
        local q
        q, err, code = I.question(message.args.type, message.args.name)
        if q then
            records, err, code = I.resolve(index, q.type, q.name)
        end
    end
    if records then
        response.ok, response.data = true, records
    else
        response.error, response.code = err, code
    end
    -- Encode public replies too: bounded data decoding on the client, no MAC.
    local ok, payload = pcall(I.encode, response)
    if not ok or #payload > 65536 then
        response = {
            kind = "public_response",
            id = message.id,
            ok = false,
            error = "Response exceeds the packet size limit",
            code = "RESPONSE_TOO_LARGE",
        }
        payload = I.encode(response)
    end
    send(sender, { publicPayload = payload })
    if config.logQueries then
        print("public #" .. sender .. " " .. (response.code or "OK"))
    end
end

local function handle(sender, message)
    cleanup()
    if not I.integer(sender, 0, 2147483647) or type(message) ~= "table" then
        return
    end
    if message.kind == "public_request" then
        handlePublic(sender, message)
    elseif message.kind == "hello" then
        if
            not I.username(message.username)
            or type(message.client) ~= "string"
            or #message.client ~= 64
        then
            return
        end
        local previous = pending[sender]
        if
            previous
            and previous.client == message.client
            and previous.username == message.username
        then
            send(sender, previous.challenge)
            return
        end
        if previous and os.clock() - previous.created < config.loginCooldown then
            return
        end
        if not previous and count(pending) >= config.maxPendingChallenges then
            return
        end
        local user = auth.users[message.username]
        local salt = user and user.salt
            or I.hex(I.hmac(auth.secret, "unknown-salt\0" .. message.username))
        local iterations = user and user.iterations or I.iterations
        local nonce = I.nonce(auth.secret)
        local challenge = {
            kind = "challenge",
            client = message.client,
            nonce = nonce,
            salt = salt,
            iterations = iterations,
        }
        pending[sender] = {
            username = message.username,
            client = message.client,
            nonce = nonce,
            created = os.clock(),
            expires = os.clock() + config.challengeTTL,
            challenge = challenge,
            key = user and user.key or I.hmac(auth.secret, "unknown-key\0" .. message.username),
            known = user ~= nil,
        }
        send(sender, challenge)
    elseif message.kind == "proof" then
        local p = pending[sender]
        if not p or p.client ~= message.client or p.nonce ~= message.nonce or p.failed then
            return
        end
        if p.welcome then
            if I.equal(message.proof, p.proof) then
                send(sender, p.welcome)
            end
            return
        end
        local transcript = {
            username = p.username,
            client = p.client,
            nonce = p.nonce,
            server = os.getComputerID(),
            sender = sender,
            salt = p.challenge.salt,
            iterations = p.challenge.iterations,
        }
        local proof = I.hmac(p.key, "dns-login-v2\0" .. I.encode(transcript))
        if not p.known or not I.equal(proof, message.proof) then
            p.failed = true
            return
        end
        if count(sessions) >= config.maxSessions then
            local oldest, expires = nil, math.huge
            for oldId, s in pairs(sessions) do
                if s.revoked and s.expires < expires then
                    oldest, expires = oldId, s.expires
                end
            end
            if oldest then
                sessions[oldest] = nil
            else
                return
            end
        end
        local sameSender = 0
        for _, s in pairs(sessions) do
            if s.sender == sender and not s.revoked then
                sameSender = sameSender + 1
            end
        end
        if sameSender >= config.maxSessionsPerComputer then
            return
        end
        local c2s, s2c = I.sessionKeys(p.key, transcript)
        local id = I.nonce(auth.secret)
        sessions[id] = {
            sender = sender,
            username = p.username,
            c2s = c2s,
            s2c = s2c,
            expires = os.clock() + config.sessionTTL,
            last = 0,
        }
        p.welcome = I.packet(s2c, {
            kind = "welcome",
            client = p.client,
            nonce = p.nonce,
            session = id,
            role = auth.users[p.username].role,
            ttl = config.sessionTTL,
        })
        p.proof = message.proof
        send(sender, p.welcome)
    elseif type(message.session) == "string" then
        local s = sessions[message.session]
        if not s or s.sender ~= sender then
            return
        end
        local body = I.unpackPacket(s.c2s, message)
        if
            not body
            or body.kind ~= "request"
            or body.session ~= message.session
            or not I.integer(body.seq, 1, 4294967295)
            or type(body.op) ~= "string"
            or #body.op > 32
            or type(body.args) ~= "table"
        then
            return
        end
        if body.seq == s.last and s.lastPayload == message.payload then
            send(sender, s.lastReply)
            return
        end
        if body.seq ~= s.last + 1 then
            return
        end
        local result, err, code = process(s, body.op, body.args)
        local response = {
            kind = "response",
            session = body.session,
            seq = body.seq,
            op = body.op,
            ok = result ~= nil,
        }
        if result ~= nil then
            response.data = result
        else
            response.error = err
            response.code = code
        end
        local ok, reply = pcall(I.packet, s.s2c, response)
        if not ok then
            reply = I.packet(s.s2c, {
                kind = "response",
                session = body.session,
                seq = body.seq,
                op = body.op,
                ok = false,
                error = "Response exceeds the packet size limit",
                code = "RESPONSE_TOO_LARGE",
            })
        end
        -- Cache before sending: retransmitting the last request never repeats a write.
        s.last, s.lastPayload, s.lastReply = body.seq, message.payload, reply
        send(sender, reply)
        if config.logQueries then
            print(s.username .. " #" .. sender .. " " .. body.op .. " " .. (response.code or "OK"))
        end
    end
end
while true do
    local sender, message = rednet.receive(I.protocol)
    handle(sender, message)
    if fatalIO then
        error("Database write failed. Stopped to avoid serving uncertain state.", 0)
    end
end
