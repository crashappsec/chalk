import json
import os
import shutil
import sqlite3
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from time import sleep
from typing import Any, Dict
from unittest import mock

import boto3
import pytest
import requests

from .chalk.runner import Chalk
from .utils.docker import compose_run_local_server, stop_container
from .utils.log import get_logger

logger = get_logger()

CONFIG_DIR = (Path(__file__).parent / "data" / "sink_configs").resolve()
TLS_CERT_PATH = (
    Path(__file__).parent.parent / "server" / "app" / "keys" / "self-signed.cert"
).resolve()

IN_GITHUB_ACTIONS = os.getenv("GITHUB_ACTIONS") or False


def aws_secrets_configured() -> bool:
    return all(
        [
            bool(os.environ.get("AWS_ACCESS_KEY_ID", "")),
            bool(os.environ.get("AWS_SECRET_ACCESS_KEY", "")),
        ]
    )


# validates some basic fields on the chalk output, which should be all the same
# since we will only be chalking one target
def _validate_chalk(
    single_chalk: Dict[str, Any],
    path: Path,
) -> None:
    assert single_chalk["_OPERATION"] == "insert", "operation expected to be insert"
    assert len(single_chalk["_CHALKS"]) == 1, "wrong number of chalks"
    chalk = single_chalk["_CHALKS"][0]
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
    chalk.run_with_custom_config(config_path=config, target_path=artifact)

    # check that file output is correct
    if not file_output_path or not file_output_path.is_file():
        logger.error("output file %s does not exist", file_output_path)
        raise AssertionError

    contents = file_output_path.read_bytes()
    if not contents:
        raise AssertionError("file output is empty!?")
    chalks = json.loads(contents)
    assert len(chalks) == 1
    _validate_chalk(chalks[0], tmp_data_dir)


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
    chalk.run_with_custom_config(config_path=config, target_path=artifact)

    # check that file output is correct
    if not rotating_log_output_path or not rotating_log_output_path.is_file():
        logger.error("output file %s does not exist", rotating_log_output_path)
        raise AssertionError

    contents = rotating_log_output_path.read_bytes()
    if not contents:
        raise AssertionError("file output is empty!?")
    chalks = json.loads(contents)

    _validate_chalk(chalks[0], tmp_data_dir)


@pytest.mark.skipif(not aws_secrets_configured(), reason="AWS secrets not configured")
# FIXME add some tests for the different options of `/` in S3 URIs
@mock.patch.dict(os.environ, {"AWS_S3_BUCKET_URI": "s3://crashoverride-chalk-tests/"})
def test_s3(tmp_data_dir: Path, chalk: Chalk):
    logger.debug("testing s3 sink...")
    artifact = Path(tmp_data_dir) / "cat"
    shutil.copy("/bin/cat", artifact)

    has_access_key = os.environ.get("AWS_ACCESS_KEY_ID") and os.environ.get(
        "AWS_SECRET_ACCESS_KEY"
    )

    aws_profile = os.environ.get("AWS_PROFILE")
    if has_access_key:
        os.environ.pop("AWS_PROFILE")
    try:
        s3 = boto3.client("s3")
        # basic validation of s3 env vars
        assert os.environ["AWS_S3_BUCKET_URI"], "s3 bucket uri must not be empty"

        config = CONFIG_DIR / "s3.conf"
        proc = chalk.run_with_custom_config(config_path=config, target_path=artifact)
        assert proc is not None
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
        chalks = json.loads(response.read())

        if not chalks:
            raise AssertionError("s3 fetched empty chalk json?!")

        _validate_chalk(chalks[0], tmp_data_dir)

    finally:
        if aws_profile:
            os.environ["AWS_PROFILE"] = aws_profile


# TODO: enable test when 400 error is fixed
@pytest.mark.skip("missing headers when sending from chalk")
@mock.patch.dict(
    os.environ,
    {
        "CHALK_POST_URL": "https://chalkapi-test.crashoverride.run/v0.1/report",
        "CHALK_POST_HEADERS": "X-Crashoverride-Id:a779384b-ed4a-441a-95b6-577caeeec081",
    },
)
def test_post(tmp_data_dir: Path, chalk: Chalk):
    logger.debug("testing https sink...")
    with TemporaryDirectory() as _tmp_bin:
        tmp_bin = Path(_tmp_bin)
        artifact = Path(tmp_bin) / "cat"
        shutil.copy("/bin/cat", artifact)

        # post url must be set
        assert os.environ["CHALK_POST_URL"] != "", "post url is not set"

        config = CONFIG_DIR / "post.conf"
        proc = chalk._run_with_custom_config(
            chalk=chalk, config_path=config, target_path=artifact
        )
        assert proc is not None
        # take the metadata id from stderr where chalk mark is put
        _output = proc.stdout.decode()

        metadata_id = ""
        for line in _output.split("\n"):
            line = line.strip()
            if line.startswith('"METADATA_ID":'):
                metadata_id = line.split('METADATA_ID":')[1].split(",")[0].strip()[1:-1]

        assert metadata_id != "", "metadata id for created chalk not found in stderr"

        check_url = (
            os.environ["CHALK_POST_URL"].removesuffix("report")
            + "chalks/"
            + metadata_id
        )

        # TODO: checking url won't work until 400 error is fixed in nimutils
        logger.info(check_url)
        logger.info("response...")
        res = requests.get(check_url, allow_redirects=True)
        logger.info(res)


@pytest.mark.skipif(
    bool(IN_GITHUB_ACTIONS),
    reason="Test doesn't work in Github Actions. Need to debug networking",
)
@mock.patch.dict(
    os.environ,
    {
        "CHALK_POST_URL": "http://chalk.crashoverride.local:8585/report",
    },
)
def test_post_http_fastapi(tmp_data_dir: Path, chalk: Chalk):
    try:
        server_id = None
        conn = None
        try:
            server_id = compose_run_local_server()
            assert server_id
            logger.debug("Spin up local http server with id", server_id=server_id)
            sleep(2)
            r = requests.get(
                "http://chalk.crashoverride.local:8585/health",
                allow_redirects=True,
                timeout=10,
            )
            if r.status_code != 200:
                raise unittest.SkipTest("Chalk Ingestion Server Down - Skipping")
        except requests.exceptions.ConnectionError:
            logger.error("Chalk ingestion server unreachable")
            raise unittest.SkipTest("Chalk Ingestion Server Unreachable - Skipping")
        logger.debug("Server healthcheck passed")
        dbfile = (
            Path(__file__).parent.parent
            / "server"
            / "app"
            / "db"
            / "data"
            / "chalkdb.sqlite"
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

            config = CONFIG_DIR / "post_http_local.conf"
            proc = chalk.run(
                chalk_cmd="insert",
                target=artifact,
                params=[
                    "--no-use-embedded-config",
                    "--config-file=",
                    str(config.absolute()),
                ],
            )
            assert proc is not None
            _output = proc.stdout.decode()
            for line in _output.split("\n"):
                line = line.strip()
                if line.startswith('"CHALK_ID":'):
                    chalk_id = line.split('CHALK_ID":')[1].split(",")[0].strip()[1:-1]
            assert chalk_id, "metadata id for created chalk not found in stderr"
            cur = conn.cursor()
            res = cur.execute(f"SELECT id FROM chalks WHERE id='{chalk_id}'")
            assert res.fetchone() is not None, "could not get chalk entry from sqlite"
            res = cur.execute("SELECT count(id) FROM stats")
            assert (
                res.fetchone()[0] > chalks_cnt
            ), "Could not get ping entry from sqlite"
    finally:
        # if server_id:
        #     stop_container(server_id)
        if conn:
            conn.close()


@pytest.mark.skipif(
    bool(IN_GITHUB_ACTIONS),
    reason="Test doesn't work in Github Actions. Need to debug networking",
)
@mock.patch.dict(
    os.environ,
    {
        "CHALK_POST_URL": "https://chalk.crashoverride.local:8585/report",
        "TLS_CERT_FILE": str(TLS_CERT_PATH),
    },
)
def test_post_https_fastapi(tmp_data_dir: Path, chalk: Chalk):
    try:
        server_id = None
        conn = None
        try:
            assert TLS_CERT_PATH.is_file()
            server_id = compose_run_local_server(https=True)
            assert server_id
            logger.debug("Spin up local https server with id", server_id=server_id)
            sleep(2)
            r = requests.get(
                "https://chalk.crashoverride.local:8585/health",
                allow_redirects=True,
                timeout=10,
                verify=TLS_CERT_PATH,
            )
            if r.status_code != 200:
                raise unittest.SkipTest("Chalk Ingestion Server Down - Skipping")
        except requests.exceptions.ConnectionError as e:
            logger.error(e)
            logger.error("Chalk ingestion server unreachable")
            raise unittest.SkipTest("Chalk Ingestion Server Unreachable - Skipping")
        logger.debug("Server healthcheck passed")
        dbfile = (
            Path(__file__).parent.parent
            / "server"
            / "app"
            / "db"
            / "data"
            / "chalkdb.sqlite"
        ).resolve()
        if not dbfile.is_file():
            raise unittest.SkipTest("Bad server state - DB file not found - skipping")
        conn = sqlite3.connect(dbfile)
        cur = conn.cursor()
        res = cur.execute("SELECT count(id) FROM stats")
        chalks_cnt = res.fetchone()[0]

        with TemporaryDirectory() as _tmp_bin:
            tmp_bin = Path(_tmp_bin)
            artifact = Path(tmp_bin) / "cat"
            shutil.copy("/bin/cat", artifact)

            # post url must be set
            assert os.environ["CHALK_POST_URL"] != "", "post url is not set"

            config = CONFIG_DIR / "post_https_local.conf"
            proc = chalk.run(
                chalk_cmd="insert",
                target=artifact,
                params=[
                    "--trace",
                    "--no-use-embedded-config",
                    "--config-file=",
                    str(config.absolute()),
                ],
            )
            assert proc is not None
            _output = proc.stdout.decode()
            for line in _output.split("\n"):
                line = line.strip()
                if line.startswith('"CHALK_ID":'):
                    chalk_id = line.split('CHALK_ID":')[1].split(",")[0].strip()[1:-1]
            assert chalk_id, "metadata id for created chalk not found in stderr"
            cur = conn.cursor()
            res = cur.execute(f"SELECT id FROM chalks WHERE id='{chalk_id}'")
            assert res.fetchone() is not None, "could not get chalk entry from sqlite"
            # XXX ping currently does not work with self signed certs
            # res = cur.execute("SELECT count(id) FROM stats")
            # assert (
            #     res.fetchone()[0] > chalks_cnt
            # ), "Could not get ping entry from sqlite"
    finally:
        if server_id:
            stop_container(server_id)
        if conn:
            conn.close()
