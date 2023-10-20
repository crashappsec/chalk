import os
import pytest

from pathlib import Path

from .chalk.runner import Chalk
from .utils.log import get_logger
from .conf import (
    LS_PATH,
    CONFIGS,
)

logger = get_logger()


def get_current_config(tmp_data_dir: Path, chalk: Chalk) -> str:
    output = tmp_data_dir / "output.c4m"
    if output.is_file():
        os.remove(output)
    chalk.dump(output)
    with open(output) as f:
        lines = f.read()
        return lines


@pytest.mark.parametrize(
    "test_config_file",
    [
        "composable/valid/compliance_docker/compliance_docker.c4m",
        "composable/valid/compliance_docker_remote/compliance_docker.c4m",
    ],
)
@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
@pytest.mark.parametrize(
    "replace",
    [
        # TODO: enable these once the replace bug has been fixed
        # True,
        False,
    ],
)
def test_composable_valid(
    tmp_data_dir: Path,
    copy_files: list[Path],
    chalk_copy: Chalk,
    test_config_file: str,
    replace: bool,
):
    # load the composable config
    _load = chalk_copy.load(
        config=(CONFIGS / test_config_file).absolute(),
        replace=replace,
        stdin=b"\n" * 2**15,
        log_level="trace",
    )
    assert _load.report["_OPERATION"] == "load"
    assert "_OP_ERRORS" not in _load.report

    # check chalk dump to validate that loaded config matches
    current_config_path = tmp_data_dir / "output.c4m"
    chalk_copy.dump(current_config_path)
    current_config = ""
    with open(current_config_path) as f:
        current_config = f.read()

    # expecting output config has `use xxx from yyy`
    config_name = test_config_file.split("/")[-1].removesuffix(".c4m")
    config_path = "/".join((CONFIGS / test_config_file).__str__().split("/")[:-1])
    use_output = f'use {config_name} from "{config_path}"'
    assert use_output in current_config

    # basic check insert operation
    bin_path = copy_files[0]
    _insert = chalk_copy.insert(artifact=bin_path)
    for report in _insert.reports:
        assert report["_OPERATION"] == "insert"

        if "_OP_ERRORS" in report:
            logger.error("report has unexpected errors", errors=report["_OP_ERRORS"])
        assert "_OP_ERRORS" not in report


@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_composable_multiple(
    tmp_data_dir: Path,
    copy_files: list[Path],
    chalk_copy: Chalk,
):
    # if we load multiple valid configs in a row
    # they should all show up in chalk dump
    sample_configs = [
        CONFIGS / "composable/valid/multiple/sample_1.c4m",
        CONFIGS / "composable/valid/multiple/sample_2.c4m",
        CONFIGS / "composable/valid/multiple/sample_3.c4m",
    ]

    # successively load all of them
    for config in sample_configs:
        _load = chalk_copy.load(
            config=config.absolute(),
            replace=False,
            stdin=b"\n" * 2**15,
            log_level="trace",
            expected_success=True,
        )
        assert _load.report["_OPERATION"] == "load"
        assert "_OP_ERRORS" not in _load.report

    # check chalk dump to validate that loaded config matches
    current_config_path = tmp_data_dir / "output.c4m"
    chalk_copy.dump(current_config_path)
    current_config = ""
    with open(current_config_path) as f:
        current_config = f.read()

    # expecting output config has `use xxx from yyy`
    # for each config in sample configs
    for config in sample_configs:
        config_name = config.__str__().split("/")[-1].removesuffix(".c4m")
        config_path = "/".join(config.__str__().split("/")[:-1])
        use_output = f'use {config_name} from "{config_path}"'
        assert use_output in current_config

    # basic check insert operation
    bin_path = copy_files[0]
    _insert = chalk_copy.insert(artifact=bin_path)
    for report in _insert.reports:
        assert report["_OPERATION"] == "insert"

        if "_OP_ERRORS" in report:
            logger.error("report has unexpected errors", errors=report["_OP_ERRORS"])
        assert "_OP_ERRORS" not in report


@pytest.mark.parametrize(
    "test_config_file, expected_error",
    [
        ("composable/invalid/circular/circular_1.c4m", "blah"),
        ("composable/invalid/invalid_file/invalid_file.c4m", "blah"),
        ("composable/invalid/invalid_remote/invalid_remote.c4m", "blah"),
    ],
)
def test_composable_invalid(test_config_file: str, expected_error: str):
    # TODO: fill this out
    return


@pytest.mark.parametrize(
    "test_config_file",
    [
        "composable/valid/multiple/sample_1.c4m",
    ],
)
@pytest.mark.parametrize(
    "replace",
    [
        True,
        # TODO: enable these once the replace bug has been fixed
        # False,
    ],
)
def test_composable_reload(
    tmp_data_dir: Path, chalk_copy: Chalk, test_config_file: str, replace: bool
):
    # load sample valid config
    config = CONFIGS / test_config_file
    chalk_copy.load(
        config=config.absolute(),
        replace=replace,
        stdin=b"\n" * 2**15,
        expected_success=True,
    )

    first_load_config = get_current_config(tmp_data_dir, chalk_copy)

    # load default config
    chalk_copy.run(command="load", params=["default"])
    default_load_config = get_current_config(tmp_data_dir, chalk_copy)

    # reload sample valid config and ensure default is overwritten
    chalk_copy.load(
        config=config.absolute(),
        replace=replace,
        stdin=b"\n" * 2**15,
        expected_success=True,
    )

    second_load_config = get_current_config(tmp_data_dir, chalk_copy)

    assert second_load_config != ""
    assert second_load_config != default_load_config
    assert second_load_config in first_load_config
