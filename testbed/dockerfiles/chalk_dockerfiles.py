import json
import logging
import multiprocessing
import os
import shutil
import subprocess
from functools import partial
from pathlib import Path
from typing import Any, List, Optional

from ..utils.chalk_run_info import ChalkRunInfo, check_results
from ..utils.output import (
    clean_previous_chalk_artifacts,
    handle_chalk_output,
    write_exceptions,
)

logger = logging.getLogger(__name__)


def _run_chalk_in_dir(
    repo_url: str,
    repo_cache_dir: Path,
    repo_result_dir: Path,
    local_test: bool,
) -> ChalkRunInfo:
    """
    @repo_cache_dir: local dir with cached repo
    @repo_result_dir: place to put results
    """

    cwd = os.getcwd()
    logger.debug("...building dockerfile")
    os.chdir(repo_cache_dir)

    exceptions = []
    try:
        info_commit = (
            os.popen("git log | grep commit | cut -d' ' -f2 | head -n1").read().rstrip()
        )
    except Exception as e:
        exceptions.append(e)
        info_commit = None

    # TODO: sometimes dockerfiles are not called Dockerfile which breaks this build
    # even though they are valid (ex: example.dockerfile will fail here)
    # in theory this shouldn't happen as we are filtering them out
    # so for now clean and retry
    # but in the future we should check for this case

    # tag name of form org/repo, or valid/sample
    tag_name = "/".join(str(repo_result_dir).split("/")[-2:]).lower()
    docker_build = subprocess.run(
        [
            "docker",
            "build",
            "-t",
            tag_name,
            "--platform=linux/amd64",
            ".",
        ],
        capture_output=True,
    )
    if docker_build.returncode != 0:
        # if docker build fails, it might be because docker is down
        # or throttling us, so print error in case we want to check
        decoded_stderr = docker_build.stderr.decode().split("\n")
        docker_build_error = ""
        for line in decoded_stderr:
            if "ERROR" in line:
                docker_build_error = line
                break
        logger.error("[ERROR] dockerfile build failed")
        logger.error("[ERROR] " + docker_build_error)

    logger.debug("...chalking docker build")
    process = subprocess.run(
        [
            "chalk",
            "--debug",
            "--log-level=warn",
            "--virtual",
            "docker",
            "build",
            "-t",
            tag_name,
            "--platform=linux/amd64",
            ".",
        ],
        capture_output=True,
    )

    # chalk should not fail if the docker builds are valid
    if process.returncode != 0:
        logger.error("chalking docker build failed")

    # if docker passes, chalk should never fail
    if docker_build.returncode == 0 and process.returncode != 0:
        exceptions.append(
            RuntimeError(
                f"Docker build succeeded but unexpected return code running chalk on {repo_cache_dir}: {process.returncode}",
                repo_cache_dir,
                process.returncode,
            )
        )
    # it is also weird if the docker fails but the chalk passes
    elif docker_build.returncode != 0 and process.returncode == 0:
        exceptions.append(
            RuntimeError(
                f"Docker build failed with {docker_build.returncode} but running chalk succeeded on on {repo_cache_dir}",
                docker_build.returncode,
                repo_cache_dir,
            )
        )

    handle_chalk_output(repo_result_dir, process, exceptions)

    os.chdir(cwd)

    # try to find image hash from image tag
    try:
        logger.debug("...inspecting docker image %s for hash", tag_name)
        docker_inspect = subprocess.run(
            ["docker", "inspect", tag_name], capture_output=True
        )
    except Exception as e:
        logger.error("docker inspect failed")
        exceptions.append(e)

    # this returns an array of json for some reason
    inspect_json = json.loads(docker_inspect.stdout.decode())
    images = []
    for i in inspect_json:
        hash = i["Id"].split("sha256:")[1]
        images.append(hash)

    info_img_hash = None
    for image in images:
        info_img_hash = image
        logger.debug("removing image %s", info_img_hash)
        try:
            subprocess.run(
                ["docker", "image", "rm", info_img_hash],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except subprocess.CalledProcessError as e:
            # it's probably fine but alert just in case
            logger.warning("[WARN] docker image removal failed: %s", str(e))
    if info_img_hash is None:
        logger.error("image hash info not stored")

    write_exceptions(exceptions, repo_result_dir)

    logger.debug("...generating chalk run info")

    if local_test:
        # we are running on hardcoded tests, so git commit + url will not make sense
        info_commit = ""
        repo_url = str(repo_result_dir)

    info = ChalkRunInfo(
        local_test=local_test,
        commit=info_commit,
        repo_url=repo_url,
        result_dir=repo_result_dir,
        image_hash=info_img_hash,
        exceptions=[str(x) for x in exceptions],
        docker_build_succeded=docker_build.returncode == 0,
    )

    with open(os.path.join(repo_result_dir, "chalk.info"), "w") as choutf:
        choutf.write(info.to_json())

    logger.debug("...chalk run info generated")
    return info


def _chalk_dockerfile_in_repo(
    repo: List[str],
    *,
    cache_dir: Path,
    result_dir: Path,
    local_test: bool,
) -> ChalkRunInfo:
    # repo is tuple of org name and repo name
    repo_url = "https://github.com/" + repo[0] + "/" + repo[1]
    repo_cache_dir = cache_dir / repo[0] / repo[1]

    logger.info("[START] chalking %s", repo_cache_dir)
    # check that local cache exists for this repository
    assert repo_cache_dir.is_dir(), f"bad cached repo at {repo_cache_dir}"
    # clean previous chalk marks to prepare for rechalking
    # in case we have a cached repo from previously
    clean_previous_chalk_artifacts(repo_cache_dir)

    repo_result_dir = result_dir / repo[0] / repo[1]
    # cleanup previous chalk output for this repo_url
    logger.debug("...removing previous results from %s", repo_result_dir)
    shutil.rmtree(repo_result_dir, ignore_errors=True)
    os.makedirs(repo_result_dir, exist_ok=True)

    try:
        chalk_run_info = _run_chalk_in_dir(
            repo_url, repo_cache_dir, repo_result_dir, local_test
        )
    except KeyboardInterrupt:
        logger.info("chalking interrupted, cleaning up current repository...")
        clean_previous_chalk_artifacts(repo_cache_dir)
        shutil.rmtree(repo_result_dir, ignore_errors=True)
    logger.info("[END] done chalking %s", repo_url)

    return chalk_run_info


def validate_results(results: List[ChalkRunInfo]):
    if results:
        for result in results[0]:
            try:
                check = check_results(result)
                if check[0]:
                    logger.info("[PASS] %s", result.repo_url)
                else:
                    logger.info("========== [FAIL]")

                # pass or fail might both have warnings
                if check[1] != "":
                    logger.info("========== [WARN] %s", check[1])
            except Exception as e:
                logger.error("check results has error " + str(e))
                continue
    else:
        logger.error("Did not get any results back")


def chalk_dockerfiles(
    results_dir: Path,
    cache_dir: Path,
    local_test: bool,
) -> List[ChalkRunInfo]:
    chalk_all = partial(
        _chalk_dockerfile_in_repo,
        cache_dir=cache_dir,
        result_dir=results_dir,
        local_test=local_test,
    )

    # list of cached repositories to chalk
    repo_list = []
    results: List[ChalkRunInfo] = []

    # otherwise run chalk on every repo we can find
    for org in os.listdir(cache_dir):
        for repo in os.listdir(cache_dir / org):
            repo_list.append([org, repo])
    if len(repo_list) == 0:
        logger.error(
            "repository cache at %s is empty! fetch repositories to populate cache before attempting to chalk",
            cache_dir,
        )
        # empty results so we don't break anything
        # technically this isn't an error so we don't raise
        return results

    # TODO: remove
    # pool = multiprocessing.Pool(processes=multiprocessing.cpu_count() // 2 + 1)
    pool = multiprocessing.Pool(processes=1)
    res = pool.map_async(chalk_all, repo_list, callback=results.append)
    res.wait()

    return results


def run_dockerfile_tests(
    local_test: bool,
    top_level_results: Optional[Path] = None,
    top_level_cache: Optional[Path] = None,
):
    if local_test:
        # local tests are stored already
        dockerfile_cache = Path(__file__).absolute().parent / "test_dockerfiles"
        assert dockerfile_cache.is_dir(), "local test does not exist"
        # create results
        dockerfile_results = Path(__file__).absolute().parent / "test_results"
        os.makedirs(dockerfile_results, exist_ok=True)
    else:
        assert top_level_results is not None, "must specify result output directory"
        # create top level result directory in case it doesn't exist
        os.makedirs(top_level_results, exist_ok=True)
        # create results subdirectory for dockerfiles
        dockerfile_results = top_level_results / "dockerfiles"
        os.makedirs(dockerfile_results, exist_ok=True)

        assert top_level_cache is not None, "must specify cache location"
        dockerfile_cache = top_level_cache / "dockerfiles"
        assert dockerfile_cache.is_dir(), "repo cache for dockerfiles does not exist!"

    results = chalk_dockerfiles(
        results_dir=dockerfile_results,
        cache_dir=dockerfile_cache,
        local_test=local_test,
    )
    validate_results(results)
