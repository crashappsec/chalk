#!/usr/bin/env sh
##
## Copyright (c) 2025, Crash Override, Inc.
##
## This file is part of the Chalk project
## (see https://crashoverride.com/docs/chalk)
##
## list-extension-arns.sh - List all published Lambda extension ARNs

set -e

# Script configuration
SCRIPT_DIR=$(dirname "$0")
SCRIPT_NAME=$(basename "$0")

# Source utilities
. "${SCRIPT_DIR}/lib/common.sh"
. "${SCRIPT_DIR}/aws-regions.sh"

# Default values
LAYER_NAME="${LAYER_NAME:-crashoverride-dust-extension}"
REGION_FILTER="${REGION_FILTER:-all}"

# Usage
usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

List all published Lambda extension ARNs in tab-delimited format.

Options:
  -a, --account-id ID      AWS Account ID (optional, auto-detected if not provided)
  -n, --layer-name NAME    Layer name (default: $LAYER_NAME)
  -R, --regions REGIONS    Comma-separated list of regions to query
  -r, --region-filter FLT  Region filter: all, us, eu, ap, primary (default: all)
  -h, --help               Show this help message

Environment Variables:
  AWS_ACCOUNT_ID           AWS Account ID (can be set instead of -a)
  LAYER_NAME               Layer name (can be set instead of -n)
  AWS_REGIONS              Comma-separated list of regions (can be set instead of -R)
  REGION_FILTER            Region filter (can be set instead of -r)

Output Format:
  Tab-delimited with columns: REGION VERSION ARN

Examples:
  # List all ARNs in all regions
  $SCRIPT_NAME

  # List ARNs in specific regions
  $SCRIPT_NAME -R "us-east-1,us-west-2"

  # List ARNs in US regions only
  $SCRIPT_NAME -r us

  # Use with specific layer name
  $SCRIPT_NAME -n my-custom-layer

EOF
  exit "${1:-0}"
}

# Parse command line arguments
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -a|--account-id)
        AWS_ACCOUNT_ID="$2"
        shift 2
        ;;
      -n|--layer-name)
        LAYER_NAME="$2"
        shift 2
        ;;
      -R|--regions)
        AWS_REGIONS="$2"
        shift 2
        ;;
      -r|--region-filter)
        REGION_FILTER="$2"
        shift 2
        ;;
      -h|--help)
        usage 0
        ;;
      -*)
        log_error "Unknown option: $1"
        usage 1
        ;;
      *)
        log_error "Unexpected argument: $1"
        usage 1
        ;;
    esac
  done
}

# List ARNs in all specified regions
list_arns() {
  regions="$1"

  # Print header
  printf "REGION\tVERSION\tARN\n"
  printf "======\t=======\t===\n"

  # Create temp file for output
  output_file=$(create_temp_file "arns")

  # Track statistics
  total_arns=0
  regions_with_layers=0

  # Query each region and collect results
  for region in $regions; do
    # List layer versions in this region
    versions=$(aws lambda list-layer-versions \
      --layer-name "$LAYER_NAME" \
      --region "$region" \
      --query 'LayerVersions[*].[Version,LayerVersionArn]' \
      --output text 2>/dev/null || true)

    if [ -n "$versions" ]; then
      regions_with_layers=$((regions_with_layers + 1))

      # Process each version and write to file
      echo "$versions" | while IFS='	' read -r version arn; do
        printf "%s\t%s\t%s\n" "$region" "$version" "$arn" >> "$output_file"
      done

      # Count lines added (versions for this region)
      version_count=$(echo "$versions" | wc -l)
      total_arns=$((total_arns + version_count))
    fi
  done

  # Sort and display results
  if [ -f "$output_file" ] && [ -s "$output_file" ]; then
    sort -t'	' -k1,1 -k2,2nr "$output_file"
  fi

  # Clean up
  rm -f "$output_file"

  # Count total regions queried
  total_regions=$(echo "$regions" | wc -w)

  # Print summary
  printf "\n"
  if [ "$total_arns" -eq 0 ]; then
    log_warning "No Lambda extension ARNs found for layer: $LAYER_NAME"
    log_info "Queried $total_regions regions"
  else
    log_info "Found ARNs in $regions_with_layers out of $total_regions regions"
  fi
}

# Main execution
main() {
  # Parse arguments
  parse_args "$@"

  # Get AWS account ID if needed (for display purposes)
  if [ -z "$AWS_ACCOUNT_ID" ]; then
    AWS_ACCOUNT_ID=$(get_aws_account_id)
    if [ -z "$AWS_ACCOUNT_ID" ]; then
      log_warning "Unable to determine AWS Account ID"
    fi
  fi

  # Display configuration
  log_info "Listing Lambda extension ARNs"
  if [ -n "$AWS_ACCOUNT_ID" ]; then
    log_info "AWS Account ID: $AWS_ACCOUNT_ID"
  fi
  log_info "Layer Name: $LAYER_NAME"

  # Get regions to query
  if [ -n "${AWS_REGIONS:-}" ]; then
    # Use explicitly provided regions (comma-separated)
    regions=$(printf "%s" "$AWS_REGIONS" | tr ',' ' ')
    log_info "Using explicitly provided regions"
  else
    # Get regions based on filter
    log_info "Getting AWS regions (filter: $REGION_FILTER)..."
    regions=$(get_deployment_regions "$REGION_FILTER")
  fi

  if [ -z "$regions" ]; then
    log_error "No regions found to query"
    exit 1
  fi

  # List ARNs
  printf "\n"
  list_arns "$regions"
}

# Run main
main "$@"
