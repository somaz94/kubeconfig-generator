# Kubernetes User Account and Context Generator

This tool provides a script to create user accounts in a Kubernetes cluster and generate kubeconfig files.

> ⚠️ This script must be run by a cluster administrator  
> The context name must be one of the results from `kubectl config get-contexts -o name`

## Prerequisites

Before using this tool, ensure you have the following components installed:

1. **kubectl** - Kubernetes command-line tool
   ```bash
   # Install on Linux
   curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
   chmod +x kubectl
   sudo mv kubectl /usr/local/bin/
   
   # Install on macOS
   brew install kubectl
   ```

2. **OpenSSL** - For certificate generation
   ```bash
   # Install on Linux
   sudo apt-get install openssl  # Debian/Ubuntu
   sudo yum install openssl      # CentOS/RHEL
   
   # Install on macOS
   brew install openssl
   ```

3. **Base64** - For encoding/decoding
   ```bash
   # Install on Linux
   sudo apt-get install coreutils  # Debian/Ubuntu
   sudo yum install coreutils      # CentOS/RHEL
   
   # Install on macOS (for gbase64)
   brew install coreutils
   ```

4. **Proper RBAC permissions** - The user running this script must have cluster-admin privileges to:
   - Create and approve CSRs
   - Create RoleBindings and ClusterRoleBindings

## Usage

### 1. Preparation
**Enter the required information**

Create a `./list` file with the following format:
```
{username} {email} {target_context} {expiration_days} {role} {namespace}
```

Field descriptions:
- `username`: The username to create
- `email`: User's email address
- `target_context`: The Kubernetes context to use
- `expiration_days`: Certificate validity period in days (or "unlimited")
- `role`: Role to assign to the user (e.g., "cluster-admin", "admin", "edit", "view")
- `namespace`: Namespace for the role binding (use "all" for cluster-wide access)

Example:
```
john john@example.com production-cluster 365 edit development
alice alice@example.com staging-cluster unlimited cluster-admin all
```

### 2. Run the script

```bash
./generate.sh
```

The script will:
1. Generate a certificate signing request (CSR)
2. Submit the CSR to the Kubernetes API server
3. Approve the CSR
4. Retrieve the signed certificate
5. Create a kubeconfig file
6. Create appropriate role bindings
7. Test the generated kubeconfig

### 3. Output

Generated kubeconfig files will be stored in the `./output` directory.

### 4. Testing the Generated Config

You can verify the generated kubeconfig works correctly:

```bash
# View the kubeconfig content
kubectl --kubeconfig=./output/{username}.config config view --raw

# Test access to the cluster
kubectl --kubeconfig=./output/{username}.config get nodes
```

## Available Roles

The script supports the following built-in roles:

- `cluster-admin`: Full control over all resources in the cluster
- `admin`: Read/write access to most resources in a namespace
- `edit`: Read/write access to most resources in a namespace (cannot modify roles)
- `view`: Read-only access to most resources in a namespace

## Certificate Expiration

The certificate expiration is determined by:
1. The value specified in the list file
2. The Kubernetes API server's maximum allowed certificate duration (typically 1 year)

Even if "unlimited" is specified, the actual duration may be limited by the cluster configuration.

## Checking Certificate Validity

To check the validity period of a generated certificate:

```bash
# Extract and decode the client certificate
kubectl --kubeconfig=./output/{username}.config config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 --decode > /tmp/cert.crt

# View certificate validity period
openssl x509 -in /tmp/cert.crt -text -noout | grep -A 2 "Validity"
```

<br/>
