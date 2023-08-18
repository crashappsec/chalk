import json
from subprocess import CompletedProcess
from typing import Any, Dict

from .log import get_logger

logger = get_logger()


# chalk report is {} json object with _CHALKS array
def get_liftable_key(chalk_report: Dict[str, Any], key: str) -> Any:
    if key in chalk_report:
        return chalk_report[key]
    elif key in chalk_report["_CHALKS"][0]:
        return chalk_report["_CHALKS"][0][key]
    else:
        raise KeyError(key)


def get_chalk_report_from_output(proc: CompletedProcess) -> Dict[str, Any]:
    # # FIXME: hacky json read of report that has to stop before we reach logs and ignore beginning docker output

    _output = proc.stdout.decode()
    json_start = _output.find("[\n")
    json_end = _output.rfind("]")

    json_string = _output[json_start : json_end + 1]
    if json_string != "":
        chalk_reports = json.loads(json_string)
        assert len(chalk_reports) == 1
        chalk_report = chalk_reports[0]
        return chalk_report
    else:
        raise Exception("json chalk report is empty!")
