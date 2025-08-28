#!/usr/bin/env sh
##
## Copyright (c) 2025, Crash Override, Inc.
##
## This file is part of the Chalk project
## (see https://crashoverride.com/docs/chalk)
##
## deploy-layer.sh - Deploy Lambda layer to all AWS regions

set -e

# Script configuration
SCRIPT_DIR=$(dirname "$0")
SCRIPT_NAME=$(basename "$0")

# Source utilities
. "${SCRIPT_DIR}/lib/common.sh"
. "${SCRIPT_DIR}/aws-regions.sh"

# Default values
LAYER_NAME="${LAYER_NAME:-crashoverride-dust-extension}"
BATCH_SIZE="${BATCH_SIZE:-5}"
DRY_RUN="${DRY_RUN:-false}"
REGION_FILTER="${REGION_FILTER:-all}"
COMPATIBLE_RUNTIMES="${COMPATIBLE_RUNTIMES:-provided.al2 provided.al2023}"
COMPATIBLE_ARCHITECTURES="${COMPATIBLE_ARCHITECTURES:-x86_64}"

# Deployment tracking
SUCCESSFUL_REGIONS=""
FAILED_REGIONS=""
TEMP_FILES=""

# Usage
usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] <archive_path>

Deploy Lambda layer to multiple AWS regions with public access.

Arguments:
  archive_path              Path to the layer ZIP archive

Options:
  -a, --account-id ID      AWS Account ID (required, or set AWS_ACCOUNT_ID)
  -n, --layer-name NAME    Layer name (default: $LAYER_NAME)
  -r, --regions FILTER     Region filter: all, us, eu, ap, primary (default: all)
  -b, --batch-size SIZE    Number of parallel deployments (default: $BATCH_SIZE)
  -d, --dry-run            Show what would be deployed without deploying
  -v, --verbose            Enable verbose output
  -h, --help               Show this help message

Environment Variables:
  AWS_ACCOUNT_ID          AWS Account ID (can be set instead of -a)
  LAYER_NAME              Layer name (can be set instead of -n)
  REGION_FILTER           Region filter (can be set instead of -r)

Examples:
  # Deploy to all regions
  $SCRIPT_NAME -a 123456789012 dist/layer.zip

  # Deploy to US regions only with dry-run
  $SCRIPT_NAME -a 123456789012 -r us -d dist/layer.zip

  # Deploy with environment variables
  export AWS_ACCOUNT_ID=123456789012
  $SCRIPT_NAME dist/layer.zip

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
      -r|--regions)
        REGION_FILTER="$2"
        shift 2
        ;;
      -b|--batch-size)
        BATCH_SIZE="$2"
        shift 2
        ;;
      -d|--dry-run)
        DRY_RUN="true"
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
        ARCHIVE_PATH="$1"
        shift
        ;;
    esac
  done

  # Validate required arguments
  if [ -z "$ARCHIVE_PATH" ]; then
    log_error "Archive path is required"
    usage 1
  fi

  if [ ! -f "$ARCHIVE_PATH" ]; then
    log_error "Archive file does not exist: $ARCHIVE_PATH"
    exit 1
  fi

  # Get AWS account ID if not provided
  if [ -z "$AWS_ACCOUNT_ID" ]; then
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

# Get layer description based on git status
get_layer_description() {
  description="Dust Lambda Extension"

  if command_exists git && git rev-parse --git-dir >/dev/null 2>&1; then
    git_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "")
    git_tag=$(git describe --exact-match HEAD 2>/dev/null || echo "")

    if [ -n "$git_tag" ]; then
      description="$description - Version: $git_tag"
    elif [ -n "$git_hash" ]; then
      description="$description - Commit: $git_hash"
    fi
  fi

  printf "%s" "$description"
}

# Deploy layer to a single region
deploy_to_region() {
  region="$1"
  archive="$2"
  layer_name="$3"
  description="$4"
  output_file="$5"

  if [ "$DRY_RUN" = "true" ]; then
    printf "DRY-RUN: Would deploy to %s\n" "$region" >> "$output_file"
    return 0
  fi

  # Create or update layer version
  if aws lambda publish-layer-version \
    --layer-name "$layer_name" \
    --description "$description" \
    --zip-file "fileb://$archive" \
    --compatible-runtimes "${COMPATIBLE_RUNTIMES}" \
    --compatible-architectures "${COMPATIBLE_ARCHITECTURES}" \
    --region "$region" \
    --output json > "${output_file}.json" 2>&1; then

    # Extract version number
    version=$(grep '"Version"' "${output_file}.json" | sed 's/.*"Version": *\([0-9]*\).*/\1/')

    if [ -n "$version" ]; then
      # Add permission for public access
      if aws lambda add-layer-version-permission \
        --layer-name "$layer_name" \
        --version-number "$version" \
        --principal "*" \
        --statement-id "public-access" \
        --action "lambda:GetLayerVersion" \
        --region "$region" >/dev/null 2>&1; then

        layer_arn=$(grep '"LayerVersionArn"' "${output_file}.json" | sed 's/.*"LayerVersionArn": *"\([^"]*\)".*/\1/')
        printf "SUCCESS: %s - %s (v%s)\n" "$region" "$layer_arn" "$version" >> "$output_file"
        return 0
      else
        printf "PARTIAL: %s - Layer created (v%s) but failed to add public permission\n" "$region" "$version" >> "$output_file"
        return 1
      fi
    else
      printf "ERROR: %s - Failed to extract version from response\n" "$region" >> "$output_file"
      return 1
    fi
  else
    error_msg=$(grep -o '"Message":"[^"]*"' "${output_file}.json" 2>/dev/null | sed 's/"Message":"\([^"]*\)"/\1/')
    printf "ERROR: %s - %s\n" "$region" "${error_msg:-Failed to create layer}" >> "$output_file"
    return 1
  fi
}

# Deploy to all regions
deploy_to_all_regions() {
  regions="$1"
  total_regions=$(printf "%s" "$regions" | wc -w)

  log_info "Starting deployment to $total_regions regions..."

  if [ "$DRY_RUN" = "true" ]; then
    log_warning "DRY-RUN MODE: No actual deployments will be made"
  fi

  # Get layer description
  description=$(get_layer_description)

  # Deploy in batches
  batch_count=0
  completed_count=0

  for region in $regions; do
    # Create output file for this region
    output_file=$(create_temp_file "deploy-${region}")
    TEMP_FILES="$TEMP_FILES $output_file ${output_file}.json"

    # Start deployment in background
    deploy_to_region "$region" "$ARCHIVE_PATH" "$LAYER_NAME" "$description" "$output_file" &

    batch_count=$((batch_count + 1))

    # Wait for batch to complete if we've reached batch size
    if [ $batch_count -ge "$BATCH_SIZE" ]; then
      wait

      # Process results
      for temp_file in $TEMP_FILES; do
        if [ -f "$temp_file" ] && [ -s "$temp_file" ] && ! printf "%s" "$temp_file" | grep -q '\.json$'; then
          result=$(cat "$temp_file")

          # Extract region from result
          result_region=$(printf "%s" "$result" | awk '{print $2}' | sed 's/://')

          if printf "%s" "$result" | grep -q "^SUCCESS"; then
            SUCCESSFUL_REGIONS="$SUCCESSFUL_REGIONS $result_region"
            log_success "$result"
          elif printf "%s" "$result" | grep -q "^DRY-RUN"; then
            log_info "$result"
          else
            FAILED_REGIONS="$FAILED_REGIONS $result_region"
            log_error "$result"
          fi

          completed_count=$((completed_count + 1))
          show_progress "$completed_count" "$total_regions" "Deploying"
        fi
      done

      # Clean up temp files for this batch
      for temp_file in $TEMP_FILES; do
        rm -f "$temp_file"
      done
      TEMP_FILES=""

      batch_count=0
    fi
  done

  # Wait for remaining jobs
  if [ $batch_count -gt 0 ]; then
    wait

    # Process remaining results
    for temp_file in $TEMP_FILES; do
      if [ -f "$temp_file" ] && [ -s "$temp_file" ] && ! printf "%s" "$temp_file" | grep -q '\.json$'; then
        result=$(cat "$temp_file")
        result_region=$(printf "%s" "$result" | awk '{print $2}' | sed 's/://')

        if printf "%s" "$result" | grep -q "^SUCCESS"; then
          SUCCESSFUL_REGIONS="$SUCCESSFUL_REGIONS $result_region"
          log_success "$result"
        elif printf "%s" "$result" | grep -q "^DRY-RUN"; then
          log_info "$result"
        else
          FAILED_REGIONS="$FAILED_REGIONS $result_region"
          log_error "$result"
        fi

        completed_count=$((completed_count + 1))
        show_progress "$completed_count" "$total_regions" "Deploying"
      fi
    done
  fi
}

# Print deployment summary
print_summary() {
  printf "\n"
  log_info "========================================="
  log_info "          DEPLOYMENT SUMMARY"
  log_info "========================================="

  if [ "$DRY_RUN" = "true" ]; then
    log_warning "DRY-RUN MODE: No actual deployments were made"
    return 0
  fi

  # Count successes and failures
  success_count=$(printf "%s" "$SUCCESSFUL_REGIONS" | wc -w)
  failure_count=$(printf "%s" "$FAILED_REGIONS" | wc -w)
  total_count=$((success_count + failure_count))

  if [ "$success_count" -gt 0 ]; then
    log_success "Successfully deployed to $success_count/$total_count regions"
    if [ "$VERBOSE" = "true" ]; then
      log_info "Successful regions: $SUCCESSFUL_REGIONS"
    fi
  fi

  if [ "$failure_count" -gt 0 ]; then
    log_error "Failed to deploy to $failure_count/$total_count regions"
    log_error "Failed regions: $FAILED_REGIONS"

    # Provide retry command
    log_info ""
    log_info "To retry failed regions, run:"
    failed_list=$(printf "%s" "$FAILED_REGIONS" | tr ' ' ',')
    log_info "  AWS_REGIONS='$failed_list' $SCRIPT_NAME $ARCHIVE_PATH"
  fi

  # Print Layer ARN format for reference
  if [ "$success_count" -gt 0 ]; then
    log_info ""
    log_info "Layer ARN format:"
    log_info "  arn:aws:lambda:<region>:$AWS_ACCOUNT_ID:layer:$LAYER_NAME:<version>"
  fi
}

# Main execution
main() {
  # Set up cleanup trap
  setup_cleanup_trap

  # Parse arguments
  parse_args "$@"

  # Validate prerequisites
  if [ "$DRY_RUN" != "true" ]; then
    log_info "Validating AWS CLI configuration..."
    if ! validate_aws_cli; then
      exit 1
    fi
  fi

  # Get regions for deployment
  if [ -n "${AWS_REGIONS:-}" ]; then
    # Use explicitly provided regions (comma-separated)
    regions=$(printf "%s" "$AWS_REGIONS" | tr ',' ' ')
    log_info "Using explicitly provided regions: $regions"
  else
    # Get regions based on filter
    log_info "Getting AWS regions (filter: $REGION_FILTER)..."
    regions=$(get_deployment_regions "$REGION_FILTER")
  fi

  if [ -z "$regions" ]; then
    log_error "No regions found for deployment"
    exit 1
  fi

  # Deploy to all regions
  deploy_to_all_regions "$regions"

  # Print summary
  print_summary

  # Exit with appropriate code
  if [ -n "$FAILED_REGIONS" ] && [ "$DRY_RUN" != "true" ]; then
    exit 1
  fi

  exit 0
}

# Run main
main "$@"
