#!/usr/bin/env python3
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

binary = Path(sys.argv[1]).resolve()
real = shutil.which('podman')
assert real
out = Path('artifacts/podman/registry')
out.mkdir(parents=True, exist_ok=True)
checks = []
report_log = Path.home() / '.local/chalk/chalk.log'

MANIFEST_ACCEPT = ', '.join([
    'application/vnd.oci.image.index.v1+json',
    'application/vnd.oci.image.manifest.v1+json',
    'application/vnd.docker.distribution.manifest.list.v2+json',
    'application/vnd.docker.distribution.manifest.v2+json',
])


def check(name, value):
    checks.append({'name': name, 'passed': bool(value)})
    assert value, name


def reports_since(offset):
    if not report_log.exists():
        return []
    data = report_log.read_text()[offset:]
    decoder = json.JSONDecoder()
    reports = []
    while data.strip():
        value, end = decoder.raw_decode(data.lstrip())
        reports.extend(value if isinstance(value, list) else [value])
        data = data.lstrip()[end:]
    return reports


def registry_get(url, username, password):
    basic = base64.b64encode(f'{username}:{password}'.encode()).decode()

    def request(authorization):
        req = urllib.request.Request(url, headers={
            'Accept': MANIFEST_ACCEPT,
            'Authorization': authorization,
        })
        return urllib.request.urlopen(req, timeout=30)

    try:
        return request('Basic ' + basic)
    except urllib.error.HTTPError as error:
        challenge = error.headers.get('WWW-Authenticate', '')
        if error.code != 401 or not challenge.startswith('Bearer '):
            raise
        params = urllib.request.parse_keqv_list(
            urllib.request.parse_http_list(challenge[len('Bearer '):]),
        )
        query = urllib.parse.urlencode({
            key: params[key] for key in ('service', 'scope') if key in params
        })
        token_req = urllib.request.Request(
            params['realm'] + ('?' + query if query else ''),
            headers={'Authorization': 'Basic ' + basic},
        )
        with urllib.request.urlopen(token_req, timeout=30) as response:
            token_doc = json.load(response)
        token = token_doc.get('token') or token_doc['access_token']
        return request('Bearer ' + token)


def read_manifest(registry, repository, reference, username, password):
    quoted_reference = urllib.parse.quote(reference, safe=':')
    url = f'https://{registry}/v2/{repository}/manifests/{quoted_reference}'
    with registry_get(url, username, password) as response:
        body = response.read()
        header_digest = response.headers.get('Docker-Content-Digest')
    body_digest = 'sha256:' + hashlib.sha256(body).hexdigest()
    check('registry digest header matches manifest body',
          header_digest in (None, body_digest))
    return json.loads(body), header_digest or body_digest


try:
    image = json.loads(Path('artifacts/podman/build/wrapped-image.json').read_text())
    mark = json.loads(Path('artifacts/podman/build/wrapped-mark.json').read_text())
    repository = os.environ['CI_REGISTRY_IMAGE'] + '/podman-contract'
    tag = repository + ':' + os.environ['CI_COMMIT_SHA'] + '-' + os.environ['CI_JOB_ID']
    with tempfile.TemporaryDirectory(prefix='chalk-podman-registry-') as temp:
        root = Path(temp)
        wrapper_dir = root / 'wrapped'
        real_dir = root / 'real'
        wrapper_dir.mkdir()
        real_dir.mkdir()
        (wrapper_dir / 'podman').symlink_to(binary)
        calls = root / 'calls.jsonl'
        (real_dir / 'podman').write_text(f'''#!{sys.executable}
import json, os, sys
with open(os.environ['REGISTRY_CALLS'], 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
os.execv(os.environ['REGISTRY_REAL'], [os.environ['REGISTRY_REAL'], *sys.argv[1:]])
''')
        (real_dir / 'podman').chmod(0o755)
        env = dict(os.environ, PATH=str(wrapper_dir) + os.pathsep + str(real_dir),
                   REGISTRY_CALLS=str(calls), REGISTRY_REAL=real)
        check('registry test path has no Docker executable',
              shutil.which('docker', path=env['PATH']) is None)
        expected_calls = []

        def run(args, *, input=None, cwd=None):
            expected_calls.append(args)
            result = subprocess.run([str(wrapper_dir / 'podman'), *args], env=env,
                                    cwd=cwd, input=input, capture_output=True,
                                    text=True, timeout=180)
            check(args[0] + ' exit zero', result.returncode == 0)
            return result.stdout

        run(['login', '--username', os.environ['CI_REGISTRY_USER'], '--password-stdin', os.environ['CI_REGISTRY']],
            input=os.environ['CI_REGISTRY_PASSWORD'])
        unrelated_tag = repository + ':unrelated-' + os.environ['CI_JOB_ID']
        run(['tag', image['Id'], unrelated_tag])
        digest_file = root / 'digest'
        push_args = [
            'push', '--digestfile=' + str(digest_file), image['Id'],
            'docker://' + tag,
        ]
        report_offset = report_log.stat().st_size if report_log.exists() else 0
        run(push_args)
        digest = digest_file.read_text().strip()
        check('registry digest format', len(digest) == 71 and digest.startswith('sha256:') and
              all(c in '0123456789abcdef' for c in digest[7:]))

        calls_after_push = [json.loads(line) for line in calls.read_text().splitlines()]
        push_native_calls = calls_after_push[len(expected_calls) - 1:]
        check('push scans the image ID and forwards the original argv',
              push_native_calls[0] == ['image', 'inspect', image['Id'], '--format', 'json'] and
              push_native_calls[1] == ['create', image['Id']] and
              push_native_calls[2][0] == 'cp' and
              push_native_calls[3][0:2] == ['rm', '--force'] and
              push_native_calls[4] == push_args and
              len(push_native_calls) == 5)
        expected_calls = calls_after_push

        registry = os.environ['CI_REGISTRY']
        repository_path = repository.removeprefix(registry + '/')
        tag_name = tag.rsplit(':', 1)[1]
        manifest, tag_digest = read_manifest(
            registry,
            repository_path,
            tag_name,
            os.environ['CI_REGISTRY_USER'],
            os.environ['CI_REGISTRY_PASSWORD'],
        )
        check('digest file matches independent registry readback',
              digest == tag_digest)
        list_digest = None
        image_digest = tag_digest
        if manifest.get('manifests'):
            list_digest = tag_digest
            architecture = {'x86_64': 'amd64', 'aarch64': 'arm64'}.get(
                platform.machine(), platform.machine(),
            )
            candidates = [item for item in manifest['manifests']
                          if item.get('platform', {}).get('os') == 'linux' and
                          item.get('platform', {}).get('architecture') == architecture]
            check('index contains one native platform image', len(candidates) == 1)
            _, image_digest = read_manifest(
                registry,
                repository_path,
                candidates[0]['digest'],
                os.environ['CI_REGISTRY_USER'],
                os.environ['CI_REGISTRY_PASSWORD'],
            )

        push_reports = [report for report in reports_since(report_offset)
                        if report.get('_OPERATION') == 'push']
        check('push writes one report', len(push_reports) == 1)
        push_report = push_reports[0]
        artifacts = push_report.get('_CHALKS', [])
        check('push report contains one artifact', len(artifacts) == 1)
        artifact = artifacts[0]
        check('push report identifies a Podman image artifact',
              artifact.get('_OP_ARTIFACT_TYPE') == 'Podman Image')
        expected_repo_digests = {
            registry: {repository_path: [image_digest.removeprefix('sha256:')]},
        }
        expected_repo_tags = {
            registry: {
                repository_path: {
                    tag_name: tag_digest.removeprefix('sha256:'),
                },
            },
        }
        check('push report image digest matches registry readback',
              artifact.get('_REPO_DIGESTS') == expected_repo_digests)
        check('push report tag matches registry readback',
              artifact.get('_REPO_TAGS') == expected_repo_tags)
        if list_digest is None:
            check('single-manifest push omits list digests',
                  '_REPO_LIST_DIGESTS' not in artifact)
        else:
            check('indexed push list digest matches registry readback',
                  artifact.get('_REPO_LIST_DIGESTS') == {
                      registry: {
                          repository_path: [list_digest.removeprefix('sha256:')],
                      },
                  })
        check('push report preserves the image and Chalk identities',
              artifact.get('CHALK_ID') == mark['CHALK_ID'] and
              artifact.get('METADATA_ID') == mark['METADATA_ID'] and
              artifact.get('PODMAN_IMAGE_ID', '').removeprefix('sha256:') ==
              image['Id'].removeprefix('sha256:') and
              artifact.get('_CURRENT_HASH', '').removeprefix('sha256:') ==
              image['Id'].removeprefix('sha256:'))
        check('push report preserves the original argv',
              push_report.get('_OP_ARGV', [])[-len(push_args):] == push_args)
        check('push report excludes unrelated local tag',
              unrelated_tag.rsplit(':', 1)[1] not in
              artifact['_REPO_TAGS'][registry][repository_path])

        profile_config = root / 'chalk.c4m'
        profile_config.write_text(
            'report_template insertion_default {\n'
            '  key._REPO_DIGESTS.use = false\n'
            '  key._REPO_LIST_DIGESTS.use = false\n'
            '  key._REPO_TAGS.use = false\n'
            '}\n'
        )
        profile_tag = (
            repository + ':profile-disabled-' + os.environ['CI_JOB_ID']
        )
        profile_push_args = ['push', image['Id'], 'docker://' + profile_tag]
        profile_report_offset = (
            report_log.stat().st_size if report_log.exists() else 0
        )
        run(profile_push_args, cwd=root)
        expected_calls = [
            json.loads(line) for line in calls.read_text().splitlines()
        ]
        profile_tag_name = profile_tag.rsplit(':', 1)[1]
        _, profile_digest = read_manifest(
            registry,
            repository_path,
            profile_tag_name,
            os.environ['CI_REGISTRY_USER'],
            os.environ['CI_REGISTRY_PASSWORD'],
        )
        check('profile-disabled push publishes the requested tag',
              profile_digest.startswith('sha256:'))
        profile_reports = [
            report for report in reports_since(profile_report_offset)
            if report.get('_OPERATION') == 'push'
        ]
        check('profile-disabled push writes one report',
              len(profile_reports) == 1)
        profile_artifacts = profile_reports[0].get('_CHALKS', [])
        check('profile-disabled push report contains one artifact',
              len(profile_artifacts) == 1)
        profile_artifact = profile_artifacts[0]
        check('profile-disabled report identifies a Podman image artifact',
              profile_artifact.get('_OP_ARTIFACT_TYPE') == 'Podman Image')
        check('profile-disabled report omits repository fields',
              all(key not in profile_artifact for key in (
                  '_REPO_DIGESTS', '_REPO_LIST_DIGESTS', '_REPO_TAGS',
              )))

        reference = repository + '@' + digest
        pull_call_start = len(expected_calls)
        run(['pull', reference])
        pull_calls = [json.loads(line) for line in calls.read_text().splitlines()]
        mark_copies = [args for args in pull_calls[pull_call_start:]
                       if args[0] == 'cp']
        check('pull extracts one image mark', len(mark_copies) == 1 and len(mark_copies[0]) == 3)
        container_id, mark_path = mark_copies[0][1].split(':', 1)
        check('pull extracts the Chalk mark', mark_path == '/chalk.json' and
              len(container_id) == 64 and all(c in '0123456789abcdef' for c in container_id))
        expected_calls.extend([
            ['image', 'inspect', reference, '--format', 'json'],
            ['create', reference],
            ['cp', container_id + ':/chalk.json', mark_copies[0][2]],
            ['rm', '--force', container_id],
            ['image', 'inspect', reference, '--format', 'json'],
        ])
        pulled = json.loads(run(['image', 'inspect', reference]))[0]
        check('registry digest integrity', pulled['Digest'] == digest)
        installed_mark = json.loads(run(['run', '--rm', '--entrypoint', '/bin/cat', reference, '/chalk.json']))
        check('registry image retains Chalk ID', installed_mark['CHALK_ID'] == mark['CHALK_ID'])
        actual_calls = [json.loads(line) for line in calls.read_text().splitlines()]
        check('registry commands and pull inspection run in order exactly once', actual_calls == expected_calls)
        (out / 'image.json').write_text(json.dumps({'reference': reference, 'digest': digest,
            'chalk_id': mark['CHALK_ID'], 'image_id': pulled['Id']}, indent=2) + '\n')
finally:
    (out / 'evidence.json').write_text(json.dumps({'schema_version': 1,
        'source_sha': os.environ.get('CI_COMMIT_SHA'), 'checks': checks,
        'passed': sys.exc_info()[0] is None}, indent=2) + '\n')
