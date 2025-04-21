#!/usr/bin/env python3
"""
Istio Automated Installer
Performs system-appropriate installation of Istio service mesh
"""

import os
import platform
import subprocess
import sys
import urllib.request
import tarfile
import shutil

# Configuration
ISTIO_VERSION = "1.25.2"
ISTIO_PROFILE = "default"  # Options: minimal/default/demo/remote/external

def execute_command(cmd, check=True):
    """Run shell command with error handling"""
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            check=check,
            text=True,
            capture_output=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"Command failed: {e.cmd}")
        print(f"Error output: {e.stderr}")
        sys.exit(1)

def get_system_info():
    """Identify operating system and architecture"""
    system = platform.system().lower()
    machine = platform.machine().lower()
    
    system = "osx" if system == "darwin" else system
    system = "win" if system == "windows" else system
    
    arch_map = {
        "x86_64": "amd64",
        "aarch64": "arm64"
    }
    machine = arch_map.get(machine, machine)
        
    return system, machine

def fetch_istio():
    """Download and extract Istio release"""
    system, arch = get_system_info()
    download_url = f"https://github.com/istio/istio/releases/download/{ISTIO_VERSION}/istio-{ISTIO_VERSION}-{system}-{arch}.tar.gz"
    download_path = f"/tmp/istio-{ISTIO_VERSION}.tar.gz"
    
    print(f"Downloading Istio {ISTIO_VERSION} for {system}/{arch}...")
    urllib.request.urlretrieve(download_url, download_path)
    
    print("Extracting package...")
    with tarfile.open(download_path, "r:gz") as tar:
        tar.extractall("/tmp")
    
    istio_path = f"/tmp/istio-{ISTIO_VERSION}"
    os.environ["PATH"] += os.pathsep + f"{istio_path}/bin"
    return istio_path

def install_istio_mesh(istio_path):
    """Perform Istio installation to Kubernetes cluster"""
    print("Installing Istio with profile:", ISTIO_PROFILE)
    
    if not execute_command("kubectl cluster-info", check=False):
        print("kubectl not configured or cluster unavailable")
        sys.exit(1)
    
    execute_command(f"sudo cp {istio_path}/bin/istioctl /usr/local/bin/")
    execute_command(f"istioctl install --set profile={ISTIO_PROFILE} -y")
    
    print("Verifying installation...")
    execute_command("kubectl get pods -n istio-system")
    
    execute_command("kubectl label namespace default istio-injection=enabled --overwrite")
    print("Istio installation completed")

def remove_temp_files(istio_path):
    """Clean up temporary installation files"""
    shutil.rmtree(istio_path, ignore_errors=True)
    os.remove(f"/tmp/istio-{ISTIO_VERSION}.tar.gz")

def main():
    print(f"Istio Automated Installer version {ISTIO_VERSION}")
    print("----------------------------------------")
    
    istio_path = fetch_istio()
    try:
        install_istio_mesh(istio_path)
    finally:
        remove_temp_files(istio_path)
    
    print("\nNext steps to verify installation:")
    print("kubectl get pods -n istio-system")
    print("kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml")
    print("istioctl dashboard prometheus")

if __name__ == "__main__":
    main()
