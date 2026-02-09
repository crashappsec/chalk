# Copyright (c) 2023-2024, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
"""
help + defaults: not tested, used for debugging
test basic config commands:
dump + load tested in test_config.py
docker commands are not tested here but as part of the docker codec tests in test_docker.py
exec commands are tested in test_exec.py as they are more involved
"""
import json
import re
from pathlib import Path

import pytest

from .chalk.runner import Chalk
from .conf import CONFIGS, DATE_PATH, LS_PATH, HELLO_GO_PATH
from .utils.dict import ANY
from .utils.log import get_logger
from .utils.os import run


logger = get_logger()


# tests multiple insertions and extractions on the same binary
@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_insert_extract_repeated(copy_files: list[Path], chalk: Chalk):
    artifact = copy_files[0]

    insert = chalk.insert(
        artifact=artifact,
        virtual=False,
        config=CONFIGS / "copy_report_template_keys.c4m",
    )
    insert.marks_by_path.contains({str(artifact): {}})

    extract = chalk.extract(artifact=artifact)

    assert extract.report.datetime > extract.mark.datetime

    # store chalk_rand and timestamp1 to compare against second chalk
    # chalk_rand may or may not have been lifted to host level
    rand1 = extract.mark.lifted["CHALK_RAND"]
    timestamp1 = extract.mark.datetime

    # repeat the above process re-chalking the same binary and assert that the
    # fields are appropriately updated
    insert2 = chalk.insert(artifact=artifact, virtual=False)
    insert2.marks_by_path.contains({str(artifact): {}})

    extract2 = chalk.extract(artifact=artifact)

    # but this time timestamps and random values should be different
    rand2 = extract2.mark.lifted["CHALK_RAND"]
    timestamp2 = extract2.mark.datetime

    assert rand1 != rand2
    assert timestamp1 < timestamp2

    # do one final extraction
    extract3 = chalk.extract(artifact=artifact)

    # report datetime is diff as its at extraction time
    # but chalkarm should stay consistent
    assert timestamp2 < extract3.report.datetime
    assert timestamp2 == extract3.mark.datetime

    # ensure that the binary executes properly although chalked
    assert run([str(artifact)]).text == run([str(LS_PATH)]).text


# test insertion and extraction on a directory with multiple binaries
@pytest.mark.parametrize(
    "copy_files", [[LS_PATH, DATE_PATH, HELLO_GO_PATH]], indirect=True
)
def test_insert_extract_directory(
    tmp_data_dir: Path, copy_files: list[Path], chalk: Chalk
):
    insert = chalk.insert(artifact=tmp_data_dir, virtual=False)
    assert insert.marks_by_path.contains({str(i): {} for i in copy_files})

    assert chalk.extract(artifact=tmp_data_dir)


@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_insert_extract_delete(copy_files: list[Path], chalk: Chalk):
    artifact = copy_files[0]

    # insert
    insert = chalk.insert(artifact=artifact, virtual=False)
    assert insert.marks_by_path.contains({str(artifact): {}})
    insert_1_hash = insert.report["_CHALKS"][0]["HASH"]

    # extract
    extract = chalk.extract(artifact=artifact)

    # delete
    delete = chalk.run(command="delete", target=artifact)

    for key in ["HASH", "_OP_ARTIFACT_PATH", "_OP_ARTIFACT_TYPE"]:
        assert extract.mark[key] == delete.mark[key]

    # extract again and we shouldn't get anything this time
    assert chalk.extract(artifact=artifact, expecting_chalkmarks=False)

    # insert again and check that hash is the same as first insert
    insert2 = chalk.insert(artifact=artifact, virtual=False)
    insert_2_hash = insert2.report["_CHALKS"][0]["HASH"]
    assert insert_1_hash == insert_2_hash


def test_version(chalk: Chalk):
    result = chalk.run(command="version", no_color=True, expecting_report=False)
    printed_version = result.find("Chalk Version", words=2).split()[-1]

    nimble = (
        Path(__file__).parent.parent.parent / "src" / "configs" / "base_keyspecs.c4m"
    )
    # version output should match the version in base_keyspecs.c4m
    internal_version = next(
        i.split("=")[1].strip().strip('"')
        for i in nimble.read_text().splitlines()
        if i.startswith("chalk_version")
    )

    assert printed_version == internal_version


@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_env(
    chalk: Chalk,
    copy_files: list[Path],
    tmp_data_dir: Path,
):
    insert = chalk.insert(copy_files[0])
    (tmp_data_dir / "chalk.json").write_text(json.dumps(insert.mark))

    env = chalk.run(
        command="env",
        env={
            "LAMBDA_TASK_ROOT": str(tmp_data_dir),
            "AWS_LAMBDA_RUNTIME_API": "localhost:8585",
            "AWS_LAMBDA_FUNCTION_NAME": "test",
        },
    )

    # fields to check: platform, hostinfo, nodename
    assert run(["uname", "-s"]).text in env.report["_OP_HOST_SYSNAME"]
    assert run(["uname", "-r"]).text in env.report["_OP_HOST_RELEASE"]
    assert run(["uname", "-v"]).text in env.report["_OP_HOST_VERSION"]
    assert run(["uname", "-n"]).text in env.report["_OP_HOST_NODENAME"]
    assert run(["uname", "-m"]).text in env.report["_OP_HOST_MACHINE"]

    # serverless should report chalkmark from task path, if present
    assert env.mark == insert.mark


@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
@pytest.mark.parametrize(
    "config",
    [
        CONFIGS / "attestation" / "embed.c4m",
        CONFIGS / "attestation" / "get.c4m",
    ],
)
def test_setup(
    copy_files: list[Path],
    chalk_copy: Chalk,
    config: Path,
    server_http: str,
):
    """
    check that after setup attestion works for all key providers
    """
    env = {
        "CHALK_GET_URL": f"{server_http}/cosign",
    }
    chalk_copy.load(config, replace=False)
    setup = chalk_copy.run(command="setup", env=env, tty=True)
    assert setup.mark.contains(
        {
            "$CHALK_PUBLIC_KEY": re.compile(r"^-----BEGIN PUBLIC KEY"),
            "$CHALK_ENCRYPTED_PRIVATE_KEY": re.compile(
                r"^-----BEGIN ENCRYPTED SIGSTORE PRIVATE KEY"
            ),
            "SIGNATURE": ANY,
            "INJECTOR_PUBLIC_KEY": setup.mark["$CHALK_PUBLIC_KEY"],
        }
    )

    if "CHALK_PASSWORD" in setup.text:
        env["CHALK_PASSWORD"] = setup.find("CHALK_PASSWORD").split("=", 1)[1]

    insert = chalk_copy.insert(copy_files[0], env=env)
    assert insert.mark.contains(
        {
            "INJECTOR_PUBLIC_KEY": setup.mark["$CHALK_PUBLIC_KEY"],
            "SIGNATURE": ANY,
        }
    )

    extract = chalk_copy.extract(copy_files[0], env=env)
    assert extract.mark.contains(
        {
            "INJECTOR_PUBLIC_KEY": setup.mark["$CHALK_PUBLIC_KEY"],
            "SIGNATURE": insert.mark["SIGNATURE"],
            "_VALIDATED_SIGNATURE": True,
        }
    )


@pytest.mark.parametrize(
    "config, require_password",
    [
        (CONFIGS / "attestation" / "embed.c4m", True),
        # note get provider does not support reading existing key
    ],
)
@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_setup_existing_keys(
    tmp_data_dir: Path,
    chalk_copy: Chalk,
    random_hex: str,
    copy_files: list[Path],
    config: Path,
    server_http: str,
    require_password: bool,
):
    """
    needs to display password, and public and private key info in chalk
    """
    password = (random_hex * 3)[:24]  # at least 24 bytes are required for PRP
    assert run(
        ["cosign", "generate-key-pair", "--output-key-prefix", "chalk"],
        env={"COSIGN_PASSWORD": password},
    )
    public = (tmp_data_dir / "chalk.pub").read_text()
    private = (tmp_data_dir / "chalk.key").read_text()
    env = {
        "CHALK_PASSWORD": password,
    }

    chalk_copy.load(config, replace=False)
    setup = chalk_copy.run(command="setup", env=env)
    assert setup.mark.contains(
        {
            "$CHALK_PUBLIC_KEY": public,
            "$CHALK_ENCRYPTED_PRIVATE_KEY": private,
            "SIGNATURE": ANY,
            "INJECTOR_PUBLIC_KEY": public,
        }
    )

    if not require_password:
        del env["CHALK_PASSWORD"]

    insert = chalk_copy.insert(copy_files[0], env=env)
    assert insert.mark.contains(
        {
            "INJECTOR_PUBLIC_KEY": setup.mark["$CHALK_PUBLIC_KEY"],
            "SIGNATURE": ANY,
        }
    )

    extract = chalk_copy.extract(copy_files[0], env=env)
    assert extract.mark.contains(
        {
            "INJECTOR_PUBLIC_KEY": setup.mark["$CHALK_PUBLIC_KEY"],
            "SIGNATURE": insert.mark["SIGNATURE"],
            "_VALIDATED_SIGNATURE": True,
        }
    )
