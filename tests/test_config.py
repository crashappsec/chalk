import difflib
import json
import os
import shutil
from pathlib import Path
from typing import Any, Dict, List, IO

import pytest

from .chalk.runner import Chalk
from .utils.log import get_logger
from .utils.validate import MAGIC

logger = get_logger()


VALIDATION_ERROR = "TEST ERROR HERE XXXXXX"
parse_error = ["Parse", "error"]
CONFIGFILES = Path(__file__).parent / "data" / "configs"
# base profiles and outconf
BASE_PROFILES = Path(__file__).parent.parent / "src" / "configs" / "base_profiles.c4m"
BASE_OUTCONF = Path(__file__).parent.parent / "src" / "configs" / "base_outconf.c4m"


# test dump + reload with error log + extract to check error
@pytest.mark.parametrize("use_embedded", [True, False])
def test_dump_load(tmp_data_dir: Path, chalk_copy: Chalk, use_embedded: bool):
    # output for updated config
    tmp_conf = tmp_data_dir / "testconf.conf"

    # dump config to file
    dump_proc = chalk_copy.run(chalk_cmd="dump", params=[str(tmp_conf)])
    assert dump_proc.returncode == 0

    # edit file (add an error output)
    assert tmp_conf.exists(), "testconf.conf not created"
    assert tmp_conf.is_file(), "testconf.conf must be a file and is not"
    with open(tmp_conf, "w+") as file:
        file_text = file.read()
        file_text = f'error("{VALIDATION_ERROR}")' + file_text
        file.write(file_text)

    # load updated config (will overwrite chalk binary)
    load_output = chalk_copy.load(str(tmp_conf), use_embedded)
    assert load_output.returncode == 0
    dir_obj = os.listdir(tmp_data_dir)
    assert "chalk" in dir_obj

    # run new chalk and check for error in log output
    chalk_copy = Chalk(binary=(tmp_data_dir / "chalk").resolve())
    extract_output = chalk_copy.run(chalk_cmd="extract", params=["."])
    assert extract_output.returncode == 0
    error_output = extract_output.stderr.decode()
    assert VALIDATION_ERROR in error_output


# sanity check that default config has not changed
# if it has then the thing to do is usually update "default.conf" with the new default config
# this test is mainly to catch any default changes that might impact other tests, or if the default config loaded to the binary is wrong
@pytest.mark.parametrize("test_config_file", ["validation/default.conf"])
def test_default_config(tmp_data_dir: Path, chalk_copy: Chalk, test_config_file: str):
    tmp_conf = tmp_data_dir / "testconf.conf"

    # dump config to file
    dump_proc = chalk_copy.run(chalk_cmd="dump", params=[str(tmp_conf)])
    assert dump_proc.returncode == 0
    assert tmp_conf.exists(), "testconf.conf not created"
    assert tmp_conf.is_file(), "testconf.conf must be a file and is not"

    with open(str(tmp_conf)) as conf:
        dump_default = conf.readlines()

    with open(str(CONFIGFILES / test_config_file)) as conf:
        saved_default = conf.readlines()

    # if there is a diff, it will show up here so error
    diff = ""
    for line in difflib.unified_diff(dump_default, saved_default):
        diff = line + diff

    assert (
        len(diff) == 0
    ), "default config has changed, or non-default config is loaded into root chalk binary"


@pytest.mark.parametrize(
    "test_config_file", ["validation/invalid_1.conf", "validation/invalid_2.conf"]
)
@pytest.mark.parametrize("use_embedded", [True, False])
def test_invalid_load(
    tmp_data_dir: Path, chalk_copy: Chalk, test_config_file: str, use_embedded: bool
):
    # call chalk load on invalid config
    load_proc = chalk_copy.load(CONFIGFILES / test_config_file, use_embedded)

    #  we expect the load to fail with associated errors
    assert load_proc.returncode != 0, "load invalid config should have failed"
    assert all(x in load_proc.stderr.decode() for x in parse_error)

    # chalk should still have default config embedded
    # and further calls should not fail and not have any errors
    extract_output = chalk_copy.extract(chalk_copy.binary)
    for report in extract_output:
        assert "_OPERATION" in report
        assert report["_OPERATION"] == "extract"

        assert "_OP_ERRORS" not in report


@pytest.mark.parametrize("test_config_file", ["validation/valid_1.conf"])
@pytest.mark.parametrize("use_embedded", [True, False])
def test_valid_load(
    tmp_data_dir: Path, chalk_copy: Chalk, test_config_file: str, use_embedded: bool
):
    # call chalk load on valid config
    load_proc = chalk_copy.load(CONFIGFILES / test_config_file, use_embedded)

    #  we expect the load to succeed
    assert load_proc.returncode == 0, "load valid config should have succeeded"
    assert not any(x in load_proc.stderr.decode() for x in parse_error)

    # extract should succeed, but the error we put in should show up
    extract_output = chalk_copy.extract(chalk_copy.binary)
    for report in extract_output:
        assert "_OPERATION" in report
        assert report["_OPERATION"] == "extract"

        assert "_OP_ERRORS" in report
        assert VALIDATION_ERROR in report["_OP_ERRORS"][0]


# tests for configs that are found in the chalk search path
# these configs are NOT loaded directly into the binary
# as these configs are global across the system,
# test needs to be exclusive so nothing else executes in parallel
@pytest.mark.exclusive
@pytest.mark.parametrize("tmp_file", [{"path": "/etc/chalk.conf"}], indirect=True)
@pytest.mark.parametrize(
    "test_config",
    [
        ("validation/valid_1.conf", 0, VALIDATION_ERROR),
        ("validation/invalid_1.conf", 1, ""),
    ],
)
def test_external_configs(
    tmp_file: IO,
    chalk_copy: Chalk,
    test_config: tuple[str, int, str],
):
    # dont allow other chalks to run while this test case is running
    # chalk_copy.lock()

    config_path, returncode, expected_error = test_config

    reference = chalk_copy.run(
        chalk_cmd="env",
        params=["--log-level=error", f"--config-file={CONFIGFILES / config_path}"],
    )
    assert reference
    assert reference.returncode == returncode
    assert expected_error in reference.stdout.decode()

    # test load by putting it in chalk default search locations
    # instead of copying to tmp data dir, we have to copy to someplace chalk looks for it
    with tmp_file as fid:
        fid.write((CONFIGFILES / config_path).read_bytes())

    external = chalk_copy.run(chalk_cmd="env", params=["--log-level=error"])
    assert external
    assert external.returncode == returncode


# TODO: fill this out
@pytest.mark.parametrize(
    "test_config_file", [CONFIGFILES / "validation/custom_report.conf"]
)
def test_custom_report(
    tmp_data_dir: Path,
    chalk_copy: Chalk,
    test_config_file: str,
):
    # using "ls" for test binary
    shutil.copy("/bin/ls", tmp_data_dir)
    ls_path = tmp_data_dir / "ls"
    assert ls_path.exists(), "bin copy went wrong"

    # config sets custom report file output here
    report_path = "/tmp/custom_report.log"

    # expecting a report for insert
    _proc = chalk_copy.run_with_custom_config(
        test_config_file, ls_path, "insert", False
    )
    assert _proc.returncode == 0

    # expecting a report for extract
    _proc = chalk_copy.run_with_custom_config(
        test_config_file, ls_path, "extract", False
    )
    assert _proc.returncode == 0

    # not expecting a report for env
    _proc = chalk_copy.run_with_custom_config(test_config_file, "", "env", False)
    assert _proc.returncode == 0

    log_lines = []
    with open(report_path) as log:
        log_lines = log.readlines()

    # only expecting report for insert and extract
    assert len(log_lines) == 2

    insert_report = json.loads(log_lines[0])[0]
    assert insert_report["_OPERATION"] == "insert"
    assert len(insert_report) == 2

    extract_report = json.loads(log_lines[1])[0]
    assert extract_report["_OPERATION"] == "extract"
    assert len(extract_report) == 2


# outconf tests

# output configurations defined in "src/configs/base_outconf.c4m"
outconf = [
    "insert",
    "extract",
    "env",
    "exec",
    "delete",
    "load",
    "dump",
    "docker",
    "build",
    "push",
    "setup",
    "help",
    "fail",
    "heartbeat",
]


# checks if the outconfs we have defined are the same
# if this is failing, something has changed in base_outconf.c4m and tests need to be updated
def test_validate_outconf_operations():
    base_outconf_file = Path(__file__).parent.parent / "src/configs/base_outconf.c4m"
    base_outconf_elements = []
    with open(base_outconf_file) as file:
        file_text = file.read()
        for line in file_text.splitlines():
            # expecting outconf def of form "outconf [operation] {"
            if "outconf" in line and "{" in line:
                words = line.split()
                base_outconf_elements.append(words[1])

    assert set(outconf) == set(
        base_outconf_elements
    ), "specified outconf operations have changed and needs to be updated"


# returns a map of profile names to enabled keys for that profile
# that are defined in test_config_file + base_profiles
def _get_profiles(test_config_file: str) -> (Dict[str, Any], Dict[str, Any]):
    profiles = {}
    # load base profiles
    with open(BASE_PROFILES) as file:
        data = file.read()
        for line in data.splitlines():
            if line.startswith("profile "):
                profile_name = line.split()[1]
                assert (
                    profile_name not in profiles
                ), "base profile definitions should not have duplicates"
                profiles[profile_name] = _get_profile_keys(profile_name, data, [])

    # map of operation to map of chalk/artifact/host to profile name
    outconf = {}
    # load base outconf
    with open(BASE_OUTCONF) as file:
        data = file.read()
        for line in data.splitlines():
            if line.startswith("outconf "):
                outconf_name = line.split()[1]
                assert (
                    outconf_name not in outconf
                ), "base outconf definitions should not have duplicates"
                outconf[outconf_name] = _get_outconf_keys(outconf_name, data, {})

    # load profiles from incoming config, if any
    with open(CONFIGFILES / test_config_file) as file:
        data = file.read()
        for line in data.splitlines():
            if line.startswith("profile "):
                profile_name = line.split()[1]
                # there may be a duplicate in the loaded config file that overwrites (ex: enables or disables) some keys from the base profile
                if profile_name in profiles:
                    profiles[profile_name] = _get_profile_keys(
                        profile_name, data, profiles[profile_name]
                    )
                else:
                    profiles[profile_name] = _get_profile_keys(profile_name, data, [])
            elif line.startswith("outconf "):
                outconf_name = line.split()[1]
                if outconf_name in outconf:
                    outconf[outconf_name] = _get_outconf_keys(
                        outconf_name, data, outconf[outconf_name]
                    )
                else:
                    outconf[outconf_name] = _get_outconf_keys(outconf_name, data, {})

    return profiles, outconf


# returns profile keys from config for specified profile name and does some very basic validation
# may have incoming keys that need to be turned off
def _get_profile_keys(
    profile_name: str, data: str, existing_keys: List[str] = []
) -> List[str]:
    # start at first { after profile name
    profile_start = data.find("{", data.find("profile " + profile_name))
    # end at first } after -- assumes that there will be no {} inside profile definition
    profile_end = data.find("\n}\n", profile_start)
    profile_data = data[profile_start + 1 : profile_end]

    for line in profile_data.splitlines():
        line = line.strip()
        # skip comments and lines that don't start with key
        comment_start = line.find("#")
        if comment_start != -1:
            line = (line[:comment_start]).strip()
        if line == "" or not line.startswith("key."):
            continue

        _line = line.split("=")
        assert len(_line) == 2

        # check enabled, and store enabled keys only
        enabled = _line[1].strip()
        assert enabled in ["true", "false"]

        _key = _line[0].strip().split(".")
        assert _key[0] == "key"
        key = _key[1]

        if enabled == "false":
            # if disabled, remove from key list
            if key in existing_keys:
                existing_keys.remove(key)
        else:
            # otherwise add to key list
            if key not in existing_keys:
                existing_keys.append(key)

    return existing_keys


def _get_outconf_keys(
    operation_name: str, data: str, existing_operation_outconf: Dict[str, Any] = {}
):
    # start at first { after operation name
    outconf_start = data.find("{", data.find("outconf " + operation_name))
    # end at first } after -- assumes that there will be no {} inside definition
    outconf_end = data.find("}", outconf_start)
    outconf_data = data[outconf_start + 1 : outconf_end]

    for line in outconf_data.splitlines():
        line = line.strip()
        # skip comments
        comment_start = line.find("#")
        if comment_start != -1:
            line = (line[:comment_start]).strip()
        if line == "":
            continue
        # store report type to profile name
        var = line.split(":")
        existing_operation_outconf[var[0].strip()] = var[1].strip("\"' ")
    return existing_operation_outconf


def _validate_chalk_report_keys(
    report: Dict[str, Any],
    operation: str,
    profile_keys: Dict[str, Any],
    outconf: Dict[str, Any],
):
    host_profile = outconf[operation]["host_report"]
    host_profile_keys = profile_keys[host_profile]
    _validate_profile_keys(report, host_profile_keys)
    # artifact keys only checked if "_CHALKS" enabled in reporting
    if "_CHALKS" in host_profile_keys:
        assert "_CHALKS" in report
        artifact_profile = outconf[operation]["artifact_report"]
        artifact_profile_keys = profile_keys[artifact_profile]
        for _chalk in report["_CHALKS"]:
            _validate_profile_keys(_chalk, artifact_profile_keys)
    else:
        assert "_CHALKS" not in report


def _validate_profile_keys(report: Dict[str, Any], expected_keys: List[str]):
    # not all expected keys will show up in the report if they can't be found
    # but we shouldn't have extra keys that aren't defined
    assert len(report) <= len(expected_keys)
    for key in report:
        assert key in expected_keys
    return


# tests outconf profiles for non-docker operations
@pytest.mark.parametrize(
    "test_config_file",
    [
        ("profiles/empty_profile.conf"),
        ("profiles/default.conf"),
        ("profiles/minimal_profile.conf"),
        ("profiles/large_profile.conf"),
    ],
)
@pytest.mark.parametrize(
    "use_embedded",
    [
        True,
        False,
    ],
)
def test_profiles(
    tmp_data_dir: Path, chalk_copy: Chalk, test_config_file: str, use_embedded: bool
):
    # call chalk load on test config
    load_proc = chalk_copy.load(CONFIGFILES / test_config_file, use_embedded)
    #  we expect the load to succeed
    assert load_proc.returncode == 0, "load valid config should have succeeded"
    assert not any(x in load_proc.stderr.decode() for x in parse_error)

    # using "ls" for test binary
    shutil.copy("/bin/ls", tmp_data_dir)
    ls_path = tmp_data_dir / "ls"
    assert ls_path.exists(), "bin copy went wrong"

    profile_definitions, outconf_definitions = _get_profiles(test_config_file)

    # insert report should have keys listed
    insert_report = chalk_copy.insert(ls_path)[0]
    _validate_chalk_report_keys(
        insert_report, "insert", profile_definitions, outconf_definitions
    )

    # check that binary has the correct chalk mark
    chalk_mark = {}
    with open(ls_path, mode="rb") as file:
        text = str(file.read())
        # MAGIC must always be present in chalk mark and marks the beginning of the json
        assert MAGIC in text
        chalk_start = text.rfind("{", 0, text.find(MAGIC))
        chalk_end = text.rfind("}", chalk_start)
        chalk_str = text[chalk_start : chalk_end + 1]
        chalk_mark = json.loads(chalk_str)
    assert len(chalk_mark) != 0, "chalk mark in binary should not be empty"

    # no matter what's defined in the profile, minimal key set below needs to be in chalk mark
    minimal_chalk = [
        "MAGIC",
        "CHALK_ID",
        "CHALK_VERSION",
        "METADATA_HASH",
        "METADATA_ID",
    ]
    for key in minimal_chalk:
        assert key in chalk_mark
        # remove so we don't have duplicates later
        del chalk_mark[key]
    # validate other things in the chalk mark profile
    chalk_profile = outconf_definitions["insert"]["chalk"]
    _validate_profile_keys(
        chalk_mark,
        [x for x in profile_definitions[chalk_profile] if x not in minimal_chalk],
    )

    # extract
    extract_report = chalk_copy.extract(ls_path)[0]
    _validate_chalk_report_keys(
        extract_report, "extract", profile_definitions, outconf_definitions
    )

    # exec
    exec_report = chalk_copy.exec(ls_path)[0]
    _validate_chalk_report_keys(
        exec_report, "exec", profile_definitions, outconf_definitions
    )

    # delete
    delete_report = chalk_copy.delete(ls_path)[0]
    _validate_chalk_report_keys(
        delete_report, "delete", profile_definitions, outconf_definitions
    )
