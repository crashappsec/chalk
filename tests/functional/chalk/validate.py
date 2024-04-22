# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

from ..conf import MAGIC, SHEBANG
from ..utils.dict import ANY, MISSING, Contains, IfExists, Length
from ..utils.log import get_logger
from .runner import ChalkMark, ChalkReport


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
    def one_elf(
        cls,
        path: Path,
        chalk_info: Optional[dict[str, Any]] = None,
        host_info: Optional[dict[str, Any]] = None,
    ):
        return {
            str(path): cls(
                type=cls.path_type(path),
                chalk_info=chalk_info or {},
                host_info=host_info or {},
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
    # jsonl is one json object per line, NOT array of json
    # number of json objects is number of artifacts chalked
    all_vchalks = [ChalkMark.from_json(i) for i in vjsonf.read_text().splitlines()]

    for vchalk in all_vchalks:
        assert vchalk.has(
            CHALK_ID=ANY,
            MAGIC=MAGIC,
        )

    # return first one
    return all_vchalks[0]


# chalk report is created after `chalk insert` operation
def validate_chalk_report(
    chalk_report: ChalkReport,
    artifact_map: dict[str, ArtifactInfo],
    virtual: bool,
    chalk_action: str = "insert",
):
    assert chalk_report.has(_OPERATION=chalk_action)

    if not artifact_map:
        assert chalk_report.has(_CHALKS=MISSING)
        return

    assert chalk_report.has(_CHALKS=Length(len(artifact_map)))

    # check arbitrary host report values
    for artifact in artifact_map.values():
        assert chalk_report.contains(artifact.host_info)

    for chalk in chalk_report.marks:
        path = chalk["PATH_WHEN_CHALKED"]
        assert path in artifact_map, "chalked artifact incorrect"
        artifact = artifact_map[path]

        assert chalk.has(
            ARTIFACT_TYPE=artifact.type,
            **artifact.chalk_info,
        )
        assert chalk.has_if(
            chalk_action == "insert",
            _VIRTUAL=virtual,
        )


# slightly different from above
def validate_docker_chalk_report(
    chalk_report: ChalkReport,
    artifact: ArtifactInfo,
    virtual: bool,
    chalk_action: str = "build",
):
    assert chalk_report.has(_OPERATION=chalk_action, _CHALKS=Length(1))
    assert chalk_report.contains(artifact.host_info)

    for chalk in chalk_report.marks:
        assert chalk.has(
            # chalk id should always exist
            CHALK_ID=ANY,
            _OP_ARTIFACT_TYPE=artifact.type,
        )
        assert chalk.contains(artifact.chalk_info)
        assert chalk.has_if(
            chalk_action == "build",
            _VIRTUAL=virtual,
        )


# extracted chalk is created after `chalk extract` operation
def validate_extracted_chalk(
    extracted_chalk: ChalkReport,
    artifact_map: dict[str, ArtifactInfo],
    virtual: bool,
) -> None:
    # there should not be operation errors
    assert extracted_chalk.has(_OPERATION="extract", _OP_ERRORS=IfExists(Length(0)))

    if len(artifact_map) == 0:
        assert extracted_chalk.has(_CHALKS=MISSING)
        return

    if virtual:
        assert extracted_chalk.has(
            _CHALKS=MISSING,
            _UNMARKED=Contains(set(artifact_map)),
        )

    else:
        # okay to have _UNMARKED as long as the chalk mark is still there
        assert extracted_chalk.has(_CHALKS=Length(len(artifact_map)))

        for chalk in extracted_chalk.marks:
            path = chalk["_OP_ARTIFACT_PATH"]
            assert path in artifact_map, "path not found"
            artifact_info = artifact_map[path]

            assert chalk.has(
                ARTIFACT_TYPE=artifact_info.type,
                # top level vs chalk-level sanity check
                PLATFORM_WHEN_CHALKED=extracted_chalk["_OP_PLATFORM"],
                INJECTOR_COMMIT_ID=extracted_chalk["_OP_CHALKER_COMMIT_ID"],
            )
