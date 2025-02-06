# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
"""
Logging configuration.

The following env vars are supported to customize logs:

LOG_LEVEL
    default logging level for all logs
    should be any of the standard logging levels succh as DEBUG,INFO,etc
"""
import logging
import logging.config
import os
import pathlib
import sys
from typing import Any, Iterable, TypedDict, cast

import _pytest.logging
import structlog
import structlog.types


__all__ = ("get_logger",)


def dotname(obj: Any) -> str:
    return f"{obj.__module__}.{obj.__name__}"


def doctest_processor(
    logger: logging.Logger, method_name: str, event_dict: structlog.types.EventDict
) -> structlog.types.EventDict:
    if event_dict.pop("doctest", False):
        print(  # noqa
            event_dict.pop("event", None),
            *[f"{k}={v}" for k, v in sorted(event_dict.items())],
        )
        raise structlog.DropEvent
    return event_dict


def path_processor(
    logger: logging.Logger, method_name: str, event_dict: structlog.types.EventDict
) -> structlog.types.EventDict:
    for k, v in event_dict.items():
        if isinstance(v, pathlib.Path):
            event_dict[k] = str(v)
    return event_dict


class Console(structlog.dev.ConsoleRenderer):
    def _repr(self, val: Any) -> str:
        if isinstance(val, str):
            return val
        return repr(val)


RENDERER = Console()

LEVEL = (os.environ.get("LOG_LEVEL") or "INFO").upper()

SHARED_PROCESSORS: Iterable[structlog.types.Processor] = [
    doctest_processor,
    path_processor,
    structlog.stdlib.add_log_level,
    structlog.stdlib.add_logger_name,
    structlog.processors.TimeStamper(fmt="iso"),
]

STRUCTLOG_PROCESSORS: Iterable[structlog.types.Processor] = list(
    filter(
        None,
        [
            (
                # non-console renderers need format_exc_info processor
                # so that exc_info is correctly converted to a string
                # in the final log message
                # however console renderer direcly processes exc_info
                # to show pretty colors and therefore format_exc_info
                # is omitted when ConsoleRenderer is used
                structlog.processors.format_exc_info
                if not isinstance(RENDERER, structlog.dev.ConsoleRenderer)
                else None
            ),
            structlog.processors.StackInfoRenderer(),
            structlog.stdlib.ProcessorFormatter.wrap_for_formatter,
        ],
    )
)


class Logger(TypedDict):
    level: str
    handlers: list[str]
    propagate: bool


def create_formatter(self, *args, **kwargs):
    return structlog.stdlib.ProcessorFormatter(
        processor=RENDERER, foreign_pre_chain=SHARED_PROCESSORS
    )


# pytest does not allow to customize the formatter class externally
# but we can monkey-patch it for compatibility
_pytest.logging.LoggingPlugin._create_formatter = cast(Any, create_formatter)


logging.config.dictConfig(
    {
        "version": 1,
        "formatters": {
            "main": {
                "()": structlog.stdlib.ProcessorFormatter,
                "processor": RENDERER,
                "foreign_pre_chain": SHARED_PROCESSORS,
            }
        },
        "handlers": {
            "default": {
                "class": dotname(logging.StreamHandler),
                "level": logging.DEBUG,
                "formatter": "main",
            },
            "null": {
                "class": dotname(logging.NullHandler),
            },
        },
        "loggers": {
            # root logger config
            "": {
                "level": LEVEL,
                "handlers": [
                    (
                        "null"
                        # pytest captures logs
                        if "pytest" in " ".join(sys.argv)
                        # else we report logs to stderr
                        else "default"
                    ),
                ],
            },
            "uvicorn": {
                "handlers": ["default"],
                "level": "INFO",
                "propagate": False,
            },
        },
    }
)

structlog.configure(
    processors=[
        structlog.stdlib.filter_by_level,
        *SHARED_PROCESSORS,
        *STRUCTLOG_PROCESSORS,
    ],
    logger_factory=structlog.stdlib.LoggerFactory(),
    cache_logger_on_first_use=True,
)

structlog.contextvars.clear_contextvars()

get_logger = structlog.stdlib.get_logger
