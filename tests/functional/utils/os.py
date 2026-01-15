# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import datetime
import json
import os
import pty
import re
import time
from contextlib import suppress
from dataclasses import asdict, dataclass
from hashlib import sha256
from pathlib import Path
from subprocess import PIPE, CalledProcessError, Popen, TimeoutExpired
from typing import Literal, Optional

from filelock import FileLock

from .log import get_logger


logger = get_logger()


def lock(name: str):
    return FileLock(Path(__file__).with_name(name).resolve())


def bin_from_cmd(cmd: list[str] | tuple[str] | str) -> str:
    return cmd.split()[0] if isinstance(cmd, str) else cmd[0]


@dataclass
class Program:
    """
    Wrapper for program output.

    This keeps all program parameters as well as outputs.
    """

    _base_logger = logger
    cmd: list[str] | tuple[str] | str
    duration: datetime.timedelta
    exit_code: int
    expected_exit_code: int
    stdout: bytes
    stderr: bytes
    stdin: Optional[bytes]
    cwd: str
    env: dict[str, str]
    shell: bool
    log_level: Literal["info", "debug"] = "info"

    def asdict(self):
        return asdict(self)

    def __post_init__(self):
        if self:
            getattr(self.logger, self.log_level)("finished running")
        else:
            if self.expected_exit_code:
                self.logger.error(f"{self.bin} succeded but was expected to fail")
            else:
                self.logger.error(f"{self.bin} failed")

    def __eq__(self, other) -> bool:
        return self.exit_code == other.exit_code and self.stdout == other.stdout

    def __bool__(self) -> bool:
        """
        Boolean when program exited successfully with 0.
        """
        return self.exit_code == self.expected_exit_code

    @property
    def bin(self):
        return bin_from_cmd(self.cmd)

    @property
    def logger(self):
        return self._base_logger.bind(
            cmd=self.cmd,
            exit_code=self.exit_code,
            expected_status_code=self.expected_exit_code,
            duration=self.duration,
            stdin=self.input,
            stdout=self.text,
            stderr=self.logs,
            cwd=self.cwd,
            ls=os.listdir(self.cwd),
        )

    @property
    def returncode(self):
        return self.exit_code

    def check(self) -> None:
        """
        Check program success state and raise exception when error occurred.
        """
        if not self:
            raise self.error

    def _strip_ansi(self, text: str):
        # strip chalk logs from stdout so we can find just json reports
        # https://stackoverflow.com/questions/14693701/how-can-i-remove-the-ansi-escape-sequences-from-a-string-in-python
        return re.sub(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])", "", text)

    @property
    def text(self) -> str:
        return self._strip_ansi(self.stdout.decode().strip())

    @property
    def logs(self) -> str:
        return self._strip_ansi(self.stderr.decode().strip())

    @property
    def input(self) -> str:
        return (self.stdin or b"").decode()

    @property
    def digest(self) -> str:
        return sha256(self.stdout).hexdigest()

    @property
    def error(self) -> CalledProcessError:
        raise CalledProcessError(
            self.exit_code, self.cmd, output=self.stdout, stderr=self.stderr
        )

    def find(
        self,
        needle: str,
        text: Optional[str] = None,
        words: int = 0,
        reverse: bool = False,
        log_level: Optional[Literal["error", "debug"]] = "error",
        default: Optional[str] = None,
        ignore_in_between: Optional[list[tuple[str, str]]] = None,
    ) -> str:
        lines = (text or self.text).splitlines()
        if reverse:
            lines = lines[::-1]
        ignoring = False
        in_between_end = ""
        for line in lines:
            if not ignoring and ignore_in_between:
                for start, end in ignore_in_between:
                    if reverse:
                        start, end = end, start
                    if start in line:
                        ignoring = True
                        in_between_end = end
            if ignoring:
                if in_between_end in line:
                    ignoring = False
                else:
                    continue
            if needle in line:
                i = line.find(needle)
                result = line[i:].replace(needle, "", 1).strip()
                if words:
                    result = " ".join(result.split()[:words])
                return result
        if default is not None:
            return default
        if log_level:
            getattr(self.logger, log_level)(
                "could not find string in output", needle=needle
            )
        raise ValueError(f"{needle} could not be found in stdout")

    def after(self, *, match: Optional[str] = None, text: Optional[str] = None) -> str:
        text = text or self.text
        if match:
            found = list(re.finditer(match, text))
            if found:
                i = found[0].start(0)
            else:
                i = 0
            text = text[i:]
        return text

    def json(
        self,
        *,
        after: Optional[str] = None,
        text: Optional[str] = None,
        log_level: Optional[Literal["error", "debug"]] = "error",
        everything: bool = True,
    ):
        data, _ = self._valid_json(
            after=after, text=text, log_level=log_level, everything=everything
        )
        return data

    def _valid_json(
        self,
        *,
        after: Optional[str] = None,
        text: Optional[str] = None,
        log_level: Optional[Literal["error", "debug"]] = "error",
        everything: bool = True,
    ):
        text = self.after(match=after, text=text)
        try:
            return json.loads(text), len(text)
        except json.JSONDecodeError as e:
            # if there is extra data we grab valid json until the
            # invalid character
            e_str = str(e)
            if everything or not e_str.startswith("Extra data:"):
                if log_level:
                    getattr(self.logger, log_level)("output is invalid json", error=e)
                raise
            # Extra data: line 25 column 1 (char 596)
            char = int(e_str.split()[-1].strip(")"))
            return json.loads(text[:char]), char


def run(
    cmd: list[str] | tuple[str] | str,
    *,
    stdout: int = PIPE,
    stderr: int = PIPE,
    stdin: Optional[bytes] = None,
    tty: bool = False,
    cwd: Optional[str | Path] = None,
    environ: Optional[dict[str, str]] = None,
    env: Optional[dict[str, str]] = None,
    check: bool = True,
    expected_exit_code: int = 0,
    timeout: Optional[int | float] = None,
    shell: bool = False,
    log_level: Literal["info", "debug"] = "info",
    attempts: int = 1,
    sleep_between_attempts: int = 1,
) -> Program:
    """
    Run cmd in a subprocess asyncronously.

    Parameters
    ----------
    cmd : Iterator[str] | str
        List of command arguments or shell command
    stdout : default PIPE, optional
        Descriptor where stdout should be forwarded
    stderr : default PIPE, optional
        Descriptor where stderr should be forwarded
    stdin : bytes, optional
        Optional input to be provided to the command via stdin
    tty : bool, optional
        Pass PTY to stdin
    cwd : str | Path, optional
        Optional path for current working directory for the cmd
    environ : dict[str, str], optional
        Mapping of all environment variables to pass to cmd
        If omitted, current process env vars will be inherited
    env : dict[str, str], optional
        Env var overrides
    check : bool, optional, default True
        Whether to check exit code of cmd for success
    expected_exit_code : int
        Expected exit code of the program which is enforced if check is True
    timeout: int, optional
        Command timeout. After timeout program will be killed via SIGKILL
    shell: bool, optional
        Whether to use shell to execute command string
    log_level: str, default "info"
        How to log program output when it succeeds

    Raises
    ------
    subprocess.CalledProcessError
        When `check` is enforced and cmd exited with not expected_exit_code

    Examples
    --------
    >>> run(['echo', '-n', 'hello']).text
    'hello'
    >>> run(['sleep', '5'], timeout=0.01, check=False).exit_code
    124
    >>> run('echo -n hello | cat', shell=True).text
    'hello'
    """
    log = logger.bind(cmd=cmd)
    log.debug("starting to run")

    cwd = str(cwd or os.getcwd())
    before = datetime.datetime.now()

    if shell:
        assert isinstance(cmd, str), "for shell=True, cmd should be provided as string"
    else:
        assert not isinstance(
            cmd, str
        ), "for shell=False, cmd should be provided as iterable of strings"

    env_vars = environ or os.environ.copy()
    env_vars.update(env or {})

    intty = None
    if tty:
        _, intty = pty.openpty()

    for attempt in range(1, attempts + 1):
        try:
            process = Popen(
                cmd,
                stdout=stdout,
                stderr=stderr,
                stdin=PIPE if stdin is not None else intty,
                cwd=cwd,
                env=env_vars,
                shell=shell,
            )

            try:
                out, err = process.communicate(stdin, timeout=timeout)
            except TimeoutExpired:
                after = datetime.datetime.now()
                process.returncode = process.returncode or 124
                if process.returncode is not None:
                    # if process did not exit yet, attempt to kill it
                    with suppress(Exception):
                        process.kill()
                out = b""
                err = b"<timeout after {timeout} seconds>"

        except FileNotFoundError as e:
            after = datetime.datetime.now()
            exit_code = 127
            out = b""
            err = str(e).encode()
            binary = Path(bin_from_cmd(cmd)).resolve()
            if binary.is_file():
                log.error(
                    "Got exception about file not found even though it exists. "
                    "Perhaps a platform incompatibility of the binary?",
                    error=e,
                    binary=str(binary),
                )

        else:
            after = datetime.datetime.now()
            exit_code = process.returncode
            assert exit_code is not None

        result = Program(
            cmd=cmd,
            exit_code=exit_code,
            expected_exit_code=expected_exit_code,
            stdout=out,
            stderr=err,
            stdin=stdin,
            duration=after - before,
            cwd=cwd,
            shell=shell,
            env=env_vars,
            log_level=log_level,
        )

        if check:
            try:
                result.check()
            except CalledProcessError as e:
                if attempt == attempts:
                    raise
                log.error(
                    "retrying failed run",
                    error=e,
                    sleep_between_attempts=sleep_between_attempts,
                )
                if sleep_between_attempts:
                    time.sleep(sleep_between_attempts)
                continue

        return result


def which(cmd: str) -> str:
    return run(["which", cmd]).text
