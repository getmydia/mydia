# Metadata Relay Kubernetes Deployment

This directory contains Kubernetes manifests for deploying the metadata-relay service.

## Overview

The metadata-relay is a proxy service that:
- Handles metadata requests to TVDB and TMDB
- Protects API keys by centralizing requests
- Reduces rate limiting issues
- Provides caching for frequently accessed metadata

## Prerequisites

- k3s cluster with Traefik ingress controller
- cert-manager installed with `letsencrypt-prod` ClusterIssuer configured
- DNS record for `relay.mydia.dev` pointing to your cluster

## Quick Start

### 1. Create Secrets

```bash
# Copy the secret template
cp secret.yaml.example secret.yaml

# Edit secret.yaml and replace placeholder values
# Generate RELAY_TOKEN_SECRET with: openssl rand -hex 32
vim secret.yaml

# Apply the secret
kubectl apply -f secret.yaml
```

### 2. Deploy All Resources

Using kustomize:
```bash
kubectl apply -k .
```

Or apply individually:
```bash
kubectl apply -f namespace.yaml
kubectl apply -f configmap.yaml
kubectl apply -f pvc.yaml
kubectl apply -f secret.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f ingress.yaml
```

### 3. Verify Deployment

```bash
# Check all resources
kubectl get all -n metadata-relay

# Check ingress and certificate
kubectl get ingress,certificate -n metadata-relay

# Check logs
kubectl logs -n metadata-relay -l app.kubernetes.io/name=metadata-relay -f

# Test health endpoint
curl https://relay.mydia.dev/health
```

## Configuration

### ConfigMap (configmap.yaml)

- `PORT`: Application port (default: 4001)
- `PHX_HOST`: Hostname for Phoenix (relay.mydia.dev)
- `MIX_ENV`: Environment (prod)
- `SQLITE_DB_PATH`: Path to SQLite database file

### Secrets (secret.yaml)

Required secrets:
- `RELAY_TOKEN_SECRET`: Authentication token (generate with `openssl rand -hex 32`)
- `TMDB_API_KEY`: The Movie Database API key
- `TVDB_API_KEY`: TheTVDB API key

Optional secrets:
- `SUBDL_API_KEY`: SubDL API key

### Storage

The deployment uses a PersistentVolumeClaim with:
- Size: 1Gi
- Storage class: `local-path` (k3s default)
- Access mode: ReadWriteOnce

SQLite database is stored at `/data/metadata_relay.db` inside the container.

## Accessing the Service

- **External URL**: https://relay.mydia.dev
- **Health Check**: https://relay.mydia.dev/health
- **Internal Service**: `metadata-relay.metadata-relay.svc.cluster.local:4001`

## Troubleshooting

### Pod not starting

```bash
# Check pod status
kubectl describe pod -n metadata-relay -l app.kubernetes.io/name=metadata-relay

# Check logs
kubectl logs -n metadata-relay -l app.kubernetes.io/name=metadata-relay
```

### Certificate not issued

```bash
# Check certificate status
kubectl describe certificate -n metadata-relay metadata-relay-tls

# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager
```

### Ingress not working

```bash
# Check ingress status
kubectl describe ingress -n metadata-relay metadata-relay

# Check Traefik logs
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik
```

### Database issues

The SQLite database is stored in a PersistentVolume. If you need to reset it:

```bash
# Scale down deployment
kubectl scale deployment -n metadata-relay metadata-relay --replicas=0

# Delete and recreate PVC (WARNING: This will delete all data)
kubectl delete pvc -n metadata-relay metadata-relay-data
kubectl apply -f pvc.yaml

# Scale back up
kubectl scale deployment -n metadata-relay metadata-relay --replicas=1
```

## Updating

### Update container image

```bash
# Edit deployment.yaml and update the image tag
# Or patch directly:
kubectl set image deployment/metadata-relay \
  -n metadata-relay \
  metadata-relay=ghcr.io/arosenfeld/mydia-metadata-relay:v1.2.3

# Watch rollout
kubectl rollout status deployment/metadata-relay -n metadata-relay
```

### Update configuration

```bash
# Edit configmap.yaml or secret.yaml
vim configmap.yaml

# Apply changes
kubectl apply -f configmap.yaml

# Restart deployment to pick up changes
kubectl rollout restart deployment/metadata-relay -n metadata-relay
```

## Resource Limits

Default resource limits:
- Requests: 256Mi memory, 100m CPU
- Limits: 512Mi memory, 500m CPU

Adjust in deployment.yaml based on your cluster capacity and traffic patterns.

## Security Notes

1. **Never commit secret.yaml** - Add it to .gitignore
2. **Rotate secrets regularly** - Update RELAY_TOKEN_SECRET periodically
3. **Protect API keys** - Store them securely in Kubernetes secrets
4. **Use TLS** - The ingress enforces HTTPS with Let's Encrypt certificates

## Auto-Deploy with Keel

The deployment is configured for automatic updates via [Keel](https://keel.sh/).
When a new image is pushed to the container registry, Keel automatically triggers a rolling update.

Deployment annotations:
```yaml
keel.sh/policy: major           # Update on any new semver version
keel.sh/trigger: poll           # Poll registry for new images
keel.sh/pollSchedule: "@every 5m"
```

To manually trigger an update:
```bash
kubectl rollout restart deployment/metadata-relay -n metadata-relay
```
