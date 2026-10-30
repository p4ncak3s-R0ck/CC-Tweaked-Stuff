"""Install the published registry through real public GitHub HTTP requests in the CC simulator."""
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError
import argparse
import json
import os
from lupa.lua52 import LuaRuntime

parser = argparse.ArgumentParser()
parser.add_argument('--self-ref', help='Also test self-update from this LPM branch/tag/commit')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
runtime = LuaRuntime(unpack_returned_tuples=True)
requests = []

def fetch(url):
    requests.append(url)
    print('HTTP', url, flush=True)
    try:
        with urlopen(Request(url, headers={'User-Agent': 'LPM-live-repository-check'}), timeout=30) as response:
            body = response.read(1048577).decode('utf-8')
            if url.startswith('https://api.github.com/'):
                body = json.dumps(json.loads(body), separators=(',', ':'))
            return body, response.status, None
    except HTTPError as error:
        return None, error.code, str(error)
    except Exception as error:
        return None, 0, str(error)

runtime.globals().LIVE_FETCH = fetch
runtime.globals().LIVE_COUNT = lambda: len(requests)
runtime.globals().LIVE_SELF_REF = args.self_ref
runtime.globals().LIVE_BUNDLE = (root/'lpm.lua').read_text()
harness = (root/'tests/test.lua').read_text().split('local tests=0',1)[0]
runtime.execute(harness + '''
http.get=function(o)
    local bytes,status,problem=LIVE_FETCH(o.url)
    if not bytes then return nil,problem,{getResponseCode=function() return status end,close=function() end} end
    local pos=1
    return {read=function(n) if pos>#bytes then return nil end; local part=bytes:sub(pos,pos+n-1); pos=pos+#part; return part end,close=function() end}
end
core.log.configure({level='info'})
fs.makeDir('project'); core.init('project')
local p=data.parse(files['project/package.lua'])
p.dependencies={dns='*',['dns-server']='*',['dns-records']='*',rfs='*',['rfs-client']='*',['rfs-server']='*',update='*',updater='*',hello='*',lpm='*'}
files['project/package.lua']=data.serialize(p)
local locked=core.install('project')
local packages=0
for n,x in pairs(locked.packages) do
    packages=packages+1
    assert(x.repository.github=='p4ncak3s-R0ck/LPM-Packages','Unexpected package source: '..n)
    if n~='lpm' then
        for src in pairs(x.manifest.files) do assert(not src:match('^https://'),'Package implementation still proxies to another repository: '..n) end
    end
end
assert(packages==10,'Expected all 10 official packages')
local verified=core.verify('project')
assert(verified>=10)
local before=LIVE_COUNT()
core.install('project',nil,false,false,true)
assert(LIVE_COUNT()==before,'Offline reinstall used the network')
normalRun('project',{},'hello')
files['project/main.lua']='return type(require("dns").new), type(require("rfs").connect), type(require("updater").new)'
local a,b,c=normalRun('project',{})
assert(a=='function' and b=='function' and c=='function','Library exports failed')
local target='project/.lpm/current/packages/dns/dns.lua'
files[target]='corrupt'
assert(not pcall(core.install,'project',nil,false,false,true),'Corrupt offline file was accepted')
core.install('project'); assert(core.verify('project')==verified)
if LIVE_SELF_REF then
    files['lpm.lua']=LIVE_BUNDLE
    shell.getRunningProgram=function() return 'lpm.lua' end
    local changed,version,pin=core.selfUpdate(LIVE_SELF_REF)
    assert(not changed and version==core.version,'Published branch bundle differs from the tested local build')
end
print('PASS live registry: '..packages..' packages, '..verified..' verified files, offline restore, corruption recovery, standalone execution and library imports')
''')
print('Completed with', len(requests), 'real HTTP requests')
