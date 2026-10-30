"""Reuse the repository's CC simulator and real RFS/LPM implementations."""
from pathlib import Path
import os
from lupa.lua52 import LuaRuntime
root = Path(__file__).resolve().parents[2]
os.chdir(root)
runtime = LuaRuntime(unpack_returned_tuples=True)
runtime.execute("package.path='updater/src/?.lua;rfs/src/?.lua;'..package.path")
runtime.execute((root/'rfs/tests/test.lua').read_text() + '\n' + (root/'updater/tests/test.lua').read_text())
