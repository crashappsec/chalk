# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import logging

FORMAT = "[%(asctime)s %(filename)s:%(funcName)s:%(lineno)s]%(levelname)s: %(message)s"
FORMATTER = logging.Formatter(FORMAT)
FH = logging.FileHandler("/tmp/crash-override-chalk-config.log")
FH.setLevel(logging.DEBUG)
FH.setFormatter(FORMATTER)


def get_logger(name, level=logging.INFO):
    logger = logging.getLogger(name)
    logger.setLevel(level)
    logger.addHandler(FH)
    return logger
