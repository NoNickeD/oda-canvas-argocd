#!/usr/bin/env bash
set -euo pipefail

# Script to delete ArgoCD applications in the correct dependency order
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
    err "$failures application(s) failed to delete."
    exit 1
  fi

  log "All target applications processed."
}

main "$@"