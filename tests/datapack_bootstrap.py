"""Exercise the ROM installer and launcher using LPM's CC:Tweaked simulator."""
from pathlib import Path
import os
from lupa.lua52 import LuaRuntime
root = Path(__file__).resolve().parents[1]
os.chdir(root)
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().DATAPACK_BUNDLE = (root/'lpm.lua').read_text()
harness = (root/'tests/test.lua').read_text().split('local tests=0', 1)[0]
lua.execute(harness + (root/'tests/datapack_bootstrap.lua').read_text())
