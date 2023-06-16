import json
from pathlib import Path
from typing import Any, Dict

from .log import get_logger

logger = get_logger()

MAGIC = "dadfedabbadabbed"


class ArtifactInfo:
    type: str
    hash: str

    def __init__(self, type: str, hash: str) -> None:
        self.type = type
        self.hash = hash


# `virtual-chalk.json` file found after chalking with `--virtual` enabled
def validate_virtual_chalk(
    tmp_data_dir: Path, artifact_map: Dict[str, ArtifactInfo], virtual: bool
):
    try:
        vjsonf = tmp_data_dir / "virtual-chalk.json"
        if not virtual:
            assert (
                not vjsonf.is_file()
            ), "virtual-chalk.json should not have been created!"
            return

        assert vjsonf.is_file(), "virtual-chalk.json not found"
        virtual_chalks_jsonl = vjsonf.read_text()

        # jsonl is one json object per line, NOT array of json
        # number of json object is number of artifacts chalked
        all_vchalks = virtual_chalks_jsonl.splitlines()
        assert len(all_vchalks) == len(artifact_map)

        for vchalk in all_vchalks:
            vjson = json.loads(vchalk)

            assert "CHALK_ID" in vjson
            assert vjson["MAGIC"] == MAGIC, "virtual chalk magic value incorrect"
    except json.JSONDecodeError as e:
        logger.error("unable to decode json", error=e)
        raise
    except AssertionError as e:
        logger.error("virtual-chalk validation failed", error=e)
        raise
    except KeyError as e:
        logger.error("key not found in vjson", error=e)
        raise


# chalk report is created after `chalk insert` operation
def validate_chalk_report(
    chalk_report: Dict[str, Any],
    artifact_map: Dict[str, ArtifactInfo],
    virtual: bool,
):
    try:
        assert chalk_report["_OPERATION"] == "insert"

        assert "_CHALKS" in chalk_report
        assert len(chalk_report["_CHALKS"]) == len(
            artifact_map
        ), "chalks missing from report"

        for chalk in chalk_report["_CHALKS"]:
            path = chalk["ARTIFACT_PATH"]
            assert path in artifact_map, "chalked artifact incorrect"
            artifact = artifact_map[path]

            # artifact specific fields
            assert (
                artifact.type == chalk["ARTIFACT_TYPE"]
            ), "artifact type doesn't match"
            assert artifact.hash == chalk["HASH"], "artifact hash doesn't match"
            assert virtual == chalk["_VIRTUAL"]
    except AssertionError as e:
        logger.error("chalk report validation failed", error=e)
        raise
    except KeyError as e:
        logger.error("key not found in chalk report", error=e)
        raise


# extracted chalk is created after `chalk extract` operation
def validate_extracted_chalk(
    extracted_chalk: Dict[str, Any],
    artifact_map: Dict[str, ArtifactInfo],
    virtual: bool,
) -> None:
    assert (
        extracted_chalk["_OPERATION"] == "extract"
    ), "operation expected to be extract"

    if virtual:
        assert (
            "_UNMARKED" in extracted_chalk and "_CHALKS" not in extracted_chalk
        ), "Expected that artifact to not have chalks embedded"
        assert len(extracted_chalk["_UNMARKED"]) == len(
            artifact_map
        ), "wrong number of unmarked chalks"
    else:
        assert (
            "_UNMARKED" not in extracted_chalk and "_CHALKS" in extracted_chalk
        ), "Expected that artifact to have chalks embedded"
        assert len(extracted_chalk["_CHALKS"]) == len(
            artifact_map
        ), "wrong number of chalks"

    # there should not be operation errors
    try:
        assert len(extracted_chalk["_OP_ERRORS"]) == 0
    except KeyError:
        # fine if this key doesn't exist
        pass

    if virtual:
        for path in extracted_chalk["_UNMARKED"]:
            assert path in artifact_map, "path not found"
    else:
        for chalk in extracted_chalk["_CHALKS"]:
            path = chalk["ARTIFACT_PATH"]
            assert path in artifact_map, "path not found"
            artifact_info = artifact_map[path]

            assert artifact_info.hash == chalk["HASH"]
            assert artifact_info.type == chalk["ARTIFACT_TYPE"]

            # top level vs chalk-level sanity check
            assert chalk["INJECTOR_PLATFORM"] == extracted_chalk["_OP_PLATFORM"]
            assert (
                chalk["INJECTOR_COMMIT_ID"] == extracted_chalk["_OP_CHALKER_COMMIT_ID"]
            )
