# monitoring-stack

GitOps-managed observability stack for Kubernetes.

## Components

| Component | Chart | Version |
|-----------|-------|---------|
| Loki | grafana/loki | 6.29.0 |
| Alloy | grafana/alloy | 1.6.2 |
| Prometheus | prometheus-community/prometheus | 25.27.0 |

## Architecture

```
Pods → Alloy (DaemonSet) → Loki (SingleBinary) ← Grafana
Nodes → node-exporter → Prometheus → RemoteWrite → Thanos
```

## Structure

```
.
├── apps/
│   ├── loki/            # Helm values - Loki single binary, 30d retention
│   ├── alloy/           # Helm values - DaemonSet, ships pod logs + Hubble flows
│   ├── prometheus/      # Helm values - scrapes nodes + FRR exporters
│   └── grafana/         # Loki datasource ConfigMap
└── argocd/              # ArgoCD Application manifests
```

## Deploy

### 1. Apply ArgoCD Applications

```bash
kubectl apply -f argocd/loki.yaml
kubectl apply -f argocd/alloy.yaml
kubectl apply -f argocd/prometheus.yaml
```

### 2. Add Loki datasource to Grafana

```bash
kubectl apply -f apps/grafana/datasource-loki.yaml
```

### 3. Verify Loki is up

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki
curl http://<loki-lb-ip>:3100/ready
```

## Notes

- Storage: `proxmox-local-lvm` (20Gi for Loki, 10Gi for Prometheus)
- Alloy ships Kubernetes pod logs and Cilium Hubble flows to Loki
- Prometheus remote-writes to external Thanos at `10.13.13.206:9090`
