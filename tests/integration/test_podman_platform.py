#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from podman_platform_proof import proves_arm_emulation

binary = Path(sys.argv[1]).resolve()
podman = shutil.which('podman')
assert podman
out = Path('artifacts/podman/platform').resolve()
out.mkdir(parents=True, exist_ok=True)
checks = []
observations = []
images = []
proof = None
suffix = str(os.getpid())
amd64_alpine = (
    'docker.io/library/alpine@sha256:'
    'eafc1edb577d2e9b458664a15f23ea1c370214193226069eb22921169fc7e43f'
)
arm64_alpine = (
    'docker.io/library/alpine@sha256:'
    '4562b419adf48c5f3c763995d6014c123b3ce1d2e0ef2613b189779caa787192'
)
alpine_index = 'docker.io/library/alpine:3.22.1'
alpine_index_digest = (
    'docker.io/library/alpine@sha256:'
    '4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1'
)
arm64_alpine_config = (
    '02f8efbefad605a169e89926147edd0676646263268f303c6fb3cdfdbc4a9612'
)
amd64_alpine_config = (
    '9234e8fb04c47cfe0f49931e4ac7eb76fa904e33b7f8576aec0501c085f02516'
)
em_x86_64 = 62
em_aarch64 = 183


def invoke(argv, *, cwd=None, env=None, require_success=True):
    started = time.monotonic()
    result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True,
                            text=True, timeout=240)
    elapsed = time.monotonic() - started
    with (out / 'commands.jsonl').open('a') as log:
        log.write(json.dumps({'argv': argv, 'exit': result.returncode,
                              'stdout': result.stdout, 'stderr': result.stderr,
                              'elapsed_seconds': elapsed}) + '\n')
    if require_success:
        assert result.returncode == 0, (argv, result.returncode, result.stderr)
    return result, elapsed


def check(name, condition):
    checks.append({'name': name, 'passed': bool(condition)})
    assert condition, name


def inspect(tag):
    result, _ = invoke([podman, 'image', 'inspect', tag])
    return json.loads(result.stdout)[0]


def tag(name):
    value = 'localhost/chalk-platform-' + name + ':' + suffix
    images.append(value)
    return value


def copy_file(image, path):
    created, _ = invoke([podman, 'create', image])
    cid = created.stdout.strip()
    dest = Path(tempfile.mkdtemp(prefix='chalk-platform-copy-')) / 'copied'
    try:
        result, _ = invoke([podman, 'cp', cid + ':' + path, str(dest)],
                           require_success=False)
        if result.returncode != 0:
            return None
        return dest.read_bytes()
    finally:
        subprocess.run([podman, 'rm', '-f', cid], capture_output=True)
        shutil.rmtree(dest.parent, ignore_errors=True)


def copy_exists(image, path):
    return copy_file(image, path) is not None


def elf_identity(image, path='/bin/busybox'):
    data = copy_file(image, path)
    assert data is not None and len(data) >= 20
    assert data[:4] == b'\x7fELF'
    assert data[5] in {1, 2}
    byteorder = 'little' if data[5] == 1 else 'big'
    return {
        'path': path,
        'sha256': hashlib.sha256(data).hexdigest(),
        'elf_class': data[4],
        'elf_data': data[5],
        'e_machine': int.from_bytes(data[18:20], byteorder),
    }


def prove_arm_execution():
    handlers = []
    handler_error = None
    binfmt = Path('/proc/sys/fs/binfmt_misc')
    try:
        if binfmt.is_dir():
            handlers = sorted(p.name for p in binfmt.iterdir()
                              if p.name not in {'register', 'status'})
    except OSError as error:
        handler_error = str(error)
    builder, _ = invoke(
        [podman, 'info', '--format', 'json'], require_success=False)
    builder_data = {}
    builder_error = None
    try:
        builder_data = json.loads(builder.stdout)
    except json.JSONDecodeError as error:
        builder_error = str(error)
    host = builder_data.get('host', {}) if isinstance(builder_data, dict) else {}
    if not isinstance(host, dict):
        host = {}
    builder_os = host.get('os')
    builder_architecture = host.get('arch')
    builder_remote = host.get('serviceIsRemote')
    native, _ = invoke(
        [podman, 'run', '--rm', '--network=none', '--platform', 'linux/arm64',
         '--entrypoint', '/bin/uname', arm64_alpine, '-m'],
        require_success=False,
    )
    handler_observed = any('aarch64' in name or 'arm64' in name or
                           name.startswith('qemu-aarch64') for name in handlers)
    proven = proves_arm_emulation(
        builder.returncode, builder_os, builder_architecture, builder_remote,
        native.returncode, native.stdout.strip())
    return {
        'proven': proven,
        'builder_info_status': builder.returncode,
        'builder_os': builder_os,
        'builder_architecture': builder_architecture,
        'builder_remote': builder_remote,
        'builder_info_error': builder_error,
        'builder_info_stderr': builder.stderr,
        'arm_image': arm64_alpine,
        'binfmt_diagnostics': {
            'path': str(binfmt),
            'handlers': handlers,
            'handler_observed': handler_observed,
            'error': handler_error,
        },
        'uname': native.stdout.strip(),
        'uname_status': native.returncode,
        'uname_stderr': native.stderr,
    }


def startup_containerfile(prefix, extra=''):
    return (prefix + 'COPY start.sh /start.sh\n'
            'ENTRYPOINT ["/bin/sh", "/start.sh"]\n'
            'CMD ["default"]\n' + extra)


def containerfile(base, extra=''):
    return startup_containerfile(f'FROM {base}\n', extra)


try:
    proof = prove_arm_execution()
    (out / 'emulation.json').write_text(json.dumps(proof, indent=2) + '\n')
    check('amd64 Podman host executed pinned ARM command', proof['proven'])

    with tempfile.TemporaryDirectory(prefix='chalk-platform-') as temp:
        root = Path(temp)
        wrapped = root / 'wrapped'
        proxy_dir = root / 'proxy'
        wrapped.mkdir()
        proxy_dir.mkdir()
        (wrapped / 'podman').symlink_to(binary)
        calls = root / 'calls.jsonl'
        proxy = proxy_dir / 'podman'
        proxy.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['PODMAN_PLATFORM_CALLS'], 'a') as output:
    output.write(json.dumps(args) + '\\n')
capture = os.environ.get('PODMAN_PLATFORM_DERIVED')
if capture and args[:1] == ['build'] and '--build-context' in args:
    file_index = args.index('--file')
    source = pathlib.Path(args[file_index + 1])
    pathlib.Path(capture).write_bytes(source.read_bytes())
if (len(args) > 2 and args[:2] == ['image', 'inspect'] and
        args[-2:] == ['--format', 'json'] and
        os.environ.get('PODMAN_PLATFORM_INSPECT_EXIT')):
    sys.exit(int(os.environ['PODMAN_PLATFORM_INSPECT_EXIT']))
os.execv(os.environ['PODMAN_PLATFORM_REAL'],
         [os.environ['PODMAN_PLATFORM_REAL'], *args])
''')
        proxy.chmod(0o755)
        env = dict(os.environ, PATH=str(wrapped) + os.pathsep + str(proxy_dir) +
                   os.pathsep + os.environ['PATH'],
                   PODMAN_PLATFORM_REAL=podman,
                   PODMAN_PLATFORM_CALLS=str(calls))
        context = root / 'context'
        context.mkdir()
        (context / 'start.sh').write_text('printf "application <%s>\\n" "$*"\n')

        local_base = tag('local-arm64-base')
        local_base_marker = 'local-arm64-' + suffix
        local_base_context = root / 'local-base'
        local_base_context.mkdir()
        (local_base_context / 'Containerfile').write_text(
            f'FROM {arm64_alpine}\n'
            f'LABEL io.chalk.platform-cache-marker="{local_base_marker}"\n')
        invoke([podman, 'build', '--platform', 'linux/arm64', '--format', 'oci',
                '-t', local_base, '.'], cwd=local_base_context)
        local_base_info = inspect(local_base)
        local_base_id = local_base_info.get('Id')
        local_base_labels = (local_base_info.get('Labels') or
                             (local_base_info.get('Config') or {}).get('Labels') or {})
        check('marked local base architecture',
              local_base_info.get('Architecture') == 'arm64')
        check('marked local base label',
              local_base_labels.get('io.chalk.platform-cache-marker') ==
              local_base_marker)

        def prepare_cache(case):
            reference = case.get('cache_reference', alpine_index)
            if case.get('prime_amd64_index'):
                invoke([podman, 'pull', '--quiet', '--platform', 'linux/amd64',
                        reference])
            if case.get('prime_arm64_index'):
                invoke([podman, 'pull', '--quiet', '--platform', 'linux/arm64',
                        reference])
            if case.get('restore_local_base'):
                invoke([podman, 'tag', local_base_id, local_base])
            reference = case.get('cache_reference')
            return None if reference is None else inspect(reference)

        def verify_image_content(name, native_image, wrapped_image, machine,
                                 path='/bin/busybox'):
            native_content = elf_identity(native_image, path)
            wrapped_content = elf_identity(wrapped_image, path)
            check(name + ' native content architecture',
                  native_content['e_machine'] == machine)
            check(name + ' wrapped content architecture',
                  wrapped_content['e_machine'] == machine)
            check(name + ' content preserved',
                  wrapped_content['sha256'] == native_content['sha256'])
            return native_content, wrapped_content

        def verify_runtime_parity(
                name, native_image, wrapped_image,
                expected_default='application <default>\n',
                expected_override='application <one two>\n'):
            original, _ = invoke(
                [podman, 'run', '--rm', '--network=none', native_image],
                require_success=False)
            instrumented, _ = invoke(
                [podman, 'run', '--rm', '--network=none', wrapped_image],
                require_success=False)
            check(name + ' default startup parity',
                  (instrumented.returncode, instrumented.stdout) ==
                  (original.returncode, original.stdout))
            check(name + ' native default startup status',
                  original.returncode == 0)
            check(name + ' native default application output',
                  original.stdout == expected_default)
            override_orig, _ = invoke(
                [podman, 'run', '--rm', '--network=none', native_image,
                 'one', 'two'], require_success=False)
            override_wrap, _ = invoke(
                [podman, 'run', '--rm', '--network=none', wrapped_image,
                 'one', 'two'], require_success=False)
            check(name + ' argument parity',
                  (override_wrap.returncode, override_wrap.stdout) ==
                  (override_orig.returncode, override_orig.stdout))
            check(name + ' native argument status',
                  override_orig.returncode == 0)
            check(name + ' native argument output',
                  override_orig.stdout == expected_override)
            return {
                'native_default_status': original.returncode,
                'native_default_stdout': original.stdout,
                'wrapped_default_status': instrumented.returncode,
                'wrapped_default_stdout': instrumented.stdout,
                'native_override_status': override_orig.returncode,
                'native_override_stdout': override_orig.stdout,
                'wrapped_override_status': override_wrap.returncode,
                'wrapped_override_stdout': override_wrap.stdout,
            }

        cases = [
            {
                'name': 'amd64-digest',
                'contents': containerfile(amd64_alpine),
                'argv': ['build', '-t', None, '.'],
                'instrument': True,
                'content_machine': em_x86_64,
            },
            {
                'name': 'amd64-cli-platform',
                'contents': containerfile(amd64_alpine),
                'argv': ['build', '--platform', 'linux/amd64', '-t', None, '.'],
                'instrument': True,
                'inspect_base': True,
                'expected_lookup': amd64_alpine,
                'expected_root_config_id': amd64_alpine_config,
                'no_chalk_pull': True,
                'content_machine': em_x86_64,
            },
            {
                'name': 'from-platform-amd64',
                'contents': containerfile(
                    f'--platform=linux/amd64 {amd64_alpine}'),
                'argv': ['build', '-t', None, '.'],
                'instrument': True,
                'inspect_base': True,
                'expected_lookup': amd64_alpine,
                'expected_root_config_id': amd64_alpine_config,
                'no_chalk_pull': True,
                'content_machine': em_x86_64,
            },
            {
                'name': 'final-amd64-after-arm-stage',
                'contents': (
                    f'FROM --platform=linux/arm64 {arm64_alpine} AS builder\n' +
                    containerfile(amd64_alpine)
                ),
                'argv': ['build', '-t', None, '.'],
                'instrument': True,
                'inspect_base': True,
                'expected_lookup': amd64_alpine,
                'expected_root_config_id': amd64_alpine_config,
                'no_chalk_pull': True,
                'content_machine': em_x86_64,
            },
            {
                'name': 'same-tag-unused-arm-stage',
                'contents': (
                    f'FROM --platform=linux/arm64 {alpine_index} AS cross\n'
                    'RUN ["/bin/busybox", "true"]\n' +
                    containerfile(alpine_index)
                ),
                'argv': ['build', '-t', None, '.'],
                'instrument': True,
                'inspect_base': True,
                'prime_amd64_index': True,
                'cache_reference': alpine_index,
                'expected_lookup': alpine_index,
                'expected_root_config_id': amd64_alpine_config,
                'no_chalk_pull': True,
                'native_cache_after_architecture': 'amd64',
                'content_machine': em_x86_64,
            },
            {
                'name': 'same-tag-used-arm-stage',
                'contents': (
                    f'FROM --platform=linux/arm64 {alpine_index} AS cross\n'
                    'RUN ["/bin/busybox", "true"]\n'
                    f'FROM {alpine_index}\n'
                    'COPY --from=cross /etc/alpine-release '
                    '/cross-alpine-release\n'
                    'COPY start.sh /start.sh\n'
                    'ENTRYPOINT ["/bin/sh", "/start.sh"]\n'
                    'CMD ["default"]\n'
                ),
                'argv': ['build', '-t', None, '.'],
                'instrument': True,
                'inspect_base': True,
                'prime_amd64_index': True,
                'cache_reference': alpine_index,
                'expected_lookup': alpine_index,
                'expected_root_config_id': amd64_alpine_config,
                'no_chalk_pull': True,
                'native_cache_after_architecture': 'amd64',
                'content_machine': em_x86_64,
            },
            {
                'name': 'from-platform-arm64',
                'contents': containerfile(f'--platform=linux/arm64 {arm64_alpine}'),
                'argv': ['build', '-t', None, '.'],
                'instrument': False,
                'inspect_base': False,
                'content_machine': em_aarch64,
            },
            {
                'name': 'cli-amd64-from-arm64',
                'contents': containerfile(f'--platform=linux/arm64 {arm64_alpine}'),
                'argv': ['build', '--platform', 'linux/amd64', '-t', None, '.'],
                'instrument': False,
                'inspect_base': False,
                'content_machine': em_aarch64,
            },
            {
                'name': 'named-stage-arm64',
                'contents': (
                    f'FROM --platform=linux/arm64 {arm64_alpine} AS base\n'
                    'FROM base\nCOPY start.sh /start.sh\n'
                    'ENTRYPOINT ["/bin/sh", "/start.sh"]\nCMD ["default"]\n'
                ),
                'argv': ['build', '-t', None, '.'],
                'instrument': False,
                'inspect_base': False,
                'content_machine': em_aarch64,
            },
            {
                'name': 'stage-reference-platform-conflict',
                'contents': (
                    f'FROM --platform=linux/arm64 {arm64_alpine} AS base\n'
                    'FROM --platform=linux/amd64 base\n'
                    'COPY start.sh /start.sh\n'
                    'ENTRYPOINT ["/bin/sh", "/start.sh"]\n'
                    'CMD ["default"]\n'
                ),
                'argv': ['build', '-t', None, '.'],
                'instrument': False,
                'inspect_base': False,
                'notice': 'image platform could not be determined',
                'content_machine': em_aarch64,
            },
            {
                'name': 'stage-reference-arm64-external',
                'contents': startup_containerfile(
                    f'FROM {alpine_index} AS base\n'
                    'FROM --platform=linux/arm64 base\n'),
                'argv': ['build', '--format', 'oci', '-t', None, '.'],
                'instrument': False,
                'inspect_base': False,
                'prime_amd64_index': True,
                'cache_reference': alpine_index,
                'no_chalk_pull': True,
                'notice': 'image platform could not be determined',
                'expected_architecture': 'amd64',
                'content_machine': em_x86_64,
            },
            {
                'name': 'stage-reference-arm64-scratch',
                'contents': (
                    'FROM scratch AS base\n'
                    'FROM --platform=linux/arm64 base\n'
                    f'COPY --from={arm64_alpine} /bin/busybox '
                    '/bin/busybox\n'
                    f'COPY --from={arm64_alpine} /lib/ /lib/\n'
                    'ENTRYPOINT ["/bin/busybox", "echo"]\n'
                    'CMD ["scratch-default"]\n'
                ),
                'argv': ['build', '--format', 'oci', '-t', None, '.'],
                'instrument': False,
                'inspect_base': False,
                'no_chalk_pull': True,
                'notice': 'image platform could not be determined',
                'expected_architecture': 'amd64',
                'content_machine': em_aarch64,
                'expected_default_stdout': 'scratch-default\n',
                'expected_override_stdout': 'one two\n',
            },
            {
                'name': 'platform-global-arg-later-env',
                'contents': startup_containerfile(
                    'ARG CHALK_REVIEW_PLATFORM=linux/arm64\n'
                    f'FROM --platform=$CHALK_REVIEW_PLATFORM {alpine_index}\n'
                    'ENV CHALK_REVIEW_PLATFORM=linux/amd64\n'),
                'argv': ['build', '--format', 'oci', '-t', None, '.'],
                'instrument': False,
                'inspect_base': False,
                'prime_amd64_index': True,
                'cache_reference': alpine_index,
                'no_chalk_pull': True,
                'notice': 'image platform could not be determined',
                'expected_architecture': 'arm64',
                'content_machine': em_aarch64,
            },
            {
                'name': 'platform-global-arg-caller-env',
                'contents': startup_containerfile(
                    'ARG CHALK_REVIEW_CALLER_PLATFORM=linux/arm64\n'
                    f'FROM --platform=$CHALK_REVIEW_CALLER_PLATFORM '
                    f'{alpine_index}\n'),
                'argv': ['build', '--format', 'oci', '-t', None, '.'],
                'ambient': {
                    'CHALK_REVIEW_CALLER_PLATFORM': 'linux/amd64',
                },
                'instrument': False,
                'inspect_base': False,
                'prime_amd64_index': True,
                'cache_reference': alpine_index,
                'no_chalk_pull': True,
                'notice': 'image platform could not be determined',
                'expected_architecture': 'arm64',
                'content_machine': em_aarch64,
            },
            {
                'name': 'platform-global-arg-stage-arg',
                'contents': startup_containerfile(
                    'ARG CHALK_REVIEW_STAGE_PLATFORM=linux/arm64\n'
                    f'FROM --platform=$CHALK_REVIEW_STAGE_PLATFORM '
                    f'{alpine_index}\n'
                    'ARG CHALK_REVIEW_STAGE_PLATFORM=linux/amd64\n'),
                'argv': ['build', '--format', 'oci', '-t', None, '.'],
                'instrument': False,
                'inspect_base': False,
                'prime_amd64_index': True,
                'cache_reference': alpine_index,
                'no_chalk_pull': True,
                'notice': 'image platform could not be determined',
                'expected_architecture': 'arm64',
                'content_machine': em_aarch64,
            },
            {
                'name': 'image-global-arg-later-env',
                'contents': startup_containerfile(
                    f'ARG CHALK_REVIEW_BASE={arm64_alpine}\n'
                    'FROM $CHALK_REVIEW_BASE\n'
                    f'ENV CHALK_REVIEW_BASE={amd64_alpine}\n'),
                'argv': ['build', '--format', 'oci', '-t', None, '.'],
                'instrument': False,
                'inspect_base': False,
                'no_chalk_pull': True,
                'notice': 'image platform could not be determined',
                'expected_architecture': 'arm64',
                'content_machine': em_aarch64,
            },
            {
                'name': 'automatic-targetplatform',
                'contents': containerfile(
                    f'--platform=$TARGETPLATFORM {alpine_index}'),
                'argv': ['build', '--format', 'oci', '-t', None, '.'],
                'ambient': {'TARGETPLATFORM': 'linux/arm64'},
                'instrument': False,
                'inspect_base': False,
                'prime_amd64_index': True,
                'cache_reference': alpine_index,
                'no_chalk_pull': True,
                'notice': 'image platform could not be determined',
                'expected_architecture': 'amd64',
                'content_machine': em_x86_64,
            },
            {
                'name': 'automatic-buildplatform',
                'contents': containerfile(
                    f'--platform=$BUILDPLATFORM {alpine_index}'),
                'argv': ['build', '--format', 'oci', '-t', None, '.'],
                'ambient': {'BUILDPLATFORM': 'linux/arm64'},
                'instrument': False,
                'inspect_base': False,
                'prime_amd64_index': True,
                'cache_reference': alpine_index,
                'no_chalk_pull': True,
                'notice': 'image platform could not be determined',
                'expected_architecture': 'amd64',
                'content_machine': em_x86_64,
            },
            {
                'name': 'index-cached-arm64-implicit-amd64',
                'contents': containerfile(alpine_index),
                'argv': ['build', '--format', 'oci', '-t', None, '.'],
                'instrument': False,
                'inspect_base': True,
                'prime_arm64_index': True,
                'cache_reference': alpine_index,
                'no_chalk_pull': True,
                'native_cache_after_architecture': 'arm64',
                # Buildah may label the ARM-content result with the host
                # architecture when it reuses an intermediate layer. Metadata
                # parity remains required, while ELF proves the actual content.
                'content_machine': em_aarch64,
            },
            {
                'name': 'arm64-digest',
                'contents': containerfile(arm64_alpine),
                'argv': ['build', '-t', None, '.'],
                'instrument': False,
                'inspect_base': True,
                'content_machine': em_aarch64,
            },
            {
                'name': 'index-from-platform-arm64',
                'contents': containerfile(f'--platform=linux/arm64 {alpine_index}'),
                'argv': ['build', '-t', None, '.'],
                'instrument': False,
                'inspect_base': False,
                'prime_amd64_index': True,
                'cache_reference': alpine_index,
                'native_cache_after_architecture': 'arm64',
                'content_machine': em_aarch64,
            },
            {
                'name': 'index-cached-arm64-cli-amd64',
                'contents': containerfile(alpine_index),
                'argv': ['build', '--platform', 'linux/amd64', '-t', None, '.'],
                'instrument': False,
                'inspect_base': True,
                'prime_arm64_index': True,
                'cache_reference': alpine_index,
                'expected_lookup': alpine_index,
                'no_chalk_pull': True,
                'notice': 'image platform could not be determined',
                'content_machine': em_x86_64,
            },
            {
                'name': 'index-cached-arm64-from-amd64',
                'contents': containerfile(
                    f'--platform=linux/amd64 {alpine_index}'),
                'argv': ['build', '-t', None, '.'],
                'instrument': False,
                'inspect_base': True,
                'prime_arm64_index': True,
                'cache_reference': alpine_index,
                'expected_lookup': alpine_index,
                'no_chalk_pull': True,
                'notice': 'image platform could not be determined',
                'content_machine': em_x86_64,
            },
            {
                'name': 'index-digest-cached-arm64-cli-amd64',
                'contents': containerfile(alpine_index_digest),
                'argv': ['build', '--platform', 'linux/amd64', '-t', None, '.'],
                'instrument': False,
                'inspect_base': True,
                'prime_arm64_index': True,
                'cache_reference': alpine_index_digest,
                'expected_cache_config_id': arm64_alpine_config,
                'expected_lookup': alpine_index_digest,
                'no_chalk_pull': True,
                'notice': 'image platform could not be determined',
                'expected_architecture': 'amd64',
                'content_machine': em_x86_64,
            },
            {
                'name': 'index-digest-cached-arm64-from-amd64',
                'contents': containerfile(
                    f'--platform=linux/amd64 {alpine_index_digest}'),
                'argv': ['build', '-t', None, '.'],
                'instrument': False,
                'inspect_base': True,
                'prime_arm64_index': True,
                'cache_reference': alpine_index_digest,
                'expected_cache_config_id': arm64_alpine_config,
                'expected_lookup': alpine_index_digest,
                'no_chalk_pull': True,
                'notice': 'image platform could not be determined',
                'expected_architecture': 'amd64',
                'content_machine': em_x86_64,
            },
            {
                'name': 'local-tagged-arm64-cli-amd64',
                'contents': containerfile(local_base),
                'argv': ['build', '--platform', 'linux/amd64', '-t', None, '.'],
                # Frozen Podman 6.1.3 cannot resolve an amd64 variant from this
                # locally built, single-platform ARM tag. This case proves
                # failure parity and cache preservation, not image contents.
                'expected_native_status': 125,
                'instrument': False,
                'inspect_base': True,
                'restore_local_base': True,
                'cache_reference': local_base,
                'expected_lookup': local_base,
                'no_chalk_pull': True,
                'expect_ordered_platform_refusal': True,
                'preserve_local_base': True,
                'notice': 'image platform could not be determined',
            },
        ]

        for case in cases:
            native_cache = prepare_cache(case)
            (context / 'Containerfile').write_text(case['contents'])
            native_tag = tag(case['name'] + '-native')
            wrapped_tag = tag(case['name'] + '-wrapped')
            native_argv = [arg if arg is not None else native_tag
                           for arg in case['argv']]
            wrapped_argv = [arg if arg is not None else wrapped_tag
                            for arg in case['argv']]
            derived_path = root / (case['name'] + '-derived.Containerfile')
            derived_path.unlink(missing_ok=True)
            ambient = case.get('ambient', {})
            native_env = dict(os.environ, **ambient)
            wrapped_env = dict(
                env,
                PODMAN_PLATFORM_DERIVED=str(derived_path),
                **ambient,
            )
            native_res, _ = invoke([podman, *native_argv], cwd=context,
                                   env=native_env,
                                   require_success=False)
            expected_native_status = case.get('expected_native_status', 0)
            check(case['name'] + ' native expected status',
                  native_res.returncode == expected_native_status)
            cache_reference = case.get('cache_reference')
            native_cache_after = (
                None if cache_reference is None else inspect(cache_reference))
            if case.get('native_cache_after_architecture'):
                check(case['name'] + ' native cache precedence',
                      native_cache_after.get('Architecture') ==
                      case['native_cache_after_architecture'])
            wrapped_cache = prepare_cache(case)
            if native_cache is not None:
                check(case['name'] + ' equivalent initial cache',
                      native_cache.get('Id') == wrapped_cache.get('Id') and
                      native_cache.get('Os') == wrapped_cache.get('Os') and
                      native_cache.get('Architecture') ==
                      wrapped_cache.get('Architecture'))
            if case.get('prime_amd64_index'):
                check(case['name'] + ' amd64 cache primed',
                      native_cache.get('Architecture') == 'amd64')
            if case.get('prime_arm64_index'):
                check(case['name'] + ' ARM cache primed',
                      native_cache.get('Architecture') == 'arm64')
            expected_cache_id = case.get('expected_cache_config_id')
            if expected_cache_id:
                expected_repo_digests = {
                    arm64_alpine,
                    alpine_index_digest,
                }
                check(case['name'] + ' exact native ARM index cache',
                      native_cache.get('Os') == 'linux' and
                      native_cache.get('Architecture') == 'arm64' and
                      native_cache.get('Id') == expected_cache_id and
                      native_cache.get('Digest') ==
                      alpine_index_digest.split('@', 1)[1] and
                      expected_repo_digests.issubset(
                          set(native_cache.get('RepoDigests') or [])))
                check(case['name'] + ' exact wrapped ARM index cache',
                      wrapped_cache.get('Os') == 'linux' and
                      wrapped_cache.get('Architecture') == 'arm64' and
                      wrapped_cache.get('Id') == expected_cache_id and
                      wrapped_cache.get('Digest') ==
                      alpine_index_digest.split('@', 1)[1] and
                      expected_repo_digests.issubset(
                          set(wrapped_cache.get('RepoDigests') or [])))
            calls.write_text('')
            wrapped_run, elapsed = invoke(
                [str(wrapped / 'podman'), *wrapped_argv], cwd=context,
                env=wrapped_env,
                require_success=False)
            recorded = [json.loads(line) for line in calls.read_text().splitlines()]
            builds = [args for args in recorded if args and args[0] == 'build']
            root_inspections = [
                args for args in recorded
                if args[:2] == ['image', 'inspect'] and args[-2:] == ['--format', 'json']
            ]
            pulls = [args for args in recorded if args[:2] == ['pull', '--quiet']]
            if case.get('inspect_base') is True:
                check(case['name'] + ' inspected base', len(root_inspections) == 1)
            elif case.get('inspect_base') is False:
                check(case['name'] + ' skipped inspect', root_inspections == [])
            expected_lookup = case.get('expected_lookup')
            if expected_lookup:
                check(case['name'] + ' exact base lookup', root_inspections == [[
                    'image', 'inspect', expected_lookup, '--format', 'json',
                ]])
            if case.get('no_chalk_pull'):
                check(case['name'] + ' no Chalk pull', pulls == [])
            expected_root_id = case.get('expected_root_config_id')
            if case.get('expect_ordered_platform_refusal'):
                check(case['name'] + ' ordered platform refusal', recorded == [
                    ['info', '--format', 'json'],
                    [
                        'image', 'inspect', expected_lookup,
                        '--format', 'json',
                    ],
                    wrapped_argv,
                ])
            if case.get('preserve_local_base'):
                local_after = inspect(local_base)
                labels_after = (local_after.get('Labels') or
                                (local_after.get('Config') or {}).get('Labels') or {})
                check(case['name'] + ' base identity preserved',
                      local_after.get('Id') == wrapped_cache.get('Id'))
                check(case['name'] + ' base marker preserved',
                      labels_after.get('io.chalk.platform-cache-marker') ==
                      local_base_marker)
            native = None
            actual = None
            native_entry = []
            native_cmd = []
            actual_entry = []
            actual_cmd = []
            native_content = None
            wrapped_content = None
            runtime = None
            expected_notice = None
            content_path = case.get('content_path', '/bin/busybox')
            if case['instrument']:
                check(case['name'] + ' wrapped build', wrapped_run.returncode == 0)
                native = inspect(native_tag)
                actual = inspect(wrapped_tag)
                native_config = native.get('Config') or {}
                actual_config = actual.get('Config') or {}
                native_entry = native_config.get('Entrypoint') or []
                native_cmd = native_config.get('Cmd') or []
                actual_entry = actual_config.get('Entrypoint') or []
                actual_cmd = actual_config.get('Cmd') or []
                check(case['name'] + ' instrumented once',
                      len(builds) == 1 and '--build-context' in builds[0])
                check(case['name'] + ' captured derived Containerfile',
                      derived_path.is_file())
                if expected_root_id:
                    derived_root = derived_path.read_text().splitlines()[0]
                    expected_root = 'FROM '
                    if '--platform=linux/amd64' in case['contents'].splitlines()[0]:
                        expected_root += '--platform=linux/amd64 '
                    expected_root += expected_root_id
                    check(case['name'] + ' immutable selected root',
                          derived_root == expected_root)
                check(case['name'] + ' Chalk entrypoint',
                      actual_entry[:3] == ['/chalk', 'exec', '--heartbeat'])
                check(case['name'] + ' has /chalk', copy_exists(wrapped_tag, '/chalk'))
                check(case['name'] + ' has /chalk.json',
                      copy_exists(wrapped_tag, '/chalk.json'))
                check(case['name'] + ' architecture', actual.get('Architecture') == 'amd64')
                check(case['name'] + ' architecture matches native',
                      actual.get('Os') == native.get('Os') and
                      actual.get('Architecture') == native.get('Architecture'))
                native_content, wrapped_content = verify_image_content(
                    case['name'], native_tag, wrapped_tag,
                    case['content_machine'], content_path)
                runtime = verify_runtime_parity(
                    case['name'], native_tag, wrapped_tag,
                    case.get('expected_default_stdout',
                             'application <default>\n'),
                    case.get('expected_override_stdout',
                             'application <one two>\n'))
            else:
                check(case['name'] + ' wrapped matches native status',
                      wrapped_run.returncode == native_res.returncode)
                check(case['name'] + ' native pass-through',
                      len(builds) == 1 and
                      '--build-context' not in builds[0] and
                      builds[0] == wrapped_argv)
                expected_notice = case.get(
                    'notice',
                    'image platform is incompatible with the Chalk executable')
                check(case['name'] + ' skip notice',
                      expected_notice in wrapped_run.stderr)
                other_notice = (
                    'image platform is incompatible with the Chalk executable'
                    if expected_notice == 'image platform could not be determined'
                    else 'image platform could not be determined')
                check(case['name'] + ' no false platform notice',
                      other_notice not in wrapped_run.stderr)
                check(case['name'] + ' notice omits image id',
                      arm64_alpine.split('@', 1)[1] not in wrapped_run.stderr)
                if native_res.returncode == 0 and wrapped_run.returncode == 0:
                    native = inspect(native_tag)
                    actual = inspect(wrapped_tag)
                    native_config = native.get('Config') or {}
                    actual_config = actual.get('Config') or {}
                    native_entry = native_config.get('Entrypoint') or []
                    native_cmd = native_config.get('Cmd') or []
                    actual_entry = actual_config.get('Entrypoint') or []
                    actual_cmd = actual_config.get('Cmd') or []
                    check(case['name'] + ' original startup',
                          actual_entry == native_entry and
                          actual_cmd == native_cmd)
                    check(case['name'] + ' no /chalk',
                          not copy_exists(wrapped_tag, '/chalk'))
                    check(case['name'] + ' no /chalk.json',
                          not copy_exists(wrapped_tag, '/chalk.json'))
                    check(case['name'] + ' architecture matches native',
                          actual.get('Os') == native.get('Os') and
                          actual.get('Architecture') ==
                          native.get('Architecture'))
                    native_content, wrapped_content = verify_image_content(
                        case['name'], native_tag, wrapped_tag,
                        case['content_machine'], content_path)
                    runtime = verify_runtime_parity(
                        case['name'], native_tag, wrapped_tag,
                        case.get('expected_default_stdout',
                                 'application <default>\n'),
                        case.get('expected_override_stdout',
                                 'application <one two>\n'))
            if native is not None and case.get('expected_architecture'):
                check(case['name'] + ' native expected architecture',
                      native.get('Architecture') ==
                      case['expected_architecture'])
                check(case['name'] + ' wrapped expected architecture',
                      actual.get('Architecture') ==
                      case['expected_architecture'])
            observations.append({
                'case': case['name'],
                'ambient': ambient,
                'native_status': native_res.returncode,
                'expected_native_status': expected_native_status,
                'wrapped_status': wrapped_run.returncode,
                'native_os': None if native is None else native.get('Os'),
                'native_architecture': None if native is None else native.get('Architecture'),
                'native_entrypoint': native_entry,
                'native_cmd': native_cmd,
                'wrapped_entrypoint': actual_entry,
                'wrapped_cmd': actual_cmd,
                'content_path': content_path,
                'native_content': native_content,
                'wrapped_content': wrapped_content,
                'runtime': runtime,
                # Preserve the schema read by the independent 211fa verifier.
                'native_busybox': native_content,
                'wrapped_busybox': wrapped_content,
                'expected_content_machine': case.get('content_machine'),
                'expected_architecture': case.get('expected_architecture'),
                'expected_notice': expected_notice,
                'calls': recorded,
                'root_inspections': root_inspections,
                'derived_root': (
                    derived_path.read_text().splitlines()[0]
                    if derived_path.is_file() else None),
                'injection_attempted': any(
                    '--build-context' in args for args in builds),
                'cache_reference': cache_reference,
                'native_cache_id': (None if native_cache is None else
                                    native_cache.get('Id')),
                'native_cache_os': (None if native_cache is None else
                                    native_cache.get('Os')),
                'native_cache_architecture': (
                    None if native_cache is None else
                    native_cache.get('Architecture')),
                'native_cache_digest': (None if native_cache is None else
                                        native_cache.get('Digest')),
                'native_cache_repo_digests': (
                    None if native_cache is None else
                    native_cache.get('RepoDigests')),
                'native_cache_after_id': (
                    None if native_cache_after is None else
                    native_cache_after.get('Id')),
                'native_cache_after_architecture': (
                    None if native_cache_after is None else
                    native_cache_after.get('Architecture')),
                'wrapped_cache_id': (None if wrapped_cache is None else
                                     wrapped_cache.get('Id')),
                'wrapped_cache_os': (None if wrapped_cache is None else
                                     wrapped_cache.get('Os')),
                'wrapped_cache_architecture': (
                    None if wrapped_cache is None else
                    wrapped_cache.get('Architecture')),
                'wrapped_cache_digest': (None if wrapped_cache is None else
                                         wrapped_cache.get('Digest')),
                'wrapped_cache_repo_digests': (
                    None if wrapped_cache is None else
                    wrapped_cache.get('RepoDigests')),
                'build_seconds': elapsed,
            })

        (context / 'Containerfile').write_text(containerfile(
            f'--platform=linux/amd64 {amd64_alpine}'))
        fail_tag = tag('inspect-failure')
        fail_argv = ['build', '-t', fail_tag, '.']
        invoke([podman, *fail_argv], cwd=context)
        calls.write_text('')
        fail_env = dict(env, PODMAN_PLATFORM_INSPECT_EXIT='17')
        fail_run, _ = invoke([str(wrapped / 'podman'), *fail_argv], cwd=context,
                             env=fail_env)
        fail_recorded = [json.loads(line) for line in calls.read_text().splitlines()]
        fail_builds = [args for args in fail_recorded if args and args[0] == 'build']
        fail_info = inspect(fail_tag)
        check('inspect failure pass-through',
              fail_builds == [fail_argv])
        check('inspect failure original entrypoint',
              (fail_info.get('Config') or {}).get('Entrypoint') ==
              ['/bin/sh', '/start.sh'])
        check('inspect failure no /chalk', not copy_exists(fail_tag, '/chalk'))
        check('inspect failure skip notice',
              'an immutable selected-base identity is unavailable' in fail_run.stderr)

        cancel_tag = tag('inspect-cancel')
        cancel_argv = ['build', '-t', cancel_tag, '.']
        calls.write_text('')
        cancel_env = dict(env, PODMAN_PLATFORM_INSPECT_EXIT='130')
        cancel_run, _ = invoke([str(wrapped / 'podman'), *cancel_argv], cwd=context,
                               env=cancel_env, require_success=False)
        cancel_recorded = [json.loads(line) for line in calls.read_text().splitlines()]
        cancel_builds = [args for args in cancel_recorded if args and args[0] == 'build']
        check('inspect cancellation exit', cancel_run.returncode == 130)
        check('inspect cancellation no build', cancel_builds == [])
finally:
    for image in reversed(images):
        subprocess.run([podman, 'image', 'rm', '-f', image], capture_output=True)
    (out / 'evidence.json').write_text(json.dumps({
        'schema_version': 1, 'source_sha': os.environ.get('CI_COMMIT_SHA'),
        'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'checks': checks, 'observations': observations,
        'emulation': proof,
        'passed': sys.exc_info()[0] is None,
    }, indent=2) + '\n')
