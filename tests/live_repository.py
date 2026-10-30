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
parser.add_argument('--layout-only', action='store_true', help='Test root self-update without reinstalling unrelated packages')
parser.add_argument('--upgrade-from-file', type=Path, help='Also upgrade this pre-root-layout bundle through the compatibility bridge')
parser.add_argument('--bridge-ref', default='52244b55d4961c8641da80392c20771f5e82b3cb')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
runtime = LuaRuntime(unpack_returned_tuples=True)
requests = []

def fetch(url, accept=None):
    requests.append(url)
    print('HTTP', url, flush=True)
    try:
        headers={'User-Agent': 'LPM-live-repository-check'}
        if accept: headers['Accept']=accept
        with urlopen(Request(url, headers=headers), timeout=30) as response:
            body = response.read(1048577).decode('utf-8')
            if url.startswith('https://api.github.com/') and body.lstrip().startswith('{'):
                body = json.dumps(json.loads(body), separators=(',', ':'))
            return body, response.status, None
    except HTTPError as error:
        return None, error.code, str(error)
    except Exception as error:
        return None, 0, str(error)

runtime.globals().LIVE_FETCH = fetch
runtime.globals().LIVE_COUNT = lambda: len(requests)
runtime.globals().LIVE_SELF_REF = args.self_ref
runtime.globals().LIVE_LAYOUT_ONLY = args.layout_only
runtime.globals().LIVE_LEGACY_BUNDLE = args.upgrade_from_file.read_text() if args.upgrade_from_file else None
runtime.globals().LIVE_BRIDGE_REF = args.bridge_ref
runtime.globals().LIVE_BUNDLE = (root/'lpm.lua').read_text()
harness = (root/'tests/test.lua').read_text().split('local tests=0',1)[0]
runtime.execute(harness + '''
http.get=function(o)
    local bytes,status,problem=LIVE_FETCH(o.url,o.headers and o.headers.Accept)
    if not bytes then return nil,problem,{getResponseCode=function() return status end,close=function() end} end
    local pos=1
    return {read=function(n) if pos>#bytes then return nil end; local part=bytes:sub(pos,pos+n-1); pos=pos+#part; return part end,close=function() end}
end
core.log.configure({level='info'})
if LIVE_LAYOUT_ONLY then
    files['lpm.lua']=LIVE_LEGACY_BUNDLE or LIVE_BUNDLE
    if LIVE_LEGACY_BUNDLE then
        local old=assert(load(LIVE_LEGACY_BUNDLE,'@pre-root-layout','t',_ENV))('__lpm_test')
        old.log.configure({level='info'})
        assert(old.selfUpdate(LIVE_BRIDGE_REF),'Old installed copy did not upgrade through the bridge')
        assert(files['lpm.lua']==LIVE_BUNDLE,'Bridge bundle differs from the root build')
        assert(files['lpm.lua.lpm-backup']==LIVE_LEGACY_BUNDLE,'Old bundle backup missing')
    end
    local changed,version=core.selfUpdate(LIVE_SELF_REF or 'main')
    assert(not changed and version==core.version,'Root self-update differs from the tested bundle')
    print('PASS layout: existing client upgrade and repository-root self-update')
else
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
end
''')
print('Completed with', len(requests), 'real HTTP requests')
