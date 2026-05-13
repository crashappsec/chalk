# Copyright (c) 2023-2024, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)

"""
Test for issue #652: Bad formatting in `chalk dump` for multiple `use` entries
"""

from pathlib import Path

from .chalk.runner import Chalk
from .conf import CONFIGS


def test_dump_multiple_use_statements_formatting(tmp_data_dir: Path, chalk_copy: Chalk):
    """
    Test that multiple use statements are properly separated by newlines in dump output.

    Issue #652: When dumping config with multiple use statements, they should be
    newline-separated, not concatenated without separation.

    Expected:
        use module1 from "url1"
        use module2 from "url2"

    Not:
        use module1 from "url1"use module2 from "url2"
    """
    # Load a config with multiple use statements
    config_path = CONFIGS / "composable" / "valid" / "valid_1.c4m"
    chalk_copy.load(config_path, use_embedded=True)

    # Dump the config to a file
    dump_output = tmp_data_dir / "dumped_config.c4m"
    chalk_copy.dump(dump_output)

    # Read the dumped config
    dumped_content = dump_output.read_text()

    # Check that use statements are properly separated
    # Each "use" keyword should be on its own line (preceded by newline or start of file)
    use_lines = [
        line for line in dumped_content.splitlines() if line.strip().startswith("use ")
    ]

    # Should have at least 2 use statements from valid_1.c4m
    assert (
        len(use_lines) >= 2
    ), f"Expected at least 2 use statements, got {len(use_lines)}"

    # Verify no concatenation by checking that "use" doesn't appear twice on the same line
    for line in dumped_content.splitlines():
        use_count = line.count("use ")
        assert (
            use_count <= 1
        ), f"Found {use_count} 'use' statements on a single line: {line}"
