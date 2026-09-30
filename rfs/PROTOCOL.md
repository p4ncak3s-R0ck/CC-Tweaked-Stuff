# Rednet Files Protocol, version 1

Status: implemented draft, package version 0.1.0. Transport protocol string: `rednet-files-v1`.

## Addressing and discovery

A connection targets a computer ID. DNS is an optional application-side resolver; it is never required by the wire protocol. Logical paths consist of a named share plus a relative path. The empty relative path addresses a share's root. Absolute paths, `.`/`..` components, backslashes, control characters, repeated/trailing separators, colons and reserved recovery suffixes are invalid. Paths are case-sensitive and limited to 240 bytes. Share names use letters, digits, underscores and hyphens, up to 64 bytes. Private server storage is outside every share root.

Servers advertise using `rednet.host("rednet-files-v1", name)`. Clients may find IDs with `rednet.lookup` and query `hello`; discovering a server does not authenticate it.

## Framing and canonical encoding

Rednet messages are Lua tables containing:

| Field | Type | Meaning |
| --- | --- | --- |
| `payload` | byte string | Canonically encoded message body, at most 60000 bytes |
| `token` | string | Identity/token name, or empty string for public access |
| `mac` | byte string or false | 32-byte HMAC-SHA-256 of payload, or false for public access |

Bodies include the same `token` inside the MAC-covered payload; the two values must match. Binary files are raw byte strings inside the payload, not Lua source or base64.

Encoding tags: `0` false, `1` true, `2` unsigned 32-bit integer followed by 4 big-endian bytes, `3` byte string followed by unsigned length and bytes, `4` map followed by unsigned pair count and encoded key/value pairs. Map keys are strings or unsigned integers, ordered by key type name (`number` before `string`) then by value. Arrays are maps with consecutive integer keys starting at 1. `nil` fields are omitted. No floats, executable code, metatables, repeated keys, cycles or trailing bytes. Decoder limits: depth 16, 20000 nodes, 10000 pairs per table. The outer packet size bound applies before decoding.

Request body:

```lua
{
    v=1, kind="request", token="", id="unique-request-id",
    client=42, server=7, time=1790769600,
    op="stat", args={share="public",path="main.lua"},
}
```

Successful response: `{v=1,kind="response",token=...,id=...,client=...,server=...,ok=true,result={...}}`.
Failure: same correlation fields with `ok=false,error={code=...,message=...}`.

`time` is Unix time in seconds. Authenticated servers require requests within 60 seconds of their clock. Invalid/malformed/unauthenticated/expired identity packets are silently discarded. Requests bind both computer IDs. Clients verify server ID, client ID, request ID, version, identity and response MAC. The protocol authenticates packets but does not encrypt them.

A client retries using the **identical packet and request ID**. For 120 seconds, the server caches response packets by client ID, identity and request ID. An identical request reuses its response; a different payload with the same ID is rejected. Live cache entries are not evicted to accept new mutations; a full cache yields `SERVER_BUSY`. Expired cached requests also fall outside the 60-second request clock window. Upload chunk replacements are idempotent.

## Operations

All path operations have `share` and `path` arguments unless explicitly listed otherwise. Pagination offsets are zero-based and page sizes are 64 entries.

| Operation | Additional arguments | Result | Permission |
| --- | --- | --- | --- |
| `hello` | none | name, server, version, maxChunk, maxFile, capability booleans | public |
| `shares` | none | visible share names | list |
| `list` | offset | entries, nextOffset, done | list |
| `stat` | optional revision, ifRevision | metadata or notModified | read |
| `batch` | requests containing op/args; stat/list only | individually successful/failed results | each child operation |
| `open` | optional revision, chunk | transfer ID, agreed chunk size, metadata | read |
| `read` | transfer, offset, optional length; no share/path | offset, data, chunk hash, revision, eof | read on transfer path |
| `upload` | size, hash, optional expected, chunk | transfer ID, chunk size | write |
| `write` | transfer, offset, data, hash; no share/path | received byte count | write on transfer path |
| `commit` | transfer; no share/path | published metadata | write on transfer path |
| `cancel` | transfer; no share/path | cancelled | owning client/identity |
| `mkdir` | none | created | write |
| `move` | destination, optional expected | moved | delete source, write destination and descendants |
| `delete` | optional expected, recursive | deleted | delete path and descendants |
| `history` | offset | versions, nextOffset, done | read |
| `restore` | revision, optional expected | newly published metadata | read and write |
| `watch` | none | watch ID, sequence, expires | watch |
| `unwatch` | watch; no share/path | cancelled | owning client/identity |
| `changes` | sequence | events, sequence, gap | watch |
| `grant` | id, nonce, expires, permissions; no share/path | changed | admin, delegated rights subset |
| `revoke` | id; no share/path | changed | admin; static configured tokens excluded |

`hello` lists supported operation families, not the caller's access rights. Public shares permit read, list and watch, never writes. Tokens use server-managed permission entries `{share,prefix,operations={read=true,...}}`. A prefix matches itself and descendants; `a` does not match `ab`. Checks apply to the relevant transfer path and every descendant touched by recursive management. Different named shares cannot overlap physical roots.

## Metadata and history

File metadata: `{revision,hash,size,deleted,time}`. `hash` is lowercase hex SHA-256. Revision identifiers are opaque to clients; this implementation uses a per-path generation and content hash. Directory metadata uses `{directory=true,size=0}`.

Deleted historical versions have `deleted=true,hash=false,size=0`; they cannot be downloaded or restored as file content. Deleting a file preserves prior snapshots. Restoring creates a new current generation even if content matches. History pages are oldest-first. Historical stat/open reads a specific persisted revision.

An `expected` revision guards a write against concurrent replacement. For upload, `expected=false` means create only; omitting `expected` permits replacement. `ifRevision` on stat yields `notModified=true` when the current revision matches. Range reads use offset plus length within a read transfer; full-file integrity requires checking metadata.hash after reconstruction. SHA-256 alone establishes integrity relative to supplied metadata, not publisher identity.

## Transfers

`open` pins an immutable read snapshot. New edits never change that transfer's bytes. `upload` allocates a write transfer with a declared whole-file size/hash and optional expected revision. Both operations negotiate a chunk size from 256 through 8192 bytes, default 4096. Requests outside supported limits are rejected rather than silently clamped.

Read offsets are arbitrary byte offsets. Read length cannot exceed the negotiated chunk. Each read response includes an offset, chunk hash, revision and eof flag. The response is the acknowledgment; missing responses trigger identical request retries.

Write offsets must align to the negotiated chunk size. Every nonfinal chunk is exactly that size; the final chunk fills the remaining bytes. The server verifies each supplied chunk hash and acknowledges receipt. Zero-byte files require no chunks. Commit requires all chunks and checks the complete hash before publishing. Its expected-revision check runs at publication time.

Transfers expire after 120 idle seconds and are bound to the initiating computer/identity. Cancellation discards transfer state. Download resume creates a fresh read transfer and reuses locally verified bytes only when the revision/hash still match. Revision changes restart the download. Upload state is memory-backed and does not survive server restart. Successful commit uses recoverable temporary-file rotation; observers never read partially accumulated chunks.

## Subscriptions

`watch` subscribes to an exact path and descendants for 300 seconds. Notification body:

```lua
{v=1,kind="event",token=...,server=7,watch="...",
 event={sequence=123,share="public",path="main.lua",kind="changed",revision="..."}}
```

Events are authenticated using the watch owner's identity, filtered by current watch permission and expiry. Kinds are changed, deleted and mkdir. Server-global sequence numbers are persisted; gaps in a scoped stream can simply mean another share changed. The journal keeps 256 events. `changes` returns at most 64 matching events, a continuation sequence and `gap=true` if the caller's cursor predates the retained journal. A gap requires refreshing directory state. Polling also recovers missed Rednet notifications. Notifications are hints; always inspect current metadata before acting. External edits are noticed when a later stat records their state, not through background polling.

## Delegated tokens

An admin supplies a new identity, public 64-hex nonce, expiry and permission subset. Both sides derive its secret as hex HMAC-SHA-256(parentSecret, `"rfs-grant-v1\0" .. id .. "\0" .. nonce`), where `\0` denotes a single zero byte. Neither the request nor the response sends the derived secret. Parent permissions/expiry bound delegation; remote grants cannot create admins. Expiration is at most 24 hours. Identities must be unique. Remote revoke removes the stored delegated identity. Static identities are managed through local configuration.

## Signed releases and mirrors

Signed envelopes are application objects `{keyId,payload,signature}`. The signature covers the exact canonical payload bytes. Payload data includes a files array containing relative paths and SHA-256 hashes, and may include a version. Clients pin trusted publisher keys and the verifier implementation locally. This implementation supplies the envelope/validation API and requires a real external signature provider; no public-key algorithm is bundled.

Mirror selection is a client policy: try alternate IDs and require each selected file to match an independently trusted hash, such as one from a verified release. Mirror revision identifiers may differ. Content discovery never grants authority to a new signing key. RFS does not execute release manifests or downloaded source.

## Client-side policies

Recursive downloads walk listings and preserve relative paths. One-way synchronization compares hashes, transfers changed files and keeps extra destination content unless deletion is explicitly requested. Two-way reconciliation is outside this implementation. Sync uses expected revisions for uploads and pinned revisions/hashes for downloads. Multi-file jobs are not transactions. Progress events are produced locally from acknowledged bytes; they do not add packets. Automatic program replacement/execution belongs to an updater application, after verification.

## Errors

Codes include `NOT_FOUND`, `ACCESS_DENIED`, `BAD_PATH`, `BAD_REQUEST`, `HASH_MISMATCH`, `REVISION_CHANGED`, `TRANSFER_EXPIRED`, `INCOMPLETE`, `ALREADY_EXISTS`, `DIRECTORY_NOT_EMPTY`, `SERVER_BUSY`, `TOO_LARGE`, `UNSUPPORTED` and `IO_ERROR`. Clients may additionally return/throw `TIMEOUT`, `BAD_RESPONSE`, `CANCELLED`, `BAD_HASH`, `MIRRORS_FAILED`, `DNS_REQUIRED`, `SIGNATURE_PROVIDER_REQUIRED`, `UNTRUSTED_PUBLISHER`, `BAD_MANIFEST` and `BAD_SIGNATURE`. Authentication rejection deliberately times out rather than providing a signed error with an unknown or expired key.
