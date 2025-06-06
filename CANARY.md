# Canary Deployment Guide

## Overview

Canary deployment is a technique that reduces risk when deploying new software versions. The process involves:

1. **Initialization**: Mark the current production deployment as stable
2. **Canary Release**: Deploy a new version with limited replicas and traffic
3. **Validation**: Monitor and test the canary version in production
4. **Decision**: Either promote the canary to production or roll back

This approach allows for real-world testing with minimal risk, as only a small percentage of users are initially exposed to the new version.

## Key Benefits

- **Risk Reduction**: Limits the impact of potential issues
- **Early Detection**: Identifies problems before full deployment
- **Gradual Rollout**: Controls the pace of the deployment
- **Real User Validation**: Tests with actual production traffic
- **Quick Rollback**: Provides fast recovery if issues arise

## Basic Canary Deployment Flow

```bash
# Step 1: Initialize your production deployment (one-time setup)
make canary-init ENV=prod

# Step 2: Deploy canary version with default settings (1 replica, 10% traffic)
make canary-deploy ENV=prod

# Step 3: Check deployment status
make canary-status ENV=prod

# Step 4: After verification, promote to production
make canary-validate-promote ENV=prod
```

## Custom Canary Deployment

Adjust the canary deployment parameters to suit your specific needs:

```bash
# Deploy with 2 replicas and 25% traffic
make canary-deploy ENV=prod CANARY_REPLICAS=2 CANARY_TRAFFIC_PERCENTAGE=25

# Monitor specific canary pods
kubectl get pods -n vault-prod -l app.kubernetes.io/track=canary --watch

# View detailed metrics of the canary deployment
make canary-metrics ENV=prod

# Rollback if issues found
make canary-rollback ENV=prod
```

## Automated Validation and Promotion

For CI/CD pipelines, you can automate the validation and promotion process:

```bash
# Deploy and automatically validate before promoting
make canary-deploy ENV=staging && \
sleep 60 && \  # Wait for deployment to stabilize
make canary-validate-promote ENV=staging
```

## Progressive Traffic Shifting

Control the traffic distribution between stable and canary versions:

```bash
# Deploy canary with zero traffic initially
make canary-deploy ENV=prod CANARY_TRAFFIC_PERCENTAGE=0

# Gradually increase traffic
make canary-traffic ENV=prod CANARY_TRAFFIC_PERCENTAGE=10
make canary-traffic ENV=prod CANARY_TRAFFIC_PERCENTAGE=25
make canary-traffic ENV=prod CANARY_TRAFFIC_PERCENTAGE=50
make canary-traffic ENV=prod CANARY_TRAFFIC_PERCENTAGE=100

# Finalize promotion
make canary-promote ENV=prod
```

## Advanced Use Cases

### Canary with Custom Image

```bash
# Deploy specific image version as canary
DOCKER_IMAGE=vault:1.15.0-beta make canary-deploy ENV=uat

# Verify specific metrics
make canary-status ENV=uat
kubectl top pods -n vault-uat
```

### Istio-Enabled Canary Deployment

When using Istio for service mesh capabilities:

```bash
# Enable Istio sidecar injection for advanced traffic control
make canary-deploy ENV=prod ENABLE_ISTIO_SIDECAR=true

# Fine-grained traffic control with Istio
make canary-traffic ENV=prod CANARY_TRAFFIC_PERCENTAGE=15 ENABLE_ISTIO_SIDECAR=true
```

### Custom Validation Timeout

```bash
# Extend validation timeout for complex applications
make canary-validate ENV=prod CANARY_VALIDATION_TIMEOUT=600s
```

## Cleanup

```bash
# Remove all canary resources completely
make canary-cleanup ENV=dev
```

## Troubleshooting

If you encounter issues during canary deployment:

1. Check canary pod logs: `make canary-metrics ENV=prod`
2. Inspect pod details: `kubectl describe pod -n vault-prod <pod-name>`
3. Verify service connectivity: `kubectl exec -n vault-prod <pod-name> -- curl localhost:8200/v1/sys/health`
4. If needed, rollback: `make canary-rollback ENV=prod`

## Best Practices

- Start with a low traffic percentage (5-10%)
- Monitor key metrics during canary deployment
- Set appropriate health checks for validation
- Use automated validation for consistent results
- Implement proper logging for troubleshooting
- Have a clear rollback strategy
