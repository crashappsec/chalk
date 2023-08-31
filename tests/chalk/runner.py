from pathlib import Path
import json
import datetime
from typing import Any, Literal, Optional

from ..utils.bin import sha256

from ..conf import MAGIC
from ..utils.log import get_logger
from ..utils.os import run, Program, CalledProcessError
from ..utils.docker import Docker

ChalkCmd = Literal[
    "delete",
    "dump",
    "env",
    "exec",
    "extract",
    "insert",
    "load",
    "setup",
    "version",
]

logger = get_logger()


class ChalkReport(dict):
    def __init__(self, report: dict[str, Any]):
        super().__init__(**report)

    @property
    def mark(self):
        assert len(self["_CHALKS"]) == 1
        return ChalkMark(self, self["_CHALKS"][0])

    @property
    def errors(self):
        return [i.strip() for i in self["_OP_ERRORS"]]

    @property
    def datetime(self):
        report_datetime = datetime.datetime.fromisoformat(self["_DATETIME"])
        report_timestamp = self["_TIMESTAMP"]
        # timestamp in milliseconds so multiply by 1000
        assert report_datetime.timestamp() * 1000 == report_timestamp
        return report_datetime

    @classmethod
    def from_json(cls, data: str):
        return cls(json.loads(data)[0])


class ChalkMark(dict):
    @classmethod
    def from_binary(cls, path: Path):
        text = path.read_text(errors="ignore")
        # MAGIC must always be present in chalk mark and marks the beginning of the json
        assert MAGIC in text
        start = text.rfind("{", 0, text.find(MAGIC))
        end = text.rfind("}", start)
        assert start > 0
        assert end > 0
        mark_json = text[start : end + 1]
        mark = json.loads(mark_json)
        assert mark
        return cls(report=ChalkReport({}), mark=mark)

    def __init__(self, report: ChalkReport, mark: dict[str, Any]):
        self.report = report
        super().__init__(**mark)

    @property
    def lifted(self):
        copy = self.copy()
        copy.update(
            {
                k: v
                for k, v in self.report.items()
                # ignore _CHALKS and if k is already present in mark
                if k != "_CHALKS" and k not in self
            }
        )
        return self.__class__(
            report=self.report,
            mark=copy,
        )

    @property
    def datetime(self):
        return datetime.datetime.fromisoformat(self["DATETIME_WHEN_CHALKED"])


class ChalkProgram(Program):
    _base_logger = logger

    def __post_init__(self):
        for e in self.errors:
            logger.error(e)

    @classmethod
    def from_program(cls, program: Program):
        return cls(**program.asdict())

    @property
    def errors(self):
        errors = [i for i in self.logs.splitlines() if i.startswith("error:")]
        return errors

    def find(self, needle) -> str:
        for line in self.text.splitlines():
            if needle in line:
                i = line.find(needle)
                return line[i:].replace(needle, "", 1).strip()
        self.logger.error("could not find string in outout", needle=needle)
        raise ValueError(f"{needle} not found in stdout")

    @property
    def reports(self):
        return [ChalkReport(i) for i in self.json(after="[\n")]

    @property
    def report(self):
        assert len(self.reports) == 1
        return self.reports[0]

    @property
    def mark(self):
        return self.report.mark


class Chalk:
    def __init__(
        self,
        *,
        binary: Optional[Path] = None,
    ):
        """
        Helper for interacting with chalk
        """
        try:
            self.binary = binary or Path(run(["which", "chalk"]).text).resolve()
        except CalledProcessError as e:
            logger.error("No chalk binary found", error=e)
            raise

        assert self.binary.is_file()

    def __repr__(self):
        return f"{self.__class__.__name__}(binary={self.binary!r})"

    def run(
        self,
        *,
        chalk_cmd: Optional[ChalkCmd] = None,
        target: Optional[Path | str] = None,
        params: Optional[list[str]] = None,
        expected_success: bool = True,
        ignore_errors: bool = False,
        cwd: Optional[Path] = None,
    ) -> ChalkProgram:
        cmd: list[str] = [str(self.binary)]

        if chalk_cmd:
            cmd.append(chalk_cmd)
        if params:
            cmd.extend(params)

        if isinstance(target, Path):
            assert target.exists()
            cmd.append(str(target))
        elif target:
            # might be a docker image or container
            # TODO: add validation for docker image and container inspection
            cmd.append(target)

        result = ChalkProgram.from_program(
            run(
                cmd,
                expected_exit_code=int(not expected_success),
                env={"DOCKER_BUILDKIT": "0"},
                cwd=cwd,
            )
        )
        if not ignore_errors and expected_success and result.errors:
            raise result.error

        return ChalkProgram.from_program(result)

    # run with custom config that is external
    def run_with_custom_config(
        self,
        config_path: Path,
        target: Optional[Path] = None,
        command: ChalkCmd = "insert",
        virtual: bool = True,
    ) -> ChalkProgram:
        params = [
            "--no-use-embedded-config",
            "--config-file=",
            str(config_path.absolute()),
        ]
        if virtual:
            params.append("--virtual")

        return self.run(
            chalk_cmd=command,
            target=target,
            params=params,
        )

    # returns chalk report
    def insert(self, artifact: Path, virtual: bool = False) -> ChalkProgram:
        # suppress output since all we want is the chalk report
        params = ["--log-level=error"]
        if virtual:
            params.append("--virtual")

        return self.run(chalk_cmd="insert", target=artifact, params=params)

    def extract(
        self,
        artifact: Path | str,
        expected_success: bool = True,
        ignore_errors: bool = False,
    ) -> ChalkProgram:
        return self.run(
            chalk_cmd="extract",
            target=artifact,
            params=["--log-level=error"],
            expected_success=expected_success,
            ignore_errors=ignore_errors,
        )

    def exec(self, artifact: Path, chalk_as_parent: bool = False) -> ChalkProgram:
        exec_flag = "--exec-command-name=" + str(artifact)
        params = [exec_flag, "--log-level=error"]
        if chalk_as_parent:
            params.append("--chalk-as-parent")

        return self.run(
            chalk_cmd="exec",
            params=params,
        )

    def delete(self, artifact: Path) -> ChalkProgram:
        return self.run(
            chalk_cmd="delete",
            params=[str(artifact), "--log-level=error"],
        )

    def dump(self, path: Path) -> ChalkProgram:
        assert not path.is_file()
        result = self.run(chalk_cmd="dump", params=[str(path)])
        assert path.is_file()
        return result

    def load(
        self,
        config: Path,
        use_embedded: bool,
        expected_success: bool = True,
        ignore_errors: bool = False,
    ) -> ChalkProgram:
        hash = sha256(self.binary)
        params = [str(config), "--log-level=error"]
        if use_embedded:
            params.append("--use-embedded-config")
        else:
            params.append("--no-use-embedded-config")
        result = self.run(
            chalk_cmd="load",
            params=params,
            expected_success=expected_success,
            ignore_errors=ignore_errors,
        )
        # sanity check that chalk binary was changed
        if expected_success:
            assert hash != sha256(self.binary)
        return result

    def docker_build(
        self,
        dockerfile: Path,
        *,
        tag: str,
        context: Optional[Path] = None,
        expected_success: bool = True,
        virtual: bool = False,
        cwd: Optional[Path] = None,
        params: Optional[list[str]] = None,
    ) -> ChalkProgram:
        cwd = cwd or dockerfile.parent
        context = context or dockerfile.parent

        # run vanilla docker build to ensure it works without chalk
        Docker.build(
            tag=tag,
            context=context,
            dockerfile=dockerfile,
            cwd=cwd,
            expected_success=expected_success,
        )

        # TODO remove log level but there are error bugs due to --debug
        # which fail the command validation
        chalk_params = ["--debug", "--log-level=none"]
        if virtual:
            chalk_params += ["--virtual"]
        return self.run(
            params=chalk_params
            + (params or [])
            + Docker.build_cmd(
                tag=tag,
                context=context,
                dockerfile=dockerfile,
            ),
            expected_success=expected_success,
            cwd=cwd,
        )

    def docker_push(self, image: str):
        return self.run(
            params=["docker", "push", image],
        )

    def docker_pull(self, image: str):
        return self.run(
            params=["docker", "pull", image],
        )
