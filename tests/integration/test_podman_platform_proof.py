#!/usr/bin/env python3
from podman_platform_proof import proves_arm_emulation


cases = [
    ('hidden-binfmt-handler', (0, 'linux', 'amd64', False, 0, 'aarch64'), True),
    ('failed-builder-inspection', (1, 'linux', 'amd64', False, 0, 'aarch64'), False),
    ('non-linux-builder', (0, 'darwin', 'amd64', False, 0, 'aarch64'), False),
    ('native-arm-builder', (0, 'linux', 'arm64', False, 0, 'aarch64'), False),
    ('remote-builder', (0, 'linux', 'amd64', True, 0, 'aarch64'), False),
    ('failed-arm-command', (0, 'linux', 'amd64', False, 125, 'aarch64'), False),
    ('wrong-arm-output', (0, 'linux', 'amd64', False, 0, 'x86_64'), False),
]

for name, inputs, expected in cases:
    actual = proves_arm_emulation(*inputs)
    assert actual is expected, (name, inputs, expected, actual)

print(f'{len(cases)} Podman ARM emulation proof cases passed')
