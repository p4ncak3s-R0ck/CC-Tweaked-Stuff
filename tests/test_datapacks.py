"""Validate Minecraft metadata, reproducible archives, checksums and release updates."""
from __future__ import annotations
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import urlparse, parse_qs
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
REPO = 'p4ncak3s-R0ck/LPM'
COMMIT = '1' * 40

def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/'tools'/f'{name}.py')
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded

builder = module('build_datapacks')
publisher = module('publish_nightly')

class FakeGitHub:
    def __init__(self):
        self.head=COMMIT; self.tag=None; self.release=None; self.assets=[]; self.calls=[]; self.next_id=10
    def request(self, method, path, body=None, **kwargs):
        self.calls.append((method,path,body))
        parsed=urlparse(path); route=parsed.path; base=f'/repos/{REPO}'
        if method=='GET' and route==base+'/git/ref/heads/main': return {'object':{'sha':self.head}}
        if method=='GET' and route==base+'/git/ref/tags/nightly': return {'object':{'sha':self.tag}} if self.tag else None
        if method=='POST' and route==base+'/git/refs':
            assert body['ref']=='refs/tags/nightly'; self.tag=body['sha']; return {}
        if method=='PATCH' and route==base+'/git/refs/tags/nightly':
            assert body['force'] is True; self.tag=body['sha']; return {}
        if method=='GET' and route==base+'/releases/tags/nightly': return self.release
        if method=='POST' and route==base+'/releases':
            self.release={'id':1,'upload_url':f'https://uploads.github.com{base}/releases/1/assets{{?name,label}}',
                          'html_url':f'https://github.com/{REPO}/releases/tag/nightly',**body}
            return self.release
        if method=='GET' and route==base+'/releases/1/assets':
            page=int(parse_qs(parsed.query)['page'][0]); return self.assets[(page-1)*100:page*100]
        if method=='DELETE' and route.startswith(base+'/releases/assets/'):
            aid=int(route.rsplit('/',1)[1]); self.assets=[a for a in self.assets if a['id']!=aid]; return None
        if method=='POST' and parsed.hostname=='uploads.github.com':
            self.next_id+=1
            asset={'id':self.next_id,'name':parse_qs(parsed.query)['name'][0],'size':len(body),
                   'digest':'sha256:'+hashlib.sha256(body).hexdigest()}
            self.assets.append(asset); return asset
        if method=='PATCH' and route==base+'/releases/1': self.release.update(body); return self.release
        raise AssertionError(f'Unexpected API call: {method} {path}')

class DatapackTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.output=Path(self.temp.name)
        self.summary=patch.dict(os.environ,{'GITHUB_STEP_SUMMARY':''}); self.summary.start()
    def tearDown(self):
        self.summary.stop(); self.temp.cleanup()
    def build(self):
        return builder.build(self.output,['1.21.1','1.21.11'],COMMIT)

    def test_all_target_archives_have_correct_metadata_payload_and_lowercase_resources(self):
        manifest=builder.build(self.output,commit=COMMIT)
        self.assertEqual(12,len(manifest['targets']))
        for target in manifest['targets']:
            with self.subTest(version=target['minecraft']), ZipFile(self.output/target['asset']) as pack:
                self.assertIsNone(pack.testzip())
                self.assertEqual(7,len(pack.namelist()))
                self.assertIn('pack.mcmeta',pack.namelist())
                self.assertTrue(all(p==p.lower() for p in pack.namelist()))
                metadata=json.loads(pack.read('pack.mcmeta'))['pack']; major,minor=target['format']
                if major<82:
                    self.assertEqual(major,metadata['pack_format']); self.assertNotIn('min_format',metadata)
                else:
                    self.assertEqual([major,minor],metadata['min_format']); self.assertEqual([major,minor],metadata['max_format'])
                    self.assertNotIn('supported_formats',metadata); self.assertNotIn('pack_format',metadata)
                self.assertEqual((ROOT/'lpm.lua').read_bytes(),pack.read('data/computercraft/lua/rom/lpm/lpm.lua'))
                self.assertIn('data/computercraft/lua/rom/autorun/lpm.lua',pack.namelist())
                self.assertIn('data/computercraft/lua/rom/modules/main/lpm_bootstrap.lua',pack.namelist())
                self.assertIn('data/computercraft/lua/rom/programs/lpm.lua',pack.namelist())
                provenance=json.loads(pack.read('lpm-build.json')); self.assertEqual(COMMIT,provenance['commit'])
        self.assertEqual([48,0],builder.load_targets()['1.21.1']['format'])
        self.assertEqual([94,1],builder.load_targets()['1.21.11']['format'])

    def test_builds_are_reproducible_and_checksums_detect_tampering(self):
        self.build(); first={p.name:p.read_bytes() for p in self.output.iterdir()}
        self.build(); self.assertEqual(first,{p.name:p.read_bytes() for p in self.output.iterdir()})
        publisher.validate_outputs(self.output,REPO,COMMIT)
        (self.output/'lpm.lua').write_text('tampered')
        with self.assertRaisesRegex(ValueError,'checksum mismatch'): publisher.validate_outputs(self.output,REPO,COMMIT)

    def test_unknown_versions_and_invalid_source_commits_fail(self):
        for versions,commit in [(['1.21.99'],COMMIT),(['1.21.1','1.21.1'],COMMIT),(['1.21.1'],'main')]:
            with self.subTest(versions=versions,commit=commit), self.assertRaises(ValueError):
                builder.build(self.output,versions,commit)

    def test_publish_creates_then_updates_nightly_and_preserves_unrelated_assets(self):
        self.build(); api=FakeGitHub()
        publisher.publish(api,self.output,REPO,COMMIT)
        self.assertEqual(COMMIT,api.tag); self.assertFalse(api.release['draft']); self.assertTrue(api.release['prerelease'])
        self.assertEqual(5,len(api.assets)); first_ids={a['id'] for a in api.assets}
        # Exercise pagination and preserve every unmanaged asset.
        api.assets += [{'id':1000+i,'name':f'unrelated-{i}.txt','size':1} for i in range(101)]
        api.tag='0'*40
        publisher.publish(api,self.output,REPO,COMMIT)
        self.assertEqual(COMMIT,api.tag); self.assertEqual(106,len(api.assets))
        self.assertTrue(first_ids.isdisjoint({a['id'] for a in api.assets}))
        managed=[a['name'] for a in api.assets if a['id']<1000]
        self.assertEqual(len(managed),len(set(managed)))

    def test_superseded_commits_do_not_mutate_the_release(self):
        self.build(); api=FakeGitHub(); api.head='2'*40
        self.assertIsNone(publisher.publish(api,self.output,REPO,COMMIT))
        self.assertTrue(all(method=='GET' for method,_,_ in api.calls)); self.assertIsNone(api.release)

    def test_wrong_repository_or_corrupt_assets_fail_before_any_api_mutation(self):
        self.build(); api=FakeGitHub()
        with self.assertRaises(ValueError): publisher.publish(api,self.output,'someone/else',COMMIT)
        (self.output/'lpm-datapack-mc-1.21.1.zip').write_bytes(b'bad zip')
        with self.assertRaises(ValueError): publisher.publish(api,self.output,REPO,COMMIT)
        self.assertEqual([],api.calls)

if __name__=='__main__': unittest.main()
