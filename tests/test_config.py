# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import itertools
from pathlib import Path
from typing import Any, IO, Iterator, Callable, Optional

import pytest

from .chalk.runner import Chalk, ChalkMark, ChalkReport
from .utils.log import get_logger
from .conf import (
    BASE_OUTCONF,
    LS_PATH,
    CONFIGS,
    BASE_REPORT_TEMPLATES,
    BASE_MARK_TEMPLATES,
)

logger = get_logger()


VALIDATION_ERROR = "XXXXXX"
parse_error = "Parse error"


# test dump + reload with error log + extract to check error
@pytest.mark.parametrize("use_embedded", [True, False])
def test_dump_load(tmp_data_dir: Path, chalk_copy: Chalk, use_embedded: bool):
    # output for updated config
    tmp_conf = tmp_data_dir / "testconf.c4m"

    # dump config to file
    chalk_copy.dump(tmp_conf)

    # edit file (add an error output)
    tmp_conf.write_text(f"error({VALIDATION_ERROR}){tmp_conf.read_text()}")

    # load updated config (will overwrite chalk binary)
    result = chalk_copy.load(
        tmp_conf, use_embedded=use_embedded, expected_success=False
    )
    assert VALIDATION_ERROR in result.logs


# sanity check that default config has not changed
# if it has then the thing to do is usually update "default.c4m" with the new default config
# this test is mainly to catch any default changes that might impact other tests, or if the default config loaded to the binary is wrong
@pytest.mark.parametrize("test_config_file", ["validation/default.c4m"])
def test_default_config(
    tmp_data_dir: Path, chalk_default: Chalk, test_config_file: str
):
    tmp_conf = tmp_data_dir / "testconf.c4m"

    # dump config to file
    chalk_default.dump(tmp_conf)

    assert tmp_conf.read_text() == (CONFIGS / test_config_file).read_text()


@pytest.mark.parametrize(
    "test_config_file",
    [
        "validation/invalid_1.c4m",
        "validation/invalid_2.c4m",
    ],
)
@pytest.mark.parametrize(
    "use_embedded",
    [
        True,
        False,
    ],
)
def test_invalid_load(chalk_copy: Chalk, test_config_file: str, use_embedded: bool):
    # call chalk load on invalid config
    load = chalk_copy.load(
        CONFIGS / test_config_file,
        use_embedded=use_embedded,
        expected_success=False,
    )
    # chalk should still have default config embedded
    # and further calls should not fail and not have any errors
    extract = chalk_copy.extract(chalk_copy.binary)
    for report in extract.reports:
        assert report["_OPERATION"] == "extract"
        assert "_OP_ERRORS" not in report


@pytest.mark.parametrize(
    "test_config_file, expected_error",
    [
        ("validation/valid_1.c4m", VALIDATION_ERROR),
    ],
)
@pytest.mark.parametrize(
    "use_embedded",
    [
        True,
        False,
    ],
)
def test_valid_load(
    chalk_copy: Chalk, test_config_file: str, expected_error: str, use_embedded: bool
):
    # call chalk load on valid config
    chalk_copy.load(CONFIGS / test_config_file, use_embedded=use_embedded)

    # extract should succeed, but the error we put in should show up
    extract = chalk_copy.extract(chalk_copy.binary, ignore_errors=True)
    for report in extract.reports:
        assert report["_OPERATION"] == "extract"

        if expected_error:
            assert report.errors
            assert expected_error in report.errors
        else:
            if "_OP_ERRORS" in report:
                logger.error(
                    "report has unexpected errors", errors=report["_OP_ERRORS"]
                )
            assert "_OP_ERRORS" not in report


@pytest.mark.parametrize(
    "path, expected_success",
    [
        ("demo-http.c4m", True),
        ("nonexisting", False),
    ],
)
def test_load_url(
    chalk_copy: Chalk, server_chalkdust: str, path: str, expected_success: bool
):
    chalk_copy.load(
        f"{server_chalkdust}/{path}",
        log_level="trace",
        expected_success=expected_success,
    )


# tests for configs that are found in the chalk search path
# these configs are NOT loaded directly into the binary
# as these configs are global across the system,
# test needs to be exclusive so nothing else executes in parallel
@pytest.mark.exclusive
@pytest.mark.parametrize("tmp_file", [{"path": "/etc/chalk.c4m"}], indirect=True)
@pytest.mark.parametrize(
    "config_path, expected_success, expected_error",
    [
        ("validation/valid_1.c4m", True, VALIDATION_ERROR),
        ("validation/invalid_1.c4m", False, ""),
    ],
)
def test_external_configs(
    tmp_file: IO,
    chalk_copy: Chalk,
    config_path: str,
    expected_success: bool,
    expected_error: str,
):
    result_config = chalk_copy.run(
        command="env",
        log_level="error",
        config=CONFIGS / config_path,
        expected_success=expected_success,
        ignore_errors=True,
    )
    if expected_error:
        assert expected_error in result_config.logs

    # test load by putting it in chalk default search locations
    # instead of copying to tmp data dir, we have to copy to someplace chalk looks for it
    with tmp_file as fid:
        fid.write((CONFIGS / config_path).read_bytes())

    result_external = chalk_copy.run(
        command="env",
        log_level="error",
        expected_success=expected_success,
        ignore_errors=True,
    )
    if expected_error:
        assert expected_error in result_external.logs


@pytest.mark.parametrize(
    "test_config_file", [CONFIGS / "validation/custom_report.c4m"]
)
@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_custom_report(
    chalk_copy: Chalk,
    copy_files: list[Path],
    test_config_file: Path,
):
    bin_path = copy_files[0]
    # config sets custom report file output here
    report_path = Path("/tmp/custom_report.log")

    # expecting a report for insert
    assert chalk_copy.run(
        config=test_config_file,
        target=bin_path,
        command="insert",
        virtual=False,
    ).report

    # expecting a report for extract
    assert chalk_copy.run(
        config=test_config_file,
        target=bin_path,
        command="extract",
        virtual=False,
    ).report

    # not expecting a report for env in report file
    # but it still shows up in stdout
    assert chalk_copy.run(
        config=test_config_file,
        command="env",
        virtual=False,
    ).reports

    log_lines = report_path.read_text().splitlines()
    reports = [ChalkReport.from_json(i) for i in log_lines]

    # only expecting report for insert and extract
    assert len(reports) == 2

    assert [i["_OPERATION"] for i in reports] == ["insert", "extract"]
    assert all(set(i.keys()) == {"_OPERATION", "_CHALKS"} for i in reports)


# outconf tests

# output configurations defined in "src/configs/base_outconf.c4m"
outconf = {
    "insert",
    "extract",
    "build",
    "push",
    "exec",
    "heartbeat",
    "delete",
    "env",
    "load",
    "dump",
    "setup",
    "docker",
}


def test_validate_outconf_operations():
    """
    checks if the outconfs we have defined are the same

    if this is failing, something has changed in base_outconf.c4m
    and tests need to be updated
    """
    configs = merged_configs()
    assert outconf == set(
        configs
    ), "specified outconf operations have changed and needs to be updated"


def _get_blocks(
    lines: Iterator[str],
    start_at: Callable[[str], bool],
    end_at: Callable[[str], bool],
    adjust: Callable[[str], str],
    keep: Callable[[str], bool],
) -> Iterator[list[str]]:
    for line in lines:
        if not start_at(line):
            continue
        yield [line] + list(
            filter(
                keep, map(adjust, itertools.takewhile(lambda i: not end_at(i), lines))
            )
        )


def get_outconf(
    path: Path = BASE_OUTCONF, base: Optional[dict[str, dict[str, str]]] = None
) -> dict[str, dict[str, str]]:
    outconfs: dict[str, dict[str, str]] = base or {}
    names: set[str] = set()
    for block in _get_blocks(
        iter(path.read_text().splitlines()),
        start_at=lambda i: i.startswith("outconf ") and i.endswith("{"),
        end_at=lambda i: i.startswith("}"),
        adjust=lambda i: i.split("#")[0].strip(),
        keep=lambda i: bool(i),
    ):
        start, *lines = block
        name = start.split()[1]
        assert (
            name not in names
        ), "outconf definitions should not have duplicates in the same file"
        names.add(name)
        conf = outconfs.setdefault(name, {})
        for line in lines:
            key, value = line.split(":")
            key = key.strip()
            value = value.strip().strip("\"'")
            conf[key] = value
    return outconfs


def get_report_templates(
    path: Path = BASE_REPORT_TEMPLATES, base: Optional[dict[str, set[str]]] = None
) -> dict[str, set[str]]:
    profiles: dict[str, set[str]] = base or {}
    for block in _get_blocks(
        iter(path.read_text().splitlines()),
        start_at=lambda i: i.startswith("report_template ") and i.endswith("{"),
        end_at=lambda i: i.startswith("}"),
        adjust=lambda i: i.split("#")[0].strip(),
        keep=lambda i: i.strip().startswith("key."),
    ):
        start, *lines = block
        name = start.split()[1]
        assert (
            name not in profiles
        ), "report template definitions should not have duplicates in the same config file"
        conf = profiles.setdefault(name, set())
        for line in lines:
            var, enabled = line.split("=")
            key = var.split(".")[1].strip()
            enabled = enabled.strip()
            assert enabled in {"true", "false"}
            if enabled == "true":
                conf.add(key)
            else:
                conf.discard(key)
    return profiles


def get_mark_templates(
    path: Path = BASE_MARK_TEMPLATES, base: Optional[dict[str, set[str]]] = None
) -> dict[str, set[str]]:
    profiles: dict[str, set[str]] = base or {}
    for block in _get_blocks(
        iter(path.read_text().splitlines()),
        start_at=lambda i: i.startswith("mark_template ") and i.endswith("{"),
        end_at=lambda i: i.startswith("}"),
        adjust=lambda i: i.split("#")[0].strip(),
        keep=lambda i: i.strip().startswith("key."),
    ):
        start, *lines = block
        name = start.split()[1]
        assert (
            name not in profiles
        ), "mark template definitions should not have duplicates in the same config file"
        conf = profiles.setdefault(name, set())
        for line in lines:
            var, enabled = line.split("=")
            key = var.split(".")[1].strip()
            enabled = enabled.strip()
            assert enabled in {"true", "false"}
            if enabled == "true":
                conf.add(key)
            else:
                conf.discard(key)
    return profiles


# returns a map of template names to enabled keys for that template for each outconf
# that are defined in test_config_file + base_report_templates.c4m + base_chalk_templates.c4m
def merged_configs(
    test_config_file: Optional[Path] = None,
) -> dict[str, dict[str, set[str]]]:
    outconfs = get_outconf()
    # templates now stored in chalk template + report template
    report_templates = get_report_templates()
    mark_templates = get_mark_templates()

    if test_config_file:
        # update configs with custom config
        get_outconf(test_config_file, outconfs)
        get_report_templates(test_config_file, report_templates)
        get_mark_templates(test_config_file, mark_templates)

    # merging ok as names should be globally unique
    report_templates.update(mark_templates)

    return {
        cmd: {report: report_templates[profile] for report, profile in outconf.items()}
        for cmd, outconf in outconfs.items()
    }


def validate_chalk_report_keys(
    report: dict[str, Any],
    config: dict[str, set[str]],
):
    report_keys = config["report_template"]
    validate_report_keys(report, report_keys)


def validate_report_keys(report: dict[str, Any], expected_keys: set[str]):
    """
    Validate report keys adhere to template report keys

    not all expected keys will show up in the report if they can't be found
    but we shouldn't have extra keys that aren't defined
    """
    assert len(report) <= len(expected_keys)
    for key in report:
        assert key in expected_keys


# tests outconf profiles for non-docker operations
@pytest.mark.parametrize(
    "test_config_file",
    [
        ("profiles/empty_profile.c4m"),
        ("profiles/default.c4m"),
        ("profiles/minimal_profile.c4m"),
        ("profiles/large_profile.c4m"),
    ],
)
@pytest.mark.parametrize(
    "use_embedded",
    [
        True,
        False,
    ],
)
@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_profiles(
    copy_files: list[Path],
    chalk_copy: Chalk,
    test_config_file: str,
    use_embedded: bool,
):
    bin_path = copy_files[0]
    configs = merged_configs(CONFIGS / test_config_file)

    # call chalk load on test config
    chalk_copy.load(CONFIGS / test_config_file, use_embedded=use_embedded)

    # insert report should have keys listed
    insert = chalk_copy.insert(bin_path)
    validate_chalk_report_keys(insert.report, configs["insert"])

    # check that binary has the correct chalk mark
    chalk_mark = ChalkMark.from_binary(bin_path)

    # no matter what's defined in the profile, minimal key set below needs to be in chalk mark
    minimal_chalk = {
        "MAGIC",
        "CHALK_ID",
        "CHALK_VERSION",
        "METADATA_ID",
    }
    for key in minimal_chalk:
        assert key in chalk_mark
    logger.info("chalk insert config", config=configs["insert"]["mark_template"])
    # validate all keys (minimal+rest) in the chalk mark profile
    validate_report_keys(chalk_mark, configs["insert"]["mark_template"] | minimal_chalk)

    # extract
    extract = chalk_copy.extract(bin_path)
    validate_chalk_report_keys(extract.report, configs["extract"])

    # exec
    exec_proc = chalk_copy.exec(bin_path)
    validate_chalk_report_keys(exec_proc.report, configs["exec"])

    # delete
    delete = chalk_copy.delete(bin_path)
    validate_chalk_report_keys(delete.report, configs["delete"])
