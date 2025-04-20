The canary deployment process begins with initializing the system to mark the current production deployment as stable. Next, a canary version is deployed with reduced replicas and a small percentage of traffic. The status can be monitored to observe the canary's performance. Based on validation results, the canary can either be promoted to full production or rolled back if issues are detected. The deployment can be customized by adjusting the number of canary replicas and traffic percentage, allowing for gradual rollout and testing of new versions while minimizing risk. This approach provides a controlled method for validating changes in production before full deployment.

## Basic Canary Deployment Flow
```
# First, initialize your production deployment (one-time setup)
make canary-init ENV=prod

# Deploy canary version with default settings (1 replica, 10% traffic)
make canary-deploy ENV=prod

# Check deployment status
make canary-status ENV=prod

# After verification, promote to production
make canary-validate-promote ENV=prod
```

## Custom Canary Deployment
```
# Deploy with 2 replicas and 25% traffic
make canary-deploy ENV=prod CANARY_REPLICAS=2 CANARY_TRAFFIC_PERCENTAGE=25

# Monitor specific canary pods
kubectl get pods -n vault-prod -l app.kubernetes.io/track=canary --watch

# Rollback if issues found
make canary-rollback ENV=prod
```

## Automated Validation and Promotion
```
# Deploy and automatically validate before promoting
make canary-deploy ENV=staging && \
sleep 60 && \  # Wait for deployment to stabilize
make canary-validate-promote ENV=staging
```

## Blue/Green Style Canary (100% Traffic Switch)
```
# Deploy canary with zero traffic initially
make canary-deploy ENV=prod CANARY_TRAFFIC_PERCENTAGE=0

# Gradually increase traffic
make canary-traffic ENV=prod CANARY_TRAFFIC_PERCENTAGE=50
make canary-traffic ENV=prod CANARY_TRAFFIC_PERCENTAGE=100

# Finalize promotion
make canary-promote ENV=prod
```

## Canary with Custom Image
```
# Deploy specific image version as canary
DOCKER_IMAGE=vault:1.15.0-beta make canary-deploy ENV=uat

# Verify specific metrics
make canary-status ENV=uat
kubectl top pods -n vault-uat
```

## Full Cleanup
```
# Remove all canary resources completely
make canary-cleanup ENV=dev
```
