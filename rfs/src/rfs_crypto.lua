-- Standalone encoding and cryptography extracted from dns/src/dns.lua.
-- No external dependencies; targets CC:Tweaked's Lua 5.2 API and bit32 library.
local I = {}
I.protocol = "rednet-files-v1"
I.maxBytes = 524288
local bit = assert(bit32, "CC:Tweaked bit32 library required")
local band, bxor, bnot, rshift, rrotate = bit.band, bit.bxor, bit.bnot, bit.rshift, bit.rrotate
local MOD = 4294967296

-- Input validation and name normalization -------------------------------------
function I.integer(v, lo, hi)
    return type(v) == "number" and v == v and v >= lo and v <= hi and v % 1 == 0
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

return I

