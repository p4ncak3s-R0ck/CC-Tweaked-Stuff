# Changelog

## 0.2.0 — package repository split

- LPM source and self-updates live in `p4ncak3s-R0ck/LPM`.
- Package implementations, manifests, examples and tests live in `p4ncak3s-R0ck/LPM-Packages`.
- Packages may be folders, standalone Lua programs with metadata comments, or root Lua manifest files.
- Dependency resolution supports multiple sources, package pins and HTTPS file proxies.
- Installs provide progress logging, lockfile hashes, verified offline restoration and rollback.
- GitHub ref lookup requests the SHA representation so large commits do not break package installation or self-update.

Use `lpm self-update` to refresh an installed copy, and `lpm update` inside a project to resolve packages from the new official source.
