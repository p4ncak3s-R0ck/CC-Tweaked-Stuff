# LPM 0.2.0

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

## Update LPM itself

```text
lpm self-update
```

This works from any directory, without `package.lua`. It resolves the built-in official repository's ref to a commit, reads its LPM manifest, and downloads the standalone bundle. Project repository settings and package source pins do not redirect self-updates. The command replaces the invoked script (normally `/bin/lpm.lua` after setup); the next invocation runs the new code. `lpm update` continues to update project dependencies.

An optional branch, tag or full commit selects a development build:

```text
lpm self-update codex/lpm-multi-repository
```

The manifest and generated bundle versions must match. LPM checks the generated bundle header, compiles it without executing it, verifies any publisher checksum, and rejects downgrades. Identical bytes are a no-op; revised builds with the same version can update. The download is limited to 1 MiB.

The candidate is staged and read back before replacement. The previous script is retained as `<script>.lpm-backup`; caught replacement failures restore it. A later successful update rotates that backup. Existing unrelated backup files or staging files (`<script>.lpm-new`) are preserved and cause an error. If the computer stops between renames, restore the backup manually before using that script again. These checks validate the download's format and optional checksum; the official HTTPS source remains the trust boundary.

Existing LPM builds without this command need a one-time download of the new bundle followed by `setup`. During development, select the PR branch when testing self-update; the default `main` source contains the most recently merged release.

## Repository setup

Official repository definitions are maintained in [`official-repositories.lua`](official-repositories.lua). Edit that file and run `python lpm/tools/build.py` to update the bundled script. The generated `lpm.lua` includes the definitions, so clients do not need a second file.

New projects use the built-in `official` repository: `p4ncak3s-R0ck/LPM-Packages` at `main`. Package source, manifests, examples and tests live there; folder packages use `<name>/manifest.lua`, and standalone packages use `<name>.lua`. Install official packages directly after `lpm init`:

```text
lpm install dns
lpm install rfs
```

Add other public GitHub repositories without replacing the official source:

```text
lpm repo add community another-user/packages main packages
lpm repo order community official
lpm repo list
lpm update
```

This reads `packages/<name>/manifest.lua` from the community repository. Omit the last argument for `<name>/manifest.lua`. Refs may be branches, tags, or full commit IDs.

Search order is `repositoryOrder`, then `defaultRepository` (or the legacy `default` source), then remaining custom repositories alphabetically, then `official` if not already listed. New projects prefer `official`; use `repo order` to put a custom repository ahead of it. The first source containing a package owns all candidate versions of that package: LPM does not mix versions from different publishers or fall through when its versions fail constraints. Only HTTP 404 for both index and manifest means a package is absent; network errors and invalid metadata stop resolution.

Pin a package, including a transitive dependency, to one source:

```text
lpm repo use dns official
lpm repo use special community
lpm repo unuse special
```

Pins never fall through to another repository. `official` is a reserved alias and cannot be redirected; use a custom alias to track a fork or development branch. `lpm repo official disable` removes the official source from searches (clear any package pins to it first); `enable` restores it. Explicitly adding the same GitHub repository under another alias is independent of this switch.

Existing main-branch source descriptors for `CC-Tweaked-Stuff` or the renamed `LPM` repository resolve package updates from `LPM-Packages`. Stored project metadata and old lockfile hashes are preserved; locked commits still fetch the original source history. Self-updates use `LPM`, independently of the package registry.

The original `lpm repo owner/repo [ref] [path]` command still sets the legacy `default` source. Existing project settings and lockfiles remain compatible. Repository edits require `lpm update` before restoring a previous lock.

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
| `lpm list` | Show installed versions, commit IDs, and source repositories |
| `lpm verify` | Check installed SHA-256 hashes |
| `lpm setup` | Make the bare command available from any directory and after reboot |
| `lpm self-update [ref]` | Update the invoked LPM script from the official repository |
| `lpm repo owner/repo [ref] [path]` | Set the legacy default GitHub repository |
| `lpm repo list` | Show effective search order and package pins |
| `lpm repo add name owner/repo [ref] [path]` | Add or replace a named source |
| `lpm repo remove name` | Remove an unused custom source |
| `lpm repo default name` | Select a preferred source after explicit order entries |
| `lpm repo order name ...` | Set repository search priority |
| `lpm repo use package name` | Assign a package to one source |
| `lpm repo unuse package` | Clear a package source assignment |
| `lpm repo official enable\|disable` | Toggle the built-in source |

Named installs and removals resolve the entire dependency set. Ordinary `install` honors the existing lock and rejects changes to `package.lua` until you run `update`. This avoids silently changing locked versions.

## Progress and diagnostics

Commands show labeled progress by default: repository searches, dependency resolution, an install/update/restore/remove plan, numbered file downloads, SHA-256 processing, transaction activation, and a final summary. The summary reports package/file counts, downloads, verified local reuse, removals, bytes staged, and elapsed time. Cached files do not appear as new downloads. A `Restore` plan entry means the version and source commit are unchanged; proxy file contents may still be fetched when resolving again.

```text
lpm install dns
lpm --verbose update
lpm install --offline --quiet
lpm self-update -v
```

`--verbose` / `-v` adds HTTP requests and response sizes, optional metadata misses, pinned commits, candidate versions and backtracking, per-file hash checks, and cache reuse. `--quiet` / `-q` suppresses progress and completion messages while preserving warnings, errors, and requested data such as `list`, repository listings, help, and version output. Flags may appear before or after the command; quiet takes precedence if both are given.

Failures use an `[ERROR][Failed]` message. Transaction recovery and rollback report their progress, and failed operations never emit a success summary. Self-updates show the selected source, version, validation, staging, and backup path. URL queries and credentials are redacted in diagnostic URLs. Logging failures cannot interrupt package activation or rollback. Output is written to the terminal; no log file is created automatically.

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

## Single-file packages

A repository can publish `<name>.lua` directly at its package root, without a package directory or separate manifest. The file starts with a metadata comment and continues with ordinary Lua code:

```lua
--[=[lpm
return {
    manifestVersion = 1,
    name = "hello",
    version = "1.0.0",
    type = "application", -- use "library" for a require-able module
    dependencies = {},
}
]=]
print("Hello from LPM!")
```

Publish this as `hello.lua` at the repository root (or its configured package subdirectory), then use `lpm install hello`. Run an application as `hello`; a library file should return its module value and can be loaded with `require("hello")`. See [`examples/hello.lua`](examples/hello.lua).

A root `<name>.lua` may instead contain a plain `return { ... }` package manifest, including `files` with HTTPS proxy URLs; no metadata comment is needed for this data-only format. It uses the same manifest schema and supports root-relative files.

For executable single-file packages, metadata is parsed as literal data and never executed during discovery. It requires the same schema, name, version and type as a regular manifest. Do not declare `files` or `hashes`: the containing file is the sole source and destination, and its SHA-256 is recorded in the lockfile after downloading. Application entry defaults to `<name>.lua`; optional module aliases may target that same file. Dependencies resolve across repositories as usual.

LPM checks `<name>/index.lua`, then `<name>/manifest.lua`, then `<name>.lua` within each repository, before moving to the next repository. Folder packages take precedence over standalone files in that source. Single-file discovery pins the selected repository ref to a commit, downloads the file once, and reuses those bytes during staging. Subsequent locked and offline installs use the same hash checks as other packages. Standalone files use the selected ref's version; version indexes continue to describe folder manifests. The limits are 1 MiB per file and 8 MiB of prefetched standalone content per resolution.

## Proxy packages and external file sources

A repository can publish a manifest that downloads files directly from HTTPS URLs. This works in official and custom repositories; the manifest and dependency metadata stay in the selected GitHub repository. Relative file sources and HTTPS sources can be mixed:

```lua
return {
    manifestVersion = 1,
    name = "example",
    version = "1.0.0",
    type = "library",
    files = {
        ["https://example.com/releases/1.0.0/example.lua"] = "example.lua",
        ["https://example.com/releases/1.0.0/helpers.lua"] = "helpers.lua",
        ["local.lua"] = "local.lua",
    },
    modules = { example = "example.lua" },
    dependencies = { dns = "^2.0.0" },
    -- Optional publisher checksums use the exact source URL as the key:
    -- hashes = {
    --     ["https://example.com/releases/1.0.0/example.lua"] = "<64 hex SHA-256>",
    -- },
}
```

Each source URL must be unique; repeating a Lua table key is rejected. Use direct file download URLs, including query strings if necessary. Only HTTPS URLs without credentials or fragments are accepted; destinations must still be safe relative paths. Additional download hosts must be allowed by the Minecraft server's HTTP configuration. Downloads retain the 1 MiB per-file and 8 MiB installation limits.

LPM records the downloaded bytes' SHA-256 hashes in the lockfile. Locked restores reject changed remote content; offline restores use verified installed files. The repository commit pins the manifest, but cannot freeze an external server's content: use immutable version URLs or optional publisher hashes for reproducible first installs and updates. `lpm update` resolves again and may accept new bytes if no publisher checksum is specified. Files are downloaded directly by the client; the official repository does not relay the bytes.

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
    defaultRepository = "default",
    repositoryOrder = { "default", "other", "official" },
    officialRepository = true, -- optional; enabled unless false
    packageRepositories = { special = "other", dns = "official" },
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

## Verify the published registry

Run `python lpm/tests/run.py` for the simulated unit suite. Run `python lpm/tests/live_repository.py --self-ref codex/lpm-single-file-packages` from a checkout of this branch to install all 10 packages using real public GitHub HTTP responses, verify hashes and library imports, execute the standalone example, restore offline, recover corruption, and check the published self-update bundle. Requires Python `lupa` and outbound HTTPS. The live test uses an isolated in-memory CC:Tweaked filesystem and does not modify a Minecraft computer.
