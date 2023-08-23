import json
import os
import shutil
from pathlib import Path
from subprocess import CalledProcessError, CompletedProcess, check_output, run
from typing import Any, Dict, List, Literal, Optional, Union

from ..utils.log import get_logger

ChalkCmd = Literal[
    "insert", "extract", "dump", "version", "delete", "load", "exec", "env"
]

logger = get_logger()


def has_errors(stderr: bytes) -> bool:
    """returns true if there were error logged by nim"""
    errored = False
    for out in stderr.decode().split("\n"):
        if out.startswith("error:"):
            logger.error(out)
            errored = True
    return errored


class Chalk:
    def __init__(
        self,
        *,
        docker_img: Optional[str] = None,
        binary: Optional[Path] = None,
        config: Optional[Path] = None,
    ):
        """We can invoke chalk either by passing a binary or the name of a
        docker container"""
        self.docker_img = docker_img
        if binary is not None:
            assert binary.is_file(), f"Could not find chalk binary {binary}"
            self.binary = binary
        else:
            try:
                self.binary = Path(
                    check_output(["which", "chalk"]).decode().strip()
                ).resolve()
            except CalledProcessError as e:
                logger.error("No chalk binary found", error=e)
                logger.error(
                    "Current directory",
                    dir=check_output(["pwd"]).decode().strip(),
                )
                logger.error(
                    "Current directory contents",
                    contents=check_output(["ls"]).decode().strip(),
                )
                raise e

        if self.binary is None:
            assert (
                docker_img
            ), "A valid binary or a docker image for chalk must be passed"

    def run(
        self,
        *,
        chalk_cmd: Optional[ChalkCmd] = None,
        target: Optional[Path] | Optional[str] = None,
        params: Optional[List[str]] = None,
        expected_success: Optional[bool] = True,
    ) -> Optional[CompletedProcess]:
        logger.info("Running chalk", binary=self.binary)
        assert self.binary.is_file()

        cmd: List[Union[Path, str, ChalkCmd]] = [self.binary]
        if chalk_cmd:
            cmd.append(chalk_cmd)
        if params:
            cmd.extend(params)

        if target is Path:
            assert target.exists(), f"Target {target} does not exist"
            cmd.append(target)
        elif target is not None:
            # might be a docker image or container
            # TODO: add validation for docker image and container inspection
            cmd.append(target)

        my_env = os.environ.copy()
        # FIXME
        my_env["DOCKER_BUILDKIT"] = "0"
        logger.debug("running chalk command: %s", cmd)
        run_process = None
        try:
            run_process = run(cmd, capture_output=True, env=my_env)
            if (
                run_process.returncode != 0 or has_errors(run_process.stderr)
            ) and expected_success:
                logger.error(
                    "Chalk invocation had unexpected errors",
                    cmd=cmd,
                    output=run_process.stdout,
                    stderr=run_process.stderr,
                    returncode=run_process.returncode,
                )
            # process is returned whether chalk was fail or success
            return run_process
        except CalledProcessError as e:
            # something else went wrong
            logger.error(
                "Chalk invocation failed unexpectedly",
                error=e,
                cmd=e.cmd,
                stdout=e.output,
                stderr=e.stderr,
                returncode=e.returncode,
                target=target,
                params=params,
                chalk_cmd=chalk_cmd,
                cur_dir=check_output(["pwd"]).decode().strip(),
                contents=check_output(["ls"]).decode().strip(),
            )
            raise
        except FileNotFoundError as e:
            if self.binary.is_file() and (target is None or target.exists()):
                logger.error(
                    "Got exception about file not found but chalk binary exists. Perhaps a platform incompatibility of the compiled binary?",
                    error=e,
                )
            else:
                logger.error(
                    "Chalk invocation failed",
                    error=e,
                    target=target,
                    params=params,
                    chalk_cmd=chalk_cmd,
                    cur_dir=check_output(["pwd"]).decode().strip(),
                    contents=check_output(["ls"]).decode().strip(),
                )
            raise

    # run with custom config that is external
    def run_with_custom_config(
        self,
        config_path: Path,
        target_path: Path,
        command: str = "insert",
        virtual: bool = True,
    ) -> Optional[CompletedProcess]:
        target = None
        if target_path != "":
            target = target_path

        params = [
            "--no-use-embedded-config",
            "--config-file=",
            str(config_path.absolute()),
        ]

        if virtual:
            params.append("--virtual")
        proc = self.run(
            chalk_cmd=command,
            target=target,
            params=params,
        )
        return proc

    # returns chalk report
    def insert(self, artifact: Path, virtual: bool = False) -> List[Dict[str, Any]]:
        # suppress output since all we want is the chalk report
        params = ["--log-level=none"]
        if virtual:
            params.append("--virtual")

        inserted = self.run(chalk_cmd="insert", target=artifact, params=params)
        assert inserted is not None
        if inserted.returncode != 0:
            logger.error(
                "chalk insertion failed with return code", ret=inserted.returncode
            )
            raise AssertionError
        try:
            return json.loads(inserted.stdout, strict=False)
        except json.decoder.JSONDecodeError:
            logger.error("Could not decode json", raw=inserted.stdout)
            raise

    def extract(self, artifact: Path | str) -> List[Dict[str, Any]]:
        extracted = self.run(
            chalk_cmd="extract",
            target=artifact,
            params=["--log-level=none"],
        )

        assert extracted is not None
        if extracted.returncode != 0:
            logger.error(
                "chalk extraction failed with return code", ret=extracted.returncode
            )
            raise AssertionError
        try:
            extract_out = extracted.stdout.decode()
            return json.loads(extract_out, strict=False)
        except json.decoder.JSONDecodeError:
            logger.error("Could not decode json", raw=extracted.stdout.decode())
            raise

    def exec(
        self, artifact: Path, chalk_as_parent: bool = False
    ) -> List[Dict[str, Any]]:
        exec_flag = "--exec-command-name=" + str(artifact)
        params = [exec_flag, "--log-level=none"]
        if chalk_as_parent:
            params.append("--chalk-as-parent")
        proc = self.run(
            chalk_cmd="exec",
            params=params,
        )

        assert proc is not None
        if proc.returncode != 0:
            logger.error("chalk exec failed with return code", ret=proc.returncode)
            raise AssertionError
        try:
            _report = proc.stdout.decode()
            # there will be exec proc output that is not chalk so ignore it
            chalk_start = _report.find("[")
            return json.loads(_report[chalk_start:], strict=False)
        except json.decoder.JSONDecodeError:
            logger.error("Could not decode json", raw=proc.stdout.decode())
            raise

    def delete(self, artifact: Path) -> List[Dict[str, Any]]:
        proc = self.run(
            chalk_cmd="delete",
            params=[str(artifact), "--log-level=none"],
        )

        assert proc is not None
        if proc.returncode != 0:
            logger.error("chalk delete failed with return code", ret=proc.returncode)
            raise AssertionError
        try:
            _report = proc.stdout.decode()
            return json.loads(_report, strict=False)
        except json.decoder.JSONDecodeError:
            logger.error("Could not decode json", raw=proc.stdout.decode())
            raise

    # FIXME: returns a process -- should it be returning the chalk report?
    # loading a config into the binary
    def load(self, config: str, use_embedded: bool) -> Optional[CompletedProcess]:
        logger.info("running chalk load")
        try:
            params = [config, "--log-level=error"]
            if use_embedded:
                params.append("--use-embedded-config")
            else:
                params.append("--no-use-embedded-config")
            load_proc = self.run(
                chalk_cmd="load",
                params=params,
            )

            return load_proc
        except CalledProcessError as e:
            logger.error("Called process error for chalk load", error=e)
            raise


# make a copy of chalk binary to the tmp directory since we don't want to overwrite the binary that all the other tests are using
def chalk_copy(tmp_data_dir: Path, chalk: Chalk) -> Chalk:
    logger.info("making a copy of chalk")
    chalk_path = chalk.binary
    shutil.copy(chalk_path, tmp_data_dir / "chalk")
    return Chalk(binary=(tmp_data_dir / "chalk").resolve())
