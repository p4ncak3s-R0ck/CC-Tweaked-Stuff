> [!WARNING]
> THIS IS A VIBE CODED PROJECT
> CODE HAS __NOT__ BEEN VERIFIED/REVIEWED. USE AT YOUR OWN DESCRETION

# Authenticated DNS over Rednet

Two runtime Lua files, an optional example record editor, and live record administration for CC:Tweaked.

```lua
local dns = require("dns")
dns.setServer(42) -- DNS server's computer ID
assert(dns.authenticate("username", "your-long-password"))
local records, err, code = dns.lookupRecord("ID", "storage.base")
```

This is a custom Rednet name service. Its addresses are computer IDs, and its packets are not compatible with Internet DNS.

## Files and runtime behavior

| File | Location | Contents / purpose |
|---|---|---|
| `dnsServer.lua` (from `src/server.lua`) | Server computer | Server program, persistence, and permission enforcement |
| `dns.lua` | Server and every client | Public client library plus shared binary/crypto implementation |
| `examples/dnsRecords.lua` | Optional admin computer | Interactive record editor; install beside `dns.lua` |
| `/dns-server.cfg` | Optional server config | Generated with `--init-config`; settings only, no credentials |
| `dns.md` | Reference | This documentation |
| `auth.bin` | Created on the server | Users, password-derived verifiers, roles, and server secret |
| `records.bin` | Created on the server | Record objects and their revision number |

Place both Lua files in the same directory on the server. On clients, put `dns.lua` beside the program that requires it. No extra Lua dependencies are needed: the code uses CC:Tweaked's built-in `bit32`, Rednet, filesystem, and event APIs.

**Lookups read the authoritative record index from RAM.** They do not read `records.bin` for each query. An admin edit is validated, saved to disk, and then published to the RAM index before the server acknowledges it. No restart is needed for record edits. Records and users persist across restarts; login sessions do not.

The two databases are separate. Editing records does not rewrite `auth.bin`. Changing a user role does not rewrite `records.bin`.

Each database also gets a `.bak` recovery copy after an update. A `.tmp` file exists while a save is staged, and may remain after an interrupted save. These are recovery files, not additional configuration databases.

## Server setup

1. Attach a modem to the server and compatible modems to the clients. Connect wired modems to the same cable network, or ensure a reachable wireless path.
2. Save `dns.lua` and `dnsServer.lua` on the server.
3. Run:

   ```text
   dnsServer back
   ```

4. On first run, enter an initial admin username and a password twice. Password entry is masked. Usernames contain 1–32 lowercase letters, digits, underscores, or hyphens. Passwords must be 12–256 bytes; use a long, unique password.
5. The server creates `/auth.bin` and `/records.bin`, prints its computer ID, and begins serving. The initial records file is empty.

Replace `back` with the modem side or peripheral name. Omitting the modem argument opens all attached modems. The optional second argument selects a directory for both databases:

```text
dnsServer back /dns-data
```

To validate existing binary files without starting the network service:

```text
dnsServer --check
dnsServer --check /dns-data
```

To start at boot, add this to the server's startup program:

```lua
shell.run("dnsServer.lua", "back")
```

Only run one server process against a given database directory. Stop it with Ctrl+T before using the offline user-management command.

## Flags and configuration

In this repository the server is `src/server.lua`; save it as `dnsServer.lua` on the computer to match these commands. Run `dnsServer --help` for all flags. Legacy positional commands still work.

```text
dnsServer --init-config --modem back --directory /dns-data
dnsServer
dnsServer --AuthenticationRequired=false
dnsServer --read-only --max-sessions 16
```

`--init-config` writes `/dns-server.cfg` and exits without creating databases or opening modems. It never overwrites an existing file. Use `--config /custom.cfg` (`-c`) to select another config; explicit files must exist except when generating them. Missing default config uses built-in defaults. Precedence is **defaults < config < flags**. Relative paths resolve from the shell's current directory. Restart to apply changes.

The config is a data-only serialized table, not an executable Lua program:

```lua
{
    directory = "/dns-data",
    modem = "back",
    AuthenticationRequired = true,
    readOnly = false,
    logQueries = true,
    sessionTTL = 1800,
    challengeTTL = 180,
    maxSessions = 64,
    maxSessionsPerComputer = 8,
    maxPendingChallenges = 64,
    loginCooldown = 2,
    publicQueryLimit = 20,
}
```

All fields are optional; unknown fields and invalid values are rejected. `modem = false` opens all attached modems. Passwords stay out of this file.

| Flag | Config field | Default / range |
|---|---|---|
| `--directory`, `-d` | `directory` | `/` |
| `--modem`, `-m` / `--all-modems` | `modem` | `false` (all modems) |
| `--authentication-required [true\|false]` (alias `--AuthenticationRequired`) / `--no-authentication-required` | `AuthenticationRequired` | `true` |
| `--read-only` / `--no-read-only` | `readOnly` | `false` |
| `--log-queries` / `--no-log-queries` | `logQueries` | `true` |
| `--session-ttl` | `sessionTTL` | 1800 seconds; integer 1..3600 |
| `--challenge-ttl` | `challengeTTL` | 180 seconds; integer 1..3600 |
| `--max-sessions` | `maxSessions` | 64; integer 1..64 |
| `--max-sessions-per-computer` | `maxSessionsPerComputer` | 8; integer 1..8 |
| `--max-pending-challenges` | `maxPendingChallenges` | 64; integer 1..64 |
| `--login-cooldown` | `loginCooldown` | 2 seconds; integer 0..60 |
| `--public-query-limit` | `publicQueryLimit` | 20 requests/second; integer 1..1000 |

Value flags accept `--flag=value` or `--flag value`. Repeated/conflicting flags are rejected. Read-only mode blocks record writes, deletes, and reloads even for admins; it does not block account management. Session limits apply together, so the total-session limit can be lower than the per-computer limit. The login cooldown applies to replacement challenges while a previous challenge is retained; exact retries reuse that challenge.

### Public lookups (optional)

`AuthenticationRequired = false` allows **lookups only** without a login. It never permits anonymous edits, listing all records, user management, or admin RPCs. Initial setup still provisions an admin. Readers still cannot edit records.

Clients must explicitly opt into unsigned replies:

```lua
local dns = require("dns")
dns.setServer(42)
dns.setAuthenticationRequired(false) -- Explicitly accept unsigned public lookups.
local records, err, code = dns.lookupRecord("ID", "storage.base")
assert(records, err)
print(records[1].value)
```

The client defaults to requiring authentication. A valid authenticated session always uses signed queries, even after opting into public lookups. There is **no fallback after a failed signed request**. With public opt-in, a lookup made without a valid session (including after logout or expiry) is public. Public replies are not cached, and cannot populate the authenticated cache. An auth-required server returns `AUTH_REQUIRED` for public lookups.

**Public replies are unsigned and spoofable.** A matching computer ID and request nonce do not prove server identity. Use authenticated sessions when lookup integrity matters. Public requests use a separate lookup-only handler, bounded replies, and a global per-second request limit. Excess requests are dropped and may cause client timeouts; this is not comprehensive denial-of-service protection.

## Create users and reset passwords

User provisioning happens **locally on the server**, where new password material never needs to cross Rednet:

```text
dnsServer --user robot reader
dnsServer --user joshua admin
```

The command prompts for a password and confirmation. For an existing username, it replaces the password and role. Restart the server afterward. With a custom database directory:

```text
dnsServer --user robot reader /dns-data
```

If no auth database exists, the first user must be an admin. The last admin cannot be demoted, deleted, or replaced with a reader role.

| Role | Permissions |
|---|---|
| `reader` | Authenticate and query records |
| `admin` | Query records, edit/reload/list records, list users, change roles, and delete users |

Authenticated users have these roles. Public lookups can optionally bypass login, but **all record edits require an authenticated admin**, enforced by the server on every operation. Changing client-side Lua code or disabling `AuthenticationRequired` cannot grant admin privileges.

## Authenticate and query

```lua
local dns = require("dns")
dns.setServer(42) -- Replace with the actual DNS server ID
assert(dns.open("back"))

write("Password: ")
local ok, roleOrError, code = dns.authenticate("robot", read("*"))
if not ok then
    print(code .. ": " .. roleOrError)
    return
end

local records, err, lookupCode = dns.lookupRecord("ID", "storage.base")
if not records then
    print(lookupCode .. ": " .. err)
    return
end
rednet.send(records[1].value, { action = "listItems" }, "storage-v1")
```

The destination application must implement `listItems`; DNS only resolves its address. Authentication protects this DNS service, not subsequent messages sent directly with `rednet.send`.

If no modem is already open, the library opens attached modems automatically. Use `dns.open("back")` first to select a specific modem; this does not close other modems your program has opened.

## Edit records live

Authenticate as an admin, then use `dns.admin.*`:

```lua
local dns = require("dns")
dns.setServer(42)
write("Admin password: ")
assert(dns.authenticate("joshua", read("*")))

-- Replace this complete name/type set with one record.
assert(dns.admin.setRecord("ID", "storage.base", 17, 300))
assert(dns.admin.setRecord("ID", "backup.base", 18, 300))
assert(dns.admin.setRecord("CNAME", "items.base", "storage.base", 60))
assert(dns.admin.setRecord("PTR", 17, "storage.base", 300))
assert(dns.admin.setRecord("TXT", "storage.base", "Main warehouse", 300))

-- Replace a name/type set with multiple records.
assert(dns.admin.setRecords("SRV", "_storage.base", {
    { value = {
        target = "storage.base", protocol = "storage-v1", priority = 10, weight = 100,
    }, ttl = 300 },
    { value = {
        target = "backup.base", protocol = "storage-v1", priority = 20, weight = 100,
    }, ttl = 300 },
}))
```

A successful mutation returns `{ revision = <new revision> }`. Invalid records are rejected before replacing the live index. A save failure stops the server after reporting `IO_ERROR`, so it does not continue serving uncertain disk state.

`setRecord` replaces all existing records of that name and type with one record. `setRecords` replaces the complete set; it does not append. It preserves other names and other types at the same name. To delete a set:

```lua
assert(dns.admin.deleteRecords("TXT", "storage.base"))
```

An empty `setRecords` list has the same effect. Repeating either operation is safe in terms of record contents, though each acknowledged edit increments the revision.

### Example record editor

Copy `examples/dnsRecords.lua` and the updated `src/dns.lua` onto an admin computer. Run:

```text
dnsRecords --server 42 --modem back --username joshua
```

The app prompts for a masked password and refuses reader accounts. Choose **list** to browse records or **edit/add set** to select a name and type. Within a set you can add, edit, or remove individual entries, then confirm **save**. Cancelling makes no changes. Removing all entries and saving deletes that name/type set. All five record types are supported, including SRV fields and empty TXT values.

The editor preserves other entries in a set and uses the loaded database revision when saving. If another admin edits in the meantime, the server returns `CONFLICT` rather than overwriting newer changes. Reopen the set and reapply your edits. A timeout can mean a save succeeded: log in and inspect the database before retrying. Read-only mode returns `READ_ONLY`. Both client and server must be updated for revision-guarded saves.

Programmatic callers can also supply a revision:

```lua
local page = assert(dns.admin.listRecords())
assert(dns.admin.setRecord("ID", "storage.base", 17, 300, page.revision))
```

### List records

Results are paginated, with at most eight records per page:

```lua
local offset = 0
repeat
    local page, err = dns.admin.listRecords(offset, 8)
    assert(page, err)
    for _, record in ipairs(page.records) do
        print(textutils.serialize(record))
    end
    offset = page.nextOffset
until offset == false
```

Each page contains `records`, `total`, `revision`, and `nextOffset` (or `false` at the end). Pages reflect the current database; if another admin edits between pages, compare revisions and restart pagination if you need a consistent snapshot.

### Reload an externally updated records file

```lua
local result, err = dns.admin.reloadRecords()
assert(result, err)
print("Loaded revision " .. result.revision .. ": " .. result.count .. " records")
```

This validates the binary object on disk and replaces the RAM index. Normal `setRecord`/`setRecords` edits already do this automatically. The server does not poll the filesystem, and it does not read the records file on every query.

External tools must write the documented binary format and increment its revision. Reload and recovery choose the highest valid revision among the primary, `.tmp`, and `.bak` files. A lower-revision edit may therefore be superseded by a newer recovery copy. Reload does not load `auth.bin`, change credentials, or end login sessions.

## Supported record types

All successful queries return a nonempty list of `{ name, type, value, ttl }` records. Names are normalized to lowercase, and one final dot is removed. TTL is in seconds.

| Type | `value` | Purpose |
|---|---|---|
| `ID` | Integer computer ID | Name to one or more computers |
| `CNAME` | Target name string | Alias to another name |
| `PTR` | Target name string | Computer ID to name |
| `SRV` | `{ target, protocol, priority, weight }` | Rednet service location |
| `TXT` | String | Application metadata or descriptive text |

`ID` is custom. This version of `SRV` uses a Rednet protocol string in place of a TCP/UDP port. `NS`, `SOA`, `MX`, `A`, `AAAA`, and `ANY` are not implemented.

Record rules:

- Names permit ASCII letters, digits, underscores, hyphens, and separating dots. Labels are at most 63 characters, complete names at most 253. Empty labels, spaces, wildcards, and leading/trailing hyphens are rejected.
- Record types are case-insensitive in API calls.
- Computer IDs are integers from 0 through 2147483647, including 0.
- TTL defaults to 300 seconds; accepted integers are 0 through 604800. A zero TTL disables client caching for that answer.
- A CNAME is the only record permitted at its name and has exactly one target. Loops and chains longer than 16 aliases are rejected. Dangling targets are allowed so records can be provisioned in any order; queries through them return `NXDOMAIN` until the target exists.
- A CNAME query returns the immediate alias. Other types follow aliases automatically. Final records keep their canonical names, and their TTLs are limited by the shortest alias TTL along the path.
- PTR records are explicit, not automatically generated from ID records. Both `lookupRecord("PTR", 17)` and `lookupRecord("PTR", "017")` query ID 17.
- TXT values may be empty and are limited to 4096 bytes.
- SRV target names are returned without resolving them. Priority and weight default to 0 and must be integers from 0 through 65535. Protocol strings must be 1–128 bytes.
- SRV results are sorted by ascending priority, then target and protocol. Weight is metadata: applications implement weighted selection and failover themselves.
- Limits: 512 total records, 64 records per name/type, 64 users, 512 KiB per encoded database object, and 64 KiB per network payload. A packet-size limit may be reached before a record-count limit.

Service query example:

```lua
local services, err = dns.lookupRecord("SRV", "_storage.base")
assert(services, err)
local service = services[1].value
local addresses, addressErr = dns.lookupRecord("ID", service.target)
assert(addresses, addressErr)
rednet.send(addresses[1].value, "status", service.protocol)
```

## Client caching

The server's RAM index is authoritative and remains loaded until an edit or reload. Record TTLs do not expire server records.

Authenticated clients have a separate RAM cache (public answers are never cached):

- Positive answers are cached under normalized name and record type for the shortest TTL in the answer.
- Up to 256 answers are retained. Expired entries are removed, and the oldest entry is evicted when full.
- Returned tables are independent copies, with cached TTLs reduced by elapsed time.
- Errors are not cached.
- `dns.clearCache()` forces subsequent lookups to query the server.
- Successful admin calls clear that client's cache. Other clients retain their cached results until TTL expiry or an explicit clear.
- Changing servers, logging out, reauthenticating, session expiry, and an uncertain network exchange clear the cache.

A still-valid cached answer does not contact the server. Consequently, a user whose role is revoked can retain already-cached data until its TTL or local session lifetime expires. Authentication cannot retract information a client has already received.

## API reference

| Function | Result / behavior |
|---|---|
| `dns.new()` | Independent client object, with its own server, login session, and cache |
| `dns.setServer(id)` | Selects the server; forgets local login and cache |
| `dns.getServer()` | Server computer ID or `nil` |
| `dns.setAuthenticationRequired(boolean)` | Default `true`; `false` opts into unsigned, uncached lookups when no valid session exists. Never authorizes admin calls. |
| `dns.getAuthenticationRequired()` | This client's policy, not a discovery query for the server's policy |
| `dns.open([modemName])` | Opens a named modem or all modems; returns `true` or an error |
| `dns.authenticate(username, password)` | Returns `true, role`, or `nil, message, code` |
| `dns.isAuthenticated()` | Whether this client has a locally unexpired session |
| `dns.getRole()` | Role from the last successful login, or `nil` |
| `dns.lookupRecord(type, location)` | Returns a record list, or `nil, message, code` |
| `dns.logout()` | Revokes the session if reachable, always clears local state |
| `dns.clearCache()` | Removes this client's cached answers |
| `dns.setTimeout(seconds)` | Per-attempt timeout, default 3; allowed range greater than 0 through 60 |
| `dns.setRetries(count)` | Additional attempts, default 1; allowed integers 0 through 5 |
| `dns.admin.setRecord(type, name, value, [ttl], [expectedRevision])` | Replaces a name/type set with one record |
| `dns.admin.setRecords(type, name, records, [expectedRevision])` | Replaces a set with a list of `{ value, ttl }` entries |
| `dns.admin.deleteRecords(type, name, [expectedRevision])` | Removes a complete name/type set |
| `dns.admin.listRecords([offset], [limit])` | Page object; defaults 0 and 8, with a maximum limit of 8 |
| `dns.admin.reloadRecords()` | Reloads disk records into RAM; returns `{ revision, count }` |
| `dns.admin.listUsers()` | List of `{ username, role }`; no credential fields |
| `dns.admin.setRole(username, role)` | Persists a role change and revokes that user's existing sessions |
| `dns.admin.deleteUser(username)` | Deletes a user and revokes their sessions |

Admin methods return `nil, message, code` on failure. Record mutations and user mutations return a revision object on success. A user's role is enforced by the server's current auth state, not the cached result of `getRole()`.

`setServer`, `setTimeout`, `setRetries`, and `setAuthenticationRequired` raise Lua errors for invalid arguments. `open` also raises for an explicitly invalid modem name. Each client object permits only one in-flight call. A second call on that object returns `BUSY`; use another `dns.new()` instance for concurrency.

There is intentionally no remote `createUser` or `setPassword` method in this version. Provision or reset passwords with the local `--user` command. Live role changes and user deletion are available remotely to admins.

## Authentication and request handling

Passwords are not sent over Rednet. Login uses PBKDF2-HMAC-SHA-256 (10,000 iterations) to derive a key from the password and per-user salt. A challenge-response proof binds the username, both computer IDs, the client nonce, and the server nonce. The server returns a signed confirmation before the client accepts the session.

Directional session keys sign every request and response with HMAC-SHA-256. Request sequence numbers reject old replays. The server caches the most recent request and reply per session: resending exactly that request returns its original reply without performing a mutation twice.

Sessions last 30 minutes by default. They are bound to the connecting computer ID and live only in RAM. `sessionTTL` in the config (or `--session-ttl`) accepts an integer from 1 through 3600 seconds. Role changes and deletion revoke the affected user's sessions. Logout revokes its own session.

The login challenge lasts three minutes to allow password derivation on slower computers. Password derivation yields periodically and may take several seconds. Defaults allow a three-second wait plus one retry for each network stage; this does not include the local password-derivation time.

After all RPC attempts time out, the client discards its session because the server may have processed the operation. Authenticate again, then inspect records before deciding whether to repeat an uncertain edit. Unknown or expired sessions after a server restart result in a timeout; an unsigned error cannot make the client accept a forged response.

Default limits are 64 simultaneous sessions, at most eight active sessions per computer ID, and 64 pending login challenges. Config/flags can lower these limits. A short per-ID login throttle limits accidental rapid attempts. Computer IDs can be spoofed, so this is not comprehensive denial-of-service protection.

### Security boundaries

- **Authenticated messages are signed, not encrypted.** Public lookups, when explicitly enabled, have no signatures or server-identity guarantees. Authentication controls which requests the server accepts. A listener can still observe record contents and usernames on the wire.
- `auth.bin` does not contain plaintext passwords, but its verifier keys are credential-equivalent secrets for this protocol. Protect that file, its backups, and the server computer. Binary encoding does not hide secrets from someone who can read the file.
- Captured login exchanges allow offline password guesses. Use long random passwords. The pure-Lua derivation cost is chosen for Minecraft practicality; this is a custom application protocol, not an audited production authentication system.
- File checksums detect accidental corruption; they are not signatures and do not stop a local editor from changing files.
- This protocol adds integrity/authentication to DNS calls only. It does not secure unrelated Rednet services or prevent network flooding.

## Binary format

Both files contain actual typed binary object encoding, not a renamed JSON document or executable Lua text.

| Field | Encoding |
|---|---|
| Magic/version | 8 bytes: `RNAUTH` + byte `2` + byte `0`, or `RNRECS` + byte `2` + byte `0` |
| Payload length | Unsigned 32-bit integer, big-endian |
| Payload checksum | 32 raw SHA-256 bytes |
| Payload | Canonical typed object described below |

Payload tags:

| Tag byte | Value |
|---|---|
| 0 | `false` |
| 1 | `true` |
| 2 | Unsigned 32-bit integer, big-endian |
| 3 | Byte string: uint32 length followed by that many bytes |
| 4 | Table/map: uint32 pair count followed by encoded key/value pairs |

Keys are strings or unsigned integers. Numeric keys are ordered first, followed by string keys, each in ascending order. Arrays are maps with contiguous numeric keys starting at 1. The codec rejects cycles, duplicate decoded keys, unsupported tags, trailing data, excess depth, and size/complexity limit violations. It does not evaluate file contents as Lua code.

The auth payload is `{ version = 2, revision, secret, users }`. Each username maps to `{ role, salt, iterations, key }`. The records payload is `{ version = 2, revision, records }`, where `records` is an array of full record objects.

Saves write and verify a temporary binary file, rotate the primary to `.bak`, and move the temporary file into place. Startup/reload select the highest valid revision from the available candidates. A completed temporary write can be recovered even if the last move was interrupted. If all copies are invalid, startup preserves them and stops rather than silently creating empty data.

The shared codec is available to the server through `require("dns")._internal`. This is an implementation detail rather than a stable application API; normal administration should use `dns.admin.*`.

## Events, concurrency, and errors

Calls wait synchronously using `os.pullEvent`. Unrelated events consumed in the same coroutine are not replayed. Put an application's receive loop in a separate `parallel` coroutine when it must keep receiving while DNS is busy. For simultaneous lookups, use independently authenticated `dns.new()` clients, one per coroutine. No separate DNS background daemon is required.

Common error codes:

| Code | Meaning |
|---|---|
| `AUTH_REQUIRED` | Login is missing, expired locally, or revoked by the server |
| `AUTH_FAILED` | Password proof failed, or authentication could not complete |
| `FORBIDDEN` | Current server-side role is not admin |
| `NO_SERVER` / `NO_MODEM` | Missing client setup |
| `TIMEOUT` | No valid reply before attempts expired; reauthenticate afterward |
| `BUSY` | Another operation is in progress on this client object |
| `BAD_TYPE` / `BAD_NAME` / `BAD_ARGUMENT` | Invalid API input |
| `BAD_RECORDS` | Proposed records violate database rules |
| `CONFLICT` | Database revision changed; reload before saving |
| `READ_ONLY` | Server has disabled record edits and reloads |
| `NXDOMAIN` / `NODATA` | Missing name / no records of requested type |
| `CNAME_LOOP` | Alias traversal limit or loop |
| `NO_USER` / `LAST_ADMIN` | Unknown account / operation would remove the last admin |
| `LIMIT` | Proposed database exceeds supported size or complexity |
| `IO_ERROR` | Save or reload failed; inspect the server and recovery files |
| `RESPONSE_TOO_LARGE` | Response cannot fit in a 64 KiB packet |
| `BAD_RESPONSE` / `NOTIMP` | Invalid record answer / unsupported operation |

For timeouts, check the server ID, running server, modems, and loaded chunks. For stale records, clear the client cache or wait for TTL expiry. For authentication failures, confirm the username/password and that user provisioning was followed by a server restart.

Validation: the Lua client and server were exercised together using a simulated CC:Tweaked transport, event loop, and filesystem. Tests include standard crypto vectors, login and permissions, replay/tamper handling, RAM-only queries, live edits, cache behavior, persistence, and file recovery. In-game testing is still required on your Minecraft server.

References: [CC:Tweaked Rednet](https://tweaked.cc/module/rednet.html), [filesystem binary handles](https://tweaked.cc/module/fs.html), [parallel event handling](https://tweaked.cc/module/parallel.html), [HMAC specification](https://www.rfc-editor.org/rfc/rfc2104), [PBKDF2 specification](https://www.rfc-editor.org/rfc/rfc8018).
