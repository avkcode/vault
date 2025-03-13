#!/usr/bin/env python3

import os
import sys
import time
import requests


def unseal_vault(vault_addr, unseal_keys):
    """
    Unseal the Vault using the provided unseal keys.
    """
    print("Attempting to unseal Vault...")
    # Check if Vault is already unsealed
    try:
        response = requests.get(f"{vault_addr}/v1/sys/seal-status", timeout=5)
        if response.json().get("sealed") is False:
            print("Vault is already unsealed.")
            return
    except requests.exceptions.RequestException as e:
        print(f"Error checking Vault seal status: {e}")
        sys.exit(1)

    # Perform unsealing
    for key in unseal_keys:
        try:
            response = requests.put(
                f"{vault_addr}/v1/sys/unseal",
                json={"key": key},
                timeout=5
            )
            if response.status_code != 200:
                print(f"Failed to unseal Vault: {response.text}")
                sys.exit(1)
            print("Unseal progress:", response.json().get("progress"))
            if response.json().get("sealed") is False:
                print("Vault successfully unsealed!")
                return
        except requests.exceptions.RequestException as e:
            print(f"Error unsealing Vault: {e}")
            sys.exit(1)

    print("Failed to unseal Vault after all keys were used.")
    sys.exit(1)


if __name__ == "__main__":
    # Configuration
    VAULT_ADDR = os.getenv("VAULT_ADDR", "http://127.0.0.1:8200")
    UNSEAL_KEYS = os.getenv("UNSEAL_KEYS", "").split(",")

    if not UNSEAL_KEYS or all(key.strip() == "" for key in UNSEAL_KEYS):
        print("Error: UNSEAL_KEYS environment variable must be set with valid unseal keys.")
        sys.exit(1)

    # Wait for Vault to start (optional, if needed)
    print("Waiting for Vault to start...")
    time.sleep(5)

    # Attempt to unseal Vault
    unseal_vault(VAULT_ADDR, UNSEAL_KEYS)
