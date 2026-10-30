# Server-wide LPM datapack

Download the ZIP matching your Minecraft version from the [nightly release](https://github.com/p4ncak3s-R0ck/LPM/releases/tag/nightly). For 1.21.1, use `lpm-datapack-mc-1.21.1.zip`; for 1.21.11, use `lpm-datapack-mc-1.21.11.zip`.

1. Put the ZIP unchanged into `<world>/datapacks/` on each Minecraft server.
2. Enable/reload datapacks with `/reload`, or restart the server. Confirm it is enabled with `/datapack list enabled`.
3. Reboot existing CC:Tweaked computers. New computers install LPM on their first boot. This applies to computers, turtles and pocket computers running CraftOS.
4. Run `lpm help` or `lpm install dns`.

Install only the ZIP for that world's Minecraft version. CC:Tweaked itself must already be installed for that game version. This pack contains Lua ROM files, not Minecraft client resources.

## Installation and updates

- The datapack includes the complete bundled LPM script, so installation needs no HTTP access.
- `/rom/autorun/lpm.lua` installs a missing copy to `/bin/lpm.lua` and adds `/bin` to the current shell path on every boot.
- Existing managed installations, including newer self-updated copies, are preserved. Existing startup files are not changed.
- `/rom/programs/lpm.lua` is a fallback launcher that delegates to the writable copy using `shell.run`. This ensures `lpm self-update` updates `/bin/lpm.lua` rather than trying to modify read-only ROM.
- Updating the datapack changes the bundled seed for new/missing installations. It does not forcibly replace existing local versions; use `lpm self-update` on those computers.
- Package installation and self-update need HTTP access to `api.github.com`, `raw.githubusercontent.com`, and any proxy download hosts used by a package.

If `/bin`, `/bin/lpm.lua`, or the staging file `/bin/lpm.lua.datapack-new` is occupied by unrelated content, the installer reports an error and preserves it. Other computer startup work continues. Removing the datapack leaves local copies in place; to keep the command on the path after removing the pack, run `/bin/lpm.lua setup` where your startup layout permits it.

## Version targets

`targets.json` lists every supported release and its Mojang release-notes source. Current assets cover Minecraft 1.21 and 1.21.1 through 1.21.11. Version-specific metadata is intentional: 1.21.1 uses format 48, while 1.21.11 uses the newer `min_format`/`max_format` metadata with format 94.1.

Add a new entry with its verified data-pack format to support another release. Building a datapack for a game version does not provide a CC:Tweaked mod build for that version.

Sources: [CC:Tweaked ROM datapacks](https://tweaked.cc/reference/data_pack.html), [computer startup](https://tweaked.cc/reference/startup.html), [Mojang's modern pack metadata](https://www.minecraft.net/en-us/article/minecraft-java-edition-1-21-9).

## Build and publish

```sh
python tools/build.py
python tools/build_datapacks.py
python tools/publish_nightly.py --dry-run
```

Local builds can select versions with `--versions 1.21.1 1.21.11` and change output location with `--output`. ZIPs have stable timestamps and include build provenance. `SHA256SUMS.txt` verifies the published ZIPs, standalone bundle and `build-manifest.json`.

The **Nightly datapacks** GitHub Actions workflow:

- Validates pull requests without publishing.
- Builds and publishes after each push to `main`.
- Supports **Actions → Nightly datapacks → Run workflow**. Select `main` to publish; other refs build/test without replacing the shared release.
- Rebuilds every configured version and publishes all assets to the mutable `nightly` prerelease, updating that tag to the built source commit.
- Uses the built-in `GITHUB_TOKEN` with `contents: write` only in the publish job; no personal access token or extra secret is needed.
- Serializes runs, skips superseded main commits, checks artifact hashes before uploading, and preserves unrelated release assets.

CI exercises the installer in the CC:Tweaked Lua simulation and validates every ZIP/metadata/checksum. It does not launch a real Minecraft server.
