#!/usr/bin/env bash
set -euo pipefail

# Script to delete ArgoCD applications and their associated namespaces/resources
# 
# Deletion order (most dependent first):
# 1. Original canvas applications (if they exist)
# 2. canvas-oda (depends on many other components)
# 3. canvas-webhook-certificate (uses cert-manager)
# 4. secretsmanagement-operator (uses vault)
# 5. canvas-kong (API gateway, depends on istio)
# 6. canvas-vault (storage backend)
# 7. istio-ingress, istiod, istio-base (Istio components in reverse order)
# 8. cert-manager-cluster-issuer, cert-manager (cert-manager components)
# 9. gateway-api-crds (base CRDs)
# 10. Delete associated namespaces and resources

# Defaults and configuration
NAMESPACE="${NAMESPACE:-argocd}"

# Original canvas applications
CANVAS_APP="${CANVAS_APP:-oda-canvas-bootstrap}"
CANVAS_ROOT="${CANVAS_ROOT:-oda-canvas-root}"
CANVAS_CERTIFICATES="${CANVAS_CERTIFICATES:-oda-canvas-certificates}"
CANVAS_PREREQUISITES="${CANVAS_PREREQUISITES:-oda-canvas-prerequisites}"
CANVAS_COMPONENTS="${CANVAS_COMPONENTS:-oda-canvas-components}"

# Applications from the provided list
CANVAS_ODA="${CANVAS_ODA:-canvas-oda}"
CANVAS_WEBHOOK_CERTIFICATE="${CANVAS_WEBHOOK_CERTIFICATE:-canvas-webhook-certificate}"
SECRETSMANAGEMENT_OPERATOR="${SECRETSMANAGEMENT_OPERATOR:-secretsmanagement-operator}"
CANVAS_KONG="${CANVAS_KONG:-canvas-kong}"
CANVAS_VAULT="${CANVAS_VAULT:-canvas-vault}"
ISTIO_INGRESS="${ISTIO_INGRESS:-istio-ingress}"
ISTIOD="${ISTIOD:-istiod}"
ISTIO_BASE="${ISTIO_BASE:-istio-base}"
CERT_MANAGER_CLUSTER_ISSUER="${CERT_MANAGER_CLUSTER_ISSUER:-cert-manager-cluster-issuer}"
CERT_MANAGER="${CERT_MANAGER:-cert-manager}"
GATEWAY_API_CRDS="${GATEWAY_API_CRDS:-gateway-api-crds}"

DELETE_TIMEOUT_SECONDS="${DELETE_TIMEOUT_SECONDS:-120}"
NAMESPACE_DELETE_TIMEOUT="${NAMESPACE_DELETE_TIMEOUT:-300}"

# List of namespaces created by the applications
MANAGED_NAMESPACES=(
  "canvas"
  "components"
  "canvas-vault"
  "kong"
  "cert-manager"
  "istio-system"
  "istio-ingress"
  "gateway-system"
)

log() { printf '%s %s\n' "[$(date +'%Y-%m-%dT%H:%M:%S%z')]" "$*"; }
warn() { log "WARN: $*"; }
err() { log "ERROR: $*" >&2; }

application_exists() {
  local application_name=$1
  kubectl get application "$application_name" -n "$NAMESPACE" >/dev/null 2>&1
}

remove_finalizers() {
  local application_name=$1
  if application_exists "$application_name"; then
    kubectl -n "$NAMESPACE" patch application "$application_name" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
  fi
}

delete_application() {
  local application_name=$1

  if ! application_exists "$application_name"; then
    log "Application $application_name not found in namespace $NAMESPACE. Skipping."
    return 0
  fi

  log "Ensuring finalizers are removed for $application_name"
  remove_finalizers "$application_name"

  log "Deleting application $application_name"
  kubectl delete application "$application_name" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

  if kubectl wait -n "$NAMESPACE" --for=delete "application/$application_name" --timeout="${DELETE_TIMEOUT_SECONDS}s" >/dev/null 2>&1; then
    log "Application $application_name deleted"
    return 0
  fi

  warn "Application $application_name did not delete within ${DELETE_TIMEOUT_SECONDS}s. Attempting to remove finalizers again and force deletion."
  remove_finalizers "$application_name"
  kubectl delete application "$application_name" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

  if kubectl wait -n "$NAMESPACE" --for=delete "application/$application_name" --timeout="30s" >/dev/null 2>&1; then
    log "Application $application_name deleted after removing finalizers"
    return 0
  fi

  err "Application $application_name still exists after cleanup attempts."
  kubectl get application "$application_name" -n "$NAMESPACE" || true
  return 1
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
  # Using --all --all-namespaces would be too broad, so we target specific resource types
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
  )
  
  for resource in "${resource_types[@]}"; do
    if kubectl get "$resource" -n "$namespace" >/dev/null 2>&1; then
      log "Deleting $resource in namespace $namespace"
      kubectl delete "$resource" --all -n "$namespace" --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
    fi
  done
  
  # Delete custom resources if they exist
  log "Checking for custom resources in namespace $namespace"
  local custom_resources=$(kubectl api-resources --verbs=list --namespaced -o name | grep -v "events.events.k8s.io" | grep -v "events" || true)
  
  for cr in $custom_resources; do
    if kubectl get "$cr" -n "$namespace" >/dev/null 2>&1; then
      log "Deleting custom resource $cr in namespace $namespace"
      kubectl delete "$cr" --all -n "$namespace" --ignore-not-found --timeout=30s >/dev/null 2>&1 || true
    fi
  done
}

delete_namespace() {
  local namespace=$1
  
  if ! namespace_exists "$namespace"; then
    log "Namespace $namespace not found. Skipping."
    return 0
  fi
  
  log "Processing namespace $namespace"
  
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
  kubectl delete namespace "$namespace" --force --grace-period=0 >/dev/null 2>&1 || true
  
  if namespace_exists "$namespace"; then
    err "Namespace $namespace still exists after cleanup attempts"
    return 1
  fi
  
  log "Namespace $namespace deleted after force deletion"
  return 0
}

discover_and_delete_crds() {
  log "Discovering and deleting all CRDs created by applications"
  
  # Define CRD patterns for different applications
  local crd_patterns=(
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
    
    # Vault-related CRDs (if any)
    ".*\.vault\.hashicorp\.com"
    ".*\.secrets\.hashicorp\.com"
  )
  
  # Get all CRDs in the cluster
  log "Fetching all CRDs in the cluster..."
  local all_crds=$(kubectl get crd -o name 2>/dev/null | sed 's|customresourcedefinition.apiextensions.k8s.io/||' || true)
  
  if [[ -z "$all_crds" ]]; then
    log "No CRDs found in the cluster"
    return 0
  fi
  
  # Track CRDs to delete
  local crds_to_delete=()
  
  # Match CRDs against patterns
  for crd in $all_crds; do
    for pattern in "${crd_patterns[@]}"; do
      if [[ "$crd" =~ $pattern ]]; then
        crds_to_delete+=("$crd")
        break
      fi
    done
  done
  
  # Also check for CRDs with specific labels
  log "Checking for labeled CRDs..."
  local labeled_crds=$(kubectl get crd -l app.kubernetes.io/managed-by=Helm -o name 2>/dev/null | sed 's|customresourcedefinition.apiextensions.k8s.io/||' || true)
  for crd in $labeled_crds; do
    if [[ ! " ${crds_to_delete[@]} " =~ " ${crd} " ]]; then
      crds_to_delete+=("$crd")
    fi
  done
  
  # Delete discovered CRDs
  if [[ ${#crds_to_delete[@]} -eq 0 ]]; then
    log "No application-related CRDs found to delete"
    return 0
  fi
  
  log "Found ${#crds_to_delete[@]} CRDs to delete"
  
  for crd in "${crds_to_delete[@]}"; do
    log "Deleting CRD: $crd"
    
    # First, delete all custom resources of this type
    local cr_count=$(kubectl get "$crd" --all-namespaces 2>/dev/null | wc -l || echo "0")
    if [[ $cr_count -gt 1 ]]; then
      log "  Deleting $((cr_count - 1)) custom resources of type $crd"
      kubectl delete "$crd" --all --all-namespaces --timeout=60s >/dev/null 2>&1 || {
        warn "  Failed to delete some resources of type $crd"
      }
    fi
    
    # Then delete the CRD itself
    kubectl delete crd "$crd" --ignore-not-found --timeout=60s >/dev/null 2>&1 || {
      warn "  Failed to delete CRD $crd, attempting force deletion"
      kubectl patch crd "$crd" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
      kubectl delete crd "$crd" --force --grace-period=0 >/dev/null 2>&1 || true
    }
  done
  
  log "CRD cleanup completed"
}

delete_cluster_resources() {
  log "Deleting cluster-wide resources"
  
  # Delete webhooks first
  log "Deleting webhooks"
  local webhooks=(
    # Istio webhooks
    "istio-sidecar-injector"
    "istio-validator-istio-system"
    "istiod-default-validator"
    "istio-revision-tag-default"
    
    # Cert-manager webhooks
    "cert-manager-webhook"
    
    # ODA webhooks
    "canvas-webhook"
    "oda-webhook"
  )
  
  for webhook in "${webhooks[@]}"; do
    kubectl delete mutatingwebhookconfiguration "$webhook" --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete validatingwebhookconfiguration "$webhook" --ignore-not-found >/dev/null 2>&1 || true
  done
  
  # Delete cluster role bindings
  log "Deleting cluster role bindings"
  # Delete by label
  kubectl delete clusterrolebinding -l app.kubernetes.io/managed-by=Helm --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete clusterrolebinding -l app.kubernetes.io/part-of=istio --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete clusterrolebinding -l app.kubernetes.io/name=cert-manager --ignore-not-found >/dev/null 2>&1 || true
  
  # Delete specific known cluster role bindings
  local crbs=(
    "istio-reader-clusterrole-istio-system"
    "istiod-clusterrole-istio-system"
    "istiod-gateway-controller-istio-system"
    "istio-sidecar-injector-istio-system"
    "cert-manager-cainjector"
    "cert-manager-controller-issuers"
    "cert-manager-controller-clusterissuers"
    "cert-manager-controller-certificates"
    "cert-manager-controller-orders"
    "cert-manager-controller-challenges"
    "cert-manager-controller-ingress-shim"
    "cert-manager-controller-approve:cert-manager-io"
    "cert-manager-controller-certificatesigningrequests"
    "cert-manager-webhook:subjectaccessreviews"
    "kong-kong"
  )
  
  for crb in "${crbs[@]}"; do
    kubectl delete clusterrolebinding "$crb" --ignore-not-found >/dev/null 2>&1 || true
  done
  
  # Delete cluster roles
  log "Deleting cluster roles"
  # Delete by label
  kubectl delete clusterrole -l app.kubernetes.io/managed-by=Helm --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete clusterrole -l app.kubernetes.io/part-of=istio --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete clusterrole -l app.kubernetes.io/name=cert-manager --ignore-not-found >/dev/null 2>&1 || true
  
  # Delete specific known cluster roles
  local crs=(
    "istio-reader-clusterrole-istio-system"
    "istiod-clusterrole-istio-system"
    "istiod-gateway-controller-istio-system"
    "istio-sidecar-injector-istio-system"
    "cert-manager-cainjector"
    "cert-manager-controller-issuers"
    "cert-manager-controller-clusterissuers"
    "cert-manager-controller-certificates"
    "cert-manager-controller-orders"
    "cert-manager-controller-challenges"
    "cert-manager-controller-ingress-shim"
    "cert-manager-controller-approve:cert-manager-io"
    "cert-manager-controller-certificatesigningrequests"
    "cert-manager-webhook:subjectaccessreviews"
    "kong-kong"
  )
  
  for cr in "${crs[@]}"; do
    kubectl delete clusterrole "$cr" --ignore-not-found >/dev/null 2>&1 || true
  done
  
  # Delete API services
  log "Deleting API services"
  kubectl delete apiservice -l app.kubernetes.io/name=cert-manager --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete apiservice -l app.kubernetes.io/part-of=istio --ignore-not-found >/dev/null 2>&1 || true
  
  # Now discover and delete all CRDs
  discover_and_delete_crds
}

main() {
  local failures=0

  # Delete applications in dependency order (most dependent first)
  
  # First, delete the original canvas applications if they exist
  log "Deleting original canvas applications..."
  delete_application "$CANVAS_ROOT" || failures=$((failures+1))
  delete_application "$CANVAS_APP" || failures=$((failures+1))
  delete_application "$CANVAS_CERTIFICATES" || failures=$((failures+1))
  delete_application "$CANVAS_PREREQUISITES" || failures=$((failures+1))
  delete_application "$CANVAS_COMPONENTS" || failures=$((failures+1))
  
  # Delete applications that depend on others
  log "Deleting dependent applications..."
  delete_application "$CANVAS_ODA" || failures=$((failures+1))
  delete_application "$CANVAS_WEBHOOK_CERTIFICATE" || failures=$((failures+1))
  delete_application "$SECRETSMANAGEMENT_OPERATOR" || failures=$((failures+1))
  
  # Delete middleware components
  log "Deleting middleware components..."
  delete_application "$CANVAS_KONG" || failures=$((failures+1))
  delete_application "$CANVAS_VAULT" || failures=$((failures+1))
  
  # Delete Istio components (in reverse order of installation)
  log "Deleting Istio components..."
  delete_application "$ISTIO_INGRESS" || failures=$((failures+1))
  delete_application "$ISTIOD" || failures=$((failures+1))
  delete_application "$ISTIO_BASE" || failures=$((failures+1))
  
  # Delete cert-manager components
  log "Deleting cert-manager components..."
  delete_application "$CERT_MANAGER_CLUSTER_ISSUER" || failures=$((failures+1))
  delete_application "$CERT_MANAGER" || failures=$((failures+1))
  
  # Delete base CRDs last
  log "Deleting base CRDs..."
  delete_application "$GATEWAY_API_CRDS" || failures=$((failures+1))

  if (( failures > 0 )); then
    warn "$failures application(s) failed to delete completely."
  fi

  log "All target applications processed."
  
  # Wait a bit for resources to be cleaned up by the applications
  log "Waiting for applications to clean up their resources..."
  sleep 10
  
  # Now delete namespaces and their resources
  log "Starting namespace and resource cleanup..."
  
  for namespace in "${MANAGED_NAMESPACES[@]}"; do
    delete_namespace "$namespace" || failures=$((failures+1))
  done
  
  # Delete cluster-wide resources
  delete_cluster_resources || failures=$((failures+1))
  
  if (( failures > 0 )); then
    err "$failures operation(s) failed during cleanup."
    exit 1
  fi
  
  log "All applications, namespaces, and resources have been cleaned up successfully."
}

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

main "$@"