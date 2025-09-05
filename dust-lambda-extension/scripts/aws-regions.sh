#!/usr/bin/env sh
##
## Copyright (c) 2025, Crash Override, Inc.
##
## This file is part of the Chalk project
## (see https://crashoverride.com/docs/chalk)
##
## aws-regions.sh - Get list of AWS regions for Lambda deployment

set -eu

# Source common utilities
SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/lib/common.sh"

# Default list of AWS regions (as of January 2025)
# This is used as fallback if AWS CLI query fails
readonly DEFAULT_REGIONS="us-east-1 us-east-2 us-west-1 us-west-2
ca-central-1 ca-west-1
eu-west-1 eu-west-2 eu-west-3 eu-central-1 eu-north-1 eu-south-1 eu-south-2 eu-central-2
ap-south-1 ap-south-2 ap-northeast-1 ap-northeast-2 ap-northeast-3 ap-southeast-1 ap-southeast-2 ap-southeast-3 ap-southeast-4 ap-east-1
me-south-1 me-central-1
sa-east-1
af-south-1
il-central-1"

# Get regions that support Lambda
get_lambda_regions() {
  # Try to get regions dynamically from AWS
  if command_exists aws && aws sts get-caller-identity >/dev/null 2>&1; then
    # Get all regions
    all_regions=$(aws ec2 describe-regions --all-regions --query 'Regions[?OptInStatus==`opted-in` || OptInStatus==`opt-in-not-required`].RegionName' --output text 2>/dev/null)

    if [ -n "$all_regions" ]; then
      # Filter for regions that support Lambda
      lambda_regions=""
      for region in $all_regions; do
        # Check if Lambda service is available in this region
        if aws lambda list-functions --region "$region" --max-items 1 >/dev/null 2>&1; then
          if [ -z "$lambda_regions" ]; then
            lambda_regions="$region"
          else
            lambda_regions="$lambda_regions $region"
          fi
        fi
      done

      if [ -n "$lambda_regions" ]; then
        printf "%s" "$lambda_regions"
        return 0
      fi
    fi
  fi

  # Fallback to default list
  log_warning "Unable to query AWS for regions, using default list"
  printf "%s" "$DEFAULT_REGIONS" | tr '\n' ' '
}

# Get regions for deployment (with optional filtering)
get_deployment_regions() {
  filter="${1:-all}"

  regions=$(get_lambda_regions)

  case "$filter" in
    all)
      printf "%s\n" "$regions"
      ;;
    us)
      printf "%s\n" "$regions" | tr ' ' '\n' | grep '^us-' | tr '\n' ' '
      ;;
    eu)
      printf "%s\n" "$regions" | tr ' ' '\n' | grep '^eu-' | tr '\n' ' '
      ;;
    ap)
      printf "%s\n" "$regions" | tr ' ' '\n' | grep '^ap-' | tr '\n' ' '
      ;;
    primary)
      # Primary regions only (one per geographic area)
      printf "us-east-1 eu-west-1 ap-northeast-1 ap-south-1\n"
      ;;
    *)
      log_error "Unknown filter: $filter"
      return 1
      ;;
  esac
}

# Validate a region name
validate_region() {
  region="$1"

  if [ -z "$region" ]; then
    log_error "Region name is empty"
    return 1
  fi

  # Check if region follows AWS naming pattern
  if ! printf "%s" "$region" | grep -E '^[a-z]{2}-[a-z]+-[0-9]+$' >/dev/null 2>&1; then
    log_error "Invalid region format: $region"
    return 1
  fi

  return 0
}

# Count regions
count_regions() {
  regions="$1"
  printf "%s" "$regions" | tr ' ' '\n' | grep -c -v '^$'
}

# Main execution
main() {
  filter="${1:-all}"

  regions=$(get_deployment_regions "$filter")

  if [ -z "$regions" ]; then
    log_error "No regions found"
    exit 1
  fi

  # Output regions
  printf "%s\n" "$regions"

  # Show count if verbose
  if [ "$VERBOSE" = "true" ]; then
    count=$(count_regions "$regions")
    log_info "Found $count regions"
  fi
}

# Run main if executed directly (not sourced)
if [ "${0##*/}" = "aws-regions.sh" ]; then
  main "$@"
fi
