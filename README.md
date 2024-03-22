# EJBCA and SignServer Ephemeral Deployment to Kubernetes

This repository contains Helm charts, boilerplate configuration, and scripts to deploy EJBCA and SignServer to Kubernetes **FOR TESTING/DEV PURPOSES**. Both EJBCA and SignServer are deployed in front of a MariaDB database, and are accessed using an NGINX Ingress Controller. Client certificates are issued by EJBCA and used to authenticate to both the EJBCA and SignServer nodes.

> This repository is not intended to be used in production environments. It is intended to be used for testing and development purposes only. For more information on deploying EJBCA and SignServer in production environments, please refer to the [EJBCA documentation](https://doc.primekey.com/ejbca/ejbca-installation) and [SignServer documentation](https://doc.primekey.com/signserver/signserver-installation).

## What functionality is included?

EJBCA is deployed with the following CA hierarchy:
* `ManagementCA` - Self-signed CA used to issue the SuperAdmin end entity certificate, and is the trusted root of the SignServer node.
* `Root-CA` - Self-signed CA that acts as the root of the EJBCA hierarchy.
* `Sub-CA` - CA issued by the Root-CA, and is used to issue end entity certificates. This CA signs the initial TLS end entity certificates for both the EJBCA and SignServer nodes.

EJBCA is configured with the following End Entity Profiles:
* `adminInternal` - Used to issue the SuperAdmin end entity certificate.
* `ephemeral` - Can be used to issue ephemeral, short-lived end entity certificates that don't get persisted to the database.
* `k8s` - Can be used to issue end entity certificates with common patterns used by Istio and Kubernetes.
* `tlsServerAnyCA` - Can be used to issue end entity certificates used for TLS, and can be signed by any CA in the hierarchy.
* `userAuthentication` - Can be used to issue end entity certificates used for client authentication.

EJBCA is configured with the following Certificate Profiles:
* `Authentication-2048-3y` - Used to issue end entity certificates with 2048-bit RSA keys that are valid for 3 years.
* `codeSigning-1y` - Used to issue RSA or ECDSA end entity certificates that are valid for 1 year, and have the `codeSigning` extended key usage.
* `istioAuth-3d` - Used to issue end entity certificates with n-bit RSA keys that are valid for 3 days, and have both Client Authentication and Server Authentication extended key usages for mTLS authentication in Istio.
* `tlsClientAuth` - Used to issue end entity certificates with n-bit RSA keys that are valid for 1 year, and have the Client Authentication extended key usage for client authentication.
* `tlsServerAuth` - Used to issue end entity certificates with n-bit RSA keys that are valid for 1 year, and have the Server Authentication extended key usage for server authentication.

## Usage in GitHub Actions

This repository contains an [action.yml](action.yml) that can be used to deploy EJBCA and SignServer to Kubernetes in GitHub Actions workflows. The following example workflow deploys a single node Kubernetes cluster using [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/), and then deploys EJBCA and SignServer to the cluster:

```yaml
name: Deploy ephemeral EJBCA and SignServer for CI testing
on:
  push:
    branches:
      - main

jobs:
  deploy-ejbca-ss:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      # Deploy a single node Kubernetes cluster with kind, then deploy EJBCA and SignServer
      - uses: m8rmclaren/ejbca-signserver-k8s@main
        with:
          deploy-k8s: 'true'
          deploy-nginx-ingress: 'true'
      
      # Demonstrate the environment variables that are set by the action
      - name: Test connection to EJBCA and SignServer
        shell: bash
        run: |
          echo "$EJBCA_HOSTNAME"
          echo "$EJBCA_CA_NAME"
          echo "$EJBCA_CERTIFICATE_PROFILE_NAME"
          echo "$EJBCA_END_ENTITY_PROFILE_NAME"
          echo "$EJBCA_CSR_SUBJECT"
          echo "$EJBCA_CLIENT_CERT_PATH"
          echo "$EJBCA_CLIENT_CERT_KEY_PATH"
          echo "$EJBCA_CA_CERT_PATH"
          echo "$SIGNSERVER_HOSTNAME"
          echo "$SIGNSERVER_CLIENT_CERT_PATH"
          echo "$SIGNSERVER_CLIENT_CERT_KEY_PATH"
          echo "$SIGNSERVER_CA_CERT_PATH"
          
          curl \
            --silent --fail \
            --cert "$EJBCA_CLIENT_CERT_PATH" \
            --key "$EJBCA_CLIENT_KEY_PATH" \
            --cacert "$EJBCA_CA_CERT_PATH" \
            "https://$EJBCA_HOSTNAME/ejbca/ejbca-rest-api/v1/certificate/status"
```

## Pre-requisites

* [jq](https://jqlang.github.io/jq/) >= v1.6
* [curl](https://curl.se/) >= v7.68.0
* [openssl](https://www.openssl.org/) >= v1.1.1
* [Docker](https://docs.docker.com/engine/install/) >= v20.10.0
* [Kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/) >= v1.11.3
* Kubernetes >= v1.19
    * [Kubernetes](https://kubernetes.io/docs/tasks/tools/), [Minikube](https://minikube.sigs.k8s.io/docs/start/), or [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/)
* [Helm](https://helm.sh/docs/intro/install/) >= v3.0.0

## Prerequisite Quick Start

### Macos

It's recommended to use [Docker Desktop](https://www.docker.com/products/docker-desktop/), which includes a [single-node Kubernetes cluster](https://docs.docker.com/desktop/kubernetes/) and the `kubectl` CLI.

Install the following tools using [Homebrew](https://brew.sh/):

```bash
brew install curl helm jq openssl
```

### Linux

This section assumes a Debian-derived Linux distribution, such as Ubuntu. If you're using a different distribution, you'll need to install the tools using your distribution's package manager.

Provision the [Docker engine](https://docs.docker.com/engine/install/ubuntu/). Commands are provided for convenience, but you should follow the official documentation for the latest instructions.

```bash
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do sudo apt-get remove $pkg; done
sudo apt-get update

# Dependencies
sudo apt-get install ca-certificates curl gnupg

# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

# Install latest version
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

For a quick start, you can use [Minikube](https://minikube.sigs.k8s.io/docs/start/) to provision a single-node Kubernetes cluster. Commands are provided for convenience, but you should follow the official documentation for the latest instructions.

```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
```

Start Minikube:

```bash
minikube start
```

> Alternatively, you can use [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/) to provision a single-node Kubernetes cluster. A [Kind configuration file](https://kind.sigs.k8s.io/docs/user/configuration/) is provided as part of this repository.
> For a quick start, you can use the following commands to provision a single-node Kubernetes cluster:
>
> ```bash
> # For AMD64 / x86_64
> [ $(uname -m) = x86_64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
> # For ARM64
> [ $(uname -m) = aarch64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-arm64
> chmod +x ./kind
> sudo mv ./kind /usr/local/bin/kind
> 
> # Deploy a single node cluster with kind
> kind create cluster --config kindconfig.yaml
> ```

Install Helm

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
```

Install kubectl, if it wasn't installed with your Kubernetes distribution:

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

kubectl version --client
```

Install the following tools using [Apt](https://wiki.debian.org/Apt):

```bash
sudo apt-get install curl jq openssl -y
```

### Windows

The shell script commands in this repository are not compatible with Windows. You can use the [Windows Subsystem for Linux](https://docs.microsoft.com/en-us/windows/wsl/install-win10) to run the shell scripts.

## Quick Start

Deploy an NGINX Ingress Controller. If you're using Minikube, you can use the following command:

```bash
minikube addons enable ingress
```

Otherwise, you can use the following command to deploy the NGINX Ingress Controller as a Helm chart:

```bash
helm upgrade --install ingress-nginx ingress-nginx \
    --repo https://kubernetes.github.io/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --set controller.allowSnippetAnnotations=true
```

> If you're using Kind, you can use the following command to deploy the NGINX Ingress Controller with the correct port mappings:
>
> ```bash
> kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
> kubectl patch configmap ingress-nginx-controller -n ingress-nginx --patch '{"data":{"allow-snippet-annotations":"true"}}'
> ```

Finally, deploy EJBCA and SignServer:

```bash
./deploy.sh --signserver-hostname localhost --ejbca-hostname localhost
```

You may need to adjust your hostname if you're using Minikube or Kind. For example, if you're using Minikube, before you run the `deploy.sh` script, add the following entry to your `/etc/hosts` file:

```bash
echo "$(minikube ip) signserver-node1.local" | sudo tee -a /etc/hosts
echo "$(minikube ip) ejbca-node1.local" | sudo tee -a /etc/hosts
```

Then, run the `deploy.sh` script:

```bash
./deploy.sh --signserver-hostname signserver-node1.local --ejbca-hostname ejbca-node1.local
```

To test the deployment, you can use the following command to retrieve the status of the EJBCA CA:

```bash
curl https://localhost/ejbca/ejbca-rest-api/v1/certificate/status \
  --cacert ./Sub-CA-chain.pem \
  --cert ./superadmin.pem \
  --key ./superadmin.key
```

## Configure SignServer

To quickly configure SignServer, you can use the REST API to create a P12 Crypto Worker and a Plain Signer that uses client-side hashing:

```bash
curl -X 'POST' \
  'https://localhost/signserver/rest/v1/workers' \
  --cacert ./Sub-CA-chain.pem \
  --cert ./superadmin.pem \
  --key ./superadmin.key \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -H 'X-Keyfactor-Requested-With: APIClient' \
  -d '{
  "properties": {
    "CRYPTOTOKEN_IMPLEMENTATION_CLASS": "org.signserver.server.cryptotokens.KeystoreCryptoToken",
    "IMPLEMENTATION_CLASS": "org.signserver.server.signers.CryptoWorker",
    "KEYSTOREPASSWORD": "foo123",
    "KEYSTOREPATH": "/opt/signserver/res/test/dss10/dss10_keystore.p12",
    "KEYSTORETYPE": "PKCS12",
    "NAME": "CryptoTokenP12",
    "TYPE": "CRYPTO_WORKER"
  }
}'

curl -X 'POST' \
  'https://localhost/signserver/rest/v1/workers' \
  --cacert ./Sub-CA-chain.pem \
  --cert ./superadmin.pem \
  --key ./superadmin.key \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -H 'X-Keyfactor-Requested-With: APIClient' \
  -d '{
  "properties": {
    "ACCEPTED_HASH_DIGEST_ALGORITHMS": "SHA-256,SHA-384,SHA-512",
    "AUTHTYPE": "NOAUTH",
    "CLIENTSIDEHASHING": "true",
    "CRYPTOTOKEN": "CryptoTokenP12",
    "DEFAULTKEY": "signer00003",
    "DISABLEKEYUSAGECOUNTER": "true",
    "DO_LOGREQUEST_DIGEST": "",
    "IMPLEMENTATION_CLASS": "org.signserver.module.cmssigner.PlainSigner",
    "LOGREQUEST_DIGESTALGORITHM": "",
    "NAME": "PlainSigner",
    "SIGNATUREALGORITHM": "NONEwithRSA",
    "TYPE": "PROCESSABLE"
  }
}'
```

## Uninstall

To uninstall EJBCA and SignServer, run the following command:

```bash
./deploy.sh --uninstall
```
