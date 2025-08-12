# ODA Canvas ArgoCD

GitOps deployment for TM Forum ODA Canvas using ArgoCD with infrastructure components including Istio service mesh, cert-manager, and monitoring stack.

## Overview

This repository contains ArgoCD application manifests and configurations for deploying the ODA Canvas platform and its infrastructure dependencies in a Kubernetes cluster using GitOps principles.

## Architecture

The deployment follows the App of Apps pattern where a single ArgoCD application manages multiple child applications. This provides centralized management and automated synchronization of all components.

### Components

#### Core Infrastructure

- **Gateway API CRDs**: Kubernetes Gateway API custom resource definitions
- **cert-manager**: Automated certificate management for TLS
- **Istio Service Mesh**:
  - Istio Base (CRDs and core components)
  - Istio Control Plane (istiod)
  - Istio Ingress Gateway

#### Monitoring Stack

- **Prometheus**: Metrics collection and storage with 30-day retention
- **Grafana**: Visualization and dashboards with pre-configured Prometheus datasource

## Prerequisites

- Kubernetes cluster (v1.28+)
- ArgoCD installed in the cluster
- kubectl configured to access the cluster
- Helm v3 (for local testing)

## Project Structure

```
.
├── apps/                      # ArgoCD Application manifests
│   ├── cert-manager.yaml      # cert-manager deployment
│   ├── gateway-api-crds.yaml  # Gateway API CRDs
│   ├── istio-base.yaml        # Istio base components
│   ├── istio-control.yaml     # Istio control plane
│   ├── istio-ingress.yaml     # Istio ingress gateway
│   ├── prometheus.yaml        # Prometheus monitoring
│   └── grafana.yaml           # Grafana visualization
├── argocd/                    # ArgoCD configuration
│   ├── app-of-apps.yaml       # Main bootstrap application
│   └── project.yaml           # ArgoCD project definition
├── resources/                 # Additional Kubernetes resources
│   ├── canvas/                # Canvas-specific resources
│   └── cert-manager/          # cert-manager configuration
└── scripts/                   # Utility scripts
    ├── cleanup-all.sh
    ├── cleanup-application.sh
    ├── cleanup-crds.sh
    └── cleanup-namespace.sh
```

## Installation

### 1. Fork and Clone Repository

```bash
git clone https://github.com/NoNickeD/oda-canvas-argocd
cd oda-canvas-argocd
```

### 2. Update Repository URL

Edit `argocd/app-of-apps.yaml` and update the `repoURL` to point to your fork:

```yaml
spec:
  source:
    repoURL: https://github.com/YOUR-USERNAME/oda-canvas-argocd
```

### 3. Deploy ArgoCD Project

```bash
kubectl apply -f argocd/project.yaml
```

### 4. Deploy App of Apps

```bash
kubectl apply -f argocd/app-of-apps.yaml
```

This will automatically deploy all infrastructure components defined in the `apps/` directory.

## Component Details

### Istio Service Mesh

Deployed in three stages with sync waves:

1. **Istio Base** (sync-wave: -1): CRDs and cluster-wide resources
2. **Istio Control** (sync-wave: 0): Control plane (istiod)
3. **Istio Ingress** (sync-wave: 1): Ingress gateway

### cert-manager

Manages TLS certificates automatically. Includes a ClusterIssuer for Let's Encrypt staging (configure for production use).

### Monitoring

#### Prometheus

- Persistent storage: 50Gi
- Retention period: 30 days
- Alertmanager enabled with 10Gi storage

#### Grafana

- Persistent storage: 10Gi
- Default admin password: `admin` (change in production)
- Pre-configured Prometheus datasource
- Includes Kubernetes cluster dashboard

## Configuration

### Namespaces

The following namespaces are configured in the ArgoCD project:

- `cert-manager`: Certificate management
- `istio-system`: Istio control plane
- `istio-ingress`: Istio ingress gateway
- `gateway-system`: Gateway API components
- `canvas`: ODA Canvas components
- `monitoring`: Prometheus and Grafana
- `argocd`: ArgoCD itself
- `kube-system`: System components

### Adding New Applications

1. Create a new YAML file in `apps/` directory
2. Define the ArgoCD Application resource
3. Commit and push to your repository
4. ArgoCD will automatically detect and deploy

Example application:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: oda-canvas
  source:
    repoURL: https://charts.example.com
    chart: my-chart
    targetRevision: 1.0.0
  destination:
    server: https://kubernetes.default.svc
    namespace: my-namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## Sync Waves

Applications are deployed in order using sync waves:

- Wave -1: Gateway API CRDs, Istio Base
- Wave 0: cert-manager, Istio Control
- Wave 1: Istio Ingress
- Wave 2: Prometheus
- Wave 3: Grafana

## Monitoring Access

### Prometheus

Port-forward to access Prometheus UI:

```bash
kubectl port-forward -n monitoring svc/prometheus-server 9090:80
```

Access at: http://localhost:9090

### Grafana

Port-forward to access Grafana:

```bash
kubectl port-forward -n monitoring svc/grafana 3000:80
```

Access at: http://localhost:3000
Default credentials: admin/admin

## Cleanup

Use the provided cleanup scripts in the `scripts/` directory:

```bash
# Remove specific application
./scripts/cleanup-application.sh <app-name>

# Remove all ODA Canvas components
./scripts/cleanup-all.sh

# Clean up CRDs
./scripts/cleanup-crds.sh

# Clean up namespaces
./scripts/cleanup-namespace.sh
```

## Troubleshooting

### Check Application Status

```bash
kubectl get applications -n argocd
```

### View Application Details

```bash
kubectl describe application <app-name> -n argocd
```

### Check Sync Status

```bash
argocd app get <app-name>
```

### Force Sync

```bash
argocd app sync <app-name>
```

### View Logs

```bash
# ArgoCD application controller
kubectl logs -n argocd deployment/argocd-application-controller

# Specific component
kubectl logs -n <namespace> deployment/<component-name>
```

## Security Considerations

1. **Change default passwords**: Update Grafana admin password in production
2. **Configure RBAC**: Set appropriate Kubernetes RBAC policies
3. **TLS certificates**: Configure cert-manager with production Let's Encrypt issuer
4. **Network policies**: Implement network segmentation using Istio policies
5. **Secret management**: Use sealed-secrets or external secret operators for sensitive data

## License

This project is licensed under the Apache License 2.0 - see the LICENSE file for details.

## References

- [TM Forum ODA Canvas](https://github.com/tmforum-oda/oda-canvas)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Istio Documentation](https://istio.io/latest/docs/)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)
