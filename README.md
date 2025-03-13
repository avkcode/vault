# Real-world example of replacing Helm and other tools with just Make.

Inspired by Rob Pike article [Less is exponentially more](https://commandcenter.blogspot.com/2012/06/less-is-exponentially-more.html)
And Apple [Pkl tool](https://pkl-lang.org/blog/know-your-place.html)

Pkl is an example of a complex tool, which is using DSL, type validation, IDE integration, complex templating. It’s built with “futamura projections” and stuff like that.. But is it possible that it could be replaced with just Make and some duct taping?

This script can be used to deploy Hashicrop Vault to as many environments as necessary, with different sets of parameters. It can validate parameters and create releases just like Helm, but without any external tooling, just kubectl and Make.

Here how it works:

The Makefile has a bunch of **targets** (commands you can run). Each target does something specific, like creating Kubernetes files, deploying the app, or cleaning up. You run these targets using the `make`command. Running make without any targets outputs the help:
```
make
Available targets:
  template          - Generate Kubernetes manifests from templates
  apply             - Apply generated manifests to the Kubernetes cluster
  delete            - Delete Kubernetes resources defined in the manifests
  kubescore         - Run kube-score against the generated manifests
  validate-%        - Validate a specific manifest using yq
  print-%           - Print the value of a specific variable
  get-vault-ui      - Fetch the Vault UI Node IP and NodePort
  build-vault-image - Build the Vault Docker image
  exec              - Execute a shell in the vault-0 pod
  logs              - Stream logs from the vault-0 pod
  switch-namespace  - Switch the current Kubernetes namespace
  archive           - Create a git archive
  bundle            - Create a git bundle
  clean             - Clean up generated files
  release           - Create a Git tag and release on GitHub
  get-vault-keys    - Initialize Vault and retrieve unseal and root keys
  show-params       - Show contents of the parameter file for the current environment
  help              - Display this help message
```

## Workflow

When you run make apply, several steps are executed in sequence to apply the Kubernetes manifests to your cluster.

```
+-------------------+
|   make apply      |
+-------------------+
          |
          v
+-------------------+
| 1. Create Release |
|   - Generates a   |
|     Kubernetes    |
|     secret with   |
|     VERSION set   |
|     to Git commit |
|     SHA.          |
+-------------------+
          |
          v
+--------------------+
| 2. Apply Manifests |
|   - Iterates over  |
|     the list of    |
|     manifests      |
|     (rbac, config- |
|     map, services, |
|     statefulset)   |
|   - Applies each   |
|     manifest to    |
|     the cluster    |
|     using kubectl  |
|     apply.         |
+--------------------+
          |
          v
+-------------------+
| 3. Output Status  |
|   - Outputs the   |
|     status of the |
|     applied       |
|     resources.    |
+-------------------+
```

Every time you run make apply, the Makefile is designed to automatically trigger the create-release target as part of the process. This ensures that a Kubernetes secret is created with the current Git commit SHA, which helps track the version of the app being deployed. By including this step, the Makefile guarantees that the release information is always up-to-date and stored in the cluster whenever the manifests are applied. This makes it easier to identify which version of the app is running and maintain consistency across deployments. Make delete triggers remove-release target.

- global.param - contains validation checks 
- dev.param - enviroment variables
```

## Unseal Script and Dockerfile

The unseal.py script automates the process of unsealing HashiCorp Vault using provided unseal keys. It checks the Vault's seal status and sends unseal keys to the /sys/unseal endpoint until the Vault is fully unsealed.
The Dockerfile builds a custom Vault image that includes the Python unseal script. It installs Python, copies the script into the container, and configures it to run alongside the Vault server. Unseal keys can be passed via the UNSEAL_KEYS environment variable for secure initialization.
