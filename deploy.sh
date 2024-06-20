#!/bin/bash

source ./ejbca.sh
source ./k8s.sh

EJBCA_NAMESPACE=ejbca
EJBCA_INGRESS_HOSTNAME=localhost
EJBCA_IMAGE="keyfactor/ejbca-ce"
EJBCA_TAG="latest"

SIGNSERVER_NAMESPACE=signserver
SIGNSERVER_INGRESS_HOSTNAME=localhost
SIGNSERVER_IMAGE="keyfactor/ejbca-ce"
SIGNSERVER_TAG="latest"

IMAGE_PULL_SECRET_NAME=""

EJBCA_ROOT_CA_NAME="Root-CA"
EJBCA_SUB_CA_NAME="Sub-CA"

# Clean up the filesystem for a clean install
cleanFilesystem() {
    find . -name "*.tgz" -type f -exec rm {} +
    find . -name "ejbca.env" -type f -exec rm {} +
}

# Verify that required tools are installed
verifySupported() {
    HAS_HELM="$(type "helm" &>/dev/null && echo true || echo false)"
    HAS_KUBECTL="$(type "kubectl" &>/dev/null && echo true || echo false)"
    HAS_JQ="$(type "jq" &>/dev/null && echo true || echo false)"
    HAS_CURL="$(type "curl" &>/dev/null && echo true || echo false)"
    HAS_OPENSSL="$(type "openssl" &>/dev/null && echo true || echo false)"

    if [ "${HAS_JQ}" != "true" ]; then
        echo "jq is required"
        exit 1
    fi

    if [ "${HAS_CURL}" != "true" ]; then
        echo "curl is required"
        exit 1
    fi

    if [ "${HAS_HELM}" != "true" ]; then
        echo "helm is required"
        exit 1
    fi

    if [ "${HAS_KUBECTL}" != "true" ]; then
        echo "kubectl is required"
        exit 1
    fi

    if [ "${HAS_OPENSSL}" != "true" ]; then
        echo "openssl is required"
        exit 1
    fi

    # Verify that an nginx ingress controller is installed. If one is, the nginx ingress class will be returned.
    if [ "$(kubectl get ingressclass -o json | jq -e '.items[] | any(.metadata; .name == "nginx")')" == "" ]; then
        echo "Couldn't find the nginx ingress class - is an nginx ingress controller installed?"
    fi
}

###############################################
# EJBCA CA Creation and Initialization        #
###############################################

# Figure out if the cluster is already initialized for EJBCA
isEjbcaAlreadyDeployed() {
    if [ "$(kubectl --namespace "$EJBCA_NAMESPACE" get pods -l app.kubernetes.io/name=ejbca -o json | jq '.items[] | select(.metadata.labels."app.kubernetes.io/name" == "ejbca") | .metadata.name' | tr -d '"')" != "" ]; then
        return 0
    else
        return 1
    fi
}

# Waits for the EJBCA node to be ready
# cluster_namespace - The namespace where the EJBCA node is running
# ejbca_pod_name - The name of the Pod running the EJBCA node
waitForEJBCANode() {
    local cluster_namespace=$1
    local ejbca_pod_name=$2

    echo "Waiting for EJBCA node to be ready"
    until ! kubectl -n "$cluster_namespace" exec "$ejbca_pod_name" -- /opt/keyfactor/bin/ejbca.sh 2>&1 | grep -q "could not contact EJBCA"; do
        echo "EJBCA node not ready yet, retrying in 5 seconds..."
        sleep 5
    done
    echo "EJBCA node $cluster_namespace/$ejbca_pod_name is ready."
}

configmapNameFromFilename() {
    local filename=$1
    echo "$(basename "$filename" | tr _ - | tr '[:upper:]' '[:lower:]')"
}

# Initialize the cluster for EJBCA
initClusterForEJBCA() {
    # Create the EJBCA namespace if it doesn't already exist
    if [ "$(kubectl get namespace -o json | jq -e '.items[] | select(.metadata.name == "'"$EJBCA_NAMESPACE"'") | .metadata.name')" == "" ]; then
        kubectl create namespace "$EJBCA_NAMESPACE"
    fi

    # Mount the staged EEPs & CPs to Kubernetes with ConfigMaps
    for file in $(find ./ejbca/staging -maxdepth 1 -mindepth 1); do
        configmapname="$(basename "$file")"
        createConfigmapFromFile "$EJBCA_NAMESPACE" "$(configmapNameFromFilename "$configmapname")" "$file"
    done

    # Mount the ejbca init script to Kubernetes using a ConigMap
    createConfigmapFromFile "$EJBCA_NAMESPACE" "ejbca-init" "./ejbca/scripts/ejbca-init.sh"
}

# Clean up the config maps used to init the EJBCA database
cleanupEJBCAConfigMaps() {
    for file in $(find ./ejbca/staging -maxdepth 1 -mindepth 1); do
        configMapName="$(configmapNameFromFilename "$file")"
        kubectl delete configmap --namespace "$EJBCA_NAMESPACE" "$configMapName"
    done
}

# Initialze the database by spinning up an instance of EJBCA infront of a MariaDB database, and
# create the CA hierarchy and import boilerplate profiles.
initEJBCADatabase() {
    helm_install_args=(
        "--namespace" 
        "$EJBCA_NAMESPACE" 
        "install" 
        "ejbca-node1" 
        "./ejbca" 
        "--set" "ejbca.ingress.enabled=false"
    )

    container_staging_dir="/opt/keyfactor/stage"
    index=0
    for file in $(find ./ejbca/staging -maxdepth 1 -mindepth 1); do
        configMapName="$(configmapNameFromFilename "$file")"
        volume_name="$(echo "$configMapName" | sed 's/\.[^.]*$//')"

        helm_install_args+=("--set" "ejbca.volumes[$index].name=$volume_name")
        helm_install_args+=("--set" "ejbca.volumes[$index].configMapName=$configMapName")
        helm_install_args+=("--set" "ejbca.volumes[$index].mountPath=$container_staging_dir/$configMapName")
        index=$((index + 1))
    done

    helm_install_args+=("--set" "ejbca.volumes[$index].name=ejbca-init")
    helm_install_args+=("--set" "ejbca.volumes[$index].configMapName=ejbca-init")
    helm_install_args+=("--set" "ejbca.volumes[$index].mountPath=/tmp/")

    helm_install_args+=("--set" "ejbca.extraEnvironmentVars[0].name=EJBCA_INGRESS_HOSTNAME")
    helm_install_args+=("--set" "ejbca.extraEnvironmentVars[0].value=$EJBCA_INGRESS_HOSTNAME")

    helm_install_args+=("--set" "ejbca.extraEnvironmentVars[1].name=EJBCA_INGRESS_SECRET_NAME")
    helm_install_args+=("--set" "ejbca.extraEnvironmentVars[1].value=ejbca-ingress-tls")

    helm_install_args+=("--set" "ejbca.extraEnvironmentVars[2].name=EJBCA_SUPERADMIN_COMMONNAME")
    helm_install_args+=("--set" "ejbca.extraEnvironmentVars[2].value=$EJBCA_INGRESS_HOSTNAME-SuperAdmin")

    helm_install_args+=("--set" "ejbca.extraEnvironmentVars[3].name=EJBCA_ROOT_CA_NAME")
    helm_install_args+=("--set" "ejbca.extraEnvironmentVars[3].value=$EJBCA_ROOT_CA_NAME")

    helm_install_args+=("--set" "ejbca.extraEnvironmentVars[4].name=EJBCA_SUB_CA_NAME")
    helm_install_args+=("--set" "ejbca.extraEnvironmentVars[4].value=$EJBCA_SUB_CA_NAME")

    k8s_reverseproxy_service_fqdn="ejbca-rp-service.$EJBCA_NAMESPACE.svc.cluster.local"
    helm_install_args+=("--set" "ejbca.extraEnvironmentVars[5].name=EJBCA_CLUSTER_REVERSEPROXY_FQDN")
    helm_install_args+=("--set" "ejbca.extraEnvironmentVars[5].value=$k8s_reverseproxy_service_fqdn")

    helm_install_args+=("--set" "ejbca.extraEnvironmentVars[6].name=EJBCA_RP_TLS_SECRET_NAME")
    helm_install_args+=("--set" "ejbca.extraEnvironmentVars[6].value=ejbca-reverseproxy-tls")

    helm_install_args+=("--set" "ejbca.image.repository=$EJBCA_IMAGE")
    helm_install_args+=("--set" "ejbca.image.tag=$EJBCA_TAG")
    if [ ! -z "$IMAGE_PULL_SECRET_NAME" ]; then
        helm_install_args+=("--set" "ejbca.image.pullSecrets[0].name=$IMAGE_PULL_SECRET_NAME")
    fi

    if ! helm "${helm_install_args[@]}" ; then
        echo "Failed to install EJBCA"
        kubectl delete namespace "$EJBCA_NAMESPACE"
        exit 1
    fi

    # Wait for the EJBCA Pod to be ready
    echo "Waiting for EJBCA Pod to be ready"
    kubectl --namespace "$EJBCA_NAMESPACE" wait --for=condition=ready pod -l app.kubernetes.io/name=ejbca --timeout=300s

    # Get the name of the EJBCA Pod
    local ejbca_pod_name
    ejbca_pod_name=$(kubectl --namespace "$EJBCA_NAMESPACE" get pods -l app.kubernetes.io/name=ejbca -o json | jq '.items[] | select(.metadata.labels."app.kubernetes.io/name" == "ejbca") | .metadata.name' | tr -d '"')

    # Wait for the EJBCA Pod to be ready
    waitForEJBCANode "$EJBCA_NAMESPACE" "$ejbca_pod_name"

    # Execute the EJBCA init script
    args=(
        --namespace "$EJBCA_NAMESPACE" exec "$ejbca_pod_name" --
        bash -c 'cp /tmp/ejbca-init.sh /opt/keyfactor/bin/ejbca-init.sh && chmod +x /opt/keyfactor/bin/ejbca-init.sh && /opt/keyfactor/bin/ejbca-init.sh'
        )
    if ! kubectl "${args[@]}" ; then
        echo "Failed to execute the EJBCA init script"
        kubectl delete ns "$EJBCA_NAMESPACE"
        exit 1
    fi

    # Uninstall the EJBCA helm chart - database is peristent
    helm --namespace "$EJBCA_NAMESPACE" uninstall ejbca-node1
    cleanupEJBCAConfigMaps
}

# Deploy EJBCA with ingress enabled
deployEJBCA() {
    # Package and deploy the EJBCA helm chart with ingress enabled
    helm_install_args=(
        "--namespace" 
        "$EJBCA_NAMESPACE" 
        "install" 
        "ejbca-node1" 
        "./ejbca" 
        "--set" 
        "ejbca.ingress.enabled=false"
    )
    helm_install_args+=("--set" "ejbca.ingress.enabled=true")
    helm_install_args+=("--set" "ejbca.ingress.hosts[0].host=$EJBCA_INGRESS_HOSTNAME")
    helm_install_args+=("--set" "ejbca.ingress.hosts[0].tlsSecretName=ejbca-ingress-tls")
    helm_install_args+=("--set" "ejbca.ingress.hosts[0].paths[0].path=/ejbca/")
    helm_install_args+=("--set" "ejbca.ingress.hosts[0].paths[0].pathType=Prefix")
    helm_install_args+=("--set" "ejbca.ingress.hosts[0].paths[0].serviceName=ejbca-service")
    helm_install_args+=("--set" "ejbca.ingress.hosts[0].paths[0].portName=ejbca-https")
    helm_install_args+=("--set" "ejbca.ingress.insecureHosts[0].host=$EJBCA_INGRESS_HOSTNAME")
    helm_install_args+=("--set" "ejbca.ingress.insecureHosts[0].paths[0].path=/ejbca/publicweb/")
    helm_install_args+=("--set" "ejbca.ingress.insecureHosts[0].paths[0].pathType=Prefix")
    helm_install_args+=("--set" "ejbca.ingress.insecureHosts[0].paths[0].serviceName=ejbca-service")
    helm_install_args+=("--set" "ejbca.ingress.insecureHosts[0].paths[0].portName=ejbca-http")
    helm_install_args+=("--set" "ejbca.reverseProxy.enabled=true")

    helm_install_args+=("--set" "ejbca.image.repository=$EJBCA_IMAGE")
    helm_install_args+=("--set" "ejbca.image.tag=$EJBCA_TAG")
    if [ ! -z "$IMAGE_PULL_SECRET_NAME" ]; then
        helm_install_args+=("--set" "ejbca.image.pullSecrets[0].name=$IMAGE_PULL_SECRET_NAME")
    fi

    if ! helm "${helm_install_args[@]}" ; then
        echo "Failed to install EJBCA"
        exit 1
    fi

    sleep 20
    
    # Wait for the EJBCA Pod to be ready
    echo "Waiting for EJBCA Pod to be ready"
    kubectl --namespace "$EJBCA_NAMESPACE" wait --for=condition=ready pod -l app.kubernetes.io/instance=ejbca-node1 --timeout=300s

    # Get the name of the EJBCA Pod
    local ejbca_pod_name
    ejbca_pod_name=$(kubectl --namespace "$EJBCA_NAMESPACE" get pods -l app.kubernetes.io/name=ejbca -o json | jq '.items[] | select(.metadata.labels."app.kubernetes.io/name" == "ejbca") | .metadata.name' | tr -d '"')

    # Wait for the EJBCA node to be ready
    waitForEJBCANode "$EJBCA_NAMESPACE" "$ejbca_pod_name"
}

# Export variables for use in the script, and test the API connection
setupEjbcaForScript() {
    EJBCA_HOSTNAME="$EJBCA_INGRESS_HOSTNAME"
    EJBCA_IN_CLUSTER_HOSTNAME="ejbca-rp-service.$EJBCA_NAMESPACE.svc.cluster.local:8443"
    EJBCA_CA_NAME="$EJBCA_SUB_CA_NAME"
    EJBCA_CERTIFICATE_PROFILE_NAME="tlsServerAuth"
    EJBCA_END_ENTITY_PROFILE_NAME="tlsServerAnyCA"
    EJBCA_CSR_SUBJECT="CN=$EJBCA_INGRESS_HOSTNAME,OU=IT"

    kubectl --namespace "$EJBCA_NAMESPACE" get secret superadmin-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > $(pwd)/superadmin.pem
    kubectl --namespace "$EJBCA_NAMESPACE" get secret superadmin-tls -o jsonpath='{.data.tls\.key}' | base64 -d > $(pwd)/superadmin.key
    kubectl --namespace "$EJBCA_NAMESPACE" get secret ejbca-ingress-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > $(pwd)/server.pem
    kubectl --namespace "$EJBCA_NAMESPACE" get secret ejbca-ingress-tls -o jsonpath='{.data.tls\.key}' | base64 -d > $(pwd)/server.key
    kubectl --namespace "$EJBCA_NAMESPACE" get secret subca -o jsonpath='{.data.ca\.crt}' | base64 -d > $(pwd)/Sub-CA-chain.pem
    kubectl --namespace "$EJBCA_NAMESPACE" get secret managementca -o jsonpath='{.data.ca\.crt}' | base64 -d > $(pwd)/managementca.pem

    EJBCA_CLIENT_CERT_PATH="$(pwd)/superadmin.pem"
    EJBCA_CLIENT_KEY_PATH="$(pwd)/superadmin.key"
    EJBCA_CA_CERT_PATH="$(pwd)/Sub-CA-chain.pem"

    if [[ ! -f "$EJBCA_CLIENT_CERT_PATH" ]]; then
        echo "Client certificate file not found: $EJBCA_CLIENT_CERT_PATH"
        return 1
    fi
    if [[ ! -f "$EJBCA_CLIENT_KEY_PATH" ]]; then
        echo "Client key file not found: $EJBCA_CLIENT_KEY_PATH"
        return 1
    fi
    if [[ ! -f "$EJBCA_CA_CERT_PATH" ]]; then
        echo "CA certificate file not found: $EJBCA_CA_CERT_PATH"
        return 1
    fi

    if ! testEjbcaConnection "$EJBCA_HOSTNAME" "$EJBCA_CLIENT_CERT_PATH" "$EJBCA_CLIENT_KEY_PATH" "$EJBCA_CA_CERT_PATH"; then
        echo "Failed to connect to EJBCA"
        return 1
    fi
}

uninstallEJBCA() {
    if ! isEjbcaAlreadyDeployed; then
        echo "EJBCA is not deployed"
        return 1
    fi

    helm --namespace "$EJBCA_NAMESPACE" uninstall ejbca-node1

}

###############################################
# SignServer Creation and Initialization      #
###############################################

isSignServerAlreadyDeployed() {
    if [ "$(kubectl --namespace "$SIGNSERVER_NAMESPACE" get pods -l app.kubernetes.io/name=signserver -o json | jq '.items[] | select(.metadata.labels."app.kubernetes.io/name" == "signserver") | .metadata.name' | tr -d '"')" != "" ]; then
        return 0
    else
        return 1
    fi
}

# Initialize the cluster for SignServer
initClusterForSignServer() {
    # Create the EJBCA namespace if it doesn't already exist
    if [ "$(kubectl get namespace -o json | jq -e '.items[] | select(.metadata.name == "'"$SIGNSERVER_NAMESPACE"'") | .metadata.name')" == "" ]; then
        kubectl create namespace "$SIGNSERVER_NAMESPACE"
    fi
}

deploySignServer() {
    # Enroll for a TLS certificate to use for the SignServer ingress
    enrollPkcs10Certificate "$EJBCA_HOSTNAME" "$EJBCA_CLIENT_CERT_PATH" "$EJBCA_CLIENT_KEY_PATH" "$EJBCA_CA_CERT_PATH" "Sub-CA" "$SIGNSERVER_INGRESS_HOSTNAME"
    kubectl create secret tls --namespace "$SIGNSERVER_NAMESPACE" signserver-ingress-tls --cert=server.pem --key=server.key

    # Create a secret contianing the CA cert to validate client certificates
    kubectl create secret generic --namespace "$SIGNSERVER_NAMESPACE" managementca --from-file=ca.crt=./managementca.pem
    kubectl create configmap --namespace "$SIGNSERVER_NAMESPACE" signserver-trusted-ca --from-file=ManagementCA.crt=./managementca.pem

    helm_install_args=(
        "--namespace" 
        "$SIGNSERVER_NAMESPACE" 
        "install" 
        "signserver-node1" 
        "./signserver" 
    )
    helm_install_args+=("--set" "signserver.ingress.enabled=true")
    helm_install_args+=("--set" "signserver.ingress.enabled=true")
    helm_install_args+=("--set" "signserver.ingress.hosts[0].host=$SIGNSERVER_INGRESS_HOSTNAME")
    helm_install_args+=("--set" "signserver.ingress.hosts[0].tlsSecretName=signserver-ingress-tls")
    helm_install_args+=("--set" "signserver.ingress.hosts[0].paths[0].path=/signserver/")
    helm_install_args+=("--set" "signserver.ingress.hosts[0].paths[0].pathType=Prefix")
    helm_install_args+=("--set" "signserver.ingress.hosts[0].paths[0].serviceName=signserver-service")
    helm_install_args+=("--set" "signserver.ingress.hosts[0].paths[0].portName=https")

    helm_install_args+=("--set" "signserver.image.repository=$EJBCA_IMAGE")
    helm_install_args+=("--set" "signserver.image.tag=$EJBCA_TAG")
    if [ ! -z "$IMAGE_PULL_SECRET_NAME" ]; then
        helm_install_args+=("--set" "signserver.image.pullSecrets[0].name=$IMAGE_PULL_SECRET_NAME")
    fi

    helm "${helm_install_args[@]}"

    sleep 20
    
    # Wait for the SignServer Pod to be ready
    echo "Waiting for SignServer Pod to be ready"
    kubectl --namespace "$SIGNSERVER_NAMESPACE" wait --for=condition=ready pod -l app.kubernetes.io/instance=signserver-node1 --timeout=300s
}

initSignServer() {
    echo ""
}

uninstallSignServer() {
    if ! isSignServerAlreadyDeployed; then
        echo "SignServer is not deployed"
        return 1
    fi

    helm --namespace "$SIGNSERVER_NAMESPACE" uninstall signserver-node1
}

###############################################
# Helper Functions                            #
###############################################

mariadbPvcExists() {
    local namespace=$1

    if [ "$(kubectl --namespace "$namespace" get pvc -l app.kubernetes.io/name=mariadb -o json | jq '.items[] | select(.metadata.labels."app.kubernetes.io/name" == "mariadb") | .metadata.name' | tr -d '"')" != "" ]; then
        return 0
    else
        return 1
    fi
}

createEnvFile() {
    # Create an environment file that can be used to connect to the EJBCA instance

    touch ./ejbca.env
    echo "EJBCA_HOSTNAME=$EJBCA_INGRESS_HOSTNAME" > ./ejbca.env
    echo "EJBCA_IN_CLUSTER_HOSTNAME=$EJBCA_IN_CLUSTER_HOSTNAME" >> ./ejbca.env
    
    echo "EJBCA_CLIENT_CERT_PATH=$(pwd)/superadmin.pem" >> ./ejbca.env
    echo "EJBCA_CLIENT_CERT_KEY_PATH=$(pwd)/superadmin.key" >> ./ejbca.env
    echo "EJBCA_CA_CERT_PATH=$(pwd)/Sub-CA-chain.pem" >> ./ejbca.env

    echo "EJBCA_CA_NAME=Sub-CA" >> ./ejbca.env
    echo "EJBCA_CERTIFICATE_PROFILE_NAME=tlsServerAuth" >> ./ejbca.env
    echo "EJBCA_END_ENTITY_PROFILE_NAME=tlsServerAnyCA" >> ./ejbca.env
    echo "EJBCA_CERTIFICATE_SUBJECT=CN=example.com" >> ./ejbca.env
    echo "EJBCA_CA_DN='CN=$EJBCA_SUB_CA_NAME,O=EJBCA'" >> ./ejbca.env
}

addSignServerValuesToEnvFile() {
    if [ ! -f ./ejbca.env ]; then
        echo "Environment file not found: $(pwd)/ejbca.env"
        return 1
    fi

    echo "SIGNSERVER_HOSTNAME=$SIGNSERVER_INGRESS_HOSTNAME" >> ./ejbca.env

    echo "SIGNSERVER_CLIENT_CERT_PATH=$(pwd)/superadmin.pem" >> ./ejbca.env
    echo "SIGNSERVER_CLIENT_CERT_KEY_PATH=$(pwd)/superadmin.key" >> ./ejbca.env
    echo "SIGNSERVER_CA_CERT_PATH=$(pwd)/Sub-CA-chain.pem" >> ./ejbca.env
}

printInstructions() {
    # Tell the user how to use the environment file and how to connect to EJBCA
    echo ""
    echo "Environment file created: $(pwd)/ejbca.env"
    echo "To use the environment file, run the following command:"
    echo "  source $(pwd)/ejbca.env"
    if isEjbcaAlreadyDeployed ; then
        echo ""
        echo "EJBCA CONNECTION INFORMATION"
        echo "To connect to EJBCA in a browser, perform the following steps:"
        echo "1. Add the following line to your hosts file:"
        echo ""
        echo "127.0.0.1 $EJBCA_INGRESS_HOSTNAME"
        echo ""
        echo "   - On Windows, the hosts file is located at C:\Windows\System32\drivers\etc\hosts"
        echo "   - On Linux/Mac, the hosts file is located at /etc/hosts"
        echo ""
        echo "2. Import the client certificate into your keychain"
        echo "   a. Export the certificate to PFX format"
        echo "      - On Mac/Linux, use the following command:"
        echo "        openssl pkcs12 -export -in superadmin.pem -inkey superadmin.key --CAfile managementca.pem -out superadmin.pfx -chain -legacy"
        echo "   b. Import the PFX file into your keychain - usually by double clicking the file. Make sure that the CA is marked as trusted if on a Mac."
        echo ""
        echo "3. Open a browser and navigate to https://$EJBCA_INGRESS_HOSTNAME/ejbca/adminweb/"
    fi

    if isSignServerAlreadyDeployed ; then
        echo ""
        echo "SIGNSERVER CONNECTION INFORMATION"
        echo "To connect to SignServer in a browser, perform the following steps:"
        echo "1. Add the following line to your hosts file:"
        echo ""
        echo "127.0.0.1 $SIGNSERVER_INGRESS_HOSTNAME"
        echo ""
        echo "2. Open a browser and navigate to https://$SIGNSERVER_INGRESS_HOSTNAME/signserver/adminweb"
    fi
}

usage() {
    echo "Usage: $0 [options...]"
    echo "Options:"
    echo "  --ejbca-hostname <hostname>        Set the hostname for the EJBCA node. Defaults to localhost"
    echo "  --ejbca-image <image>              Set the image to use for the EJBCA node. Defaults to keyfactor/ejbca-ce"
    echo "  --ejbca-tag <tag>                  Set the tag to use for the EJBCA node. Defaults to latest"
    echo "  --image-pull-secret <secret>       Use a particular image pull secret in the ejbca namespace for the EJBCA node. Defaults to none"
    echo "  --ejbca-namespace <namespace>      Set the namespace to deploy the EJBCA node in. Defaults to ejbca"
    echo "  --no-signserver                    Skip deploying SignServer"
    echo "  --signserver-hostname <hostname>   Set the hostname for the signserver node. Defaults to localhost"
    echo "  --signserver-namespace <namespace> Set the namespace to deploy the signserver node in. Defaults to signserver"
    echo "  --uninstall                        Uninstall EJBCA and SignServer"
    echo "  -h, --help                         Show this help message"
    exit 1
}

# Verify that required tools are installed
verifySupported

# Ensure a fresh install
cleanFilesystem

# Locals
install_signserver=true

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --ejbca-hostname)
            EJBCA_INGRESS_HOSTNAME="$2"
            shift # past argument
            shift # past value
            ;;
        --ejbca-namespace)
            EJBCA_NAMESPACE="$2"
            shift # past argument
            shift # past value
            ;;
        --ejbca-image)
            EJBCA_IMAGE="$2"
            shift # past argument
            shift # past value
            ;;
        --ejbca-tag)
            EJBCA_TAG="$2"
            shift # past argument
            shift # past value
            ;;
        --image-pull-secret)
            IMAGE_PULL_SECRET_NAME="$2"
            shift # past argument
            shift # past value
            ;;
        --no-signserver)
            install_signserver=false
            shift # past argument
            ;;
        --signserver-hostname)
            signserver_hostname="$2"
            shift # past argument
            shift # past value
            ;;
        --signserver-namespace)
            SIGNSERVER_NAMESPACE="$2"
            shift # past argument
            shift # past value
            ;;
        --uninstall)
            uninstallEJBCA
            uninstallSignServer
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)    # unknown option
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Figure out if the cluster is already initialized for EJBCA
if ! isEjbcaAlreadyDeployed; then
    if mariadbPvcExists "$EJBCA_NAMESPACE"; then
        echo "The EJBCA database has already been configured - skipping database initialization"

        # Deploy EJBCA with ingress enabled
        deployEJBCA
    else
        # Prepare the cluster for EJBCA
        initClusterForEJBCA

        # Initialize the database by spinning up an instance of EJBCA infront of a MariaDB database, and then
        # create the CA hierarchy and import boilerplate profiles.
        initEJBCADatabase

        # Deploy EJBCA with ingress enabled
        deployEJBCA
    fi
fi


if ! setupEjbcaForScript ; then
    echo "EJBCA setup is incomplete"
    exit 1
else
    echo "EJBCA is ready to use"
fi

# Create an environment file that can be used to connect to the EJBCA instance
createEnvFile

if [ "$install_signserver" = true ]; then
    if ! isSignServerAlreadyDeployed ; then
        # Prepare the cluster for SignServer
        initClusterForSignServer

        # Deploy SignServer
        deploySignServer
    fi
    
    addSignServerValuesToEnvFile
fi

# Print instructions to the user on how to use the environment file and how to connect to EJBCA
printInstructions
