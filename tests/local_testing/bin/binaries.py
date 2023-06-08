import logging
import os
import subprocess
from pathlib import Path
from typing import List, Optional

from ..chalkruninfo import ChalkRunInfo
from ..output import (
    clean_previous_chalk_artifacts,
    handle_chalk_output,
    write_exceptions,
)

logger = logging.getLogger(__name__)


# fetch binaries from binaries list and copy them to temporary cache
# this assumes we are on a machine that has these
def fetch_binaries(top_level_cache: Path, count: int):
    bin_list_file = Path(__file__).absolute().parent / "bin_list.txt"
    if not bin_list_file.is_file():
        logger.info("bin_list.txt does not exist, no binaries copied")
        return

    bin_list = bin_list_file.read_bytes().decode().split("\n")[:-1]

    if not top_level_cache.is_dir():
        os.makedirs(top_level_cache, exist_ok=True)
    bin_cache = top_level_cache / "binaries"
    os.makedirs(bin_cache, exist_ok=True)

    # limit to count
    if count < len(bin_list):
        bin_list = bin_list[:count]

    for bin in bin_list:
        # get path for binary
        which_bin = subprocess.run(
            ["which", bin],
            capture_output=True,
        )
        bin_path = which_bin.stdout.decode().strip()
        if bin_path == "":
            # assuming this failed with an error
            logger.info("%s not found: %s", bin, which_bin.stderr.decode())
            continue

        os.makedirs(bin_cache / bin, exist_ok=True)
        bin_cp = subprocess.run(
            [
                "cp",
                bin_path,
                bin_cache / bin / (bin + "_copy"),
            ],
            capture_output=True,
        )
        if bin_cp.stderr.decode() != "":
            logger.info("could not copy %s: %s", bin, which_bin.stderr.decode())


def _run_chalk_in_dir(
    bin_name: str, bin_cache_dir: Path, bin_result_dir: Path
) -> ChalkRunInfo:
    logger.info("[START] chalking %s", bin_cache_dir)
    # results directory in case that doesn't exist
    os.makedirs(bin_result_dir, exist_ok=True)

    # FIXME: validate binaries? check that they run with 0 return

    cwd = os.getcwd()
    os.chdir(bin_cache_dir)

    exceptions = []

    # check that local cache exists for this binary
    assert bin_cache_dir.is_dir(), f"bad cached binary at {bin_cache_dir}"
    logger.debug("...removing previous results from %s", bin_result_dir)
    clean_previous_chalk_artifacts(bin_cache_dir)

    logger.debug("...running chalk in directory %s", bin_cache_dir)
    process = subprocess.run(
        [
            "chalk",
            "--debug",
            "--log-level=warn",
            "--virtual",
            "insert",
            "./" + bin_name + "_copy",
        ],
        capture_output=True,
    )

    # chalk should not fail if the binaries are valid, which they all should be
    if process.returncode != 0:
        logger.error("chalking binary %s failed: %s", bin_name, process.stderr.decode())

    handle_chalk_output(bin_result_dir, process, exceptions)

    os.chdir(cwd)

    write_exceptions(exceptions, bin_result_dir)

    # TODO: fill this out
    info = ChalkRunInfo(
        # commit=info_commit,
        repo_url=bin_name,
        result_dir=bin_result_dir,
        # image_hash=info_img_hash,
        exceptions=[str(x) for x in exceptions],
        # docker_build_succeded=docker_build.returncode == 0,
    )

    with open(os.path.join(bin_result_dir, "chalk.info"), "w") as choutf:
        choutf.write(info.to_json())

    logger.debug("...chalk run info generated")
    return info


# TODO: fill this out
def chalk_binaries(
    results_dir: Path,
    cache_dir: Path,
) -> List[ChalkRunInfo]:
    # TODO: remove
    print(results_dir, cache_dir)

    bin_list = []
    for name in os.listdir(cache_dir):
        bin_list.append(name)
    if len(bin_list) == 0:
        logger.error("binary cache at %s is empty! no tests will be run", cache_dir)

    # TODO: remove
    print(bin_list)

    results: List[ChalkRunInfo] = []
    for bin in bin_list:
        res = _run_chalk_in_dir(bin, cache_dir / bin, results_dir / bin)
        results.append(res)

    return results


def run_binaries_tests(
    top_level_results: Optional[Path] = None,
    top_level_cache: Optional[Path] = None,
):
    logger.debug("running tests for chalking binaries")

    # create top level result directory in case it doesn't exist
    assert top_level_results is not None, "must specify result output directory"
    os.makedirs(top_level_results, exist_ok=True)
    # create results subdirectory for binaries
    bin_results = top_level_results / "binaries"
    os.makedirs(bin_results, exist_ok=True)

    assert top_level_cache is not None, "must specify cache location"
    bin_cache = top_level_cache / "binaries"
    assert bin_cache.is_dir(), "cache for binaries does not exist!"

    results = chalk_binaries(results_dir=bin_results, cache_dir=bin_cache)
    # TODO:
    logger.error("validate results not implemented")
    # validate_results(results)


if __name__ == "__main__":
    fetch_binaries(Path(__file__).absolute().parent.parent / "cache")
