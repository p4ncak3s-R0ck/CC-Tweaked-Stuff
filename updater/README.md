# Root-file self updater

Pull `meter.os.lua` from an RFS share and install it as **`/meter.os.lua`** on each client. DNS is public: there is no username/password prompt. The updater looks up **`SRV update.server.pancakes`**, resolves each target's `ID` records, and uses RFS to fetch the file. `SRV` is the spelling used by the DNS API (rather than `SVR`).

## Client installation

From the computer's root directory, with LPM already installed:

```text
cd /
lpm init
lpm repo p4ncak3s-R0ck/CC-Tweaked-Stuff main
lpm install update
update init 42 public
update pull
```

Replace **42** with your DNS computer's ID, and **public** with the RFS share containing `meter.os.lua`. Until this change is merged, use the PR head commit as the repository ref instead of `main`. If this directory already has an LPM project, skip `lpm init`.

This installs the `update` command and the `updater`, `dns`, and `rfs` libraries. Files are fetched over Rednet at runtime; GitHub/HTTP is only used for the initial LPM installation. Attach a modem and keep the DNS/RFS computers loaded.

The generated `/update-config.json`:

```json
{
  "dnsServer": 42,
  "service": "update.server.pancakes",
  "share": "public",
  "path": "meter.os.lua",
  "file": "meter.os.lua",
  "interval": 10,
  "background": true,
  "reboot": false
}
```

`path` is relative to the RFS share. `file` is a filename installed at the client root; for example, `"path":"os/meter.os.lua"` still installs as `/meter.os.lua`. You can change both to update another single file. `interval` defaults to 10 seconds and accepts 10–86400 seconds. Optional `modem` selects a DNS modem; otherwise attached modems are opened automatically.

## Automatic updates and startup

For a launcher that checks before launch, polls while Meter OS runs, and reboots after installing changed code, use:

```text
update auto
```

Add this to your existing startup program, or `/startup/meter.lua` if `/startup` is a directory:

```lua
shell.run("/update.lua", "auto", "/update-config.json")
```

`auto` enables background polling and reboot after updates, respecting your configured `interval`. New configs and the fallback interval use **10 seconds**. For an existing config, set `"interval": 10` to use that cadence. It compares file contents by SHA-256, downloads only changed code, and requires only the server's `meter.os.lua`. No additional server metadata is needed. If the network is unavailable, it starts the existing local copy. An update installed before launch starts immediately; a background update reboots so startup runs the new code. Polling ends if Meter OS returns or fails.

Use the existing `run` mode below when you want the config's `background` and `reboot` fields to control that behavior instead of the explicit `auto` defaults.

Add this to your existing startup program, or save it as `/startup/meter.lua` if `/startup` is a directory:

```lua
shell.run("/update.lua", "run", "/update-config.json")
```

`run` checks for updates, then launches `/meter.os.lua`. If DNS or RFS is offline it launches the existing local copy. With `background=true`, it checks every 10 seconds by default while the program runs. A successful check replaces the file on disk; the running Lua program continues until its next launch. **Set `reboot=true` to reboot the computer automatically when a background update is installed.** Leave it false if interrupting the running program would be undesirable. `background=false` checks only before launch.

With no initial local copy, an unsuccessful first download stops startup with an error. Startup is never installed or overwritten automatically. The managed program runs with the shell's current working directory unchanged. If it returns or fails, `run` ends; rollback is a manual command.

Commands:

```text
update check
update pull
update status
update rollback
update watch
update run
update auto
```

All commands also accept a configuration filename: `update pull /other-config.json`. Arguments after that filename are passed to the program by `run`, e.g. `update run /update-config.json --display left`. `watch` only polls and updates; it does not launch the managed program.

## Server setup

Use the existing RFS server; no additional updater server process or signed release manifest is needed. Put the source file at the configured share-relative path:

```text
/shared/meter.os.lua
```

For example, an RFS configuration can expose it with:

```json
{
  "name": "updates",
  "state": "/.rfs",
  "shares": {"public": {"root": "/shared", "public": true}},
  "tokens": {}
}
```

The DNS record already exists on your network. Its service values should use the RFS protocol string **`rfs-v1`**, and each target should have `ID` records for the actual RFS server computers. Example provisioning from an authenticated DNS admin client:

```lua
assert(dns.admin.setRecord("ID", "updates-primary.pancakes", 7, 60))
assert(dns.admin.setRecord("ID", "updates-backup.pancakes", 12, 60))
assert(dns.admin.setRecords("SRV", "update.server.pancakes", {
    {value={target="updates-primary.pancakes", protocol="rfs-v1", priority=0, weight=100}, ttl=60},
    {value={target="updates-backup.pancakes", protocol="rfs-v1", priority=10, weight=100}, ttl=60},
}))
```

Keep the DNS server's `AuthenticationRequired=false` for open lookups. Record administration still requires admin authentication. Clients always opt into public lookups explicitly. DNS caches are cleared each check so changes in the service targets are discovered promptly.

Lower priority numbers are tried first. Within a priority tier, positive weights select attempt order; zero-weight services follow positive-weight services. All IDs at a target are tried. A missing target or unreachable server falls through to alternatives. The first reachable service's file is authoritative for that check. Keep mirror contents synchronized; direct files have no release sequence, so an out-of-date primary can replace newer local content.

After changing the server file, the next client check notices the SHA-256 change. RFS stat captures external edits; a server restart is unnecessary. Publish complete files with RFS upload, or stop writing before clients fetch them. RFS provides immutable snapshots during each transfer.

## Verification and recovery

Downloads are staged under `/.updater/meter.os.lua/`, checked against the selected file's SHA-256 and size, and Lua syntax is checked without running the downloaded program. Failed downloads and syntax errors preserve the root file. Mirror fallback must match the content hash selected at the start of the check. RFS partial downloads can resume after interruption.

Before activation, the previous root file is saved as `/.updater/meter.os.lua/previous.lua`. Activation uses RFS's recoverable file rotation; interrupted moves are recovered on the next check/status/rollback. `update rollback` restores that backup and holds automatic updates. `update pull` explicitly resumes them. Only one updater process should manage a given root filename at a time. Old RFS partial/checkpoint files may remain after failed downloads; they are confined to the updater state directory.

Public DNS and public RFS do not prove publisher identity: the fetched hash detects corruption, not a malicious server or spoofed routing. This default is intended for your trusted Minecraft network. Optional `"hash":"<64 lowercase hex SHA-256>"` pins independently trusted content, but must be changed locally for each new version. Optional `rfs={token=...,secret=...}` credentials authenticate RFS responses; provision those locally and give the token read-only permissions. Never distribute a write/admin secret to update clients.

This updates the configured root file, including a program's own on-disk code when it is `meter.os.lua`; the separate LPM updater/runtime dependencies are maintained through `lpm update`.

## Launching through the Lua API

Use the library under a local variable named `update`:

```lua
local update = require("updater")
update.open("/meter.os.lua")
```

This reads DNS/share/remote-path settings from `/update-config.json`, checks for changed file contents, launches `/meter.os.lua`, and keeps checking while it runs. Like `update auto`, it enables background polling and reboot after background updates by default. It uses the configured interval, or 10 seconds if none is configured. Network failures are reported and the local copy still starts. It returns true when the launched program exits successfully; initial-install or application failures raise an error. The launcher must be started again at boot for reboot activation to work.

For explicit settings or arguments:

```lua
local update = require("updater")
update.open("meter.os.lua", {
    dnsServer = 42,
    interval = 10,
    args = {"--display", "left"},
})
```

`configPath` selects a different config file; `configPath=false` uses only supplied options and built-in defaults. Options override config settings. `background=false` checks only before launch, and `reboot=false` installs background updates for the next launch without rebooting. Root filenames with or without a leading slash are accepted. Use `path="apps/meter.os.lua"` to choose a different share-relative source; the installed destination remains `/meter.os.lua`. Opening a different filename selects that filename on the share unless you supply `path` explicitly. This API is a blocking launcher: put it in startup or another wrapper, rather than inside the file it launches.

## Library integration

A program can check for its own replacement without a separate launch wrapper:

```lua
local updater = require("updater")
local updates = updater.new({dnsServer=42, share="public", path="meter.os.lua"})
local ok, changed = pcall(function() return updates:poll() end)
if ok and changed then os.reboot() end -- Only reboot when appropriate for your app.
```

`check()` returns a candidate, `apply([candidate])` installs it, `poll()` honors the rollback hold, `status()` reports local state, and `rollback()` restores the previous file. Network/filesystem errors throw; use `pcall` around background jobs. Run polling in a separate `parallel` coroutine if the application needs its own event loop. Root programs run with normal CC privileges.

## Tests

```text
python -m pip install lupa
python updater/tests/run.py
```

The tests reuse the repository's simulated CC filesystem, actual RFS protocol implementation, and real LPM installer/module loaders. They cover package installation, public DNS, SRV ordering and ID zero, failover, root replacement, unchanged files, syntax rejection, offline failure, pinned hashes, rollback holds, failed activation, and restart recovery. The launcher tests also cover argument forwarding, 10-second polling, reboot after changed content, and no reboot when the file is unchanged. Actual Minecraft modem/startup behavior still needs an in-game check.
