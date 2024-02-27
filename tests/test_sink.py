# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import json
from pathlib import Path
from typing import Any, Callable

import boto3
import os
import pytest
import requests

from .chalk.runner import Chalk
from .conf import CAT_PATH, SERVER_CERT, SERVER_HTTP, SERVER_HTTPS, SINK_CONFIGS
from .utils.log import get_logger


logger = get_logger()


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
    single_chalk: dict[str, Any],
    path: Path,
) -> None:
    assert single_chalk["_OPERATION"] == "insert", "operation expected to be insert"
    assert len(single_chalk["_CHALKS"]) == 1, "wrong number of chalks"
    chalk = single_chalk["_CHALKS"][0]
    assert chalk["PATH_WHEN_CHALKED"] == str(path / "cat")
    assert chalk["ARTIFACT_TYPE"] == "ELF"


# TODO add a test for the file not being present
@pytest.mark.parametrize("copy_files", [[CAT_PATH]], indirect=True)
def test_file_present(tmp_data_dir: Path, chalk: Chalk, copy_files: list[Path]):
    artifact = copy_files[0]

    # prep config file
    file_output_path = Path("/tmp/sink_file.json")
    if not file_output_path.is_file():
        # touch the file
        open(file_output_path, "a").close()
        os.utime(file_output_path, None)
    assert file_output_path.is_file(), "file sink path must be a valid path"

    config = SINK_CONFIGS / "file.c4m"
    chalk.insert(
        config=config,
        artifact=artifact,
        env={"SINK_TEST_OUTPUT_FILE": str(file_output_path)},
    )

    # check that file output is correct
    assert file_output_path.is_file(), "file sink should exist after chalk operation"

    contents = file_output_path.read_text()
    assert contents
    chalks = json.loads(contents)
    assert len(chalks) == 1
    _validate_chalk(chalks[0], tmp_data_dir)


@pytest.mark.parametrize("copy_files", [[CAT_PATH]], indirect=True)
def test_rotating_log(tmp_data_dir: Path, copy_files: list[Path], chalk: Chalk):
    artifact = copy_files[0]

    rotating_log_output_path = Path("/tmp/sink_rotating.json")
    rotating_log_output_path.unlink(missing_ok=True)

    config = SINK_CONFIGS / "rotating_log.c4m"
    chalk.insert(
        config=config,
        artifact=artifact,
        env={"SINK_TEST_OUTPUT_ROTATING_LOG": str(rotating_log_output_path)},
    )

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
@pytest.mark.parametrize("copy_files", [[CAT_PATH]], indirect=True)
def test_s3(tmp_data_dir: Path, copy_files: list[Path], chalk: Chalk):
    artifact = copy_files[0]

    os.environ.pop("AWS_PROFILE")

    s3 = boto3.client("s3")

    config = SINK_CONFIGS / "s3.c4m"
    proc = chalk.insert(
        config=config,
        artifact=artifact,
        log_level="info",
        env={"AWS_S3_BUCKET_URI": "s3://crashoverride-chalk-tests/sink-test.json"},
    )

    # expecting log line from chalk of form
    # info: Post to: 1686605005558-CSP9AXH5CMXKAE3D9BN8G25K0G-sink-test; response = 200 OK (sink conf='my_s3_config')
    object_name = proc.find("Post to:", words=1, text=proc.logs).strip(";")
    assert object_name.endswith(".json")
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


@pytest.mark.parametrize("copy_files", [[CAT_PATH]], indirect=True)
def test_post_wrong_method(
    copy_files: list[Path],
    chalk: Chalk,
    server_http: str,
    server_https: str,
):
    """
    even if server scheme is invalid chalk should not segfault but simply should not send report
    """
    server = SERVER_HTTPS.replace("https", "http")
    result = chalk.insert(
        copy_files[0],
        config=SINK_CONFIGS / "post_https_local.c4m",
        env={
            # this server needs to return http->https redirect
            # e.g. such as nginx redirecting all http traffic to https
            "CHALK_USAGE_URL": f"{server_http}/redirect",
            "CHALK_POST_URL": f"{server}/report",
        },
    )
    assert result
    metadata_id = result.mark["METADATA_ID"]
    response = requests.get(
        f"{server_https}/chalks/{metadata_id}",
        allow_redirects=True,
        timeout=5,
        verify=False,
    )
    assert response.status_code == 404


@pytest.mark.parametrize("copy_files", [[CAT_PATH]], indirect=True)
def test_post_http_fastapi(
    copy_files: list[Path],
    chalk: Chalk,
    server_sql: Callable[[str], str | None],
    server_http: str,
):
    _test_server(
        artifact=copy_files[0],
        chalk=chalk,
        conf="post_https_local.c4m",
        url=server_http,
        server_sql=server_sql,
        verify=None,
        env={
            "CHALK_USAGE_URL": f"{SERVER_HTTP}/ping",
            "CHALK_POST_URL": f"{SERVER_HTTP}/report",
            # testing if chalk at least parses headers correctly
            "CHALK_POST_HEADERS": "x-test-header: test-header",
        },
    )


@pytest.mark.parametrize("copy_files", [[CAT_PATH]], indirect=True)
def test_post_https_fastapi(
    copy_files: list[Path],
    chalk: Chalk,
    server_sql: Callable[[str], str | None],
    server_https: str,
    server_cert: str,
):
    _test_server(
        artifact=copy_files[0],
        chalk=chalk,
        conf="post_https_local.c4m",
        url=server_https,
        server_sql=server_sql,
        verify=server_cert,
        env={
            "CHALK_USAGE_URL": f"{SERVER_HTTPS}/ping",
            "CHALK_POST_URL": f"{SERVER_HTTPS}/report",
            # testing if chalk at least parses headers correctly
            "CHALK_POST_HEADERS": "x-test-header: test-header",
            "TLS_CERT_FILE": str(SERVER_CERT),
        },
    )


@pytest.mark.parametrize("copy_files", [[CAT_PATH]], indirect=True)
def test_presign_http_fastapi(
    copy_files: list[Path],
    chalk: Chalk,
    server_sql: Callable[[str], str | None],
    server_http: str,
):
    _test_server(
        artifact=copy_files[0],
        chalk=chalk,
        conf="presign_http_local.c4m",
        url=server_http,
        server_sql=server_sql,
        verify=None,
        env={
            "CHALK_POST_URL": f"{SERVER_HTTP}/report/presign",
            # testing if chalk at least parses headers correctly
            "CHALK_POST_HEADERS": "x-test-header: test-header",
        },
    )


def _test_server(
    artifact: Path,
    chalk: Chalk,
    conf: str,
    url: str,
    server_sql: Callable[[str], str | None],
    verify: str | None,
    env: dict[str, str],
):
    initial_chalks_count = int(server_sql("SELECT count(*) FROM chalks") or 0)

    # post url must be set
    assert env["CHALK_POST_URL"] != "", "post url is not set"

    config = SINK_CONFIGS / conf
    proc = chalk.run(
        command="insert",
        target=artifact,
        config=config,
        use_embedded=False,
        log_level="trace",
        env=env,
    )

    metadata_id = proc.mark["METADATA_ID"]
    assert metadata_id, "metadata id for created chalk not found in stderr"

    db_id = server_sql(f"SELECT chalk_id FROM chalks WHERE metadata_id='{metadata_id}'")
    assert db_id is not None

    chalks_count = int(server_sql("SELECT count(*) FROM chalks") or 0)
    # tests can run in parallel so we cant know exact number except it has to be higher
    assert chalks_count > initial_chalks_count

    # get the chalk from the api
    response = requests.get(
        f"{url}/chalks/{metadata_id}", allow_redirects=True, timeout=5, verify=verify
    )
    response.raise_for_status()
    fetched_chalk = response.json()
    assert fetched_chalk["METADATA_ID"] == metadata_id
