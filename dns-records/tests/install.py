"""Exercise actual package manifests through the LPM simulated CC environment."""
from pathlib import Path
import os
from lupa.lua52 import LuaRuntime
root = Path(__file__).resolve().parents[1]
lpm = root.parent / 'lpm'
os.chdir(lpm)
runtime = LuaRuntime(unpack_returned_tuples=True)
dns_manifest = root.parent / 'dns/manifest.lua'
dns_source = root.parent / 'dns/src/dns.lua'
if not dns_manifest.exists():
    dns_manifest = lpm / 'github-ready/dns/manifest.lua'
if not dns_source.exists():
    dns_source = lpm / 'github-ready/dns/src/dns.lua'
for key, file in {
    'EDITOR_MANIFEST': root / 'manifest.lua',
    'EDITOR_SOURCE': root / 'main.lua',
    'EDITOR_PROJECT': root / 'package.lua',
    'DNS_MANIFEST': dns_manifest,
    'DNS_SOURCE': dns_source,
}.items():
    runtime.globals()[key] = file.read_text()
runtime.execute((lpm / 'tests/test.lua').read_text() + '''
check('Editor package installs DNS dependency and launches normally',function()
    setup({['dns-records']='*'})
    responses[raw(tip,'dns-records/manifest.lua')]=EDITOR_MANIFEST
    responses[raw(tip,'dns-records/main.lua')]=EDITOR_SOURCE
    responses[raw(tip,'dns/manifest.lua')]=DNS_MANIFEST
    responses[raw(tip,'dns/src/dns.lua')]=DNS_SOURCE
    local installed=core.install('project')
    assert(installed.packages.dns.version=='2.0.0')
    assert(fs.exists('project/dns.lua') and fs.exists('project/dns-records.lua'))
    assert(not fs.exists('project/main.lua') or files['project/main.lua']:find('local a=',1,true))
    assert(core.verify('project')==2)
    local help
    textutils.pagedPrint=function(s) help=s end
    normalRun('project',{'--help'},'dns-records')
    assert(help and help:find('DNS record editor',1,true))
    files['project/main.lua']='return type(require("dns").new)'
    assert(normalRun('project',{})=='function')
    assert(data.parse(EDITOR_PROJECT).dependencies.dns=='^2.0.0')
end)
''')
