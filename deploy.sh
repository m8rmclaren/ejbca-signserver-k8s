#! /bin/bash

source ./ejbca.sh
source ./k8s.sh

# Use parameter expansion to provide default values.
: "${EJBCA_NAMESPACE:=ejbca}"
: "${EJBCA_INGRESS_HOSTNAME:=localhost}"
: "${SIGNSERVER_NAMESPACE:=signserver}"
: "${SIGNSERVER_INGRESS_HOSTNAME:=localhost}"

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

# Initialize the cluster for EJBCA
initClusterForEJBCA() {
    # Create the EJBCA namespace if it doesn't already exist
    if [ "$(kubectl get namespace -o json | jq -e '.items[] | select(.metadata.name == "'"$EJBCA_NAMESPACE"'") | .metadata.name')" == "" ]; then
        kubectl create namespace "$EJBCA_NAMESPACE"
    fi

    # Create configmaps containing end entity creation definitions
    createConfigmapFromFile "$EJBCA_NAMESPACE" "ejbca-eep-admininternal" "./ejbca/staging/entityprofile_adminInternal-151490904.xml"
    createConfigmapFromFile "$EJBCA_NAMESPACE" "ejbca-eep-ephemeral" "./ejbca/staging/entityprofile_ephemeral-9725769.xml"
    createConfigmapFromFile "$EJBCA_NAMESPACE" "ejbca-eep-k8sendentity" "./ejbca/staging/entityprofile_k8s-285521485.xml"
    createConfigmapFromFile "$EJBCA_NAMESPACE" "ejbca-eep-userauthentication" "./ejbca/staging/entityprofile_userAuthentication-1804366791.xml"
    createConfigmapFromFile "$EJBCA_NAMESPACE" "ejbca-eep-tlsserveranyca" "./ejbca/staging/entityprofile_tlsServerAnyCA-327363278.xml"

    # Create configmaps containing certificate profile creation definitions
    createConfigmapFromFile "$EJBCA_NAMESPACE" "ejbca-cp-codesign1y" "./ejbca/staging/certprofile_codeSigning-1y-1271968915.xml"
    createConfigmapFromFile "$EJBCA_NAMESPACE" "ejbca-cp-istioauth3d" "./ejbca/staging/certprofile_istioAuth-3d-781718050.xml"
    createConfigmapFromFile "$EJBCA_NAMESPACE" "ejbca-cp-tlsclientauth" "./ejbca/staging/certprofile_tlsClientAuth-1615825638.xml"
    createConfigmapFromFile "$EJBCA_NAMESPACE" "ejbca-cp-tlsserverauth" "./ejbca/staging/certprofile_tlsServerAuth-1841776707.xml"
    createConfigmapFromFile "$EJBCA_NAMESPACE" "ejbca-cp-auth20483y" "./ejbca/staging/certprofile_Authentication-2048-3y-1510586178.xml"
}

# Initialze the database by spinning up an instance of EJBCA infront of a MariaDB database, and
# create the CA hierarchy and import boilerplate profiles.
initEJBCADatabase() {
    # Package and deploy the EJBCA helm chart with ingress disabled
    helm package ejbca --version 1.0.0
    helm --namespace "$EJBCA_NAMESPACE" install ejbca-node1 ejbca-1.0.0.tgz \
        --set ejbca.ingress.enabled=false

    # Wait for the EJBCA Pod to be ready
    echo "Waiting for EJBCA Pod to be ready"
    kubectl --namespace "$EJBCA_NAMESPACE" wait --for=condition=ready pod -l app.kubernetes.io/name=ejbca --timeout=300s

    # Get the name of the EJBCA Pod
    local ejbca_pod_name
    ejbca_pod_name=$(kubectl --namespace "$EJBCA_NAMESPACE" get pods -l app.kubernetes.io/name=ejbca -o json | jq '.items[] | select(.metadata.labels."app.kubernetes.io/name" == "ejbca") | .metadata.name' | tr -d '"')

    # Wait for the EJBCA Pod to be ready
    waitForEJBCANode "$EJBCA_NAMESPACE" "$ejbca_pod_name"

    # Create token properties file
    kubectl --namespace "$EJBCA_NAMESPACE" exec "$ejbca_pod_name" -- sh -c 'touch /opt/keyfactor/token.properties'
    kubectl --namespace "$EJBCA_NAMESPACE" exec "$ejbca_pod_name" -- sh -c 'echo "certSignKey signKey" >> /opt/keyfactor/token.properties'
    kubectl --namespace "$EJBCA_NAMESPACE" exec "$ejbca_pod_name" -- sh -c 'echo "crlSignKey signKey" >> /opt/keyfactor/token.properties'
    kubectl --namespace "$EJBCA_NAMESPACE" exec "$ejbca_pod_name" -- sh -c 'echo "keyEncryptKey encryptKey" >> /opt/keyfactor/token.properties'
    kubectl --namespace "$EJBCA_NAMESPACE" exec "$ejbca_pod_name" -- sh -c 'echo "testKey testKey" >> /opt/keyfactor/token.properties'
    kubectl --namespace "$EJBCA_NAMESPACE" exec "$ejbca_pod_name" -- sh -c 'echo "defaultKey encryptKey" >> /opt/keyfactor/token.properties'

    # Create ManagementCA
    createRootCA "$EJBCA_NAMESPACE" "$ejbca_pod_name" "ManagementCA" "/opt/keyfactor/token.properties"

    # Create Root-CA
    createRootCA "$EJBCA_NAMESPACE" "$ejbca_pod_name" "Root-CA" "/opt/keyfactor/token.properties"

    # Create Sub-CA
    createSubCA "$EJBCA_NAMESPACE" "$ejbca_pod_name" "Sub-CA" "Root-CA"

    # Import end entity profiles from staging area
    importStagedEndEntityProfiles "$EJBCA_NAMESPACE" "$ejbca_pod_name"

    # Enable REST API
    kubectl --namespace "$EJBCA_NAMESPACE" exec "$ejbca_pod_name" -- /opt/keyfactor/bin/ejbca.sh config protocols enable --name "REST Certificate Management"

    # Create the SuperAdmin user and get its certificate
    createSuperAdmin "$EJBCA_NAMESPACE" "$ejbca_pod_name" "management_ca.pem" "superadmin.pem" "superadmin.key"

    # Create a TLS certificate for ingress
    createServerCertificate "$EJBCA_NAMESPACE" "$ejbca_pod_name" "$EJBCA_INGRESS_HOSTNAME" "Sub-CA"

    # Put the CA cert in a file for later use
    echo -e "$SERVER_CA" > ./Sub-CA-chain.pem

    # Create a TLS certificate for ingress
    kubectl create secret tls --namespace "$EJBCA_NAMESPACE" ejbca-ingress-tls --cert=<(echo -e "$SERVER_CERTIFICATE") --key=<(echo -e "$SERVER_KEY")

    # Create a secret contianing the CA cert to validate client certificates
    kubectl create secret generic --namespace "$EJBCA_NAMESPACE" ejbca-ingress-auth --from-file=ca.crt=./management_ca.pem

    # Uninstall the EJBCA helm chart - database is peristent
    helm --namespace "$EJBCA_NAMESPACE" uninstall ejbca-node1
}

# Deploy EJBCA with ingress enabled
deployEJBCA() {
    # Package and deploy the EJBCA helm chart with ingress enabled
    helm package ejbca --version 1.0.0
    helm --namespace "$EJBCA_NAMESPACE" install ejbca-node1 ejbca-1.0.0.tgz \
        --set "ejbca.ingress.enabled=true" \
        --set "ejbca.ingress.hosts[0].host=$EJBCA_INGRESS_HOSTNAME" \
        --set "ejbca.ingress.hosts[0].tlsSecretName=ejbca-ingress-tls" \
        --set "ejbca.ingress.hosts[0].paths[0].path=/ejbca/" \
        --set "ejbca.ingress.hosts[0].paths[0].pathType=Prefix" \
        --set "ejbca.ingress.hosts[0].paths[0].serviceName=ejbca-service" \
        --set "ejbca.ingress.hosts[0].paths[0].portName=ejbca-https"
    
    # Wait for the EJBCA Pod to be ready
    echo "Waiting for EJBCA Pod to be ready"
    kubectl --namespace "$EJBCA_NAMESPACE" wait --for=condition=ready pod -l app.kubernetes.io/name=ejbca --timeout=300s

    # Get the name of the EJBCA Pod
    local ejbca_pod_name
    ejbca_pod_name=$(kubectl --namespace "$EJBCA_NAMESPACE" get pods -l app.kubernetes.io/name=ejbca -o json | jq '.items[] | select(.metadata.labels."app.kubernetes.io/name" == "ejbca") | .metadata.name' | tr -d '"')

    # Wait for the EJBCA node to be ready
    waitForEJBCANode "$EJBCA_NAMESPACE" "$ejbca_pod_name"
}

# Export variables for use in the script, and test the API connection
setupEjbcaForScript() {
    EJBCA_HOSTNAME="$EJBCA_INGRESS_HOSTNAME"
    EJBCA_CA_NAME="Sub-CA"
    EJBCA_CERTIFICATE_PROFILE_NAME="tlsServerAuth"
    EJBCA_END_ENTITY_PROFILE_NAME="tlsServerAnyCA"
    EJBCA_CSR_SUBJECT="CN=$EJBCA_INGRESS_HOSTNAME,OU=IT"

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
    if [ "$(kubectl get namespace -o json | jq -e '.items[] | select(.metadata.name == "'"$EJBCA_NAMESPACE"'") | .metadata.name' | tr -d '"')" == "$EJBCA_NAMESPACE" ]; then
        # Uninstall the EJBCA helm chart
        helm --namespace "$EJBCA_NAMESPACE" uninstall ejbca-node1

        # Delete the EJBCA namespace
        kubectl delete namespace "$EJBCA_NAMESPACE"
    fi
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
    kubectl create secret tls --namespace "$SIGNSERVER_NAMESPACE" signserver-ingress-tls --cert=<(echo -e "$PKCS10_CERTIFICATE") --key=<(echo -e "$PKCS10_KEY")

    # Create a secret contianing the CA cert to validate client certificates
    kubectl create secret generic --namespace "$SIGNSERVER_NAMESPACE" signserver-ingress-auth --from-file=ca.crt=./management_ca.pem
    kubectl create configmap --namespace "$SIGNSERVER_NAMESPACE" signserver-trusted-ca --from-file=ManagementCA.crt=./management_ca.pem

    # Package and deploy the SignServer helm chart with ingress enabled
    helm package signserver --version 1.0.0
    helm --namespace "$SIGNSERVER_NAMESPACE" install signserver-node1 signserver-1.0.0.tgz \
        --set "signserver.ingress.enabled=true" \
        --set "signserver.ingress.hosts[0].host=$SIGNSERVER_INGRESS_HOSTNAME" \
        --set "signserver.ingress.hosts[0].tlsSecretName=signserver-ingress-tls" \
        --set "signserver.ingress.hosts[0].paths[0].path=/signserver/" \
        --set "signserver.ingress.hosts[0].paths[0].pathType=Prefix" \
        --set "signserver.ingress.hosts[0].paths[0].serviceName=signserver-service" \
        --set "signserver.ingress.hosts[0].paths[0].portName=https"
    
    # Wait for the SignServer Pod to be ready
    echo "Waiting for SignServer Pod to be ready"
    kubectl --namespace "$SIGNSERVER_NAMESPACE" wait --for=condition=ready pod -l app.kubernetes.io/name=signserver --timeout=300s
}

initSignServer() {
    echo ""
}

uninstallSignServer() {
    if [ "$(kubectl get namespace -o json | jq -e '.items[] | select(.metadata.name == "'"$SIGNSERVER_NAMESPACE"'") | .metadata.name' | tr -d '"')" == "$SIGNSERVER_NAMESPACE" ]; then
        # Uninstall the SignServer helm chart
        helm --namespace "$SIGNSERVER_NAMESPACE" uninstall signserver-node1

        # Delete the SignServer namespace
        kubectl delete namespace "$SIGNSERVER_NAMESPACE"
    fi
}

###############################################
# Helper Functions                            #
###############################################

createEnvFile() {
    # Create an environment file that can be used to connect to the EJBCA instance

    touch ./ejbca.env
    echo "EJBCA_HOSTNAME=$EJBCA_INGRESS_HOSTNAME" >> ./ejbca.env
    
    echo "EJBCA_CA_NAME=Sub-CA" >> ./ejbca.env
    echo "EJBCA_CERTIFICATE_PROFILE_NAME=tlsServerAuth" >> ./ejbca.env
    echo "EJBCA_END_ENTITY_PROFILE_NAME=tlsServerAnyCA" >> ./ejbca.env
    echo "EJBCA_CSR_SUBJECT=CN=$EJBCA_INGRESS_HOSTNAME,OU=IT" >> ./ejbca.env

    echo "EJBCA_CLIENT_CERT_PATH=$(pwd)/superadmin.pem" >> ./ejbca.env
    echo "EJBCA_CLIENT_KEY_PATH=$(pwd)/superadmin.key" >> ./ejbca.env
    echo "EJBCA_CA_CERT_PATH=$(pwd)/Sub-CA-chain.pem" >> ./ejbca.env
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
        echo "        openssl pkcs12 -export -in superadmin.pem -inkey superadmin.key --CAfile management_ca.pem -out superadmin.pfx -chain -legacy"
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
    echo "  --signserver-hostname <hostname>   Set the hostname for the signserver node. Defaults to localhost"
    echo "  --ejbca-namespace <namespace>      Set the namespace to deploy the EJBCA node in. Defaults to ejbca"
    echo "  --signserver-namespace <namespace> Set the namespace to deploy the signserver node in. Defaults to signserver"
    echo "  --uninstall                        Uninstall EJBCA and SignServer"
    echo "  -h, --help                         Show this help message"
    exit 1
}

# Verify that required tools are installed
verifySupported

# Ensure a fresh install
cleanFilesystem

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
if ! isEjbcaAlreadyDeployed ; then
    # Prepare the cluster for EJBCA
    initClusterForEJBCA

    # Initialize the database by spinning up an instance of EJBCA infront of a MariaDB database, and then
    # create the CA hierarchy and import boilerplate profiles.
    initEJBCADatabase

    # Deploy EJBCA with ingress enabled
    deployEJBCA
fi

if ! setupEjbcaForScript ; then
    echo "EJBCA setup is incomplete"
    exit 1
else
    echo "EJBCA is ready to use"
fi

# Create an environment file that can be used to connect to the EJBCA instance
createEnvFile

if ! isSignServerAlreadyDeployed ; then
    # Prepare the cluster for SignServer
    initClusterForSignServer

    # Deploy SignServer
    deploySignServer
fi

addSignServerValuesToEnvFile

# Print instructions to the user on how to use the environment file and how to connect to EJBCA
printInstructions