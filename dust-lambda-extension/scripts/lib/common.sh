#!/usr/bin/env sh
##
## Copyright (c) 2025, Crash Override, Inc.
##
## This file is part of the Chalk project
## (see https://crashoverride.com/docs/chalk)
##
## common.sh - Common utilities for deployment scripts

set -eu

# Color codes for output (POSIX-compliant)
if [ -t 1 ]; then
  RED=$(printf '\033[0;31m')
  GREEN=$(printf '\033[0;32m')
  YELLOW=$(printf '\033[0;33m')
  BLUE=$(printf '\033[0;34m')
  RESET=$(printf '\033[0m')
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  RESET=""
fi

# Logging functions
log_info() {
  printf "${BLUE}[INFO]${RESET} %s\n" "$1" >&2
}

log_success() {
  printf "${GREEN}[SUCCESS]${RESET} %s\n" "$1" >&2
}

log_warning() {
  printf "${YELLOW}[WARN] %s\n" "$1${RESET}" >&2
}

log_error() {
  printf "${RED}[ERROR] %s\n" "$1${RESET}" >&2
}

# Check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Validate AWS CLI is installed and configured
validate_aws_cli() {
  if ! command_exists aws; then
    log_error "AWS CLI is not installed. Please install it first."
    return 1
  fi

  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_error "AWS credentials are not configured or are invalid."
    log_error "Please configure AWS credentials using 'aws configure' or environment variables."
    return 1
  fi

  return 0
}

# Get AWS account ID
get_aws_account_id() {
  aws sts get-caller-identity --query Account --output text 2>/dev/null
}

# Validate required environment variables
validate_env_var() {
  var_name="$1"
  var_value="$2"

  if [ -z "$var_value" ]; then
    log_error "$var_name is not set. Please provide it as an environment variable or make argument."
    return 1
  fi

  return 0
}

# Check if git repository is clean
check_git_clean() {
  if ! command_exists git; then
    log_warning "git is not installed, skipping dirty check"
    return 0
  fi

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log_warning "Not in a git repository, skipping dirty check"
    return 0
  fi

  if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    return 1
  fi

  return 0
}

# Create a temporary file (POSIX-compliant)
create_temp_file() {
  tmpdir="${TMPDIR:-/tmp}"
  template="${1:-dust-deploy}"

  # Use mktemp if available, otherwise fallback
  if command_exists mktemp; then
    mktemp "${tmpdir}/${template}.XXXXXX"
  else
    # Fallback for systems without mktemp
    # Use process ID and timestamp for uniqueness
    timestamp=$(date +%s 2>/dev/null || date +%Y%m%d%H%M%S)
    tmpfile="${tmpdir}/${template}.$$.${timestamp}"
    touch "$tmpfile"
    printf "%s" "$tmpfile"
  fi
}

# Clean up temporary files
cleanup_temp_files() {
  if [ -n "$TEMP_FILES" ]; then
    for file in $TEMP_FILES; do
      if [ -f "$file" ]; then
        rm -f "$file"
      fi
    done
  fi
}

# Set up trap for cleanup on exit
setup_cleanup_trap() {
  trap cleanup_temp_files EXIT INT TERM
}

# Wait for background processes and collect results
wait_for_jobs() {
  failed_count=0

  while [ "$(jobs -p | wc -l)" -gt 0 ]; do
    for pid in $(jobs -p); do
      if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid"
        exit_code=$?
        if [ $exit_code -ne 0 ]; then
          failed_count=$((failed_count + 1))
        fi
      fi
    done
    sleep 1
  done

  return $failed_count
}

# Progress indicator
show_progress() {
  current=$1
  total=$2
  description="${3:-Processing}"

  percentage=$((current * 100 / total))
  printf "\r${BLUE}[%3d%%]${RESET} %s: %d/%d" "$percentage" "$description" "$current" "$total" >&2

  if [ "$current" -eq "$total" ]; then
    printf "\n" >&2
  fi
}
