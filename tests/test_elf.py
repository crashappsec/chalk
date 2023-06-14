import json
import os
import shutil
import stat
from datetime import timezone
from pathlib import Path
from subprocess import check_output
from typing import Any, Dict, List

import dateutil.parser

from .chalk.runner import Chalk
from .utils.bin import sha256
from .utils.log import get_logger

logger = get_logger()


def _insert_and_extract_on_artifact(
    chalk: Chalk, artifact: Path, virtual: bool = False
) -> List[Dict[str, Any]]:
    params = []
    if virtual:
        params.append("--virtual")

    chalk.run(chalk_cmd="insert", target=artifact, params=params)
    extracted = chalk.run(
        chalk_cmd="extract",
        target=artifact,
        params=["--log-level=none"],
    )
    try:
        return json.loads(extracted.stderr, strict=False)
    except json.decoder.JSONDecodeError:
        logger.error("Could not decode json", raw=extracted.stdout)
        raise


def _validate_extracted_chalk(
    single_chalk: Dict[str, Any],
    # dict of path to hash
    artfact_info: Dict[str, str],
) -> None:
    assert single_chalk["_OPERATION"] == "extract", "operation expected to be extract"
    assert len(single_chalk["_CHALKS"]) == len(artfact_info), "wrong number of chalks"

    try:
        assert len(single_chalk["_OP_ERRORS"]) == 0
    except KeyError:
        # fine if this key doesn't exist
        pass

    for _chalk in single_chalk["_CHALKS"]:
        artifact_path = _chalk["ARTIFACT_PATH"]
        assert artfact_info[artifact_path] == _chalk["HASH"]

        assert _chalk["ARTIFACT_TYPE"] == "ELF"
        assert _chalk["INJECTOR_PLATFORM"] == single_chalk["_OP_PLATFORM"]
        assert _chalk["INJECTOR_COMMIT_ID"] == single_chalk["_OP_CHALKER_COMMIT_ID"]


# tests multiple insertions and extractions on the same binary
def test_insert_extract_repeated(tmp_data_dir: Path, chalk: Chalk):
    bin_path = "/bin/ls"
    assert Path(bin_path).is_file(), f"{bin_path} does not exist!"
    bin_hash = sha256(Path(bin_path))

    artifact = Path(tmp_data_dir) / "ls"
    shutil.copy(bin_path, artifact)

    chalks = _insert_and_extract_on_artifact(
        chalk=chalk, artifact=artifact, virtual=False
    )
    assert len(chalks) == 1
    single_chalk = chalks[0]
    _validate_extracted_chalk(
        single_chalk=single_chalk, artfact_info={str(artifact): bin_hash}
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

    # store chalk_rand and timestamp1 to compare agaisnt second chalk
    rand1 = _chalk["CHALK_RAND"]
    timestamp1 = single_chalk["_TIMESTAMP"]

    # repeat the above process re-chalking the same binary and assert that the
    # fields are appropriately updated
    second_chalk = _insert_and_extract_on_artifact(
        chalk=chalk, artifact=artifact, virtual=False
    )
    # basic fields
    _validate_extracted_chalk(
        single_chalk=second_chalk[0], artfact_info={str(artifact): bin_hash}
    )

    # but this time timestamps and random values should be different
    _chalk = second_chalk[0]["_CHALKS"][0]
    assert rand1 != _chalk["CHALK_RAND"]
    timestamp2 = second_chalk[0]["_TIMESTAMP"]
    assert timestamp1 < timestamp2
    last_chalk_datetime = _chalk["DATETIME"]

    # do one final extraction
    extracted = chalk.run(
        chalk_cmd="extract",
        target=artifact,
        params=["--log-level=none"],
    )

    third_chalk = json.loads(extracted.stderr, strict=False)
    # basic fields
    _validate_extracted_chalk(
        single_chalk=third_chalk[0], artfact_info={str(artifact): bin_hash}
    )
    _chalk = third_chalk[0]["_CHALKS"][0]
    # _TIMESTAMP is time at extraction time, so these will be different
    assert timestamp2 < third_chalk[0]["_TIMESTAMP"]
    assert last_chalk_datetime == _chalk["DATETIME"]

    # ensure that the binary executes properly although chalked
    st = os.stat(artifact)
    os.chmod(artifact, st.st_mode | stat.S_IEXEC)
    assert check_output([str(artifact)]).decode() == check_output(["/bin/ls"]).decode()


# test insertion and extraction on a directory with multiple binaries
def test_insert_extract_directory(tmp_data_dir: Path, chalk: Chalk):
    artifact = tmp_data_dir

    ls_path = "/bin/ls"
    assert Path(ls_path).is_file(), f"{ls_path} does not exist!"
    shutil.copy(ls_path, artifact / "ls")
    ls_hash = sha256(Path(ls_path))

    date_path = "/bin/date"
    assert Path(date_path).is_file(), f"{date_path} does not exist!"
    shutil.copy(date_path, artifact / "date")
    date_hash = sha256(Path(date_path))

    output = _insert_and_extract_on_artifact(
        chalk=chalk, artifact=artifact, virtual=False
    )

    _validate_extracted_chalk(
        single_chalk=output[0],
        artfact_info={
            str(artifact / "ls"): ls_hash,
            str(artifact / "date"): date_hash,
        },
    )


def test_virtual(tmp_data_dir: Path, chalk: Chalk):
    ls_path = "/bin/ls"
    assert Path(ls_path).is_file(), f"{ls_path} does not exist!"

    shutil.copy(ls_path, tmp_data_dir / "ls")
    ls_hash = sha256(Path(ls_path))

    virtual_extract_out = _insert_and_extract_on_artifact(
        chalk=chalk, artifact=tmp_data_dir, virtual=True
    )

    assert len(virtual_extract_out) == 1
    chalked = virtual_extract_out[0]
    # virtual output validation
    assert (
        "_UNMARKED" in chalked and "_CHALKS" not in chalked
    ), "Expected that artifact to not not have chalks embedded"
    assert len(chalked["_UNMARKED"]) == 1, "should only be one unmarked"
    assert chalked["_UNMARKED"][0] == str(tmp_data_dir / "ls")

    # store to compare later
    timestamp_1 = chalked["_TIMESTAMP"]

    try:
        assert len(chalked["_OP_ERRORS"]) == 0
    except KeyError:
        # fine if this key doesn't exist
        pass

    vjsonf = tmp_data_dir / "virtual-chalk.json"
    assert vjsonf.is_file(), "virtual-chalk.json not found"
    vjson = json.loads(vjsonf.read_bytes())
    assert "CHALK_ID" in vjson
    assert vjson["HASH"] == ls_hash

    # compare extractions
    proc = chalk.run(
        chalk_cmd="extract",
        target=tmp_data_dir / "ls",
        params=["--log-level=none"],
    )
    virtual_extract_2 = json.loads(proc.stderr, strict=False)
    assert timestamp_1 < virtual_extract_2[0]["_TIMESTAMP"]
