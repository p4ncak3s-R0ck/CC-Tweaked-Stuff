from pathlib import Path
import os
from lupa.lua52 import LuaRuntime
root=Path(__file__).resolve().parents[2]
os.chdir(root)
runtime=LuaRuntime(unpack_returned_tuples=True)
runtime.execute("package.path='rfs/src/?.lua;'..package.path")
runtime.execute((root/'rfs/tests/test.lua').read_text())
