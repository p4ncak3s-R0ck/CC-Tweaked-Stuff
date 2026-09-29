# DNS record editor

An independently packaged application using the public DNS library API. It builds on the existing DNS example editor and adds package installation, an interactive server prompt, and record search. The DNS library is a declared dependency and is installed automatically.

## Install

Run these from your project directory after setting up `lpm`:

```text
lpm repo p4ncak3s-R0ck/CC-Tweaked-Stuff dns-record-editor
lpm install dns-records
dns-records --server 42 --username joshua
```

Until the editor PR is merged, use the branch shown above. After merging, select `main`. You can also launch `dns-records` without arguments and enter the server ID and admin username interactively. Passwords are entered with a masked prompt and are never stored in the project configuration. Use `dns-records --help` for modem, timeout, and retry options.

## Editing

- **List** loads all records through revision-consistent pagination.
- **Find** filters records by name, type, or value using a literal, case-insensitive search.
- **Edit/add set** selects a record type and name. Add, edit, or remove individual entries, then explicitly confirm saving. Cancelling leaves the server unchanged.
- Supported records: ID, CNAME, PTR, TXT, and SRV. TXT can contain an empty value. SRV includes target, Rednet protocol, priority, and weight.
- Saving removes a set when its last entry is deleted. The editor asks for a deletion confirmation.
- Existing entries in the selected name/type set are preserved unless you change them. Other sets are not overwritten.
- The loaded database revision is sent with each save. A concurrent edit returns CONFLICT; reopen the set before retrying.
- A timeout may mean a save succeeded. Reauthenticate and inspect the records before repeating it.
- Reader accounts are rejected. Authorization is enforced again by the DNS server on every operation. The editor uses authenticated replies and never enables public/unsigned lookup mode.
- Logout is attempted on exit, errors, and Ctrl+T. Modems remain open for other programs.

The server must be running, reachable through Rednet, and support the current v2 admin API. Credentials belong to the DNS service; lpm only downloads the application.

## Develop from source

The included `package.lua` describes the application's DNS dependency. From the source folder run `lpm install`, then launch `main.lua` normally. For branch testing, set the repository ref before installing. The remote `manifest.lua` installs a directly runnable `dns-records.lua` in the consuming project.

## Validation

Run `python3 tests/run.py` and `python3 tests/install.py` with `lupa` installed, from this folder in a checkout of the repository. Tests use Lua 5.2, scripted terminal input, and a simulated public DNS API. They cover all five record types, edits and deletion, cancellation, filtering, reader rejection, revision conflicts, pagination changes, uncertain saves, option parsing, and logout. The installation test also loads the package through lpm's resolver and normal CC module loading. Actual Minecraft testing is still needed.
