import json
import os
import shutil
import stat
from datetime import timezone
from pathlib import Path
from subprocess import check_output, run

import dateutil.parser

from .chalk.runner import Chalk
from .utils.bin import sha256
from .utils.log import get_logger
from .utils.validate import (
    ArtifactInfo,
    validate_chalk_report,
    validate_extracted_chalk,
    validate_virtual_chalk,
)

logger = get_logger()

# test basic commands for insert, extract, delete
bin_path = "/bin/ls"
assert Path(bin_path).is_file(), f"{bin_path} does not exist!"
bin_hash = sha256(Path(bin_path))


# tests multiple insertions and extractions on the same binary
def test_insert_extract_repeated(tmp_data_dir: Path, chalk: Chalk):
    artifact = tmp_data_dir / "ls"
    shutil.copy(bin_path, artifact)

    artifact_info = {str(artifact): ArtifactInfo(type="ELF", hash=bin_hash)}

    chalk_reports = chalk.insert(artifact=artifact, virtual=False)
    assert len(chalk_reports) == 1
    chalk_report = chalk_reports[0]
    validate_chalk_report(
        chalk_report=chalk_report, artifact_map=artifact_info, virtual=False
    )

    extracted_chalks = chalk.extract(artifact=artifact)
    assert len(extracted_chalks) == 1
    single_chalk = extracted_chalks[0]
    validate_extracted_chalk(
        extracted_chalk=single_chalk, artifact_map=artifact_info, virtual=False
    )
    validate_virtual_chalk(
        tmp_data_dir=tmp_data_dir, artifact_map=artifact_info, virtual=False
    )

    _chalk = single_chalk["_CHALKS"][0]
    assert (
        # timestamp in milliseconds so multiply by 1000
        dateutil.parser.isoparse(single_chalk["_DATETIME"])
        .replace(tzinfo=timezone.utc)
        .timestamp()
        * 1000
        == single_chalk["_TIMESTAMP"]
    )
    assert single_chalk["_DATETIME"] > _chalk["DATETIME"]

    # store chalk_rand and timestamp1 to compare against second chalk
    rand1 = _chalk["CHALK_RAND"]
    timestamp1 = single_chalk["_TIMESTAMP"]

    # repeat the above process re-chalking the same binary and assert that the
    # fields are appropriately updated
    chalk_reports_2 = chalk.insert(artifact=artifact, virtual=False)
    validate_chalk_report(
        chalk_report=chalk_reports_2[0], artifact_map=artifact_info, virtual=False
    )

    extracted_chalks_2 = chalk.extract(artifact=artifact)
    validate_extracted_chalk(
        extracted_chalk=extracted_chalks_2[0], artifact_map=artifact_info, virtual=False
    )

    # but this time timestamps and random values should be different
    _chalk = extracted_chalks_2[0]["_CHALKS"][0]
    assert rand1 != _chalk["CHALK_RAND"]
    timestamp2 = extracted_chalks_2[0]["_TIMESTAMP"]
    assert timestamp1 < timestamp2
    last_chalk_datetime = _chalk["DATETIME"]

    # do one final extraction
    extracted = chalk.run(
        chalk_cmd="extract",
        target=artifact,
        params=["--log-level=none"],
    )
    assert extracted
    extracted_chalks_3 = json.loads(extracted.stdout, strict=False)
    # basic fields
    validate_extracted_chalk(
        extracted_chalk=extracted_chalks_3[0], artifact_map=artifact_info, virtual=False
    )
    _chalk = extracted_chalks_3[0]["_CHALKS"][0]
    # _TIMESTAMP is time at extraction time, so these will be different
    assert timestamp2 < extracted_chalks_3[0]["_TIMESTAMP"]
    assert last_chalk_datetime == _chalk["DATETIME"]

    # ensure that the binary executes properly although chalked
    st = os.stat(artifact)
    os.chmod(artifact, st.st_mode | stat.S_IEXEC)
    assert check_output([str(artifact)]).decode() == check_output([bin_path]).decode()


# test insertion and extraction on a directory with multiple binaries
def test_insert_extract_directory(tmp_data_dir: Path, chalk: Chalk):
    artifact = tmp_data_dir

    assert Path(bin_path).is_file(), f"{bin_path} does not exist!"
    shutil.copy(bin_path, artifact / "ls")

    date_path = "/bin/date"
    assert Path(date_path).is_file(), f"{date_path} does not exist!"
    shutil.copy(date_path, artifact / "date")
    date_hash = sha256(Path(date_path))

    artifact_info = {
        str(tmp_data_dir / "ls"): ArtifactInfo(type="ELF", hash=bin_hash),
        str(tmp_data_dir / "date"): ArtifactInfo(type="ELF", hash=date_hash),
    }

    chalk_reports = chalk.insert(artifact=artifact, virtual=False)
    validate_chalk_report(
        chalk_report=chalk_reports[0], artifact_map=artifact_info, virtual=False
    )

    output = chalk.extract(artifact=artifact)
    validate_extracted_chalk(
        extracted_chalk=output[0], artifact_map=artifact_info, virtual=False
    )
    validate_virtual_chalk(
        tmp_data_dir=tmp_data_dir, artifact_map=artifact_info, virtual=False
    )


def test_insert_extract_delete(tmp_data_dir: Path, chalk: Chalk):
    artifact = tmp_data_dir / "ls"

    assert Path(bin_path).is_file(), f"{bin_path} does not exist!"
    shutil.copy(bin_path, artifact)
    artifact_info = {str(artifact): ArtifactInfo(type="ELF", hash=bin_hash)}

    # insert
    chalk_reports = chalk.insert(artifact=artifact, virtual=False)
    validate_chalk_report(
        chalk_report=chalk_reports[0], artifact_map=artifact_info, virtual=False
    )

    # extract
    chalk_extract = chalk.extract(artifact=artifact)
    validate_extracted_chalk(
        extracted_chalk=chalk_extract[0], artifact_map=artifact_info, virtual=False
    )

    # delete
    chalk_delete = chalk.run(
        chalk_cmd="delete", target=artifact, params=["--log-level=none"]
    )
    assert chalk_delete.returncode == 0

    # delete operation report info validation
    delete_stdout = json.loads(chalk_delete.stdout, strict=False)
    assert len(delete_stdout) == 1
    deleted_chalk = delete_stdout[0]

    assert deleted_chalk["_OPERATION"] == "delete"

    extracted_subchalk = chalk_extract[0]["_CHALKS"][0]
    deleted_subchalk = deleted_chalk["_CHALKS"][0]
    for key in ["HASH", "_OP_ARTIFACT_PATH", "_OP_ARTIFACT_TYPE"]:
        assert extracted_subchalk[key] == deleted_subchalk[key]

    # extract again and we shouldn't get anything this time
    chalk_extract_2 = chalk.extract(artifact=artifact)
    assert "_CHALKS" not in chalk_extract_2[0]


# help + defaults: not tested, used for debugging


# test basic config commands:
# dump, load
def test_dump_load(tmp_data_dir: Path, chalk: Chalk):
    validation_string = "TEST ERROR HERE XXXXXX"
    # output for updated config
    tmp_conf = tmp_data_dir / "testconf.conf"
    # copy chalk binary over to temp file since we are overwriting
    chalk_path = Path(__file__).parent.parent / "chalk"
    shutil.copy(chalk_path, tmp_data_dir)
    chalk = Chalk(binary=(tmp_data_dir / "chalk").resolve())

    # dump config to file
    dump_output = chalk.run(chalk_cmd="dump", params=[str(tmp_conf)])
    assert dump_output.returncode == 0

    # edit file (add an error output)
    assert tmp_conf.exists(), "testconf.conf not created"
    assert tmp_conf.is_file(), "testconf.conf must be a file and is not"
    with open(tmp_conf, "w+") as file:
        file_text = file.read()
        file_text = f'error("{validation_string}")' + file_text
        file.write(file_text)

    # load updated config and check that chalk binary was created
    load_output = chalk.run(chalk_cmd="load", params=[str(tmp_conf)])
    assert load_output.returncode == 0
    dir_obj = os.listdir(tmp_data_dir)
    assert "chalk" in dir_obj

    # run new chalk and check for error in log output
    chalk = Chalk(binary=(tmp_data_dir / "chalk").resolve())
    extract_output = chalk.run(chalk_cmd="extract", params=["."])
    assert extract_output.returncode == 0
    error_output = extract_output.stderr.decode()
    assert validation_string in error_output

    return


# docker commands are not tested here but as part of the docker codec tests


# exec commands are tested in test_exec as they are more involved


# version
def test_version(chalk: Chalk):
    version_proc = chalk.run(chalk_cmd="version")
    # this should never error
    assert version_proc.returncode == 0
    assert version_proc.stderr.decode() == ""

    # version output should match the version in chalk_internal.nimble
    internal_version = ""
    with open(r"../chalk_internal.nimble", "r") as file:
        lines = file.readlines()
        for line in lines:
            if "version" in line:
                internal_version = line.split("=")[1].strip().strip('"')
                # assuming it is the first one
                break
    assert internal_version != ""
    version_output = version_proc.stdout.decode()
    printed_version = ""
    for line in version_output.splitlines():
        if "Chalk version" in line:
            printed_version = line.split("Chalk version")[1].strip()
            break
    assert printed_version != ""
    assert printed_version == internal_version


# env
def test_env(chalk: Chalk):
    env_proc = chalk.run(chalk_cmd="env")
    # this should never error
    assert env_proc.returncode == 0
    assert env_proc.stderr.decode() == ""

    # env output should match system
    _stdout = env_proc.stdout.decode()
    env_output = json.loads(_stdout)[0]
    logger.info("!!!!")
    logger.info(env_output)

    # fields to check: platform, hostinfo, nodename
    _proc = run(args=["uname", "-s"], capture_output=True)
    assert _proc.stdout.decode().strip() in env_output["_OP_PLATFORM"]

    _proc = run(args=["uname", "-v"], capture_output=True)
    assert _proc.stdout.decode().strip() in env_output["_OP_HOSTINFO"]

    _proc = run(args=["uname", "-n"], capture_output=True)
    assert _proc.stdout.decode().strip() in env_output["_OP_NODENAME"]
