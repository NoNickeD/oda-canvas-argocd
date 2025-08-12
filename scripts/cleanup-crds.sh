#!/usr/bin/env bash
set -euo pipefail

# Script to discover and delete CRDs created by ODA Canvas applications
# Usage: ./cleanup-crds.sh [options]

log() { printf '%s %s\n' "[$(date +'%Y-%m-%dT%H:%M:%S%z')]" "$*"; }
warn() { log "WARN: $*"; }
err() { log "ERROR: $*" >&2; }

usage() {
  cat << EOF
Usage: $0 [options]

Discover and optionally delete Custom Resource Definitions (CRDs) created by ODA Canvas applications.

Options:
  -h, --help       Show this help message
  -l, --list       List CRDs only, don't delete
  -f, --force      Delete without confirmation
  -p, --pattern    Add custom pattern to match CRDs (can be used multiple times)
  -v, --verbose    Show detailed information about each CRD

Examples:
  $0 --list                     # List all application CRDs
  $0 --force                    # Delete all application CRDs without confirmation
  $0 --pattern ".*\.myapp\.io"  # Include custom pattern for CRD matching

EOF
  exit 1
}

# Default CRD patterns for ODA Canvas applications
DEFAULT_CRD_PATTERNS=(
  # ODA Canvas CRDs
  ".*\.oda\.tmforum\.org"
  
  # Cert-manager CRDs
  ".*\.cert-manager\.io"
  ".*\.acme\.cert-manager\.io"
  
  # Istio CRDs
  ".*\.networking\.istio\.io"
  ".*\.security\.istio\.io"
  ".*\.config\.istio\.io"
  ".*\.authentication\.istio\.io"
  ".*\.rbac\.istio\.io"
  ".*\.telemetry\.istio\.io"
  ".*\.extensions\.istio\.io"
  
  # Gateway API CRDs
  ".*\.gateway\.networking\.k8s\.io"
  
  # Kong CRDs
  ".*\.configuration\.konghq\.com"
  
  # APISIX CRDs
  ".*\.apisix\.apache\.org"
  
  # Vault-related CRDs
  ".*\.vault\.hashicorp\.com"
  ".*\.secrets\.hashicorp\.com"
)

discover_crds() {
  local patterns=("${@}")
  local all_crds=$(kubectl get crd -o name 2>/dev/null | sed 's|customresourcedefinition.apiextensions.k8s.io/||' || true)
  
  if [[ -z "$all_crds" ]]; then
    return
  fi
  
  local matched_crds=()
  
  # Match CRDs against patterns
  for crd in $all_crds; do
    for pattern in "${patterns[@]}"; do
      if [[ "$crd" =~ $pattern ]]; then
        matched_crds+=("$crd")
        break
      fi
    done
  done
  
  # Also check for CRDs with specific labels
  local labeled_crds=$(kubectl get crd -l app.kubernetes.io/managed-by=Helm -o name 2>/dev/null | sed 's|customresourcedefinition.apiextensions.k8s.io/||' || true)
  for crd in $labeled_crds; do
    if [[ ! " ${matched_crds[@]} " =~ " ${crd} " ]]; then
      matched_crds+=("$crd")
    fi
  done
  
  # Return unique CRDs
  printf '%s\n' "${matched_crds[@]}" | sort -u
}

get_crd_info() {
  local crd=$1
  local verbose=$2
  
  # Get basic info
  local created=$(kubectl get crd "$crd" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "unknown")
  local group=$(kubectl get crd "$crd" -o jsonpath='{.spec.group}' 2>/dev/null || echo "unknown")
  local scope=$(kubectl get crd "$crd" -o jsonpath='{.spec.scope}' 2>/dev/null || echo "unknown")
  
  # Count resources
  local resource_count=0
  if [[ "$scope" == "Namespaced" ]]; then
    resource_count=$(kubectl get "$crd" --all-namespaces 2>/dev/null | grep -v "NAMESPACE" | wc -l || echo "0")
  else
    resource_count=$(kubectl get "$crd" 2>/dev/null | grep -v "NAME" | wc -l || echo "0")
  fi
  
  echo "  CRD: $crd"
  echo "    Group: $group"
  echo "    Scope: $scope"
  echo "    Created: $created"
  echo "    Resources: $resource_count"
  
  if [[ "$verbose" == "true" ]] && [[ $resource_count -gt 0 ]]; then
    echo "    Resource instances:"
    if [[ "$scope" == "Namespaced" ]]; then
      kubectl get "$crd" --all-namespaces 2>/dev/null | grep -v "NAMESPACE" | head -10 | while read -r line; do
        echo "      $line"
      done
      if [[ $resource_count -gt 10 ]]; then
        echo "      ... and $((resource_count - 10)) more"
      fi
    else
      kubectl get "$crd" 2>/dev/null | grep -v "NAME" | head -10 | while read -r line; do
        echo "      $line"
      done
      if [[ $resource_count -gt 10 ]]; then
        echo "      ... and $((resource_count - 10)) more"
      fi
    fi
  fi
  echo ""
}

delete_crd() {
  local crd=$1
  
  log "Deleting CRD: $crd"
  
  # First, delete all custom resources of this type
  local scope=$(kubectl get crd "$crd" -o jsonpath='{.spec.scope}' 2>/dev/null || echo "Namespaced")
  
  if [[ "$scope" == "Namespaced" ]]; then
    local cr_count=$(kubectl get "$crd" --all-namespaces 2>/dev/null | grep -v "NAMESPACE" | wc -l || echo "0")
    if [[ $cr_count -gt 0 ]]; then
      log "  Deleting $cr_count custom resources of type $crd"
      kubectl delete "$crd" --all --all-namespaces --timeout=60s >/dev/null 2>&1 || {
        warn "  Failed to delete some resources of type $crd"
      }
    fi
  else
    local cr_count=$(kubectl get "$crd" 2>/dev/null | grep -v "NAME" | wc -l || echo "0")
    if [[ $cr_count -gt 0 ]]; then
      log "  Deleting $cr_count custom resources of type $crd"
      kubectl delete "$crd" --all --timeout=60s >/dev/null 2>&1 || {
        warn "  Failed to delete some resources of type $crd"
      }
    fi
  fi
  
  # Then delete the CRD itself
  kubectl delete crd "$crd" --ignore-not-found --timeout=60s >/dev/null 2>&1 || {
    warn "  Failed to delete CRD $crd, attempting force deletion"
    kubectl patch crd "$crd" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
    kubectl delete crd "$crd" --force --grace-period=0 >/dev/null 2>&1 || true
  }
  
  # Verify deletion
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    err "  Failed to delete CRD $crd"
    return 1
  else
    log "  Successfully deleted CRD $crd"
    return 0
  fi
}

main() {
  local list_only=false
  local force=false
  local verbose=false
  local custom_patterns=()
  
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        usage
        ;;
      -l|--list)
        list_only=true
        shift
        ;;
      -f|--force)
        force=true
        shift
        ;;
      -v|--verbose)
        verbose=true
        shift
        ;;
      -p|--pattern)
        custom_patterns+=("$2")
        shift 2
        ;;
      *)
        err "Unknown option: $1"
        usage
        ;;
    esac
  done
  
  # Check if kubectl is available
  if ! command -v kubectl &> /dev/null; then
    err "kubectl command not found. Please install kubectl and ensure it's in your PATH."
    exit 1
  fi
  
  # Check if we can connect to the cluster
  if ! kubectl cluster-info &> /dev/null; then
    err "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
    exit 1
  fi
  
  # Combine default and custom patterns
  local all_patterns=("${DEFAULT_CRD_PATTERNS[@]}" "${custom_patterns[@]}")
  
  log "Discovering CRDs in the cluster..."
  local crds=($(discover_crds "${all_patterns[@]}"))
  
  if [[ ${#crds[@]} -eq 0 ]]; then
    log "No application-related CRDs found"
    exit 0
  fi
  
  log "Found ${#crds[@]} application-related CRDs:"
  echo ""
  
  # List CRDs with information
  for crd in "${crds[@]}"; do
    get_crd_info "$crd" "$verbose"
  done
  
  if [[ "$list_only" == "true" ]]; then
    exit 0
  fi
  
  # Confirm deletion unless force flag is set
  if [[ "$force" != "true" ]]; then
    echo "WARNING: This will delete all ${#crds[@]} CRDs listed above and ALL their resources."
    echo "This action cannot be undone."
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " confirmation
    if [[ "$confirmation" != "yes" ]]; then
      log "Deletion cancelled."
      exit 0
    fi
  fi
  
  # Delete CRDs
  log "Starting CRD deletion..."
  local failures=0
  
  for crd in "${crds[@]}"; do
    if ! delete_crd "$crd"; then
      failures=$((failures + 1))
    fi
  done
  
  if [[ $failures -gt 0 ]]; then
    err "$failures CRD(s) failed to delete completely"
    exit 1
  fi
  
  log "Successfully deleted all application-related CRDs"
}

main "$@"