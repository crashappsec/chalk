import json
import os
import shutil
import stat
from contextlib import chdir
from datetime import timezone
from pathlib import Path
from subprocess import check_output
from tempfile import TemporaryDirectory
from typing import Any, Dict, Optional

import dateutil.parser

from .chalk.runner import Chalk
from .utils.bin import sha256
from .utils.log import get_logger

logger = get_logger()

# FIXME make fixture
chalk = Chalk(binary=(Path(__file__).parent.parent / "chalk").resolve())


def _insert_and_extract_on_artifact(chalk: Chalk, artifact: Path) -> Dict[str, Any]:
    chalk.run(
        chalk_cmd="insert",
        target=artifact,
    )
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


def insert_and_extract_on_artifact(
    *, chalk: Chalk, artifact: Path, change_cwd: Optional[Path] = None
) -> Dict[str, Any]:
    if change_cwd is None:
        return _insert_and_extract_on_artifact(chalk, artifact)

    with chdir(change_cwd):
        return _insert_and_extract_on_artifact(chalk, artifact)


def test_insert_extract_timestamps_ls():
    with TemporaryDirectory() as _tmp_bin:
        tmp_bin = Path(_tmp_bin)
        artifact = Path(tmp_bin) / "ls"
        shutil.copy("/bin/ls", artifact)

        output = insert_and_extract_on_artifact(
            chalk=chalk, artifact=artifact, change_cwd=tmp_bin
        )

        assert output["_OPERATION"] == "extract"
        assert len(output["_CHALKS"]) == 1
        _chalk = output["_CHALKS"][0]
        assert _chalk["ARTIFACT_TYPE"] == "ELF"
        assert _chalk["ARTIFACT_PATH"] == str(artifact)
        assert _chalk["HASH"] == sha256(Path("/bin/ls"))
        assert _chalk["INJECTOR_PLATFORM"] == output["_OP_PLATFORM"]
        assert _chalk["INJECTOR_COMMIT_ID"] == output["_OP_CHALKER_COMMIT_ID"]
        assert (
            # timestamp in milliseconds so multiply by 1000
            dateutil.parser.isoparse(output["_DATETIME"])
            .replace(tzinfo=timezone.utc)
            .timestamp()
            * 1000
            == output["_TIMESTAMP"]
        )
        assert output["_DATETIME"] > _chalk["DATETIME"]
        rand1 = _chalk["CHALK_RAND"]
        timestamp1 = output["_TIMESTAMP"]

        # repeat the above process re-chalking the same binary and assert that the
        # fields are appropriately updated
        output = insert_and_extract_on_artifact(
            chalk=chalk, artifact=artifact, change_cwd=tmp_bin
        )

        # we still should have only one chalk
        assert len(output["_CHALKS"]) == 1

        # but this time timestamps and random values should be different
        _chalk = output["_CHALKS"][0]
        assert rand1 != _chalk["CHALK_RAND"]
        timestamp2 = output["_TIMESTAMP"]
        assert timestamp1 < timestamp2
        last_chalk_datetime = _chalk["DATETIME"]

        # do one final extraction
        extracted = chalk.run(
            chalk_cmd="extract",
            target=artifact,
            params=["--log-level=none"],
        )
        try:
            output = json.loads(extracted.stdout, strict=False)
        except json.decoder.JSONDecodeError:
            logger.error("Could not decode json", raw=extracted.stdout)

        _chalk = output["_CHALKS"][0]
        assert timestamp2 == output["_TIMESTAMP"]
        assert last_chalk_datetime == _chalk["DATETIME"]

        # ensure that the binary executes properly although chalked
        st = os.stat(artifact)
        os.chmod(artifact, st.st_mode | stat.S_IEXEC)
        assert (
            check_output([str(artifact)]).decode() == check_output(["/bin/ls"]).decode()
        )


def test_insert_extract_directory():
    with TemporaryDirectory() as tmp_bin:
        artifact = Path(tmp_bin)
        shutil.copy("/bin/ls", artifact / "ls")
        shutil.copy("/bin/date", artifact / "date")

        output = insert_and_extract_on_artifact(
            chalk=chalk, artifact=artifact, change_cwd=artifact
        )

        assert output["_OPERATION"] == "extract"
        assert len(output["_CHALKS"]) == 2
        paths = sorted([c["ARTIFACT_PATH"] for c in output["_CHALKS"]])
        assert paths == sorted([str(artifact / "ls"), str(artifact / "date")])


def test_virtual():
    with TemporaryDirectory() as _tmp_dir:
        tmp_dir = Path(_tmp_dir)

        shutil.copy("/bin/ls", tmp_dir / "ls")

        with chdir(_tmp_dir):
            chalk.run(
                chalk_cmd="insert",
                params=["--log-level=none", "--virtual"],
                target=tmp_dir / "ls",
            )
            extracted = chalk.run(
                chalk_cmd="extract",
                target=tmp_dir / "ls",
                params=["--log-level=none"],
            )

            try:
                virtual_extract_out = json.loads(extracted.stderr, strict=False)
            except json.decoder.JSONDecodeError:
                logger.error("Could not decode json", raw=extracted.stdout)
                raise

            assert (
                "_UNMARKED" in virtual_extract_out
                and "_CHALKS" not in virtual_extract_out
            ), "Expected that artifact to not not have chalks embedded"

            vjsonf = tmp_dir / "virtual-chalk.json"
            assert vjsonf.is_file(), "virtual-chalk.json not found"
            vjson = json.loads(vjsonf.read_bytes())
            assert "CHALK_ID" in vjson
