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
