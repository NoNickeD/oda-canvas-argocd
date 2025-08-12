#!/usr/bin/env bash
set -euo pipefail

# Script to delete a specific namespace and all its resources
# Usage: ./cleanup-namespace.sh <namespace-name>

NAMESPACE_DELETE_TIMEOUT="${NAMESPACE_DELETE_TIMEOUT:-300}"

log() { printf '%s %s\n' "[$(date +'%Y-%m-%dT%H:%M:%S%z')]" "$*"; }
warn() { log "WARN: $*"; }
err() { log "ERROR: $*" >&2; }

usage() {
  cat << EOF
Usage: $0 <namespace-name> [options]

Delete a Kubernetes namespace and all its resources.

Arguments:
  namespace-name    The name of the namespace to delete

Options:
  -h, --help       Show this help message
  -f, --force      Force deletion without confirmation
  -t, --timeout    Timeout in seconds for namespace deletion (default: 300)

Examples:
  $0 canvas
  $0 istio-system --force
  $0 cert-manager --timeout 600

EOF
  exit 1
}

namespace_exists() {
  local namespace=$1
  kubectl get namespace "$namespace" >/dev/null 2>&1
}

remove_namespace_finalizers() {
  local namespace=$1
  if namespace_exists "$namespace"; then
    log "Removing finalizers from namespace $namespace"
    kubectl patch namespace "$namespace" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
  fi
}

delete_namespace_resources() {
  local namespace=$1
  
  if ! namespace_exists "$namespace"; then
    log "Namespace $namespace not found. Skipping."
    return 0
  fi

  log "Deleting all resources in namespace $namespace"
  
  # Delete all resources except the namespace itself
  local resource_types=(
    "deployments"
    "statefulsets"
    "daemonsets"
    "services"
    "ingresses"
    "configmaps"
    "secrets"
    "serviceaccounts"
    "rolebindings"
    "roles"
    "persistentvolumeclaims"
    "jobs"
    "cronjobs"
    "pods"
    "replicasets"
    "horizontalpodautoscalers"
    "poddisruptionbudgets"
    "networkpolicies"
    "virtualservices"
    "destinationrules"
    "gateways"
    "serviceentries"
    "sidecars"
    "authorizationpolicies"
    "peerauthentications"
    "requestauthentications"
    "telemetries"
    "workloadentries"
    "workloadgroups"
    "envoyfilters"
  )
  
  for resource in "${resource_types[@]}"; do
    if kubectl get "$resource" -n "$namespace" >/dev/null 2>&1; then
      log "Deleting $resource in namespace $namespace"
      kubectl delete "$resource" --all -n "$namespace" --ignore-not-found --timeout=60s >/dev/null 2>&1 || {
        warn "Failed to delete some $resource resources, continuing..."
      }
    fi
  done
  
  # Delete custom resources if they exist
  log "Checking for custom resources in namespace $namespace"
  local custom_resources=$(kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null | grep -v "events.events.k8s.io" | grep -v "^events$" || true)
  
  for cr in $custom_resources; do
    if [[ -n "$cr" ]] && kubectl get "$cr" -n "$namespace" >/dev/null 2>&1; then
      log "Deleting custom resource $cr in namespace $namespace"
      kubectl delete "$cr" --all -n "$namespace" --ignore-not-found --timeout=30s >/dev/null 2>&1 || {
        warn "Failed to delete some $cr resources, continuing..."
      }
    fi
  done
}

delete_namespace() {
  local namespace=$1
  
  if ! namespace_exists "$namespace"; then
    err "Namespace $namespace not found."
    return 1
  fi
  
  log "Processing namespace $namespace"
  
  # Show what's in the namespace
  log "Resources in namespace $namespace:"
  kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null | while read -r resource; do
    if [[ -n "$resource" ]]; then
      count=$(kubectl get "$resource" -n "$namespace" 2>/dev/null | wc -l)
      if [[ $count -gt 1 ]]; then
        echo "  - $resource: $((count - 1)) items"
      fi
    fi
  done || true
  
  # First delete all resources in the namespace
  delete_namespace_resources "$namespace"
  
  # Remove finalizers from the namespace
  remove_namespace_finalizers "$namespace"
  
  # Delete the namespace
  log "Deleting namespace $namespace"
  kubectl delete namespace "$namespace" --ignore-not-found >/dev/null 2>&1 || true
  
  # Wait for namespace deletion
  if kubectl wait --for=delete "namespace/$namespace" --timeout="${NAMESPACE_DELETE_TIMEOUT}s" >/dev/null 2>&1; then
    log "Namespace $namespace deleted successfully"
    return 0
  fi
  
  warn "Namespace $namespace did not delete within ${NAMESPACE_DELETE_TIMEOUT}s. Forcing deletion."
  
  # Force remove finalizers and try again
  remove_namespace_finalizers "$namespace"
  
  # Force delete using grace period 0
  kubectl delete namespace "$namespace" --force --grace-period=0 >/dev/null 2>&1 || true
  
  # Final check
  sleep 5
  if namespace_exists "$namespace"; then
    err "Namespace $namespace still exists after cleanup attempts"
    err "You may need to manually inspect and remove stuck resources:"
    err "  kubectl get all -n $namespace"
    err "  kubectl api-resources --verbs=list --namespaced -o name | xargs -n 1 kubectl get --show-kind --ignore-not-found -n $namespace"
    return 1
  fi
  
  log "Namespace $namespace deleted successfully"
  return 0
}

# Parse command line arguments
FORCE=false
TARGET_NAMESPACE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      usage
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    -t|--timeout)
      NAMESPACE_DELETE_TIMEOUT="$2"
      shift 2
      ;;
    -*)
      err "Unknown option: $1"
      usage
      ;;
    *)
      if [[ -z "$TARGET_NAMESPACE" ]]; then
        TARGET_NAMESPACE="$1"
      else
        err "Multiple namespaces specified. This script deletes one namespace at a time."
        usage
      fi
      shift
      ;;
  esac
done

# Check if namespace was provided
if [[ -z "$TARGET_NAMESPACE" ]]; then
  err "No namespace specified"
  usage
fi

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

# Confirm deletion unless force flag is set
if [[ "$FORCE" != "true" ]]; then
  echo "WARNING: This will delete namespace '$TARGET_NAMESPACE' and ALL resources within it."
  echo "This action cannot be undone."
  echo ""
  read -p "Are you sure you want to continue? (yes/no): " confirmation
  if [[ "$confirmation" != "yes" ]]; then
    log "Deletion cancelled."
    exit 0
  fi
fi

# Execute deletion
if delete_namespace "$TARGET_NAMESPACE"; then
  log "Successfully deleted namespace $TARGET_NAMESPACE and all its resources."
  exit 0
else
  err "Failed to completely delete namespace $TARGET_NAMESPACE"
  exit 1
fi