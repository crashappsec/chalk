from pathlib import Path
import logging, sys
import shutil

from .utils.flag import parse_arguments
from .dockerfiles.fetch_repos import repo_fetch
from .dockerfiles.chalk_dockerfiles import run_dockerfile_tests
from .binaries.binaries import fetch_binaries, run_binaries_tests

logger = logging.getLogger(__name__)

def clean(dir: Path, module: str):
    logger.info("cleaning %s", dir / module)
    shutil.rmtree(dir / module, ignore_errors=True, onerror=None)

def fetch(dir: Path, module: str, count: int):
    logger.info("populating cache for %s", module)
    if module == "dockerfiles":
        logger.info("fetching top %s repositories with dockerfiles", count)
        repo_fetch(top_level_cache=dir, count=count)
    elif module == "binaries":
        logger.info("fetching top %s binaries from bin", count)
        fetch_binaries(top_level_cache=dir, count=count)
    else:
        logger.error("unknown module %s", module)

def chalk_and_validate(cache_dir: Path, result_dir: Path, module: str):
    logger.info("chalk and validate %s", module)
    if module == "dockerfiles":
        try:
            # first run tests for locally stored dockerfiles
            run_dockerfile_tests(local_test=True)

            # run tests on cached repos
            run_dockerfile_tests(local_test=False, top_level_results=result_dir, top_level_cache=cache_dir)
        except AssertionError as e:
            logger.error("dockerfile tests broke")
            logger.error(e)
    elif module == "binaries":
        try:
            # tests on stored binaries
            run_binaries_tests(local_test=True)
            # run tests on cached binaries
            run_binaries_tests(local_test=False, top_level_results=result_dir, top_level_cache=cache_dir)
        except AssertionError as e:
            logger.error("binaries tests broke")
            logger.error(e)
    else:
        logger.error("unknown module %s", module)

if __name__ == "__main__":
    args = parse_arguments()

    # TODO: logging to file?
    logger.setLevel(logging.INFO)
    handler = logging.StreamHandler(sys.stdout)

    if args.debug:
        logging.basicConfig(level=logging.DEBUG)
        handler.setLevel(logging.DEBUG)
    else:
        logging.basicConfig(level=logging.INFO)
        handler.setLevel(logging.INFO)
        
    logger.addHandler(handler)
    logging.debug("debug on")

    # top level cache for downloaded data
    cache_dir = args.cache
    # top level results on downloaded data
    result_dir = args.results

    # by default, all test types here
    modules = ["dockerfiles", "binaries"]
    # if module was specified, only run on that one
    if args.module:
        if args.module not in modules:
            logger.error("unknown module %s", args.module)
            sys.exit(1)
        modules = [args.module]

    # TODO: remove
    print(cache_dir, result_dir, modules)

    # clean results and cache, then exit
    if args.clean:
        for mod in modules:
            clean(cache_dir, mod)
            clean(result_dir, mod)
        sys.exit(0)

    # fetch top x repositories, binaries, etc, then exit
    if args.fetch:
        for mod in modules:
            fetch(cache_dir, mod, args.count)
        sys.exit(0)

    # chalk and validate
    for mod in modules:
        chalk_and_validate(cache_dir, result_dir, mod)

    # TODO: verify flag (without chalking)
    # TODO: verify single
