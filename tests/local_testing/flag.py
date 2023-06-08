import argparse
from pathlib import Path

root_dir = Path(__file__).absolute().parent


def parse_arguments():
    parser = argparse.ArgumentParser()

    # set directory to store local test data
    # path for individual modules will be [cache] / [modulename] / [test name]
    parser.add_argument(
        "--cache",
        type=lambda p: Path(p).absolute(),
        default=root_dir / "cache",
        help="set cache directory for test data (ex: repositores downloaded)",
    )

    # specify single module to run on
    parser.add_argument("--module", type=str, help="ex: docker, bin, etc.")

    # clean cache and cache results
    parser.add_argument(
        "--clean",
        action="store_true",
        help="remove local cache and results",
    )

    # populate cache
    parser.add_argument(
        "--fetch",
        action="store_true",
        help="populate local cache",
    )

    # set directory to store local result outputs
    # path for individual modules will be [results] / [modulename] / [test name]
    parser.add_argument(
        "--results",
        type=lambda p: Path(p).absolute(),
        default=root_dir / "results",
        help="set result directory for chalk result outputs",
    )

    parser.add_argument(
        "--count",
        type=int,
        default=10,
        help="number of repositories/etc to fetch that will be validated (default 10)",
    )

    parser.add_argument(
        "--debug",
        action="store_true",
        help="enable debug logging",
    )

    return parser.parse_args()
