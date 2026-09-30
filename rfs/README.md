# RFS 0.1.0

Rednet file sharing for CC:Tweaked. Install it with LPM, or copy the four files in `src/` together and name `rfs.lua` as `rfs.lua`. RFS has **no required DNS or LPM runtime dependency**. The library is `require("rfs")`; the applications are ordinary `rfs-client` and `rfs-server` commands.

## Install

Once this package is on the selected repository ref:

```text
lpm init
lpm install rfs-server
rfs-server init rfs-config.json /shared
rfs-server rfs-config.json
```

On another computer:

```text
lpm init
lpm install rfs-client
rfs-client 7 hello
rfs-client 7 list public
rfs-client 7 get public hello.txt hello.txt
```

Replace `7` with the file server's computer ID. Attach a modem to both computers. Discovery uses Rednet's lookup broadcasts; direct connections need no discovery service. To install a review branch before merging, run `lpm repo p4ncak3s-R0ck/CC-Tweaked-Stuff rfs-v0.1.0` before installing.

For a program which only needs the API, use `lpm install rfs` and `require("rfs")`. `examples/package.lua` shows a project dependency. LPM still installs packages from GitHub: this release does **not** add a Rednet repository backend to LPM itself.

## Features

| Feature | Implementation |
| --- | --- |
| IDs and optional DNS | Numeric IDs, numeric strings, or an application-supplied hostname resolver |
| Named shares | Independent physical roots, public read defaults, scoped permissions |
| List/stat | Paginated listings, size/hash/revision, conditional stat |
| Binary transfers | Negotiated 256–8192 byte chunks, explicit replies as acknowledgments, retries, integrity checks |
| Download resume | Partial file plus revision/hash checkpoint, validated before resuming |
| Consistent reads | Immutable content snapshots; older revisions remain readable |
| Uploads | Temporary in-memory chunks, whole-file verification, recoverable file replacement |
| Range/batch | Range reads; batches of up to 32 stat/list requests with individual results |
| Recursive downloads | Preserve directory structure, reject unsafe remote names |
| Synchronization | One-way upload/download, copy changed content only; deletion must be explicitly enabled |
| Watches | Five-minute subscriptions, mutation notifications, sequence cursors, gap detection and polling recovery |
| Cancellation/progress | Explicit transfer cancellation, idle expiry, local progress callbacks |
| Remote management | mkdir, file/directory move, rename through move, file deletion, explicitly recursive directory deletion |
| History | Persistent snapshots, historical downloads, restore as a fresh revision |
| Tokens | Preconfigured identities; admin delegation with scoped rights and expiration, revoke, authenticated request/response MACs |
| Release manifests | Canonical signed payload envelope; verification delegates to a trusted local public-key provider and fails closed without one |
| Mirrors | Try alternate server IDs; require an independently trusted SHA-256 hash |
| Independent packaging | Three LPM manifests; no required runtime DNS/LPM imports |

Downloads resume after connection loss or restart. Upload chunks survive request retries but **not** server restart; restart an interrupted upload. Synchronization is one-way; there is no two-way conflict solver in this release. SHA-256/HMAC and canonical encoding are extracted from the existing DNS implementation, bundled independently.

## API

```lua
local rfs = require("rfs")
local client = rfs.connect(7)
local metadata, err, code = client:stat("public", "startup.lua")
assert(metadata, err)
local result, err = client:download("public", "startup.lua", "startup.lua", {
    hash = metadata.hash,
    revision = metadata.revision,
    progress = function(p) print(p.bytes, p.total, p.speed, p.eta) end,
    cancelled = function() return false end,
})
assert(result, err)
```

Network operations return `value` or `nil, message, code`. Local validation and multi-file helpers may throw structured `{code,message}` errors; use `pcall` around a job. `request(op,args)` provides all protocol operations. `must(op,args)` throws on a remote failure. One client supports one outstanding request at a time; use sequential jobs. `nextEvent(timeout)` reads verified notifications and `changes(share,path,sequence)` fills gaps. Renew watches before their `expires` time; a `gap=true` response requires relisting.

```lua
client:list("public", "releases")
client:readRange("public", "large.dat", 1024, 4096)
client:upload("public", "new.lua", "local.lua", {expected=false}) -- create only
client:upload("public", "new.lua", "local.lua", {expected=oldRevision})
client:downloadTree("public", "releases", "/downloads")
client:sync("public", "releases", "/downloads") -- download; keeps extra local files
client:sync("public", "releases", "/downloads", {direction="upload"})
client:sync("public", "releases", "/downloads", {delete=true}) -- explicitly removes extra local files
client:history("public", "new.lua")
client:restore("public", "new.lua", historicalRevision, currentRevision)
client:move("public", "old-name", "new-name", currentRevision)
client:delete("public", "directory", nil, true) -- explicit recursive deletion
```

Sync creates required subdirectories but retains empty extra directories. Keep the local sync root dedicated to shared content. Recursive jobs are multiple independent operations, not a transaction across an entire directory. Batches are read-only and not transactional. Directory listings can change between pages.

## Authentication and configuration

`rfs-server init` creates a public, read-only share. Edit its JSON configuration locally. A private share uses `"public": false`.

```json
{
  "name": "files-7",
  "state": "/.rfs",
  "shares": {
    "public": {"root": "/shared", "public": true},
    "releases": {"root": "/releases", "public": false}
  },
  "tokens": {
    "maintainer": {
      "secret": "REPLACE_WITH_A_RANDOM_SECRET_OF_AT_LEAST_32_BYTES",
      "admin": true,
      "permissions": [
        {"share": "public", "prefix": "", "operations": {"read": true, "list": true, "watch": true, "write": true, "delete": true}},
        {"share": "releases", "prefix": "", "operations": {"read": true, "list": true, "watch": true, "write": true, "delete": true}}
      ]
    }
  }
}
```

Generate a real random secret off-computer, replace the placeholder, and provision matching client credentials locally. `admin` allows token management but does not bypass share permissions. Optional `expires` is Unix time in seconds. Token paths match exact paths or descendants, never neighboring prefixes. Shares cannot overlap each other or the private state root. Do not expose the filesystem root.

A client credentials file:

```json
{"token":"maintainer","secret":"THE_SAME_PROVISIONED_SECRET"}
```

```text
rfs-client 7 put public new.lua local.lua --auth credentials.json
```

Library clients pass the same fields into `rfs.connect`. Admins can call `client:grant(id, unixExpiration, permissions)` to get new credentials, and `client:revoke(id)`. Delegation lasts at most 24 hours and cannot exceed the parent's expiry or permissions. Secrets are derived using HMAC; the new secret is not transmitted over Rednet. Provision the returned credentials through a trusted channel. Static configuration tokens cannot be altered remotely. A revoked/expired/unknown token gets no authenticated response, so clients report `TIMEOUT`.

Authenticated messages use HMAC-SHA-256, bind client/server IDs, and enforce a 60-second clock window and a duplicate-request cache. Computers need roughly synchronized clocks. Tokens authenticate messages; **file contents and metadata are not encrypted**. Public transfers do not authenticate the server; Rednet IDs are routing addresses, not identities. For trusted software updates, supply an independently trusted hash or verify a signed release first.

## DNS is optional

Install `dns` separately only where desired. RFS accepts `resolve=function(hostname) return computerId end`. The application owns DNS server selection/authentication and the interpretation of ID/SRV records. See `examples/dns-client.lua` for your current DNS API. This callback keeps both protocols independent.

## Signed releases and mirrors

A signed envelope is `{keyId=..., payload=canonicalBytes, signature=signatureBytes}`. `rfs.verifyRelease(envelope, trustedKeys, verify)` first checks the signature using a **local trusted verification provider**, then decodes and validates the file paths/hashes. `verify(publicKey,payload,signature)` must return exactly `true` for a valid signature. Choose the algorithm/key format through your provider and pin it locally. Never load a verifier or trust key from an unverified server. No built-in Ed25519/RSA implementation is supplied; cryptographic signature correctness must be tested with the chosen provider.

```lua
local release = rfs.verifyRelease(envelope, trustedKeys, verifySignature)
local file = release.files[1]
local result, failures = rfs.downloadMirrors({7, 12, 18}, "releases", file.path,
    "downloaded.lua", file.hash, credentials)
assert(result, failures)
```

Release payloads contain `files={{path="main.lua",hash="<64 hex SHA-256>"},...}` and may include a version. Mirrors need matching file content, not matching revision numbers. Never promote an unsigned mirror hash to a trusted update hash. Installing/running a downloaded program is an explicit application action; RFS does not execute remote files or manifests.

## Limits and recovery

Default hard limits: 1 MiB/file, 16 active transfers/server, 8192 bytes/chunk, 64 watchers, 256 retained change events, 256 cached requests, 32 requests/batch, 64 entries/page, 4096 entries/recursive job, depth 32, 120-second transfer idle/cache TTL, 300-second watch TTL. Resume sidecars use `.rfs-part` and `.rfs-resume.json`. `.rfs-old` and `.rfs-new` suffixes are reserved and hidden. Keep private object/history data outside shares.

File replacement moves a verified temporary file into place and keeps a recovery backup during activation. This is recoverable CC filesystem rotation, not a filesystem-wide atomic transaction. One server process must own its state and shares; avoid external writes during a management operation. `stat` captures external changes; watches automatically notify protocol mutations, and externally edited files when subsequently statted. There is no background filesystem watcher. History keeps snapshots indefinitely; no automatic retention cleanup is supplied.

## Validation

From the repository root:

```sh
python -m pip install lupa
python lpm/tools/build.py
python rfs/tests/run.py
```

Tests run in Lua 5.2 with simulated CC APIs and the real LPM resolver/installer/loaders. They exercise installation, normal requires/commands, binary transfers, retry idempotency, path confinement, permissions, HMAC tampering, snapshots, resume, expiry/cancellation, recursive jobs, sync, notifications/gaps, tokens, mirror verification, signature-provider rejection and history/restart recovery. The signature test uses a fixture provider, not a real public-key implementation. Actual Minecraft modem behavior remains to be tested.
