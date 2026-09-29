from pathlib import Path
from lupa.lua52 import LuaRuntime
root = Path(__file__).resolve().parents[1]
runtime = LuaRuntime(unpack_returned_tuples=True)
runtime.globals().EDITOR_SOURCE = (root / 'main.lua').read_text()
dns = root.parent / 'dns/src/dns.lua'
if not dns.exists():
    dns = root.parent / 'lpm/github-ready/dns/src/dns.lua'
runtime.globals().DNS_SOURCE = dns.read_text()
runtime.execute((root / 'tests/test.lua').read_text())
