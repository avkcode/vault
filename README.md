# Real-world example of replacing Helm and other tools with just Make.

## Rational

Using Make instead of Helm or other tools offers greater flexibility due to its simplicity and adaptability. Make allows for dynamic generation of Kubernetes manifests tailored to specific environments through parameterized variables, enabling precise control over configurations without the overhead of a more complex tool. Unlike Helm, which relies on templating and predefined charts, Make provides unrestricted customization, allowing users to define bespoke workflows and integrate with any command-line tooling seamlessly. Additionally, Make's conditional logic and dependency management enable efficient handling of environment-specific parameters and tasks, making it an ideal choice for projects requiring high customization and minimal abstraction.

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

## Unseal Script and Dockerfile

The unseal.py script automates the process of unsealing HashiCorp Vault using provided unseal keys. It checks the Vault's seal status and sends unseal keys to the /sys/unseal endpoint until the Vault is fully unsealed.
The Dockerfile builds a custom Vault image that includes the Python unseal script. It installs Python, copies the script into the container, and configures it to run alongside the Vault server. Unseal keys can be passed via the UNSEAL_KEYS environment variable for secure initialization.
