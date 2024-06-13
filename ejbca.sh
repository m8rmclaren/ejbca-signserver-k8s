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
