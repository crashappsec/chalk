# Readme
Fetches repositories with Dockerfiles from github, runs chalk, and checks results.

# Setup
To run tests on github reposities, repo cache must first be populated
1. ensure personal github access token is set (needed to download repositories) to env var "GITHUB_TOKEN"
2. (optional) clean out cached repositories with `python -m testbed.run_tests --clean`
3. `python -m testbed.run_tests --fetch` will fetch top 10 repos to populate repository cache

# Run
1. `python -m testbed.run_tests` will chalk and validate all repos in current cache + test repos
2. output will say if tests passed or not -- some may require manual validation (ex: dockerfile didn't build)
