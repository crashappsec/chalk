import json
import os
import pprint
import shutil
import sqlite3
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from tempfile import TemporaryDirectory
from typing import Any
from unittest import mock

import boto3
import pytest
import requests

from .chalk.runner import Chalk
from .utils.log import get_logger

logger = get_logger()

CONFIG_DIR = (Path(__file__).parent / "data" / "sink_configs").resolve()


def aws_secrets_configured() -> bool:
    return any(
        [
            all(
                [
                    bool(os.environ.get("AWS_ACCESS_KEY_ID", "")),
                    bool(os.environ.get("AWS_SECRET_ACCESS_KEY", "")),
                ]
            ),
            bool(os.environ.get("AWS_PROFILE", "")),
        ]
    )


def _run_chalk_with_custom_config(
    chalk: Chalk, config_path: Path, target_path: Path
) -> CompletedProcess:
    proc = chalk.run(
        chalk_cmd="insert",
        target=target_path,
        params=[
            "--no-embedded-config",
            "--virtual",
            "--config-file=",
            str(config_path.absolute()),
        ],
    )
    return proc


# validates some basic fields on the chalk output, which should be all the same
# since we will only be chalking one target
def _validate_chalk(
    top_level_chalk: Any,
    path: Path,
) -> None:
    assert top_level_chalk["_OPERATION"] == "insert", "operation expected to be insert"
    assert len(top_level_chalk["_CHALKS"]) == 1, "wrong number of chalks"
    chalk = top_level_chalk["_CHALKS"][0]
    assert chalk["ARTIFACT_PATH"] == str(path / "cat")
    assert chalk["ARTIFACT_TYPE"] == "ELF"


# TODO add a test for the file not being present
@mock.patch.dict(os.environ, {"SINK_TEST_OUTPUT_FILE": "/tmp/sink_file.json"})
def test_file_present(tmp_data_dir: Path, chalk: Chalk):
    logger.debug("testing file sink with an existing file...")
    artifact = tmp_data_dir / "cat"
    shutil.copy("/bin/cat", artifact)

    # prep config file
    file_output_path = Path(os.environ["SINK_TEST_OUTPUT_FILE"])
    if not file_output_path.is_file():
        # touch the file
        open(file_output_path, "a").close()
        os.utime(file_output_path, None)
    assert file_output_path.is_file(), "file sink path must be a valid path"

    config = CONFIG_DIR / "file.conf"
    proc = _run_chalk_with_custom_config(
        chalk=chalk, config_path=config, target_path=artifact
    )

    # check that file output is correct
    if not file_output_path or not file_output_path.is_file():
        logger.error("output file %s does not exist", file_output_path)
        raise AssertionError

    contents = file_output_path.read_bytes()
    if not contents:
        raise AssertionError("file output is empty!?")
    top_level_chalk = json.loads(contents)

    _validate_chalk(top_level_chalk, tmp_data_dir)


@mock.patch.dict(
    os.environ, {"SINK_TEST_OUTPUT_ROTATING_LOG": "/tmp/sink_rotating.json"}
)
def test_rotating_log(tmp_data_dir: Path, chalk: Chalk):
    logger.debug("testing rotating log sink...")
    artifact = Path(tmp_data_dir) / "cat"
    shutil.copy("/bin/cat", artifact)

    assert (
        os.environ["SINK_TEST_OUTPUT_ROTATING_LOG"] != ""
    ), "rotating log output not set"
    rotating_log_output_path = Path(os.environ["SINK_TEST_OUTPUT_ROTATING_LOG"])
    try:
        os.remove(rotating_log_output_path)
    except FileNotFoundError:
        # okay if file doesn't exist
        pass

    config = CONFIG_DIR / "rotating_log.conf"
    proc = _run_chalk_with_custom_config(
        chalk=chalk, config_path=config, target_path=artifact
    )

    # check that file output is correct
    if not rotating_log_output_path or not rotating_log_output_path.is_file():
        logger.error("output file %s does not exist", rotating_log_output_path)
        raise AssertionError

    contents = rotating_log_output_path.read_bytes()
    if not contents:
        raise AssertionError("file output is empty!?")
    top_level_chalk = json.loads(contents)

    _validate_chalk(top_level_chalk, tmp_data_dir)


@pytest.mark.skipif(not aws_secrets_configured(), reason="AWS secrets not configured")
@mock.patch.dict(os.environ, {"AWS_S3_BUCKET_URI": "s3://crashoverride-chalk-tests"})
def test_s3(tmp_data_dir: Path, chalk: Chalk):
    logger.debug("testing s3 sink...")
    artifact = Path(tmp_data_dir) / "cat"
    shutil.copy("/bin/cat", artifact)

    has_access_key = os.environ.get("AWS_ACCESS_KEY_ID") and os.environ.get(
        "AWS_SECRET_ACCESS_KEY"
    )
    logger.info(os.environ.get("AWS_ACCESS_KEY_ID"))
    logger.info(os.environ.get("AWS_SECRET_ACCESS_KEY"))

    aws_profile = os.environ.get("AWS_PROFILE")
    if has_access_key:
        os.environ.pop("AWS_PROFILE")
    try:
        s3 = boto3.client("s3")
        # basic validation of s3 env vars
        assert os.environ["AWS_S3_BUCKET_URI"], "s3 bucket uri must not be empty"

        config = CONFIG_DIR / "s3.conf"
        proc = _run_chalk_with_custom_config(
            chalk=chalk, config_path=config, target_path=artifact
        )

        # get object name out of response code
        logs = proc.stderr.decode().split("\n")
        object_name = ""
        for line in logs:
            # expecting log line from chalk of form `info: Post to: 1686605005558-CSP9AXH5CMXKAE3D9BN8G25K0G-sink-test; response = 200 OK (sink conf='my_s3_config')`
            if "Post to" in line:
                object_name = line.split(" ")[3].strip(";")

        assert object_name != "", "object name could not be found"
        logger.debug("object name fetched from s3 %s", object_name)

        # fetch s3 bucket object and then validate
        bucket_name = "crashoverride-chalk-tests"
        response = s3.get_object(Bucket=bucket_name, Key=object_name)["Body"]
        if not response:
            raise AssertionError("s3 sent empty response?")
        top_level_chalk = json.loads(response.read())

        if not top_level_chalk:
            raise AssertionError("s3 fetched empty chalk json?!")

        _validate_chalk(top_level_chalk, tmp_data_dir)

    finally:
        os.environ["AWS_PROFILE"] = aws_profile


# TODO: currently post only accepts docker events
# fix test when that is added
@pytest.mark.skip("currently POST only accepts docker events")
@mock.patch.dict(
    os.environ,
    {
        "CHALK_POST_URL": "https://chalkapi-test.crashoverride.run/v0.1/report",
        "CHALK_POST_HEADERS": "X-Crashoverride-Id:a779384b-ed4a-441a-95b6-577caeeec081",
    },
)
def test_post():
    logger.debug("testing https sink...")
    with TemporaryDirectory() as _tmp_bin:
        tmp_bin = Path(_tmp_bin)
        artifact = Path(tmp_bin) / "cat"
        shutil.copy("/bin/cat", artifact)

        # post url must be set
        assert os.environ["CHALK_POST_URL"] != "", "post url is not set"

        config = CONFIG_DIR / "post.conf"
        proc = _run_chalk_with_custom_config(config_path=config, target_path=artifact)

        # take the metadata id from stderr where chalk mark is put
        stderr_output = proc.stderr.decode()
        metadata_id = ""
        for line in stderr_output.split("\n"):
            if "METADATA_ID" in line:
                metadata_id = line.split(":")[1].strip().strip('"').lower()

        assert metadata_id != "", "metadata id for created chalk not found in stderr"

        check_url = (
            os.environ["CHALK_POST_URL"].removesuffix("report")
            + "chalks/"
            + metadata_id
        )

        # TODO: checking url doesn't work until miro figures out why the redirects aren't working
        print(check_url)
        print("response...")
        res = requests.get(check_url, allow_redirects=True)
        print(res)


@mock.patch.dict(
    os.environ,
    {
        "CHALK_POST_URL": "http://tests.crashoverride.run:8585/report",
    },
)
def test_post_http_fastapi():
    try:
        r = requests.get("http://tests.crashoverride.run:8585/health")
        if r.status_code != 200:
            raise unittest.SkipTest("Chalk Ingestion Server Down - Skipping")
    except requests.exceptions.ConnectionError:
        raise unittest.SkipTest("Chalk ingestion server unreachable - skipping")
    try:
        dbfile = (
            Path(__file__).parent.parent / "server" / "app" / "data" / "sql_app.db"
        ).resolve()
        if not dbfile.is_file():
            raise unittest.SkipTest("Bad server state - DB file not found - skipping")
        conn = sqlite3.connect(dbfile)
        cur = conn.cursor()
        res = cur.execute("SELECT count(id) FROM stats")
        chalks_cnt = res.fetchone()[0]

        with TemporaryDirectory() as _tmp_bin:
            tmp_bin = Path(_tmp_bin)
            artifact = Path(tmp_bin) / "ls"
            shutil.copy("/bin/ls", artifact)

            # post url must be set
            assert os.environ["CHALK_POST_URL"] != "", "post url is not set"

            config = CONFIG_DIR / "post_beacon_local.conf"
            proc = chalk.run(
                chalk_cmd="insert",
                target=artifact,
                params=[
                    "--no-embedded-config",
                    "--config-file=",
                    str(config.absolute()),
                ],
            )

            stderr_output = proc.stderr.decode()
            for line in stderr_output.split("\n"):
                line = line.strip()
                if line.startswith('"CHALK_ID":'):
                    chalk_id = line.split('CHALK_ID":')[1].split(",")[0].strip()[1:-1]
            assert chalk_id, "metadata id for created chalk not found in stderr"
            cur = conn.cursor()
            res = cur.execute(f"SELECT id FROM chalks WHERE id='{chalk_id}'")
            assert res.fetchone() is not None
            res = cur.execute("SELECT count(id) FROM stats")
            assert res.fetchone()[0] >= chalks_cnt
    finally:
        if conn:
            conn.close()
