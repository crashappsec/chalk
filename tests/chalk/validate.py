# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

from ..conf import MAGIC, SHEBANG
from ..utils.log import get_logger


logger = get_logger()


@dataclass
class ArtifactInfo:
    type: str
    chalk_info: dict[str, Any] = field(default_factory=dict)
    host_info: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def path_type(cls, path: Path) -> str:
        if path.suffix == ".py":
            return "python"
        else:
            return "ELF"

    @classmethod
    def one_elf(cls, path: Path, chalk_info: Optional[dict[str, Any]] = None):
        return {
            str(path): cls(
                type=cls.path_type(path),
                chalk_info=chalk_info or {},
            )
        }

    @classmethod
    def all_shebangs(cls):
        return {
            str(i.resolve()): cls(type=cls.path_type(i))
            for i in Path().iterdir()
            if i.is_file() and i.read_text().startswith(SHEBANG)
        }


# `virtual-chalk.json` file found after chalking with `--virtual` enabled
def validate_virtual_chalk(
    tmp_data_dir: Path, artifact_map: dict[str, ArtifactInfo], virtual: bool
) -> dict[str, Any]:
    vjsonf = tmp_data_dir / "virtual-chalk.json"
    if not virtual or not artifact_map:
        assert not vjsonf.is_file(), "virtual-chalk.json should not have been created!"
        return {}

    assert vjsonf.is_file(), "virtual-chalk.json not found"
    virtual_chalks_jsonl = vjsonf.read_text()

    # jsonl is one json object per line, NOT array of json
    # number of json objects is number of artifacts chalked
    all_vchalks = virtual_chalks_jsonl.splitlines()
    assert len(all_vchalks) == len(artifact_map)

    for vchalk in all_vchalks:
        vjson = json.loads(vchalk)

        assert "CHALK_ID" in vjson
        assert vjson["MAGIC"] == MAGIC, "virtual chalk magic value incorrect"

    # return first one
    return json.loads(all_vchalks[0])


# chalk report is created after `chalk insert` operation
def validate_chalk_report(
    chalk_report: dict[str, Any],
    artifact_map: dict[str, ArtifactInfo],
    virtual: bool,
    chalk_action: str = "insert",
):
    assert chalk_report["_OPERATION"] == chalk_action

    if not artifact_map:
        assert "_CHALKS" not in chalk_report
        return

    assert "_CHALKS" in chalk_report
    assert len(chalk_report["_CHALKS"]) == len(
        artifact_map
    ), "chalks missing from report"

    for chalk in chalk_report["_CHALKS"]:
        path = chalk["PATH_WHEN_CHALKED"]
        assert path in artifact_map, "chalked artifact incorrect"
        artifact = artifact_map[path]

        # artifact specific fields
        assert artifact.type == chalk["ARTIFACT_TYPE"], "artifact type doesn't match"

        # check arbitrary artifact values
        for key, value in artifact.chalk_info.items():
            assert key in chalk
            assert value == chalk[key]

        if chalk_action == "insert":
            assert virtual == chalk["_VIRTUAL"], "_VIRTUAL mismatch"


# slightly different from above
def validate_docker_chalk_report(
    chalk_report: dict[str, Any],
    artifact: ArtifactInfo,
    virtual: bool,
    chalk_action: str = "build",
):
    assert chalk_report["_OPERATION"] == chalk_action

    assert "_CHALKS" in chalk_report
    assert (
        len(chalk_report["_CHALKS"]) == 1
    ), "should only get one chalk report per docker image"

    for key in artifact.host_info:
        assert artifact.host_info[key] == chalk_report[key]

    for chalk in chalk_report["_CHALKS"]:
        for key in artifact.chalk_info:
            if isinstance(artifact.chalk_info[key], list):
                assert all(i in chalk[key] for i in artifact.chalk_info[key])
            else:
                assert artifact.chalk_info[key] == chalk[key]
        # chalk id should always exist
        assert "CHALK_ID" in chalk

        assert artifact.type == chalk["_OP_ARTIFACT_TYPE"]
        if chalk_action == "build":
            assert virtual == chalk["_VIRTUAL"]


# extracted chalk is created after `chalk extract` operation
def validate_extracted_chalk(
    extracted_chalk: dict[str, Any],
    artifact_map: dict[str, ArtifactInfo],
    virtual: bool,
) -> None:
    assert (
        extracted_chalk["_OPERATION"] == "extract"
    ), "operation expected to be extract"

    if len(artifact_map) == 0:
        assert "_CHALKS" not in extracted_chalk
        return

    if virtual:
        assert (
            "_UNMARKED" in extracted_chalk and "_CHALKS" not in extracted_chalk
        ), "Expected that artifact to not have chalks embedded"

        # everything should be unmarked, but not everything is an artifact
        assert len(extracted_chalk["_UNMARKED"]) >= len(
            artifact_map
        ), "wrong number of unmarked chalks"

        # we should find artifact in _UNMARKED
        for key in artifact_map:
            assert key in extracted_chalk["_UNMARKED"]

    else:
        if len(artifact_map) > 0:
            # okay to have _UNMARKED as long as the chalk mark is still there
            assert (
                "_CHALKS" in extracted_chalk
            ), "Expected that artifact to have chalks embedded"

            assert len(extracted_chalk["_CHALKS"]) == len(
                artifact_map
            ), "wrong number of chalks"

            for chalk in extracted_chalk["_CHALKS"]:
                path = chalk["_OP_ARTIFACT_PATH"]
                assert path in artifact_map, "path not found"
                artifact_info = artifact_map[path]

                assert artifact_info.type == chalk["ARTIFACT_TYPE"]

                # top level vs chalk-level sanity check
                assert chalk["PLATFORM_WHEN_CHALKED"] == extracted_chalk["_OP_PLATFORM"]
                assert (
                    chalk["INJECTOR_COMMIT_ID"]
                    == extracted_chalk["_OP_CHALKER_COMMIT_ID"]
                )
        else:
            assert "_CHALKS" not in extracted_chalk

    # there should not be operation errors
    try:
        assert len(extracted_chalk["_OP_ERRORS"]) == 0
    except KeyError:
        # fine if this key doesn't exist
        pass
