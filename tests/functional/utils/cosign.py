from secrets import token_bytes
from tempfile import TemporaryDirectory

from pathlib import Path

from ..conf import TESTS
from .os import run, Program


class Cosign:
    def __init__(self):
        with TemporaryDirectory() as tmp_dir:
            tmp_data_dir = Path(tmp_dir)
            self.password = token_bytes(
                12
            ).hex()  # at least 24 bytes are required for PRP
            assert run(
                [
                    "cosign",
                    "generate-key-pair",
                    "--output-key-prefix",
                    f"{tmp_dir}/chalk",
                ],
                env={"COSIGN_PASSWORD": self.password},
            )
            self.public = (tmp_data_dir / "chalk.pub").read_text()
            self.private = (tmp_data_dir / "chalk.key").read_text()

    @property
    def env(self) -> dict[str, str]:
        return {"CHALK_PASSWORD": self.password}

    def write(self):
        Path("chalk.pub").write_text(self.public)
        Path("chalk.key").write_text(self.private)

    def verify(self, name: str) -> Program:
        return run(
            [
                str(TESTS / "cosign.sh"),
                name,
                "--verify",
            ],
            env=self.env,
        )
