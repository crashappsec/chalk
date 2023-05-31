import os
import subprocess
from pathlib import Path
from typing import List


# clean up chalk mark from previous runs
def clean_previous_chalk_artifacts(artifact_dir: Path) -> None:
    cwd = os.getcwd()
    os.chdir(artifact_dir)
    os.system("rm chalk-reports.jsonl 1>/dev/null 2>&1")
    os.system("rm virtual-chalk.json 1>/dev/null 2>&1")
    os.system("rm chalk-*.tmp 1>/dev/null 2>&1")
    os.chdir(cwd)


def write_exceptions(exceptions: List[Exception], output_dir: Path) -> None:
    if exceptions:
        with open(os.path.join(output_dir, "chalk.exceptions"), "w") as errf:
            for e in exceptions:
                errf.write(str(e) + "\n")


def handle_chalk_output(
    repo_result_dir: Path, process: subprocess.CompletedProcess, exceptions: List
):
    # process stderr to "chalk.err"
    with open(os.path.join(repo_result_dir, "chalk.err"), "w") as errf:
        errf.write(process.stderr.decode())

    # process stdout to "chalk.out"
    with open(os.path.join(repo_result_dir, "chalk.out"), "w") as choutf:
        choutf.write(process.stdout.decode())

    # copy chalk report to result directory
    try:
        if process.returncode == 0:
            subprocess.run(
                [
                    "cp",
                    "chalk-reports.jsonl",
                    repo_result_dir,
                ],
                check=True,
            )
    except subprocess.CalledProcessError as e:
        exceptions.append(e)

    # copy virtual chalk to result direcotry
    try:
        if process.returncode == 0:
            subprocess.run(
                [
                    "cp",
                    "virtual-chalk.json",
                    repo_result_dir,
                ],
                check=True,
            )
    except subprocess.CalledProcessError as e:
        exceptions.append(e)
