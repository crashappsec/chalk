import os
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