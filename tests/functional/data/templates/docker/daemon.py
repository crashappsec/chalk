#!/usr/bin/env python3

import argparse
import json
import pathlib
import sys

import os


IP = os.environ.get("IP", "localhost")

parser = argparse.ArgumentParser()
parser.add_argument(
    "path",
    help="path to daemon.json",
    type=pathlib.Path,
)
parser.add_argument(
    "-w",
    "--write",
    action="store_true",
    help="whether to write the changes back into config file",
)
parser.add_argument(
    "-f",
    "--fail-on-changes",
    action="store_true",
    help="whether to exit with exit_code 1 when any changes were made",
)

if __name__ == "__main__":
    args = parser.parse_args()
    path: pathlib.Path = args.path

    if path.is_file():
        config = json.loads(path.read_text())
    else:
        config = {}
    updated = config.copy()
    updated["insecure-registries"] = sorted(
        set(updated.get("insecure-registries", []))
        | {
            "localhost:5044",
            "registry:5044",
            f"{IP}:5044",
            f"{IP}:5046",
            f"{IP}:5047",
        }
    )
    has_changes = config != updated
    formatted = json.dumps(updated, indent=4)

    if not has_changes:
        sys.exit(0)

    print(formatted)
    if args.write:
        path.write_text(formatted)
    if args.fail_on_changes:
        sys.exit(1)
