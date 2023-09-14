# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from pathlib import Path
import json
import datetime
import os
from typing import Any, Literal, Optional, cast

from ..utils.bin import sha256

from ..conf import MAGIC
from ..utils.log import get_logger
from ..utils.dict import ContainsMixin
from ..utils.os import run, Program, CalledProcessError
from ..utils.docker import Docker

ChalkCommand = Literal[
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
ChalkLogLevel = Literal[
    "none",
    "trace",
    "info",
    "error",
]

logger = get_logger()


class ChalkReport(ContainsMixin, dict):
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

    def validate(self, operation: str):
        assert self["_OPERATION"] == operation


class ChalkMark(ContainsMixin, dict):
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

    @property
    def reports(self):
        reports = []
        text = self.after(match=r"\[\s")
        while text.strip():
            try:
                # assume all of text is valid json
                reports += json.loads(text)
            except json.JSONDecodeError as e:
                # if not we grab valid json until the invalid
                # character and then keep doing that until we
                # find all reports in the text
                e_str = str(e)
                if not e_str.startswith("Extra data:"):
                    self.logger.error("output is invalid json", error=e)
                    raise
                # Extra data: line 25 column 1 (char 596)
                char = int(e_str.split()[-1].strip(")"))
                reports += self.json(text=text[:char])
                text = text[char:]
            else:
                break
        return [ChalkReport(i) for i in reports]

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
        command: Optional[ChalkCommand] = None,
        target: Optional[Path | str] = None,
        config: Optional[Path] = None,
        use_embedded: bool = True,
        virtual: bool = False,
        debug: bool = False,
        heartbeat: bool = False,
        log_level: Optional[ChalkLogLevel] = None,
        exec_command: Optional[str | Path] = None,
        as_parent: Optional[bool] = None,
        no_color: bool = False,
        no_api_login: bool = False,
        params: Optional[list[str]] = None,
        expected_success: bool = True,
        ignore_errors: bool = False,
        cwd: Optional[Path] = None,
        env: Optional[dict[str, str]] = None,
    ) -> ChalkProgram:
        params = params or []
        cmd: list[str] = [str(self.binary)]

        if command:
            cmd += [command]
        if virtual:
            cmd += ["--virtual"]
        if config:
            cmd += [f"--config-file={config.absolute()}"]
            if use_embedded:
                cmd += ["--use-embedded-config"]
            else:
                cmd += ["--no-use-embedded-config"]
        if log_level:
            cmd += [f"--log-level={log_level}"]
        if exec_command:
            cmd += [f"--exec-command-name={exec_command}"]
        if as_parent:
            cmd += ["--chalk-as-parent"]
        if heartbeat:
            cmd += ["--heartbeat"]
        if debug:
            cmd += ["--debug"]
        if no_color:
            cmd += ["--no-color"]
        if no_api_login:
            cmd += ["--no-api-login"]
        if params:
            cmd += params

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
                cwd=cwd,
                env=env,
            )
        )
        if not ignore_errors and expected_success and result.errors:
            raise result.error

        # if chalk outputs report, sanity check its operation matches chalk_cmd
        try:
            report = result.report
        except Exception:
            pass
        else:
            # report could be silenced on the profile level
            if report:
                operation = cast(str, command)
                # when calling docker, the arg after docker is the operation
                if not operation and "docker" in params:
                    operation = params[params.index("docker") + 1]
                if operation:
                    report.validate(operation)

        return result

    # returns chalk report
    def insert(
        self,
        artifact: Path,
        virtual: bool = False,
        config: Optional[Path] = None,
        # suppress output since all we want is the chalk report
        log_level: ChalkLogLevel = "none",
    ) -> ChalkProgram:
        return self.run(
            command="insert",
            target=artifact,
            config=config,
            virtual=virtual,
            log_level=log_level,
        )

    def extract(
        self,
        artifact: Path | str,
        expected_success: bool = True,
        ignore_errors: bool = False,
    ) -> ChalkProgram:
        return self.run(
            command="extract",
            target=artifact,
            log_level="error",
            expected_success=expected_success,
            ignore_errors=ignore_errors,
        )

    def exec(self, artifact: Path, as_parent: bool = False) -> ChalkProgram:
        return self.run(
            command="exec",
            exec_command=artifact,
            log_level="error",
            as_parent=as_parent,
        )

    def delete(self, artifact: Path) -> ChalkProgram:
        return self.run(
            command="delete",
            target=artifact,
            log_level="error",
        )

    def dump(self, path: Path) -> ChalkProgram:
        assert not path.is_file()
        result = self.run(command="dump", params=[str(path)])
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
        result = self.run(
            command="load",
            params=[str(config)],
            log_level="error",
            use_embedded=use_embedded,
            expected_success=expected_success,
            ignore_errors=ignore_errors,
        )
        # sanity check that chalk binary was changed
        if expected_success:
            assert hash != sha256(self.binary)
        return result

    def docker_build(
        self,
        *,
        dockerfile: Optional[Path] = None,
        tag: Optional[str] = None,
        context: Optional[Path] = None,
        expected_success: bool = True,
        virtual: bool = False,
        cwd: Optional[Path] = None,
        config: Optional[Path] = None,
        buildkit: bool = True,
    ) -> tuple[str, ChalkProgram]:
        cwd = cwd or Path(os.getcwd())
        context = context or getattr(dockerfile, "parent", cwd)

        # run vanilla docker build to ensure it works without chalk
        Docker.build(
            tag=tag,
            context=context,
            dockerfile=dockerfile,
            cwd=cwd,
            expected_success=expected_success,
            buildkit=buildkit,
        )

        image_hash, result = Docker.with_image_id(
            self.run(
                # TODO remove log level but there are error bugs due to --debug
                # which fail the command validation
                log_level="none",
                debug=True,
                virtual=virtual,
                config=config,
                params=Docker.build_cmd(
                    tag=tag,
                    context=context,
                    dockerfile=dockerfile,
                ),
                expected_success=expected_success,
                cwd=cwd,
                env=Docker.build_env(buildkit=buildkit),
            )
        )
        dockerfile = dockerfile or (
            (cwd or context or Path(os.getcwd())) / "Dockerfile"
        )
        if expected_success:
            # sanity check that chalk mark includes basic chalk keys
            assert image_hash == result.mark["_CURRENT_HASH"]
            assert image_hash == result.mark["_IMAGE_ID"]
            assert str(dockerfile) == result.mark["DOCKERFILE_PATH"]
        return image_hash, result

    def docker_push(self, image: str):
        return self.run(
            params=["docker", "push", image],
        )

    def docker_pull(self, image: str):
        return self.run(
            params=["docker", "pull", image],
        )
