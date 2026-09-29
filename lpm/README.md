# LPM 0.1.0

A GitHub-backed package manager for CC:Tweaked. The bundled `lpm.lua` has no external Lua dependencies. DNS and message brokers are not required.

## Install on a computer

Download the bundled script as `lpm`, then run `lpm setup` once. This copies it to `/bin/lpm.lua`, adds `/bin` to the current shell path, and creates `/startup/lpm-path.lua` so the bare `lpm` command is available after reboot. If `/startup` is an existing file, setup preserves it and asks you to add `/bin` to your shell path manually. CC:Tweaked 1.88+ is required for `cc.require`; HTTP must be enabled for online installation. Public GitHub repositories only. Both `raw.githubusercontent.com` and `api.github.com` must be permitted by your server's HTTP rules.

```text
lpm setup
mkdir warehouse
cd warehouse
lpm init
lpm install dns
lpm verify
main
```

Create `main.lua`, then launch it normally as `main`. There is no `lpm run` or `lpm exec` command. The included `examples/warehouse` project loads `require("dns")`. Set your server ID and authenticate separately when you want DNS lookups.

## Repository setup

`github-ready/` contains files to copy into the root of your `CC-Tweaked-Stuff` repository. It adds DNS's package manifest, a separate DNS-server application package, and the LPM application package. Existing DNS source files are preserved. The DNS package version `2.0.0` describes the current v2 protocol; it is a proposed package release identifier.

The repository must contain these manifests before `lpm install dns` can work. In a draft branch, configure the source branch first:

```text
lpm repo p4ncak3s-R0ck/CC-Tweaked-Stuff codex/lpm-v0.1.0
lpm install dns
```

After merging, `main` is the default. You can configure any public source:

```text
lpm repo another-user/packages main packages
```

This reads `packages/<name>/manifest.lua`. Omit `packages` to use `<name>/manifest.lua`.

## Commands

| Command | Purpose |
| --- | --- |
| `lpm init` | Create project metadata |
| `lpm install` | Restore exact locked packages; resolve if no lock exists |
| `lpm install dns` | Add DNS using `*` and resolve the project |
| `lpm install dns@2.0.0` | Add an exact version |
| `lpm install dns@^2.0.0` | Add a compatible version constraint |
| `lpm install --offline` | Restore a matching lock using verified installed files |
| `lpm update` | Refresh all versions within declared constraints |
| `lpm remove dns` | Remove a direct dependency, retaining it if needed transitively |
| `lpm list` | Show installed versions and commit IDs |
| `lpm verify` | Check installed SHA-256 hashes |
| `lpm setup` | Make the bare command available from any directory and after reboot |
| `lpm repo owner/repo [ref] [path]` | Set the default GitHub repository |

Named installs and removals resolve the entire dependency set. Ordinary `install` honors the existing lock and rejects changes to `package.lua` until you run `update`. This avoids silently changing locked versions.

## Package manifest

```lua
return {
    manifestVersion = 1,
    name = "example",
    version = "1.0.0",
    type = "library", -- or "application"
    files = {
        ["src/example.lua"] = "example.lua",
        ["src/helpers.lua"] = "helpers.lua",
    },
    modules = { example = "example.lua" },
    dependencies = { dns = "^2.0.0" },
    -- Applications may specify entry = "example.lua".
    -- Optional hashes = { ["src/example.lua"] = "<64 hex SHA-256>" }.
}
```

Source paths are relative to the package's source directory. Destinations are relative to its installation directory. Explicit file lists avoid GitHub directory scraping. `modules` creates project-local loader files for require aliases; a library's installed `init.lua` also exports its package name. Other `.lua` paths get project-local loaders. Ordinary programs can use `require("dns")` without a special launcher or modified runtime. Installed applications get `<package-name>.lua` launch files, so run `dns-server --help` directly from the project directory. Loader files preserve the normal program environment and forward arguments. Module name conflicts and existing project files are rejected before activation.

## Project package.lua

```lua
return {
    manifestVersion = 1,
    name = "my-project",
    version = "0.1.0",
    type = "application",
    entry = "main.lua",
    repositories = {
        default = { github = "user/packages", ref = "main" },
        other = { github = "someone/libraries", ref = "main" },
    },
    packageRepositories = { special = "other" },
    dependencies = { dns = "^2.0.0", special = "1.0.0" },
}
```

Repository mappings are controlled by the project, including transitive dependency sources. Packages cannot redirect dependencies to arbitrary URLs.

## Versions and indexes

Without `index.lua`, LPM reads the manifest at the repository's selected ref. It pins that ref to one full commit before fetching manifests and source files. This supports a simple single-version repository immediately.

For multiple versions, add `<package>/index.lua`:

```lua
return {
    indexVersion = 1,
    versions = {
        ["1.0.0"] = { ref = "<full 40-character source commit>", path = "example" },
        ["1.1.0"] = { ref = "<another full source commit>", path = "example" },
    },
}
```

Replace the angle-bracket placeholders before use. First commit the version's manifest and sources; then add its commit SHA to the index in a subsequent commit. `examples/index.lua` is only a template, not a published catalog. Index refs must be immutable full commits. Version selection tries the newest compatible candidates and backtracks when transitive constraints conflict. One version per package name is supported. Cyclic dependency graphs can resolve, but cyclic runtime module initialization may still fail.

Supported constraints: `*`, exact `1.2.3`, caret `^1.2.3`, tilde `~1.2.3`. Stable three-component versions only; no prereleases, range unions, or comparison operators in V1.

## Files, recovery, and integrity

Installed packages and the lockfile live under `.lpm/current/`. Generated loader files live in the project directory and are tracked in the lockfile. Updates and removals manage only those files; edited loaders are preserved and produce an error instead of being overwritten. Normal launch does not automatically verify hashes; use `lpm verify` when you want an integrity check. Keep the project `package.lua` and `.lpm/current/package.lock` together when distributing reproducible projects. Source files can be downloaded again from their locked commits. Offline installation requires the currently installed files; this version does not have a separate historical package cache.

Downloads are staged under `.lpm/stage/`. A verified transaction journal and backup directory allow failed activation or the next LPM command to restore the old project metadata, installation, and module loaders. File rotation on CC's filesystem is recoverable, but is not a filesystem-wide atomic transaction. Avoid running two LPM writers in the same project concurrently.

SHA-256 hashes detect changes relative to the lock or optional manifest hashes. These hashes are not publisher signatures: initial installation trusts HTTPS and the configured GitHub repository, and a local editor can modify both files and lock metadata. Installed applications run with normal CC privileges when you explicitly launch them.

Manifests, indexes, projects, journals, and lockfiles are parsed as data, never executed. The parser supports `return { ... }`, quoted strings, decimal numbers, booleans, table keys, and comments. Functions, arbitrary expressions, nil, long-bracket strings, metatables, and executable hooks are rejected. No preinstall/postinstall scripts run.

Limits: 64 packages, 128 indexed versions per package, 256 files per package, 512 exported modules, 256 KiB metadata downloads, 1 MiB per downloaded file, 8 MiB installed data, 4,096 solver states. GitHub's unauthenticated API limits apply to resolving moving refs. Full commit refs bypass that API request. A network failure aborts the operation and preserves the previous installation; retry the command to retry the download.

## Development and validation

```sh
python3 tools/build.py
python3 -m pip install lupa
python3 tests/run.py
```

Tests use Lua 5.2 and simulated CC HTTP/filesystem/shell APIs. They cover cryptographic vectors, safe parsing, semver bounds, solver backtracking, rollback/restart recovery, corruption, offline restoration, path validation, CLI flows, normal module/application loading, bare-command setup, loader collisions, and loader rollback. `tests/run.py /path/to/cc/require.lua` additionally exercises the real CC module loader with its one Cobalt-specific pattern replacement normalized for stock Lua 5.2. Testing on an actual Minecraft computer remains necessary.

The SHA-256 implementation was extracted from your existing `dns/src/dns.lua`; it is bundled independently and does not require DNS at runtime. The existing DNS client/server copies retain their original contents.

## Future independent backends

The GitHub backend is built in. DNS discovery, Rednet package transfer, private GitHub authentication, package search, publisher signatures, and runtime dependency sandboxing are not implemented in V1. A future Rednet backend can reuse the same manifests and lock structure without changing DNS or the broker.
