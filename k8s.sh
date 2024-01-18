createConfigmapFromFile() { 
    local cluster_namespace=$1
    local configmap_name=$2
    local filepath=$3

    if [ $(kubectl get configmap -n "$cluster_namespace" -o json | jq -c ".items | any(.[] | .metadata; .name == \"$configmap_name\")") == "false" ]; then
        echo "Creating "$configmap_name" configmap"
        kubectl create configmap -n "$cluster_namespace" "$configmap_name" --from-file="$filepath"
    else
        echo "$configmap_name exists"
    fi
}