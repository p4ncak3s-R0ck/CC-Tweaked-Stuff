from pathlib import Path
import os
import sys
from lupa.lua52 import LuaRuntime
root = Path(__file__).resolve().parents[1]
os.chdir(root)
runtime = LuaRuntime(unpack_returned_tuples=True)
if len(sys.argv) > 1:
    # Cobalt accepts the upstream replacement "%%%."; stock Lua 5.2 does not.
    # Use the equivalent standard Lua spelling for this one pattern escape.
    source = Path(sys.argv[1]).read_text().replace('sep:gsub("%.", "%%%.")', 'sep:gsub("%.", "%%.")')
    runtime.globals().realRequireSource = source
runtime.execute((root / 'tests/test.lua').read_text())
