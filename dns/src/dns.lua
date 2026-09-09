-- Rednet DNS v2: require("dns"). Also supplies shared internals to dnsServer.lua.
-- No external dependencies; targets CC:Tweaked's Lua 5.2 API and bit32 library.
local I = {}
I.protocol = "rednet-dns-v2"
I.types = { ID = true, CNAME = true, PTR = true, SRV = true, TXT = true }
I.iterations = 10000
I.maxBytes = 524288
local bit = assert(bit32, "CC:Tweaked bit32 library required")
local band, bxor, bnot, rshift, rrotate = bit.band, bit.bxor, bit.bnot, bit.rshift, bit.rrotate
local MOD = 4294967296

-- Input validation and name normalization -------------------------------------
function I.integer(v, lo, hi)
    return type(v) == "number" and v == v and v >= lo and v <= hi and v % 1 == 0
end
function I.name(v)
    if type(v) ~= "string" then
        return nil
    end
    local n = v:lower():gsub("%.$", "")
    if
        #n == 0
        or #n > 253
        or n:find("[^a-z0-9_.%-]")
        or n:sub(1, 1) == "."
        or n:sub(-1) == "."
        or n:find("..", 1, true)
    then
        return nil
    end
    for label in n:gmatch("[^.]+") do
        if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-" then
            return nil
        end
    end
    return n
end
function I.username(v)
    return type(v) == "string" and #v >= 1 and #v <= 32 and v:match("^[a-z0-9_%-]+$") ~= nil
end
function I.question(kind, name)
    kind = type(kind) == "string" and kind:upper() or ""
    if not I.types[kind] then
        return nil, "Unsupported record type", "BAD_TYPE"
    end
    if kind == "PTR" and I.integer(name, 0, 2147483647) then
        name = tostring(name)
    end
    name = I.name(name)
    if not name then
        return nil, "Invalid record name", "BAD_NAME"
    end
    if kind == "PTR" then
        if not name:match("^%d+$") or not I.integer(tonumber(name), 0, 2147483647) then
            return nil, "PTR name must be a computer ID", "BAD_NAME"
        end
        name = string.format("%.0f", tonumber(name))
    end
    return { type = kind, name = name }
end
local function u32(n)
    return string.char(
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256
    )
end
local function read32(s, p)
    local a, b, c, d = s:byte(p, p + 3)
    assert(d, "Truncated integer")
    return ((a * 256 + b) * 256 + c) * 256 + d
end
I.u32 = u32

-- Canonical typed binary encoding. Table keys are strings or unsigned integers.
-- Tags: 0=false, 1=true, 2=uint32, 3=byte string, 4=map. No Lua evaluation.
function I.encode(value)
    local parts, seen, nodes, size = {}, {}, 0, 0
    local function emit(s)
        size = size + #s
        assert(size <= I.maxBytes, "Object too large")
        parts[#parts + 1] = s
    end
    local function encode(v, depth)
        nodes = nodes + 1
        assert(depth <= 16 and nodes <= 20000, "Object too complex")
        if v == false then
            emit("\0")
        elseif v == true then
            emit("\1")
        elseif I.integer(v, 0, MOD - 1) then
            emit("\2" .. u32(v))
        elseif type(v) == "string" then
            emit("\3" .. u32(#v))
            emit(v)
        elseif type(v) == "table" then
            assert(not seen[v], "Cyclic object")
            seen[v] = true
            local keys = {}
            for k in pairs(v) do
                assert(type(k) == "string" or I.integer(k, 0, MOD - 1), "Invalid table key")
                keys[#keys + 1] = k
            end
            table.sort(keys, function(a, b)
                if type(a) ~= type(b) then
                    return type(a) < type(b)
                end
                return a < b
            end)
            emit("\4" .. u32(#keys))
            for _, k in ipairs(keys) do
                encode(k, depth + 1)
                encode(v[k], depth + 1)
            end
            seen[v] = nil
        else
            error("Unsupported value in binary object")
        end
    end
    encode(value, 0)
    return table.concat(parts)
end
function I.decode(bytes)
    assert(type(bytes) == "string" and #bytes <= I.maxBytes, "Invalid binary object size")
    local pos, nodes = 1, 0
    local function take(n)
        assert(n >= 0 and pos + n - 1 <= #bytes, "Truncated object")
        local s = bytes:sub(pos, pos + n - 1)
        pos = pos + n
        return s
    end
    local function number()
        return read32(take(4), 1)
    end
    local function decode(depth)
        nodes = nodes + 1
        assert(depth <= 16 and nodes <= 20000, "Object too complex")
        local tag = take(1):byte()
        if tag == 0 then
            return false
        elseif tag == 1 then
            return true
        elseif tag == 2 then
            return number()
        elseif tag == 3 then
            return take(number())
        elseif tag == 4 then
            local count = number()
            assert(count <= 10000, "Table too large")
            local out = {}
            for _ = 1, count do
                local k = decode(depth + 1)
                assert(type(k) == "string" or I.integer(k, 0, MOD - 1), "Invalid key")
                assert(out[k] == nil, "Duplicate key")
                out[k] = decode(depth + 1)
            end
            return out
        end
        error("Unknown binary tag")
    end
    local value = decode(0)
    assert(pos == #bytes + 1, "Trailing bytes")
    return value
end
function I.clone(value)
    return I.decode(I.encode(value))
end
function I.array(t, maxCount)
    if type(t) ~= "table" then
        return false
    end
    local count = 0
    for k in pairs(t) do
        if not I.integer(k, 1, maxCount) then
            return false
        end
        count = count + 1
    end
    for n = 1, count do
        if t[n] == nil then
            return false
        end
    end
    return true, count
end

-- SHA-256, HMAC-SHA-256, and PBKDF2-HMAC-SHA-256 (one 32-byte block).
local K = {
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
}
function I.sha256(s)
    local len = #s
    s = s
        .. "\128"
        .. string.rep("\0", (55 - len) % 64)
        .. u32(math.floor(len / 536870912))
        .. u32((len * 8) % MOD)
    local h = {
        0x6a09e667,
        0xbb67ae85,
        0x3c6ef372,
        0xa54ff53a,
        0x510e527f,
        0x9b05688c,
        0x1f83d9ab,
        0x5be0cd19,
    }
    for start = 1, #s, 64 do
        if start > 1 and (start - 1) % 16384 == 0 and sleep then
            sleep(0)
        end
        local w = {}
        for j = 1, 16 do
            w[j] = read32(s, start + (j - 1) * 4)
        end
        for j = 17, 64 do
            local x, y = w[j - 15], w[j - 2]
            w[j] = (
                w[j - 16]
                + bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
                + w[j - 7]
                + bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
            ) % MOD
        end
        local a, b, c, d, e, f, g, hh = table.unpack(h)
        for j = 1, 64 do
            local t1 = (
                hh
                + bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
                + bxor(band(e, f), band(bnot(e), g))
                + K[j]
                + w[j]
            ) % MOD
            local t2 = (
                bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
                + bxor(band(a, b), band(a, c), band(b, c))
            ) % MOD
            hh, g, f, e, d, c, b, a = g, f, e, (d + t1) % MOD, c, b, a, (t1 + t2) % MOD
        end
        local v = { a, b, c, d, e, f, g, hh }
        for j = 1, 8 do
            h[j] = (h[j] + v[j]) % MOD
        end
    end
    local out = {}
    for j = 1, 8 do
        out[j] = u32(h[j])
    end
    return table.concat(out)
end
function I.hmac(key, message)
    if #key > 64 then
        key = I.sha256(key)
    end
    key = key .. string.rep("\0", 64 - #key)
    local inner, outer = {}, {}
    for i = 1, 64 do
        inner[i] = string.char(bxor(key:byte(i), 0x36))
        outer[i] = string.char(bxor(key:byte(i), 0x5c))
    end
    return I.sha256(table.concat(outer) .. I.sha256(table.concat(inner) .. message))
end
function I.equal(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then
        return false
    end
    local diff = 0
    for n = 1, #a do
        diff = bit.bor(diff, bxor(a:byte(n), b:byte(n)))
    end
    return diff == 0
end
function I.pbkdf2(password, salt, iterations)
    assert(type(password) == "string" and #password <= 256, "Invalid password")
    assert(
        type(salt) == "string" and #salt <= 128 and I.integer(iterations, 1, 100000),
        "Invalid KDF parameters"
    )
    local u = I.hmac(password, salt .. u32(1))
    local result = { u:byte(1, 32) }
    for n = 2, iterations do
        u = I.hmac(password, u)
        for j = 1, 32 do
            result[j] = bxor(result[j], u:byte(j))
        end
        if n % 64 == 0 and sleep then
            sleep(0)
        end
    end
    return string.char(table.unpack(result))
end
function I.hex(s)
    return (s:gsub(".", function(c)
        return string.format("%02x", c:byte())
    end))
end
local nonceCounter = 0
function I.nonce(secret)
    nonceCounter = nonceCounter + 1
    local seed = tostring(os.epoch("utc"))
        .. ":"
        .. tostring(os.clock())
        .. ":"
        .. nonceCounter
        .. ":"
        .. tostring(os.getComputerID())
        .. ":"
        .. tostring(math.random(1, 2147483647))
    return I.hex(secret and I.hmac(secret, seed) or I.sha256(seed))
end
function I.packet(key, body)
    local payload = I.encode(body)
    assert(#payload <= 65536, "Packet exceeds 64 KiB")
    return { payload = payload, mac = I.hmac(key, payload) }
end
function I.unpackPacket(key, packet)
    if
        type(packet) ~= "table"
        or type(packet.payload) ~= "string"
        or #packet.payload > 65536
        or not I.equal(packet.mac, I.hmac(key, packet.payload))
    then
        return nil
    end
    local ok, body = pcall(I.decode, packet.payload)
    return ok and type(body) == "table" and body or nil
end
function I.sessionKeys(userKey, transcript)
    local base = I.hmac(userKey, "dns-session-v2\0" .. I.encode(transcript))
    return I.hmac(base, "client-to-server"), I.hmac(base, "server-to-client")
end

-- Record validation, indexing, and alias resolution ----------------------------
function I.record(raw)
    assert(type(raw) == "table", "Record must be a table")
    local q, err = I.question(raw.type, raw.name)
    assert(q, err)
    local ttl = raw.ttl
    if ttl == nil then
        ttl = 300
    end
    assert(I.integer(ttl, 0, 604800), "TTL must be 0..604800")
    local v = raw.value
    if q.type == "ID" then
        assert(I.integer(v, 0, 2147483647), "Invalid computer ID")
    elseif q.type == "CNAME" or q.type == "PTR" then
        v = assert(I.name(v), "Invalid target")
    elseif q.type == "TXT" then
        assert(type(v) == "string" and #v <= 4096, "TXT must be at most 4096 bytes")
    elseif q.type == "SRV" then
        assert(type(v) == "table", "SRV value must be a table")
        local target = assert(I.name(v.target), "Invalid SRV target")
        assert(
            type(v.protocol) == "string" and #v.protocol >= 1 and #v.protocol <= 128,
            "Invalid SRV protocol"
        )
        local priority, weight = v.priority or 0, v.weight or 0
        assert(
            I.integer(priority, 0, 65535) and I.integer(weight, 0, 65535),
            "Invalid SRV priority/weight"
        )
        v = { target = target, protocol = v.protocol, priority = priority, weight = weight }
    end
    return { name = q.name, type = q.type, value = v, ttl = ttl }
end
function I.index(records)
    assert(I.array(records, 512), "Records must be an array of at most 512 items")
    local index = {}
    for _, record in ipairs(records) do
        local r = I.record(record)
        index[r.name] = index[r.name] or {}
        local node = index[r.name]
        node[r.type] = node[r.type] or {}
        assert(#node[r.type] < 64, "At most 64 records per name/type")
        node[r.type][#node[r.type] + 1] = r
    end
    for name, node in pairs(index) do
        if node.CNAME then
            assert(#node.CNAME == 1, "Only one CNAME per name")
            for kind in pairs(node) do
                assert(kind == "CNAME", "CNAME cannot coexist with other records")
            end
            local seen, current, hops = {}, name, 0
            while index[current] and index[current].CNAME do
                assert(not seen[current] and hops < 16, "CNAME loop or chain exceeds 16 aliases")
                seen[current] = true
                hops = hops + 1
                current = index[current].CNAME[1].value
            end
        end
    end
    return index
end
function I.resolve(index, kind, name)
    local seen, current, ttl, hops = {}, name, 604800, 0
    while true do
        if seen[current] or hops > 16 then
            return nil, "Alias loop", "CNAME_LOOP"
        end
        seen[current] = true
        local node = index[current]
        if not node then
            return nil, "Name not found", "NXDOMAIN"
        end
        if node[kind] then
            local answer = I.clone(node[kind])
            for _, r in ipairs(answer) do
                r.ttl = math.min(r.ttl, ttl)
            end
            if kind == "SRV" then
                table.sort(answer, function(a, b)
                    if a.value.priority ~= b.value.priority then
                        return a.value.priority < b.value.priority
                    end
                    if a.value.target ~= b.value.target then
                        return a.value.target < b.value.target
                    end
                    return a.value.protocol < b.value.protocol
                end)
            end
            return answer
        end
        if kind == "CNAME" or not node.CNAME then
            return nil, "No records of this type", "NODATA"
        end
        ttl = math.min(ttl, node.CNAME[1].ttl)
        current = node.CNAME[1].value
        hops = hops + 1
    end
end

-- Client setup, transport, and authentication ----------------------------------
local function newClient()
    local dns = { admin = {} }
    local server, timeout, retries = nil, 3, 1
    local session, cache, busy = nil, {}, false
    local function reset()
        session = nil
        cache = {}
    end
    function dns.setServer(id)
        assert(not busy, "DNS client is busy")
        assert(I.integer(id, 0, 2147483647), "Server must be a computer ID")
        server = id
        reset()
    end
    function dns.getServer()
        return server
    end
    function dns.setTimeout(n)
        assert(type(n) == "number" and n > 0 and n <= 60, "Timeout must be >0..60")
        timeout = n
    end
    function dns.setRetries(n)
        assert(I.integer(n, 0, 5), "Retries must be 0..5")
        retries = n
    end
    function dns.clearCache()
        cache = {}
    end
    function dns.open(name)
        if name then
            rednet.open(name)
        else
            for _, p in ipairs(peripheral.getNames()) do
                if peripheral.hasType(p, "modem") then
                    rednet.open(p)
                end
            end
        end
        if not rednet.isOpen() then
            return nil, "No modem available", "NO_MODEM"
        end
        return true
    end
    local function ready()
        if server == nil then
            return nil, "Call dns.setServer first", "NO_SERVER"
        end
        if not rednet.isOpen() then
            return dns.open()
        end
        return true
    end
    -- One timer per attempt, unaffected by unrelated traffic. A separate client
    -- instance is needed for simultaneous calls; use dns.new() with parallel.
    local function exchange(packet, accept)
        local ok, err, code = ready()
        if not ok then
            return nil, err, code
        end
        for _ = 1, retries + 1 do
            if not rednet.send(server, packet, I.protocol) then
                return nil, "No open modem", "NO_MODEM"
            end
            local timer = os.startTimer(timeout)
            while true do
                local event, sender, message, protocol = os.pullEvent()
                if event == "timer" and sender == timer then
                    break
                end
                if event == "rednet_message" and sender == server and protocol == I.protocol then
                    local accepted = accept(message)
                    if accepted then
                        os.cancelTimer(timer)
                        return accepted
                    end
                end
            end
        end
        return nil, "DNS server did not return a valid reply", "TIMEOUT"
    end
    local function locked(fn, ...)
        if busy then
            return nil, "Use dns.new() for simultaneous calls", "BUSY"
        end
        busy = true
        local result = table.pack(pcall(fn, ...))
        busy = false
        if not result[1] then
            error(result[2], 0)
        end
        return table.unpack(result, 2, result.n)
    end
    function dns.isAuthenticated()
        return session ~= nil and os.clock() < session.expires
    end
    function dns.getRole()
        if dns.isAuthenticated() then
            return session.role
        end
    end
    local rpc
    function dns.authenticate(username, password)
        return locked(function()
            if dns.isAuthenticated() then
                rpc("logout", {})
            end
            reset()
            if
                not I.username(username)
                or type(password) ~= "string"
                or #password < 12
                or #password > 256
            then
                return nil, "Use a lowercase username and a 12..256 byte password", "BAD_ARGUMENT"
            end
            local hello = { kind = "hello", username = username, client = I.nonce() }
            local challenge, err, code = exchange(hello, function(m)
                if
                    type(m) == "table"
                    and m.kind == "challenge"
                    and m.client == hello.client
                    and type(m.nonce) == "string"
                    and #m.nonce == 64
                    and type(m.salt) == "string"
                    and #m.salt == 64
                    and I.integer(m.iterations, 1000, 100000)
                then
                    return m
                end
            end)
            if not challenge then
                return nil, err, code
            end
            local key = I.pbkdf2(password, challenge.salt, challenge.iterations)
            local transcript = {
                username = username,
                client = hello.client,
                nonce = challenge.nonce,
                server = server,
                sender = os.getComputerID(),
                salt = challenge.salt,
                iterations = challenge.iterations,
            }
            local c2s, s2c = I.sessionKeys(key, transcript)
            local proof = {
                kind = "proof",
                client = hello.client,
                nonce = challenge.nonce,
                proof = I.hmac(key, "dns-login-v2\0" .. I.encode(transcript)),
            }
            local started = os.clock()
            local answer
            answer, err, code = exchange(proof, function(m)
                local body = I.unpackPacket(s2c, m)
                if
                    body
                    and body.kind == "welcome"
                    and body.client == hello.client
                    and body.nonce == challenge.nonce
                    and type(body.session) == "string"
                    and #body.session == 64
                    and (body.role == "admin" or body.role == "reader")
                    and I.integer(body.ttl, 1, 3600)
                then
                    return body
                end
            end)
            if not answer then
                return nil, "Authentication failed or server unavailable", "AUTH_FAILED"
            end
            session = {
                id = answer.session,
                c2s = c2s,
                s2c = s2c,
                seq = 0,
                expires = started + answer.ttl,
                role = answer.role,
            }
            return true, answer.role
        end)
    end
    rpc = function(op, args)
        if not dns.isAuthenticated() then
            reset()
            return nil, "Call dns.authenticate first", "AUTH_REQUIRED"
        end
        local s = session
        s.seq = s.seq + 1
        local body = { kind = "request", session = s.id, seq = s.seq, op = op, args = args or {} }
        local encoded, packet = pcall(I.packet, s.c2s, body)
        if not encoded then
            s.seq = s.seq - 1
            return nil, "Request exceeds supported size or structure", "BAD_ARGUMENT"
        end
        -- Session ID is a routing hint; the authenticated body must repeat it.
        packet.session = s.id
        local answer, err, code = exchange(packet, function(m)
            local r = I.unpackPacket(s.s2c, m)
            if
                r
                and r.kind == "response"
                and r.session == s.id
                and r.seq == s.seq
                and r.op == op
                and type(r.ok) == "boolean"
            then
                if r.ok and r.data ~= nil then
                    return r
                end
                if not r.ok and type(r.error) == "string" and type(r.code) == "string" then
                    return r
                end
            end
        end)
        if not answer then
            reset() -- Unknown sequence state; never silently reuse an uncertain session.
            return nil, err .. "; authenticate again before continuing", code
        end
        if not answer.ok then
            if answer.code == "AUTH_REQUIRED" then
                reset()
            end
            return nil, answer.error, answer.code
        end
        return answer.data
    end
    function dns.logout()
        return locked(function()
            local result, err, code
            if dns.isAuthenticated() then
                result, err, code = rpc("logout", {})
            else
                result = true
            end
            reset()
            return result, err, code
        end)
    end
    -- Lookups and TTL-aware local caching.
    function dns.lookupRecord(kind, name)
        return locked(function()
            local q, err, code = I.question(kind, name)
            if not q then
                return nil, err, code
            end
            -- Check session before cache: logging out never permits cached lookups.
            if not dns.isAuthenticated() then
                reset()
                return nil, "Call dns.authenticate first", "AUTH_REQUIRED"
            end
            local key = q.type .. ":" .. q.name
            local now = os.clock()
            local item = cache[key]
            if item and now < item.expires then
                local answer = I.clone(item.records)
                for _, r in ipairs(answer) do
                    r.ttl = math.max(0, math.floor(r.ttl - (now - item.at)))
                end
                return answer
            end
            cache[key] = nil
            local records
            records, err, code = rpc("lookup", q)
            if not records then
                return nil, err, code
            end
            local valid, count = I.array(records, 64)
            if not valid or count == 0 then
                return nil, "Invalid answer", "BAD_RESPONSE"
            end
            local clean, ttl = {}, 604800
            for n, r in ipairs(records) do
                local ok, c = pcall(I.record, r)
                if not ok or c.type ~= q.type then
                    return nil, "Invalid answer record", "BAD_RESPONSE"
                end
                clean[n] = c
                ttl = math.min(ttl, c.ttl)
            end
            if ttl > 0 then
                local total, oldest, oldTime = 0, nil, math.huge
                for k, v in pairs(cache) do
                    if os.clock() >= v.expires then
                        cache[k] = nil
                    else
                        total = total + 1
                        if v.at < oldTime then
                            oldest, oldTime = k, v.at
                        end
                    end
                end
                if total >= 256 then
                    cache[oldest] = nil
                end
                cache[key] = { records = clean, at = os.clock(), expires = os.clock() + ttl }
            end
            return I.clone(clean)
        end)
    end
    -- Administrative RPC helpers. Authorization is enforced by the server.
    local function admin(op, args)
        return locked(function()
            local value, err, code = rpc(op, args)
            if value then
                cache = {}
            end
            return value, err, code
        end)
    end
    function dns.admin.setRecords(kind, name, records)
        local q, err, code = I.question(kind, name)
        if not q then
            return nil, err, code
        end
        if not I.array(records, 64) then
            return nil, "Expected up to 64 {value,ttl} entries", "BAD_ARGUMENT"
        end
        local clean = {}
        for n, r in ipairs(records) do
            if type(r) ~= "table" then
                return nil, "Invalid record", "BAD_ARGUMENT"
            end
            local ok, c =
                pcall(I.record, { type = q.type, name = q.name, value = r.value, ttl = r.ttl })
            if not ok then
                return nil, tostring(c), "BAD_ARGUMENT"
            end
            clean[n] = c
        end
        q.records = clean
        return admin("setRecords", q)
    end
    function dns.admin.setRecord(kind, name, value, ttl)
        return dns.admin.setRecords(kind, name, { { value = value, ttl = ttl } })
    end
    function dns.admin.deleteRecords(kind, name)
        return dns.admin.setRecords(kind, name, {})
    end
    function dns.admin.listRecords(offset, limit)
        offset, limit = offset or 0, limit or 8
        if not I.integer(offset, 0, 512) or not I.integer(limit, 1, 8) then
            return nil, "Offset must be 0..512 and limit 1..8", "BAD_ARGUMENT"
        end
        return admin("listRecords", { offset = offset, limit = limit })
    end
    function dns.admin.reloadRecords()
        return admin("reloadRecords", {})
    end
    function dns.admin.listUsers()
        return admin("listUsers", {})
    end
    function dns.admin.setRole(username, role)
        if not I.username(username) or (role ~= "reader" and role ~= "admin") then
            return nil, "Invalid username or role", "BAD_ARGUMENT"
        end
        return admin("setRole", { username = username, role = role })
    end
    function dns.admin.deleteUser(username)
        if not I.username(username) then
            return nil, "Invalid username", "BAD_ARGUMENT"
        end
        return admin("deleteUser", { username = username })
    end
    return dns
end
local dns = newClient()
dns.new = newClient
dns._internal = I -- Shared implementation for dnsServer.lua, not a stable public API.
return dns
