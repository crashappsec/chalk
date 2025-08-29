#!/usr/bin/env sh
##
## Copyright (c) 2025, Crash Override, Inc.
##
## This file is part of the Chalk project
## (see https://crashoverride.com/docs/chalk)
##
## delete-layer.sh - Delete Lambda layer versions from AWS regions

set -e

# Script configuration
SCRIPT_DIR=$(dirname "$0")
SCRIPT_NAME=$(basename "$0")

# Source utilities
. "${SCRIPT_DIR}/lib/common.sh"
. "${SCRIPT_DIR}/aws-regions.sh"

# Default values
LAYER_NAME="${LAYER_NAME:-crashoverride-dust-extension}"
DRY_RUN="${DRY_RUN:-false}"
DELETE_ALL="${DELETE_ALL:-false}"
BATCH_SIZE="${BATCH_SIZE:-5}"
VERBOSE="${VERBOSE:-false}"

# Tracking
SUCCESSFUL_DELETIONS=""
FAILED_DELETIONS=""
TEMP_FILES=""

# Usage
usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Delete Lambda layer versions from AWS regions.

Options:
  -a, --account-id ID      AWS Account ID (required, or set AWS_ACCOUNT_ID)
  -n, --layer-name NAME    Layer name (default: $LAYER_NAME)
  -r, --region REGION      AWS region (required unless using --regions)
  -R, --regions LIST       Comma-separated list of regions
  -V, --version VERSION    Specific version to delete (delete all if not specified)
  -A, --all                Delete all versions (requires confirmation)
  -d, --dry-run            Show what would be deleted without deleting
  -y, --yes                Skip confirmation prompts
  -v, --verbose            Enable verbose output
  -h, --help               Show this help message

Environment Variables:
  AWS_ACCOUNT_ID          AWS Account ID (can be set instead of -a)
  LAYER_NAME              Layer name (can be set instead of -n)

Examples:
  # List all versions in a region (dry-run)
  $SCRIPT_NAME -a 123456789012 -r us-east-1 -d

  # Delete specific version
  $SCRIPT_NAME -a 123456789012 -r us-east-1 -V 5

  # Delete all versions in a region (with confirmation)
  $SCRIPT_NAME -a 123456789012 -r us-east-1 -A

  # Delete all versions in multiple regions
  $SCRIPT_NAME -a 123456789012 -R us-east-1,us-west-2 -A

  # Skip confirmation with environment variable
  export AWS_ACCOUNT_ID=123456789012
  $SCRIPT_NAME -r us-east-1 -A -y

EOF
  exit "${1:-0}"
}

# Parse command line arguments
parse_args() {
  SKIP_CONFIRMATION="false"
  SPECIFIC_VERSION=""
  REGION=""
  REGIONS=""

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
      -r|--region)
        REGION="$2"
        shift 2
        ;;
      -R|--regions)
        REGIONS="$2"
        shift 2
        ;;
      -V|--version)
        SPECIFIC_VERSION="$2"
        shift 2
        ;;
      -A|--all)
        DELETE_ALL="true"
        shift
        ;;
      -d|--dry-run)
        DRY_RUN="true"
        shift
        ;;
      -y|--yes)
        SKIP_CONFIRMATION="true"
        shift
        ;;
      -v|--verbose)
        VERBOSE="true"
        export VERBOSE
        shift
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

  # Validate required arguments
  if [ -z "$REGION" ] && [ -z "$REGIONS" ]; then
    log_error "Either --region or --regions is required"
    usage 1
  fi

  if [ -n "$REGION" ] && [ -n "$REGIONS" ]; then
    log_error "Cannot specify both --region and --regions"
    usage 1
  fi

  if [ -z "$SPECIFIC_VERSION" ] && [ "$DELETE_ALL" != "true" ]; then
    log_error "Must specify either --version or --all"
    usage 1
  fi

  if [ -n "$SPECIFIC_VERSION" ] && [ "$DELETE_ALL" = "true" ]; then
    log_error "Cannot specify both --version and --all"
    usage 1
  fi

  # Convert single region to regions list
  if [ -n "$REGION" ]; then
    REGIONS="$REGION"
  fi

  # Convert comma-separated to space-separated
  REGIONS=$(printf "%s" "$REGIONS" | tr ',' ' ')

  # Get AWS account ID if not provided
  if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    log_info "AWS_ACCOUNT_ID not provided, attempting to get from AWS CLI..."
    AWS_ACCOUNT_ID=$(get_aws_account_id)
    if [ -z "$AWS_ACCOUNT_ID" ]; then
      log_error "Unable to determine AWS Account ID"
      log_error "Please provide it via -a option or AWS_ACCOUNT_ID environment variable"
      exit 1
    fi
    log_info "Using AWS Account ID: $AWS_ACCOUNT_ID"
  fi
}

# Get layer versions in a region
get_layer_versions() {
  region="$1"
  layer_name="$2"

  if [ "${VERBOSE:-false}" = "true" ]; then
    log_info "Fetching versions for $layer_name in $region..."
  fi

  versions=$(aws lambda list-layer-versions \
    --layer-name "$layer_name" \
    --region "$region" \
    --query "LayerVersions[*].Version" \
    --output text 2>/dev/null) || {
    # Check if layer doesn't exist
    error_msg=$(aws lambda list-layer-versions \
      --layer-name "$layer_name" \
      --region "$region" 2>&1 | grep -o "ResourceNotFoundException" || true)

    if [ -n "$error_msg" ]; then
      log_warning "Layer '$layer_name' not found in region $region"
      return 1
    else
      log_error "Failed to list versions for '$layer_name' in $region"
      return 1
    fi
  }

  if [ -z "$versions" ]; then
    log_warning "No versions found for layer '$layer_name' in region $region"
    return 1
  fi

  printf "%s" "$versions"
}

# Delete a specific layer version
delete_layer_version() {
  region="$1"
  layer_name="$2"
  version="$3"
  output_file="$4"

  if [ "$DRY_RUN" = "true" ]; then
    printf "DRY-RUN: Would delete %s:%s (version %s)\n" "$region" "$layer_name" "$version" >> "$output_file"
    return 0
  fi

  if aws lambda delete-layer-version \
    --layer-name "$layer_name" \
    --version-number "$version" \
    --region "$region" >/dev/null 2>&1; then
    printf "SUCCESS: Deleted %s:%s (version %s)\n" "$region" "$layer_name" "$version" >> "$output_file"
    return 0
  else
    printf "ERROR: Failed to delete %s:%s (version %s)\n" "$region" "$layer_name" "$version" >> "$output_file"
    return 1
  fi
}

# Delete layer versions in a region
delete_in_region() {
  region="$1"

  log_info "Processing region: $region"

  # Get versions to delete
  if [ -n "$SPECIFIC_VERSION" ]; then
    versions="$SPECIFIC_VERSION"
  else
    versions=$(get_layer_versions "$region" "$LAYER_NAME") || return 1
  fi

  if [ -z "$versions" ]; then
    return 0
  fi

  # Count versions
  version_count=$(printf "%s" "$versions" | wc -w)

  if [ "$DRY_RUN" = "true" ]; then
    log_info "Found $version_count version(s) that would be deleted in $region:"
    for version in $versions; do
      log_info "  - Version $version"
    done
  else
    log_info "Found $version_count version(s) to delete in $region"
  fi

  # Delete each version
  for version in $versions; do
    output_file=$(create_temp_file "delete-${region}-${version}")
    TEMP_FILES="$TEMP_FILES $output_file"

    delete_layer_version "$region" "$LAYER_NAME" "$version" "$output_file"

    # Process result
    if [ -f "$output_file" ]; then
      result=$(cat "$output_file")

      if printf "%s" "$result" | grep -q "^SUCCESS"; then
        SUCCESSFUL_DELETIONS="$SUCCESSFUL_DELETIONS ${region}:${version}"
        log_success "$result"
      elif printf "%s" "$result" | grep -q "^DRY-RUN"; then
        log_info "$result"
      else
        FAILED_DELETIONS="$FAILED_DELETIONS ${region}:${version}"
        log_error "$result"
      fi

      rm -f "$output_file"
    fi
  done
}

# Process all regions
process_all_regions() {

  if [ "$DELETE_ALL" = "true" ] && [ "$SKIP_CONFIRMATION" != "true" ] && [ "$DRY_RUN" != "true" ]; then
    printf "\n"
    log_warning "WARNING: This will delete ALL versions of layer '$LAYER_NAME' in the following region(s):"
    for region in $REGIONS; do
      log_warning "  - $region"
    done
    printf "\n"
    printf "Are you sure you want to continue? (yes/no): "
    read -r confirmation
    if [ "$confirmation" != "yes" ]; then
      log_info "Operation cancelled"
      exit 0
    fi
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_warning "DRY-RUN MODE: No actual deletions will be made"
  fi

  # Process each region
  for region in $REGIONS; do
    delete_in_region "$region"
  done
}

# Print summary
print_summary() {
  printf "\n"
  log_info "========================================="
  log_info "          DELETION SUMMARY"
  log_info "========================================="

  if [ "$DRY_RUN" = "true" ]; then
    log_warning "DRY-RUN MODE: No actual deletions were made"
    return 0
  fi

  # Count successes and failures
  success_count=$(printf "%s" "$SUCCESSFUL_DELETIONS" | wc -w)
  failure_count=$(printf "%s" "$FAILED_DELETIONS" | wc -w)

  if [ "$success_count" -gt 0 ]; then
    log_success "Successfully deleted $success_count version(s)"
    if [ "${VERBOSE:-false}" = "true" ]; then
      log_info "Successful deletions:"
      for item in $SUCCESSFUL_DELETIONS; do
        log_info "  - $item"
      done
    fi
  fi

  if [ "$failure_count" -gt 0 ]; then
    log_error "Failed to delete $failure_count version(s)"
    log_error "Failed deletions:"
    for item in $FAILED_DELETIONS; do
      log_error "  - $item"
    done
  fi

  if [ "$success_count" -eq 0 ] && [ "$failure_count" -eq 0 ]; then
    log_info "No versions to delete"
  fi
}

# Main execution
main() {
  # Set up cleanup trap
  setup_cleanup_trap

  # Parse arguments
  parse_args "$@"

  # Validate AWS CLI
  if [ "$DRY_RUN" != "true" ]; then
    log_info "Validating AWS CLI configuration..."
    if ! validate_aws_cli; then
      exit 1
    fi
  fi

  # Display account info
  log_info "Using AWS Account ID: $AWS_ACCOUNT_ID"
  log_info "Layer name: $LAYER_NAME"

  # Process all regions
  process_all_regions

  # Print summary
  print_summary

  # Exit with appropriate code
  if [ -n "$FAILED_DELETIONS" ] && [ "$DRY_RUN" != "true" ]; then
    exit 1
  fi

  exit 0
}

# Run main
main "$@"
