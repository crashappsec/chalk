import logging.config


def config():
    config = {
        "version": 1,
        "disable_existing_loggers": False,
        "formatters": {
            "default": {
                "()": "uvicorn.logging.DefaultFormatter",
                "fmt": "%(levelprefix)s %(name)-20s %(message)s",
                "use_colors": None,
            },
        },
        "handlers": {
            "default": {
                "formatter": "default",
                "class": "logging.StreamHandler",
                "stream": "ext://sys.stderr",
            },
        },
        "loggers": {
            __name__.split(".")[0]: {
                "handlers": ["default"],
                "level": "INFO",
                "propagate": False,
            },
            "uvicorn": {
                "handlers": ["default"],
                "level": "INFO",
                "propagate": False,
            },
        },
    }
    logging.config.dictConfig(config)
    # remove double logging from uvicorn
    uvicorn_logger = logging.getLogger("uvicorn")
    uvicorn_logger.propagate = False
