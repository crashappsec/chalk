import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

from mashumaro.mixins.json import DataClassJSONMixin


# FIXME: remove kw_only and also re-order attributes so that fields with default values follow after the ones without, so that this is compatible with older versions of python like 3.9
@dataclass(kw_only=True)
class ChalkRunInfo(DataClassJSONMixin):
    # local test is true if we are running on hardcoded dockerfiles
    # and false if we are running on repo_cache from github
    local_test: bool

    # only valid for repositories we've downloaded from github
    repo_url: str
    """https url for the repository analyzed"""
    commit: Optional[str] = field(default=None)
    """commit hash in the repo as cloned"""

    result_dir: Path
    """path with the results for this repo"""
    image_hash: Optional[str] = field(default=None)
    """hash of the image built by docker"""
    exceptions: Optional[List[str]] = field(default=None)
    """exceptions that occurred"""
    docker_build_succeded: Optional[bool] = field(default=True)


# FIXME: not currently used
def load_chalk_run_info(result_dir: Path) -> ChalkRunInfo:
    if not result_dir.is_dir():
        raise AssertionError("%s is not a directory", result_dir.absolute())
    elif not (result_dir / "chalk.info").is_file():
        raise AssertionError("%s/chalk.info is not a file", result_dir.absolute())
    return ChalkRunInfo.from_json((result_dir / "chalk.info").read_bytes())


def _check_virtual_chalk(info: ChalkRunInfo) -> str:
    jsonpath = info.result_dir / "virtual-chalk.json"
    if not jsonpath or not jsonpath.is_file():
        raise AssertionError("File virtual-chalk.json does not exist")
    chalk_id = ""
    try:
        contents = jsonpath.read_bytes()
        if not contents:
            raise AssertionError("Empty virtual-chalk.json")
        vchalk = json.loads(contents)
    except json.decoder.JSONDecodeError:
        raise AssertionError("Bad virtual-chalk json")

    assert vchalk["MAGIC"] == "dadfedabbadabbed", "Broken virtual-chalk.json"
    # checked against chalk report
    chalk_id = vchalk["CHALK_ID"]
    return chalk_id


def _check_chalk_reports(info: ChalkRunInfo) -> str:
    jsonpath = info.result_dir / "chalk-reports.jsonl"
    if not jsonpath or not jsonpath.is_file():
        raise AssertionError("File chalk-reports.jsonl does not exist")
    chalk_id = ""
    with open(jsonpath, "r") as report:
        for line in report:
            vchalk = json.loads(line.strip())
            try:
                if not info.local_test:
                    # only "real" github repos will have this
                    assert vchalk["COMMIT_ID"] == info.commit, "commit ID mismatch"
                    assert vchalk["ORIGIN_URI"] == info.repo_url, "Bad ORIGIN URI"
                    # for now we are only pulling from main branches
                    assert (
                        vchalk["BRANCH"] == "main" or vchalk["BRANCH"] == "master"
                    ), "branch is expected to be main or master"
                if info.docker_build_succeded:
                    assert (
                        len(vchalk["_CHALKS"]) == 1
                    ), f"Unexpected entries in _CHALKS (got {len(vchalk['_CHALKS'])})"
                    chalk = vchalk["_CHALKS"][0]
                    assert (
                        chalk["_CURRENT_HASH"] == info.image_hash
                    ), "Bad docker image hash"
                    chalk_id = chalk["CHALK_ID"]
                else:
                    assert (
                        vchalk.get("_CHALKS") is None
                    ), "Docker build did not succeed but we have a _CHALK"
            except AssertionError as e:
                raise e
            except KeyError as e:
                raise AssertionError("Broken chalk") from e
    return chalk_id


def check_results(info: ChalkRunInfo) -> tuple[bool, str]:
    try:
        if info.docker_build_succeded is True:
            # if docker succeeded, we should be able to check virtual chalks/chalk reports
            chalk_id_vchalk = _check_virtual_chalk(info)
            chalk_id_report = _check_chalk_reports(info)
            assert chalk_id_vchalk == chalk_id_report, "chalk ids do not match"
            # TODO: verify that chalked image has labels
            return True, ""
        elif not (info.result_dir / "chalk.exceptions").is_file():
            # otherwise, check if there are any unexpected exceptions, and if not
            return (
                True,
                f"docker build for {info.repo_url} failed, errors match but no chalking has been done",
            )
        else:
            # any other errors are unexpected (ex: cp failed in a way that wasn't file doesn't exist)
            assert not (
                info.result_dir / "chalk.exceptions"
            ).is_file(), (
                "encountered unexpected exceptions, check chalk.exceptions file"
            )

    except AssertionError as e:
        return False, str(e)
