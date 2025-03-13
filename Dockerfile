# Use the official HashiCorp Vault image as the base
FROM hashicorp/vault:latest

# Set environment variables
ENV UNSEAL_SCRIPT_PATH=/usr/local/bin/unseal.py

# Install Python and required dependencies
RUN apt-get update && \
    apt-get install -y python3 python3-pip && \
    rm -rf /var/lib/apt/lists/*

# Copy the Python unseal script into the container
COPY unseal.py ${UNSEAL_SCRIPT_PATH}

# Make the script executable
RUN chmod +x ${UNSEAL_SCRIPT_PATH}

# Optionally, set the entrypoint to include the unseal script logic
ENTRYPOINT ["/bin/sh", "-c", "vault server -config=/vault/config && python3 ${UNSEAL_SCRIPT_PATH}"]
