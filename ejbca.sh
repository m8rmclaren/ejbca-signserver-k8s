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

# Uses the EJBCA CLI inside a given EJBCA node to
# create a crypto token according to provided arguments
# cluster_namespace - The namespace where the EJBCA node is running
# ejbca_pod_name - The name of the Pod running the EJBCA node
# name - The name of the crypto token
# type - The type of the crypto token (e.g. SoftCryptoToken)
# pin - The pin for the crypto token
# autoactivate - Whether or not to autoactivate the crypto token
createCryptoToken() {
    local cluster_namespace=$1
    local ejbca_pod_name=$2
    local name=$3
    local type=$4
    local pin=$5
    local autoactivate=$6

    echo "Creating crypto token $name"

    kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- /opt/keyfactor/bin/ejbca.sh cryptotoken create \
        --token "$name" \
        --type "$type" \
        --pin "$pin" \
        --autoactivate "$autoactivate"
}

# Uses the EJBCA CLI inside a given EJBCA node to
# generate a key-pair for a given crypto token
# cluster_namespace - The namespace where the EJBCA node is running
# ejbca_pod_name - The name of the Pod running the EJBCA node
# token - The name of the crypto token
# alias - The alias for the key-pair
# keyspec - The key size
generateCryptoTokenKeyPair() {
    local cluster_namespace=$1
    local ejbca_pod_name=$2
    local token=$3
    local alias=$4
    local keyspec=$5

    echo "Generating key-pair $alias for crypto token $token"

    kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- /opt/keyfactor/bin/ejbca.sh cryptotoken generatekey \
        --token "$token" \
        --alias "$alias" \
        --keyspec "$keyspec"
}

# Create a root CA
# cluster_namespace - The namespace where the EJBCA node is running
# ejbca_pod_name - The name of the Pod running the EJBCA node
# name - The name of the CA to create. Will be used as CN too.
# token_prop_file - The path to the file containing the token properties
createRootCA() {
    local cluster_namespace=$1
    local ejbca_pod_name=$2
    local ca_name=$3
    local token_prop_file=$4

    echo "Initializing root CA called $ca_name"

    # Create a crypto token called $ca_name
    createCryptoToken "$cluster_namespace" "$ejbca_pod_name" "$ca_name" "SoftCryptoToken" 1234 true

    generateCryptoTokenKeyPair "$cluster_namespace" "$ejbca_pod_name" "$ca_name" "signKey" 2048
    generateCryptoTokenKeyPair "$cluster_namespace" "$ejbca_pod_name" "$ca_name" "encryptKey" 2048
    generateCryptoTokenKeyPair "$cluster_namespace" "$ejbca_pod_name" "$ca_name" "testKey" 2048

    # Create the CA
    kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- /opt/keyfactor/bin/ejbca.sh ca init \
        --caname "$ca_name" \
        --dn "CN=$ca_name,O=EJBCA" \
        --keyspec 2048 \
        --keytype RSA \
        --policy null \
        -s SHA256WithRSA \
        --tokenName $ca_name \
        --tokenPass 1234 \
        --tokenprop $token_prop_file \
        -v 3650
}

# Creates a sub CA signed by a given CA
# cluster_namespace - The namespace where the EJBCA node is running
# ejbca_pod_name - The name of the Pod running the EJBCA node
# ca_name - The name of the CA to create. Will be used as CN too.
# signed_by - The name of the CA that will sign this CA
createSubCA() {
    local cluster_namespace=$1
    local ejbca_pod_name=$2
    local ca_name=$3
    local signed_by=$4

    echo "Creating intermediate CA called $ca_name"

    createCryptoToken "$cluster_namespace" "$ejbca_pod_name" "$ca_name" "SoftCryptoToken" 1234 true
    generateCryptoTokenKeyPair "$cluster_namespace" "$ejbca_pod_name" "$ca_name" "signKey" 2048
    generateCryptoTokenKeyPair "$cluster_namespace" "$ejbca_pod_name" "$ca_name" "encryptKey" 2048
    generateCryptoTokenKeyPair "$cluster_namespace" "$ejbca_pod_name" "$ca_name" "testKey" 2048

    local signed_by_id=$(kubectl -n "$cluster_namespace" exec "$ejbca_pod_name" -- /opt/keyfactor/bin/ejbca.sh ca info --caname "$signed_by" | grep " (main) CA ID: " | awk '{print $8}')

    kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- /opt/keyfactor/bin/ejbca.sh ca init \
        --caname "$ca_name" \
        --signedby "$signed_by_id" \
        --dn "CN=$ca_name,O=EJBCA" \
        --keyspec 2048 \
        --keytype RSA \
        --policy null \
        -s SHA256WithRSA \
        --tokenName "$ca_name" \
        --tokenPass 1234 \
        --tokenprop /opt/keyfactor/token.properties \
        -v 3650
}

# Imports the staged certificate profiles into EJBCA
# cluster_namespace - The namespace where the EJBCA node is running
# ejbca_pod_name - The name of the Pod running the EJBCA node
importStagedEndEntityProfile() {
    local cluster_namespace=$1
    local ejbca_pod_name=$2
    local full_path=$3

    kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- /opt/keyfactor/bin/ejbca.sh ca importprofiles \
        -d "$full_path"
}

# Imports the staged certificate profiles into EJBCA
# cluster_namespace - The namespace where the EJBCA node is running
# ejbca_pod_name - The name of the Pod running the EJBCA node
importStagedEEP() {
    local cluster_namespace=$1
    local ejbca_pod_name=$2
    local base_directory=$3
    local config_file=$4

    echo "Importing $config_file from $base_directory"
    kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- /opt/keyfactor/bin/ejbca.sh ra importeep \
        -d "$base_directory/$config_file"
}

# Creates the SuperAdmin end entity, enrolls its certificate,
# and adds it to the Super Administrator Role
# cluster_namespace - The namespace where the EJBCA node is running
# ejbca_pod_name - The name of the Pod running the EJBCA node
# ca_filename - The name of the file where the CA certificate will be saved
# end_entity_filename - The name of the file where the end entity certificate will be saved
# end_entity_key_filename - The name of the file where the end entity key will be saved
createSuperAdmin() {
    local cluster_namespace=$1
    local ejbca_pod_name=$2
    local common_name=$3
    local ca_filename=$4
    local end_entity_filename=$5
    local end_entity_key_filename=$6

    echo "Creating SuperAdmin"
    
    # Create SuperAdmin
    kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- /opt/keyfactor/bin/ejbca.sh ra addendentity \
        --username "SuperAdmin" \
        --dn "CN=$common_name" \
        --caname "ManagementCA" \
        --certprofile "Authentication-2048-3y" \
        --eeprofile "adminInternal" \
        --type 1 \
        --token "PEM" \
        --password "foo123"

    # Prepare batch processing
    kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- /opt/keyfactor/bin/ejbca.sh ra setclearpwd \
        SuperAdmin foo123

    # Batch process
    kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- /opt/keyfactor/bin/ejbca.sh batch

    # Save the CA to the CA file
    kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- cat "/opt/keyfactor/p12/pem/$common_name-CA.pem" > "$ca_filename"

    # Save the end entity to the end entity file
    kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- cat "/opt/keyfactor/p12/pem/$common_name.pem" > "$end_entity_filename"

    # Save the end entity key to the end entity key file
    kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- cat "/opt/keyfactor/p12/pem/$common_name-Key.pem" > "$end_entity_key_filename"

    # Add a role to allow the SuperAdmin to access the node
    kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- /opt/keyfactor/bin/ejbca.sh roles addrolemember \
        --role 'Super Administrator Role' \
        --caname 'ManagementCA' \
        --with 'WITH_COMMONNAME' \
        --value "$common_name"
}

# Enrolls a certificate for server TLS use
# cluster_namespace - The namespace where the EJBCA node is running
# ejbca_pod_name - The name of the Pod running the EJBCA node
# name - The name of the certificate
# ca_name - The name of the CA that will sign the certificate
# Output:
#   SERVER_CERTIFICATE - The leaf end entity certificate
#   SERVER_KEY - The server certificate's private key
#   SERVER_CA - The CA certificate that signed the server certificate
createServerCertificate() {
    local cluster_namespace=$1
    local ejbca_pod_name=$2
    local name=$3
    local ca_name=$4

    echo "Creating server certificate for $name"
    
    kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- /opt/keyfactor/bin/ejbca.sh ra addendentity \
        --username "$name" \
        --altname dNSName="$name" \
        --dn "CN=$name" \
        --caname "$ca_name" \
        --certprofile "tlsServerAuth" \
        --eeprofile "tlsServerAnyCA" \
        --type 1 \
        --token "PEM" \
        --password "foo123"

    # Prepare batch processing
    kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- /opt/keyfactor/bin/ejbca.sh ra setclearpwd \
        "$name" foo123

    # Batch process
    kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- /opt/keyfactor/bin/ejbca.sh batch

    # Save the certificate to an environment variable
    SERVER_CERTIFICATE=$(kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- cat /opt/keyfactor/p12/pem/"$name".pem)
    SERVER_KEY=$(kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- cat /opt/keyfactor/p12/pem/"$name"-Key.pem)
    SERVER_CA=$(kubectl -n "$cluster_namespace" exec -it "$ejbca_pod_name" -- cat /opt/keyfactor/p12/pem/"$name"-CA.pem)
}

# Tests the API connection to EJBCA using the provided credentials
# hostname - The hostname of the EJBCA node
# client_certificate_path - The path to the client certificate
# client_key_path - The path to the client key
# ca_certificate_path - The path to the CA certificate
testEjbcaConnection() {
    local hostname=$1
    local client_certificate_path=$2
    local client_key_path=$3
    local ca_certificate_path=$4

    echo "curl --silent --fail --cert $client_certificate_path --key $client_key_path --cacert $ca_certificate_path https://$hostname/ejbca/ejbca-rest-api/v1/certificate/status" > testconn.sh

    curl \
        --silent --fail \
        --cert "$client_certificate_path" \
        --key "$client_key_path" \
        --cacert "$ca_certificate_path" \
        "https://$hostname/ejbca/ejbca-rest-api/v1/certificate/status" \
        > /dev/null
    
    local status=$?  # Capture the exit status of curl

    if [ $status -ne "0" ]; then
        echo "Could not connect to EJBCA - curl exit status: $status"
    fi

    return $status
}

enrollPkcs10Certificate() {
    local hostname=$1
    local client_certificate_path=$2
    local client_key_path=$3
    local ca_certificate_path=$4
    local ca_name=$5
    local common_name=$6

    echo "Enrolling PKCS10 certificate for $common_name"

    echo "Generating 2048-bit RSA key"

    # Create a PKCS10 certificate request
    openssl req \
        -newkey rsa:2048 \
        -nodes \
        -keyout "$common_name".key \
        -out "$common_name".csr \
        -subj "/CN=$common_name" \
        > /dev/null 2>&1

    local req=$(cat "$common_name".csr)

    template='{"certificate_request":$csr, "certificate_profile_name":$cp, "end_entity_profile_name":$eep, "certificate_authority_name":$ca, "username":$ee, "password":$pwd}'
    json_payload=$(jq -n \
        --arg csr "$req" \
        --arg cp "tlsServerAuth" \
        --arg eep "tlsServerAnyCA" \
        --arg ca "$ca_name" \
        --arg ee "$common_name" \
        --arg pwd "foo123" \
        "$template")

    curl \
        --silent --fail \
        --cert "$client_certificate_path" \
        --key "$client_key_path" \
        --cacert "$ca_certificate_path" \
        --header "Content-Type: application/json" \
        --request POST \
        --data "$json_payload" \
        "https://$hostname/ejbca/ejbca-rest-api/v1/certificate/pkcs10enroll" \
        > response.json
    
    local status=$?  # Capture the exit status of curl

    if [ $status -ne "0" ]; then
        echo "Could not enroll certificate - curl exit status: $status"
        rm -f "$common_name.csr" "$common_name.key" response.json        return $status
    fi

    # Extract the certificate from the response
    cat response.json | jq -r '.certificate' | base64 -d > "$common_name".crt

    # The response is in DER format, but most services will require PEM format
    openssl x509 -in "$common_name".crt -out "$common_name".crt

    PKCS10_CERTIFICATE=$(cat "$common_name".crt)
    PKCS10_KEY=$(cat "$common_name".key)

    rm -f "$common_name.csr" "$common_name.key" response.json "$common_name.crt"

    return $status

}
