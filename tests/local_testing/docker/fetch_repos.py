import logging
import os, sys
import requests
import shutil
import subprocess
import multiprocessing
from functools import partial
from pathlib import Path
from typing import Optional

from github import Github
from github.GithubException import UnknownObjectException

logger = logging.getLogger(__name__)

def get_repo_name(repo_url: str) -> str:
    return repo_url.split("/")[-1]

def get_repo_org(repo_url: str) -> str:
    return repo_url.split("/")[-2]

# FIXME: put back some way to pass this in
def github_client(token: Optional[str] = None) -> Github:
    token = token or os.getenv("GITHUB_TOKEN")
    assert token, "Could not retrieve github token"
    return Github(token)
       
# Fetches a filtered list of the top 100 repos that have a 
# `language:dockerfile` present AND has a top-level dockerfile
# but doesn't download anything
def fetch_top_repos(
    gh: Github,
    outf: Path,
) -> None:
    """Fetches the top 100 repos that have a `language:dockerfile` present"""

    url = "https://api.github.com/search/repositories"
    headers = {"Accept": "application/vnd.github.v3+json"}

    query = "language:dockerfile"
    sort = "forks"
    order = "desc"

    response = requests.get(
        f"{url}?q={query}&sort={sort}&order={order}&per_page=100", headers=headers
    )
    data = response.json()

    repos = [result["html_url"] for result in data["items"]]

    # filters out the ones we can't use by check for dockerfile at root
    filtered = sorted(list(filter(partial(_dockerfile_at_root, logger, gh), repos)))

    with open(outf, "w") as out:
        for repo in filtered:
            out.write(f"{repo}\n")


# checks if the repository has a Dockerfile at root
# needs that specific name or later steps will fail
# FIXME: check for arbitrary .dockerfile 
def _dockerfile_at_root(
    gh: Github,
    repo_url: str,
) -> bool:
    logger.info("checking repository %s for dockerfile at root", repo_url)
    repo = gh.get_repo("/".join(repo_url.split("/")[-2:]))
    try:
        return repo.get_contents("Dockerfile") is not None
    except UnknownObjectException:
        return False


# download a single specified repository
def _git_clone_repo(
    repo_url: str,
    cache_dir: Path,
) -> None:
    logger.debug("...downloading repo from %s", repo_url)

    """Download the repo locally unless we have it in the cache already"""

    if not cache_dir.is_dir():
        # see if we need to re-download in our local cache
        # do not download if the cache_dir is already there
        # unless we are forcing a refresh
        try:
            subprocess.run(
                ["git", "clone", "--depth=1", repo_url, cache_dir],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            logger.debug("...%s successfully downloaded", repo_url)
        except subprocess.CalledProcessError as e:
            raise
        except KeyboardInterrupt as e:
            # ctrl+c will clean up partially downloaded files
            # so we don't try to verify them later
            logger.debug("...download of %s interrupted, cleaning up files", repo_url)
            shutil.rmtree(cache_dir, ignore_errors=True)
    else:
        logger.debug("...%s already in cache, skipping download", repo_url)

def fetch_repo(
    repo_url: str,
    *,
    local_cache_dir: Path = None,
):
    logger.info("[START] downloading %s and chalking root Dockerfile...", repo_url)
    """Download the repo locally in temporary file and unless we
    have it in the cache already in which case just cleanup previous artifacts"""

    # check that local repo_cache have been created
    assert local_cache_dir is None or local_cache_dir.is_dir(), f"bad local cache dir for {repo_url} at {local_cache_dir}"

    # cache_dir is local_cache / repo_name / repo_name
    # (unless local cache is empty in which case local_cache becomes a temp directory)
    # repo_name / org_name structure to prevent name conflicts when
    # two different organizations have the same repository name
    repo_name = get_repo_name(repo_url)
    repo_org = get_repo_org(repo_url)
    repo_cache_dir = local_cache_dir / repo_org / repo_name

    try:
        _git_clone_repo(repo_url, repo_cache_dir)
        logger.info("[END] caching complete for %s", repo_url)
    except Exception as e:
        # if something goes wrong with the download, log the exception
        logger.info("[ERROR] download for %s failed: %s", repo_url, str(e))

def repo_fetch(top_level_cache: Path, count: int):
    logger.info("populating repository cache from github")
    # setup github token
    gh = github_client()

    # delete this file if there are issues with top repositories
    # ex: one of them changed and no longer has Dockerfile at root
    repolist = Path(__file__).absolute().parent / "top100_forked.txt"
    if not repolist.is_file():
        logger.info("filtered list at %s does not exist, regenerating", repolist)
        fetch_top_repos(gh, repolist)
        logger.info("filtered list updated")
    
    filtered = repolist.read_bytes().decode().split("\n")[:-1]  # last entry is \n
    # default run on top 10, but don't exceed max
    if count > len(filtered):
        count = len(filtered)
        logger.warn("max count is %s because that's how many we can fetch", count)
    filtered = filtered[:count]
    logger.debug("fetching top %s repos", count)

    # create the cache (sub) directory and set up fetch function
    repo_cache = top_level_cache / "dockerfiles"
    os.makedirs(repo_cache, exist_ok=True)
    fetch = partial(fetch_repo, local_cache_dir=repo_cache)

    # fetch multiple
    pool = multiprocessing.Pool(processes=multiprocessing.cpu_count() // 2 + 1)
    res = pool.map_async(fetch, filtered)
    res.wait()
