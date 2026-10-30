"""Publish verified build outputs to the mutable nightly prerelease using GITHUB_TOKEN."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
from urllib.error import HTTPError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen

class GitHub:
    def __init__(self, token):
        if not token:
            raise ValueError('GITHUB_TOKEN is required for publishing')
        self.token = token

    def request(self, method, path, body=None, *, optional=False, content_type='application/json'):
        url = path if path.startswith('https://') else 'https://api.github.com' + path
        if urlparse(url).hostname not in {'api.github.com', 'uploads.github.com'}:
            raise ValueError('Unexpected GitHub API upload host')
        payload = body if isinstance(body, bytes) else json.dumps(body).encode() if body is not None else None
        headers = {'Authorization': 'Bearer ' + self.token, 'Accept': 'application/vnd.github+json',
                   'User-Agent': 'LPM-nightly-publisher', 'X-GitHub-Api-Version': '2022-11-28'}
        if payload is not None:
            headers['Content-Type'] = content_type
        try:
            with urlopen(Request(url, data=payload, headers=headers, method=method), timeout=120) as response:
                data = response.read()
                return json.loads(data) if data else None
        except HTTPError as error:
            if optional and error.code == 404:
                return None
            detail = error.read(1000).decode('utf-8', 'replace')
            raise RuntimeError(f'GitHub {method} {urlparse(url).path}: HTTP {error.code}: {detail}') from None

def validate_outputs(directory, repository, commit):
    directory = Path(directory)
    manifest = json.loads((directory / 'build-manifest.json').read_text())
    if manifest['repository'] != repository or manifest['commit'] != commit:
        raise ValueError('Artifacts do not match the publishing repository/commit')
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Expected a full source commit')
    names = [entry['asset'] for entry in manifest['targets']] + ['lpm.lua', 'build-manifest.json']
    if len(names) != len(set(names)) or any(Path(n).name != n for n in names):
        raise ValueError('Invalid or duplicate release filenames')
    if any(not re.fullmatch(r'lpm-datapack-mc-\d+\.\d+(?:\.\d+)?\.zip', n) for n in names[:-2]):
        raise ValueError('Invalid datapack asset name')
    hashes = {}
    for line in (directory / 'SHA256SUMS.txt').read_text().splitlines():
        digest, name = line.split('  ', 1)
        if name in hashes or not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise ValueError('Invalid checksum listing')
        hashes[name] = digest
    if set(hashes) != set(names):
        raise ValueError('Checksum listing does not match the build manifest')
    for name in names:
        if hashlib.sha256((directory / name).read_bytes()).hexdigest() != hashes[name]:
            raise ValueError(f'Artifact checksum mismatch: {name}')
    return manifest, names + ['SHA256SUMS.txt']

def publish(api, directory, repository, commit):
    directory = Path(directory)
    manifest, names = validate_outputs(directory, repository, commit)
    base = f'/repos/{repository}'
    main = api.request('GET', base + '/git/ref/heads/main')
    if main['object']['sha'] != commit:
        print('Skipping superseded commit; nightly is only published from the current main head')
        return None
    release = api.request('GET', base + '/releases/tags/nightly', optional=True)
    if release is None:
        ref = api.request('GET', base + '/git/ref/tags/nightly', optional=True)
        if ref is None:
            api.request('POST', base + '/git/refs', {'ref': 'refs/tags/nightly', 'sha': commit})
        release = api.request('POST', base + '/releases', {'tag_name': 'nightly', 'target_commitish': commit,
            'name': 'LPM Nightly', 'prerelease': True, 'draft': True, 'make_latest': 'false'})
    rid = release['id']
    existing = []
    for page in range(1, 51):
        chunk = api.request('GET', base + f'/releases/{rid}/assets?per_page=100&page={page}')
        existing.extend(chunk)
        if len(chunk) < 100:
            break
    else:
        raise RuntimeError('Too many release assets')
    owned = lambda name: name.startswith('lpm-datapack-mc-') or name in {'lpm.lua', 'build-manifest.json', 'SHA256SUMS.txt'}
    for asset in existing:
        if owned(asset['name']):
            api.request('DELETE', base + f'/releases/assets/{asset["id"]}')
    upload_base = release['upload_url'].split('{', 1)[0]
    for name in names:
        data = (directory / name).read_bytes()
        kind = 'application/zip' if name.endswith('.zip') else 'application/json' if name.endswith('.json') else 'text/plain'
        result = api.request('POST', upload_base + '?name=' + quote(name, safe=''), data, content_type=kind)
        if result['size'] != len(data):
            raise RuntimeError(f'Uploaded asset size mismatch: {name}')
        digest = result.get('digest')
        if digest and digest != 'sha256:' + hashlib.sha256(data).hexdigest():
            raise RuntimeError(f'Uploaded asset digest mismatch: {name}')
        print('Uploaded', name)
    ref = api.request('GET', base + '/git/ref/tags/nightly', optional=True)
    if ref is None:
        api.request('POST', base + '/git/refs', {'ref': 'refs/tags/nightly', 'sha': commit})
    elif ref['object']['sha'] != commit:
        api.request('PATCH', base + '/git/refs/tags/nightly', {'sha': commit, 'force': True})
    notes = (directory / 'RELEASE_NOTES.md').read_text()
    release = api.request('PATCH', base + f'/releases/{rid}', {'name': 'LPM Nightly', 'body': notes,
        'tag_name': 'nightly', 'prerelease': True, 'draft': False, 'make_latest': 'false'})
    print('Published', release['html_url'])
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as stream:
            stream.write(f'## LPM nightly\n\n[Download datapacks]({release["html_url"]})\n\nCommit: `{commit}`\n\n')
            for entry in manifest['targets']:
                stream.write(f'- Minecraft {entry["minecraft"]}: `{entry["asset"]}`\n')
    return release

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=Path('dist'))
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    repository = os.environ.get('GITHUB_REPOSITORY', 'p4ncak3s-R0ck/LPM')
    manifest = json.loads((args.directory / 'build-manifest.json').read_text())
    commit = os.environ.get('GITHUB_SHA', manifest['commit'])
    if args.dry_run:
        _, assets = validate_outputs(args.directory, repository, commit)
        print('Validated release assets:', ', '.join(assets))
    else:
        publish(GitHub(os.environ.get('GITHUB_TOKEN')), args.directory, repository, commit)
