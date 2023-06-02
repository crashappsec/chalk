import json
import logging
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

from mashumaro.mixins.json import DataClassJSONMixin

logger = logging.getLogger(__name__)


# magic value taken from config to compare against
CHALK_MAGIC = "dadfedabbadabbed"


# FIXME: remove kw_only and also re-order attributes so that fields with default values follow after the ones without, so that this is compatible with older versions of python like 3.9
@dataclass
class ChalkRunInfo(DataClassJSONMixin):
    # chalk common fields
    local_test: bool
    """local test is true if we are running on hardcoded testdata and false if we are running on populated caches"""
    result_dir: Path
    """path with the results for this repo"""
    exceptions: List[str]
    """exceptions that occurred"""
    module: str
    """module for the test (binaries, dockerfiles, etc)"""
    insertion_hostinfo: str
    """uname info for host running chalk"""
    insertion_nodename: str
    """uname info for node running chalk"""
    virtual: bool
    """if chalk was run with --virtual mode"""
    artifact_path: str
    """path to chalked artifact"""
    artifact_type: str
    """type of chalked artifact"""
    operation: str
    """chalk operation performed"""
    chalk_ok: bool
    """chalk was successful or not"""

    # dockerfiles
    repo_url: Optional[str] = field(default=None)
    """https url for the repository analyzed, only valid for repositories we've downloaded from github"""
    commit: Optional[str] = field(default=None)
    """commit hash in the repo as cloned"""
    branch: Optional[str] = field(default=None)
    """git branch of the repo"""
    image_hash: Optional[str] = field(default=None)
    """hash of the image built by docker"""
    docker_build_succeded: Optional[bool] = field(default=True)
    """whether the dockerfile actually built or not by itself"""


# stores some fields common between virtual chalk and chalk-reports
# for sanity checking
@dataclass
class CrossChalkCheck:
    chalk_id: str
    chalk_rand: str
    metadata_hash: str
    metadata_id: str
    source: str
    """virtual chalk or chalk-reports"""

    def validate(self):
        assert self.chalk_id != "", f"chalk id in {self.source} should not be empty"
        assert self.chalk_rand != "", f"chalk rand in {self.source} should not be empty"
        assert (
            self.metadata_hash != ""
        ), f"metadata_hash in {self.source} should not be empty"
        assert (
            self.metadata_id != ""
        ), f"metadata_id in {self.source} should not be empty"


# FIXME: not currently used
def load_chalk_run_info(result_dir: Path) -> ChalkRunInfo:
    if not result_dir.is_dir():
        raise AssertionError("%s is not a directory", result_dir.absolute())
    elif not (result_dir / "chalk.info").is_file():
        raise AssertionError("%s/chalk.info is not a file", result_dir.absolute())
    return ChalkRunInfo.from_json((result_dir / "chalk.info").read_bytes())


# runs uname -v and returns result
def get_insertion_hostinfo() -> str:
    try:
        uname = subprocess.run(["uname", "-v"], capture_output=True)
        insertion_hostinfo = uname.stdout.decode().strip()
        return insertion_hostinfo
    except:
        return ""


# runs uname -n and returns result
def get_insertion_nodename() -> str:
    try:
        uname = subprocess.run(["uname", "-n"], capture_output=True)
        insertion_nodename = uname.stdout.decode().strip()
        return insertion_nodename
    except:
        return ""


def _check_virtual_chalk(info: ChalkRunInfo) -> CrossChalkCheck:
    logging.debug("checking virtual-chalk.json...")
    jsonpath = info.result_dir / "virtual-chalk.json"
    if not jsonpath or not jsonpath.is_file():
        raise AssertionError("File virtual-chalk.json does not exist")

    try:
        contents = jsonpath.read_bytes()
        if not contents:
            raise AssertionError("Empty virtual-chalk.json")
        vchalk = json.loads(contents)
    except json.decoder.JSONDecodeError as e:
        raise AssertionError("Error decoding virtual-chalk json: %s", e)

    assert (
        vchalk["MAGIC"] == CHALK_MAGIC
    ), "virtual-chalk.json magic does not match expected value"
    # fields returned to be checked against chalk-reports.jsonl
    # chalk id - returned to check against chalk json
    # chalk rand - returned to check against chalk json
    # metadata hash -- returned to check against chalk json
    # metadata id -- returned to check against chalk json
    check = CrossChalkCheck(
        chalk_id=vchalk["CHALK_ID"],
        chalk_rand=vchalk["CHALK_RAND"],
        metadata_hash=vchalk["METADATA_HASH"],
        metadata_id=vchalk["METADATA_ID"],
        source="virtual-chalk.json",
    )
    return check


def _check_chalk_reports(info: ChalkRunInfo) -> CrossChalkCheck:
    logging.debug("checking chalk-reports.jsonl...")
    jsonpath = info.result_dir / "chalk-reports.jsonl"
    if not jsonpath or not jsonpath.is_file():
        raise AssertionError("File chalk-reports.jsonl does not exist")

    try:
        contents = jsonpath.read_bytes()
        if not contents:
            raise AssertionError("Empty chalk-reports.jsonl")
        top_level_chalk = json.loads(contents)
    except json.decoder.JSONDecodeError as e:
        raise AssertionError("Error decoding chalk-reports.jsonl: %s", e)

    # FIXME: assuming only 1 chalk in each report here
    sub_chalk = top_level_chalk["_CHALKS"][0]

    assert (
        top_level_chalk["INSERTION_HOSTINFO"] == info.insertion_hostinfo
    ), "insertion hostinfo doesn't match"
    assert (
        top_level_chalk["INSERTION_NODENAME"] == info.insertion_nodename
    ), "insertion node name doesn't match"
    assert sub_chalk["_VIRTUAL"] == info.virtual, "virtual doesn't match"
    assert (
        sub_chalk["ARTIFACT_PATH"] == info.artifact_path
    ), "artifact path does not match"
    assert (
        sub_chalk["ARTIFACT_TYPE"] == info.artifact_type
    ), "artifact type does not match"
    assert (
        top_level_chalk["_OPERATION"] == info.operation
    ), "operation type does not match"

    check = CrossChalkCheck(
        chalk_id=sub_chalk["CHALK_ID"],
        chalk_rand=top_level_chalk["CHALK_RAND"],
        metadata_hash=sub_chalk["METADATA_HASH"],
        metadata_id=sub_chalk["METADATA_ID"],
        source="chalk-reports.jsonl",
    )
    return check


# check generic chalk fields in virtual chalk and chalk reports
# module-specific fields are handled by the module
def check_results(info: ChalkRunInfo) -> tuple[bool, str]:
    try:
        if not info.chalk_ok:
            return True, "chalk was not expected to be successful, skipping checks..."

        assert not info.exceptions, "unexpected exceptions"

        virtual_chalk_check = _check_virtual_chalk(info)
        virtual_chalk_check.validate()

        chalk_report_check = _check_chalk_reports(info)
        chalk_report_check.validate()

        assert (
            virtual_chalk_check.chalk_id == chalk_report_check.chalk_id
        ), "chalk_id does not match between virtual chalk and chalk reports"
        assert (
            virtual_chalk_check.chalk_rand == chalk_report_check.chalk_rand
        ), "chalk_rand does not match between virtual chalk and chalk reports"
        assert (
            virtual_chalk_check.metadata_hash == chalk_report_check.metadata_hash
        ), "metadata_hash does not match between virtual chalk and chalk reports"
        assert (
            virtual_chalk_check.metadata_id == chalk_report_check.metadata_id
        ), "metadata_id does not match between virtual chalk and chalk reports"
        return True, ""

    except AssertionError as e:
        return False, str(e)
