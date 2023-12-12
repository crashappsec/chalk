# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import datetime
import json
import os
import itertools
from pathlib import Path
from typing import Any, Literal, Optional, cast

from ..conf import MAGIC
from ..utils.bin import sha256
from ..utils.dict import ContainsMixin
from ..utils.docker import Docker
from ..utils.log import get_logger
from ..utils.os import CalledProcessError, Program, run

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
    def marks(self):
        assert len(self["_CHALKS"]) > 0
        return [ChalkMark(i, report=self) for i in self["_CHALKS"]]

    @property
    def mark(self):
        assert len(self.marks) == 1
        return self.marks[0]

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

    @classmethod
    def from_json(cls, data: str):
        return cls(json.loads(data))

    def __init__(
        self, mark: dict[str, Any], *, report: Optional[dict[str, Any]] = None
    ):
        self.report = ChalkReport(report or {})
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
        errors = itertools.takewhile(
            lambda i: "--debug" not in i,
            [i for i in self.logs.splitlines() if i.startswith("error:")],
        )
        return list(errors)

    @property
    def reports(self):
        text = "\n".join(
            [
                i
                for i in self.text.splitlines()
                if not any(i.startswith(j) for j in {"info:", "trace:", "error:"})
            ]
        )
        reports = []
        # find start of report structure. it should start with either:
        # * `[{"` - start of report
        # * `[{}`
        # with any number of whitespace in-between
        # the report is either:
        # * empty object
        # * has a string key
        match = r'\[\s+\{\s*["\}]'
        text = self.after(match=match, text=text)
        while text.strip():
            try:
                # assume all of text is valid json
                reports += self.json(text=text, log_level=None)
            except json.JSONDecodeError:
                next_reports, char = self._valid_json(text=text, everything=False)
                reports += next_reports
                text = self.after(match=match, text=text[char:])
                if not text.strip().startswith("["):
                    break
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

    @property
    def marks(self):
        return self.report.marks


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
        config: Optional[Path | str] = None,
        use_embedded: bool = True,
        virtual: bool = False,
        debug: bool = False,
        heartbeat: bool = False,
        replace: bool = False,
        log_level: Optional[ChalkLogLevel] = None,
        exec_command: Optional[str | Path] = None,
        as_parent: Optional[bool] = None,
        no_color: bool = False,
        no_api_login: bool = False,
        params: Optional[list[str]] = None,
        expected_success: bool = True,
        expecting_report: bool = True,
        ignore_errors: bool = False,
        cwd: Optional[Path] = None,
        env: Optional[dict[str, str]] = None,
        stdin: Optional[bytes] = None,
    ) -> ChalkProgram:
        params = params or []
        cmd: list[str] = [str(self.binary)]

        if command:
            cmd += [command]
        if virtual:
            cmd += ["--virtual"]
        if config:
            absolute = config.absolute() if isinstance(config, Path) else config
            cmd += [f"--config-file={absolute}"]
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
        if replace:
            cmd += ["--replace"]
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
                stdin=stdin,
            )
        )
        if not ignore_errors and expected_success and result.errors:
            raise result.error

        # if chalk outputs report, sanity check its operation matches chalk_cmd
        if expecting_report:
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
                        try:
                            operation = params[params.index("buildx") + 1]
                        except ValueError:
                            operation = params[params.index("docker") + 1]
                    if operation:
                        assert report.has(_OPERATION=operation)

        return result

    # returns chalk report
    def insert(
        self,
        artifact: Path,
        virtual: bool = False,
        config: Optional[Path] = None,
        # suppress output since all we want is the chalk report
        log_level: ChalkLogLevel = "none",
        env: Optional[dict[str, str]] = None,
    ) -> ChalkProgram:
        return self.run(
            command="insert",
            target=artifact,
            config=config,
            virtual=virtual,
            log_level=log_level,
            env=env,
        )

    def extract(
        self,
        artifact: Path | str,
        expected_success: bool = True,
        ignore_errors: bool = False,
        log_level: ChalkLogLevel = "error",
    ) -> ChalkProgram:
        return self.run(
            command="extract",
            target=artifact,
            log_level=log_level,
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
        config: Path | str,
        *,
        replace: bool = True,
        use_embedded: bool = False,
        expected_success: bool = True,
        ignore_errors: bool = False,
        log_level: ChalkLogLevel = "error",
        stdin: Optional[bytes] = None,
    ) -> ChalkProgram:
        hash = sha256(self.binary)
        result = self.run(
            command="load",
            params=[str(config)],
            log_level=log_level,
            replace=replace,
            use_embedded=use_embedded,
            expected_success=expected_success,
            expecting_report=False,
            ignore_errors=ignore_errors,
            stdin=stdin,
        )
        # sanity check that chalk binary was changed
        if expected_success:
            assert hash != sha256(self.binary)
        return result

    def docker_build(
        self,
        *,
        dockerfile: Optional[Path | str] = None,
        tag: Optional[str] = None,
        context: Optional[Path | str] = None,
        expected_success: bool = True,
        expecting_report: bool = True,
        virtual: bool = False,
        cwd: Optional[Path] = None,
        args: Optional[dict[str, str]] = None,
        push: bool = False,
        platforms: Optional[list[str]] = None,
        buildx: bool = False,
        config: Optional[Path] = None,
        buildkit: bool = True,
        secrets: Optional[dict[str, Path]] = None,
        log_level: ChalkLogLevel = "none",
        env: Optional[dict[str, str]] = None,
    ) -> tuple[str, ChalkProgram]:
        cwd = cwd or Path(os.getcwd())
        context = context or getattr(dockerfile, "parent", cwd)

        # run vanilla docker build to ensure it works without chalk
        Docker.build(
            tag=tag,
            context=context,
            dockerfile=dockerfile,
            args=args,
            cwd=cwd,
            push=push,
            platforms=platforms,
            expected_success=expected_success,
            buildkit=buildkit,
            buildx=buildx,
            secrets=secrets,
        )

        image_hash, result = Docker.with_image_id(
            self.run(
                # TODO remove log level but there are error bugs due to --debug
                # which fail the command validation
                log_level=log_level,
                debug=True,
                virtual=virtual,
                config=config,
                params=Docker.build_cmd(
                    tag=tag,
                    context=context,
                    dockerfile=dockerfile,
                    args=args,
                    push=push,
                    platforms=platforms,
                    buildx=buildx,
                    secrets=secrets,
                    buildkit=buildkit,
                ),
                expected_success=expected_success,
                ignore_errors=not expecting_report,
                cwd=cwd,
                env={
                    **Docker.build_env(buildkit=buildkit),
                    **(env or {}),
                },
            )
        )
        if expecting_report and expected_success and image_hash:
            if platforms:
                assert len(result.marks) == len(platforms)
            else:
                assert len(result.marks) == 1
            # sanity check that chalk mark includes basic chalk keys
            assert image_hash == result.marks[-1]["_CURRENT_HASH"]
            assert image_hash == result.marks[-1]["_IMAGE_ID"]
            if isinstance(context, Path):
                dockerfile = dockerfile or (
                    (cwd or context or Path(os.getcwd())) / "Dockerfile"
                )
                assert str(dockerfile) == result.marks[-1]["DOCKERFILE_PATH"]
        elif not expecting_report:
            try:
                assert not result.reports
            except json.JSONDecodeError:
                # we are not expecting any report json to be present in output
                # so this exception is expected here
                pass
        return image_hash, result

    def docker_push(self, image: str):
        return self.run(
            params=["docker", "push", image],
        )

    def docker_pull(self, image: str):
        return self.run(
            params=["docker", "pull", image],
        )
