#!/bin/bash

usage() {
    echo "Usage: $0 [-h] [-d] path_to_install_yamls"
    echo "  -h  Display this help message"
    echo "  -d  Enable debug mode"
    echo "  path_to_install_yamls path to install_yamls"
}

. env.sh

while getopts "dh" opt; do
    case ${opt} in
    d)
        set -x
        ;;
    h)
        usage
        exit 0
        ;;
    \?)
        echo "Invalid Option: -$OPTARG" 1>&2
        exit 1
        ;;
    esac
done

shift $((OPTIND - 1))

if [ "$#" -ne 1 ]; then
    usage
    exit 1
fi

install_yaml_dir=$(realpath "$1")

for node in $NG_NODES; do
    oc label nodes "${node}" type=openstack || {
        echo "Failed to label node, $node"
        exit 1
    }
done

echo "Apply nncp..."
# create and apply custom NNCPs for OSP 18
# the NNCPs should obey the labels applied above
envsubst <../yamls/node1-nncp.yaml | oc apply -f - || {
    echo "Failed to set apply node1-nncp.yaml"
    exit 1
}

envsubst <../yamls/node2-nncp.yaml | oc apply -f - || {
    echo "Failed to set apply node2-nncp.yaml"
    exit 1
}

envsubst <../yamls/node3-nncp.yaml | oc apply -f - || {
    echo "Failed to set apply node3-nncp.yaml"
    exit 1
}

echo "Apply NetworkAttachmentDefinition"

envsubst <../yamls/nads.yaml | oc apply -f - || {
    echo "Failed to apply net-attach-defs..."
    exit 1
}

# Install the OSP 18 operators
#(cd "$install_yaml_dir" || exit && BMO_SETUP=false NETWORK_ISOLATION=false NAMESPACE="$OSP18_NAMESPACE" make openstack)

# install_yaml doesn't install metallb with the above parameters
# install it now
# if [ "$(oc get pod --no-headers=true -l component=speaker -n metallb-system | wc -l)" -ne 3 ]; then
#     # Install metallb
#     (cd "$install_yaml_dir" || exit && BMO_SETUP=false NETWORK_ISOLATION=false make metallb)
# fi

# Make sure OVNKubernetes IPForwarding is enabled
oc patch network.operator cluster -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"ipForwarding": "Global"}}}}}' --type=merge || {
    echo "Failed to patch network.operator"
    exit 1
}

envsubst <../yamls/ipaddresspools.yaml | oc apply -f - || {
    echo "Failed to apply ipaddresspool"
    exit 1
}
envsubst <../yamls/l2advertisement.yaml | oc apply -f - || {
    echo "Failed to apply l2advertisement"
    exit 1
}

# envsubst <../yamls/netconfig.yaml | oc apply -f - || {
#     echo "Failed to apply netconfig"
#     exit 1
# }
