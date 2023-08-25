"""
Logging configuration.

The following env vars are supported to customize logs:

LOG_FORMAT
    primary format how logs are formatted. can be:
        * json
        * console
    by default if terminal is interactive console is used and otherwise json

LOG_LEVEL
    default logging level for all logs
    should be any of the standard logging levels succh as DEBUG,INFO,etc

LOGGER_<dotpath>
    override log configuration for specific modules
    format is <level>[:<handler>]
    <level> is any of the standard logging levels such as DEBUG,INFO,etc
    <handler> is either:
        * default
        * null
    this allows to either silence unwanted logs or surgically increase logging
    verbosity dynamically via environment variables
    examples:
        LOGGER_integrations.foo=INFO
        LOGGER_integrations.bar=INFO:default
        LOGGER_integrations.bar=DEBUG:null
"""
import logging
import logging.config
import os
import sys
from typing import Any, Iterable, List, TypedDict, cast

import structlog
import structlog.types

__all__ = ("get_logger",)


def is_interactive() -> bool:
    return sys.stdout.isatty() and sys.stderr.isatty()


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


PROCESSOR_MAPPING = {
    "json": structlog.processors.JSONRenderer(),
    "console": structlog.dev.ConsoleRenderer(),
}

LOG_FORMAT = os.environ.get("LOG_FORMAT", "")
RENDERER = PROCESSOR_MAPPING.get(
    LOG_FORMAT,
    PROCESSOR_MAPPING["console"] if is_interactive() else PROCESSOR_MAPPING["json"],
)

LEVEL = (os.environ.get("LOG_LEVEL") or "INFO").upper()

SHARED_PROCESSORS: Iterable[structlog.types.Processor] = [
    doctest_processor,
    structlog.stdlib.add_log_level,
    structlog.stdlib.add_logger_name,
    structlog.processors.TimeStamper(fmt="iso"),
]

STRUCTLOG_PROCESSORS: Iterable[structlog.types.Processor] = filter(
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


class Logger(TypedDict):
    level: str
    handlers: List[str]
    propagate: bool


def override_to_logger(override: str) -> Logger:
    config = dict(list(zip(["level", "handler"], override.split(":"))))
    return {
        "level": config.get("level", LEVEL).upper(),
        "handlers": [config.get("handler", "default").lower()],
        # cannot bubble up logs as overrides will be ignored then
        "propagate": False,
    }


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
                "handlers": ["default"],
            },
            **{
                k.replace("LOGGER_", "").lower(): cast(Any, override_to_logger(v))
                for k, v in os.environ.items()
                if k.startswith("LOGGER_") and v
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
