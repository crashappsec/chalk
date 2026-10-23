#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


binary = Path(sys.argv[1]).resolve()
binary_sha256 = hashlib.sha256(binary.read_bytes()).hexdigest()
output = Path('artifacts/podman/mark-hashes.json')
output.parent.mkdir(parents=True, exist_ok=True)

FAKE_PODMAN = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import sys

argv = sys.argv[1:]
mark = Path(os.environ['PODMAN_MARK'])
image_id = 'sha256:' + 'a' * 64

if argv == ['info', '--format', 'json']:
    print('{"host":{"os":"linux","arch":"amd64",'
          '"serviceIsRemote":false,"buildahVersion":"1.43.1"}}')
    sys.exit(0)

if argv and argv[0] == 'build':
    context = Path(argv[argv.index('--build-context') + 1].split('=', 1)[1])
    shutil.copyfile(context / 'chalk.json', mark)
    iidfile = Path(argv[argv.index('--iidfile') + 1])
    iidfile.write_text(image_id + '\n')
    sys.exit(0)

if argv and argv[0] == 'pull':
    sys.exit(0)

if argv[:2] == ['image', 'inspect']:
    print(json.dumps([{'Id': image_id, 'RepoTags': []}]))
    sys.exit(0)

if argv and argv[0] == 'create':
    print('mark-hash-container')
    sys.exit(0)

if argv and argv[0] == 'cp':
    shutil.copyfile(mark, argv[2])
    sys.exit(0)

if argv[:2] == ['rm', '--force']:
    sys.exit(0)

sys.stderr.write('unexpected fake Podman invocation: ' + repr(argv) + '\n')
sys.exit(99)
'''

ANCESTOR_HELPER = '''#!/usr/bin/env python3
import subprocess
import sys

result = subprocess.run(sys.argv[3:])
sys.exit(result.returncode)
'''


def json_values(text):
    decoder = json.JSONDecoder()
    values = []
    while text.strip():
        text = text.lstrip()
        value, end = decoder.raw_decode(text)
        values.append(value)
        text = text[end:]
    return values


def validated_metadata(value):
    if isinstance(value, dict):
        result = ([value['_VALIDATED_METADATA']]
                  if '_VALIDATED_METADATA' in value else [])
        for child in value.values():
            result.extend(validated_metadata(child))
        return result
    if isinstance(value, list):
        result = []
        for child in value:
            result.extend(validated_metadata(child))
        return result
    return []


results = []
with tempfile.TemporaryDirectory(prefix='podman-mark-hashes-') as temp:
    root = Path(temp)
    real_dir = root / 'real'
    home = root / 'home'
    context = root / 'context'
    for directory in (real_dir, home, context):
        directory.mkdir()
    real = real_dir / 'podman'
    real.write_text(FAKE_PODMAN)
    real.chmod(0o755)
    ancestor_helper = root / 'ancestor-helper.py'
    ancestor_helper.write_text(ANCESTOR_HELPER)
    (context / 'Containerfile').write_text(
        'FROM scratch\nENTRYPOINT ["/bin/true"]\n'
    )
    secret = 'ci-mark-hash-sentinel'
    ancestor_arg = 'BUILD_ARGS=TOKEN=' + secret
    quoted_ancestor_arg = 'make image TOKEN="' + secret + '"'
    label_fixtures = {
        'original_unsupported_dollar_var': 'desc=pass --env $VAR',
        'literal_same_value': 'note=see --env VISIBLE=value',
        'quoted_same_value': 'note=see --env VISIBLE="value"',
    }

    for template in ('mark_large', 'mark_all'):
        mark_path = root / (template + '.json')
        config = root / (template + '.c4m')
        config.write_text(
            'log_format = "plain"\n'
            'subscribe("report", "json_console_out")\n'
            'subscribe("fail", "json_console_out")\n'
            'custom_report.terminal_chalk_time.enabled = false\n'
            'custom_report.terminal_other_op.enabled = false\n'
            f'outconf.build.mark_template = "{template}"\n'
        )
        env = dict(
            os.environ,
            HOME=str(home),
            PATH=str(real_dir) + os.pathsep + os.environ['PATH'],
            PODMAN_MARK=str(mark_path),
        )
        common = [
            str(binary), f'--config-file={config}', '--use-embedded-config',
            '--skip-custom-reports', '--no-color', '--log-level=none',
            'podman',
        ]
        image = 'localhost/chalk-mark-hash-' + template + ':latest'
        build_args = common + [
            'build', '--file', 'Containerfile', '--tag', image,
            '--build-arg=TOKEN=' + secret, '--env=VISIBLE=value',
        ]
        for label in label_fixtures.values():
            build_args.extend(['--label', label])
        build_args.append('.')
        build = subprocess.run(
            [sys.executable, str(ancestor_helper), ancestor_arg,
             quoted_ancestor_arg] + build_args,
            cwd=context,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert build.returncode == 0, build
        mark_text = mark_path.read_text()
        mark = json.loads(mark_text)
        argv = mark['INJECTOR_ARGV']
        fixture_results = {
            'confidential_build_arg': {
                'input': '--build-arg=TOKEN=' + secret,
                'operand_absent': not any(
                    'TOKEN=' + secret in token for token in argv
                ),
            },
            'confidential_env': {
                'input': '--env=VISIBLE=value',
                'operand_absent': not any(
                    'VISIBLE=value' in token for token in argv
                ),
            },
        }
        for name, label in label_fixtures.items():
            fixture_results[name] = {
                'input': label,
                'operand_absent': (
                    label not in argv and
                    not any('VISIBLE="value"' in token for token in argv)
                ),
            }
        assert all(
            fixture['operand_absent']
            for fixture in fixture_results.values()
        ), (template, fixture_results, argv)
        assert 'METADATA_ID' in mark, mark

        extract = subprocess.run(
            common + ['pull', image],
            cwd=context,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert extract.returncode == 0, extract
        reports = json_values(extract.stdout)
        validations = validated_metadata(reports)
        default_report_sentinel_absent = secret not in build.stdout
        metadata_valid = validations == [True]
        results.append({
            'template': template,
            'metadata_id': mark['METADATA_ID'],
            'metadata_hash': mark.get('METADATA_HASH'),
            'validated_metadata': (
                validations[0] if len(validations) == 1 else None
            ),
            'sentinel_absent': secret not in mark_text,
            'default_report_sentinel_absent': default_report_sentinel_absent,
            'fixtures': fixture_results,
            'passed': (
                secret not in mark_text and
                default_report_sentinel_absent and
                metadata_valid
            ),
        })

binary_unchanged = hashlib.sha256(binary.read_bytes()).hexdigest() == binary_sha256
evidence = {
    'schema_version': 1,
    'source_sha': os.environ.get('CI_COMMIT_SHA'),
    'binary_sha256': binary_sha256,
    'binary_unchanged': binary_unchanged,
    'cases': results,
    'passed': (
        binary_unchanged and
        len(results) == 2 and
        all(case['passed'] for case in results)
    ),
}
output.write_text(json.dumps(evidence, indent=2) + '\n')
assert evidence['passed'], evidence
print('Podman mark hash validation passed')
