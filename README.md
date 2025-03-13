## Unseal Script and Dockerfile

The unseal.py script automates the process of unsealing HashiCorp Vault using provided unseal keys. It checks the Vault's seal status and sends unseal keys to the /sys/unseal endpoint until the Vault is fully unsealed.
The Dockerfile builds a custom Vault image that includes the Python unseal script. It installs Python, copies the script into the container, and configures it to run alongside the Vault server. Unseal keys can be passed via the UNSEAL_KEYS environment variable for secure initialization.
