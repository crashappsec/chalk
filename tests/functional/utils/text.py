# Copyright (c) 2023-2026, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import json
import re
from typing import Any, Optional


def after_match(text: str, match: Optional[str] = None) -> str:
    if match:
        found = list(re.finditer(match, text))
        if found:
            i = found[0].start(0)
        else:
            i = 0
        text = text[i:]
    return text


def valid_json(
    text: str,
    *,
    after: Optional[str] = None,
    everything: bool = True,
) -> tuple[Any, int]:
    text = after_match(text, match=after)
    try:
        return json.loads(text), len(text)
    except json.JSONDecodeError as e:
        # if there is extra data we grab valid json until the
        # invalid character
        e_str = str(e)
        if everything or not e_str.startswith("Extra data:"):
            raise
        # Extra data: line 25 column 1 (char 596)
        char = int(e_str.split()[-1].strip(")"))
        return json.loads(text[:char]), char
