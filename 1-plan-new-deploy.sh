#!/bin/bash

#KUBECONFIG=/root/ostest-working/kubeconfig

usage() {
    echo "Usage: $0 [-h] [-d] path_to_install_yamls"
    echo "  -h  Display this help message"
    echo "  -d  Enable debug mode"
    echo "  path_to_install_yamls path to install_yamls"
}

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

# shellcheck source=common.sh
. common.sh
# sets project
. common-ospdo.sh

# Remove OSPdO NNCPs from the other two nodes which are not running the controller VM
for i in br-ctlplane br-ex br-osp; do
    oc patch -n "$OSPDO_NAMESPACE" osnetconfig openstacknetconfig --type json -p '[{"op": "replace", "path": "/spec/attachConfigurations/'$i'/nodeNetworkConfigurationPolicy/nodeSelector", "value": {"kubernetes.io/hostname": "'"$CONTROLLER_NODE"'"} } ]'
done

# Get the names of the other two nodes that we will use for NG
NG_NODES=$(oc get nodes -o name -l kubernetes.io/hostname!="$CONTROLLER_NODE" | sed 's#node/##g' | tr '\n' ' ')
OSP18_NODE1=$(echo "${NG_NODES}" | cut -d ' ' -f 1)
export OSP18_NODE1
OSP18_NODE2=$(echo "${NG_NODES}" | cut -d ' ' -f 2)
export OSP18_NODE2

echo "Label nodes..."
oc label nodes "${OSP18_NODE1}" type=openstack || {
    echo "Failed to label node1"
    exit 1
}
oc label nodes "${OSP18_NODE2}" type=openstack || {
    echo "Failed to label node2"
    exit 1
}

oc get namespace ${OSP18_NAMESPACE} 2>/dev/null || {
    oc create namespace ${OSP18_NAMESPACE} || {
        echo "Failed to create namespace ${OSP18_NAMESPACE}"
        exit 1
    }
}

echo "Apply nncp..."
# create and apply custom NNCPs for OSP 18
# the NNCPs should obey the labels applied above
envsubst <yamls/node1-nncp.yaml | oc apply -f - || {
    echo "Failed to set apply node1-nncp.yaml"
    exit 1
}
envsubst <yamls/node2-nncp.yaml | oc apply -f - || {
    echo "Failed to set apply node2-nncp.yaml"
    exit 1
}

echo "Apply NetworkAttachmentDefinition"

envsubst <yamls/nads.yaml | oc apply -f - || {
    echo "Failed to apply net-attach-defs..."
    exit 1
}

# Install the OSP 18 operators
(cd "$install_yaml_dir" || exit && BMO_SETUP=false NETWORK_ISOLATION=false NAMESPACE="$OSP18_NAMESPACE" make openstack)

# install_yaml doesn't install metallb with the above parameters
# install it now
if [ "$(oc get pod -n $OSPDO_NAMESPACE --no-headers=true -l component=speaker -n metallb-system | wc -l)" -ne 3 ]; then
    # Install metallb
    (cd "$install_yaml_dir" || exit && BMO_SETUP=false NETWORK_ISOLATION=false make metallb)
fi

# Make sure OVNKubernetes IPForwarding is enabled
oc patch network.operator cluster -n $OSPDO_NAMESPACE -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"ipForwarding": "Global"}}}}}' --type=merge || {
    echo "Failed to patch network.operator"
    exit 1
}

envsubst <yamls/ipaddresspools.yaml | oc apply -f - || {
    echo "Failed to apply ipaddresspool"
    exit 1
}
envsubst <yamls/l2advertisement.yaml | oc apply -f - || {
    echo "Failed to apply l2advertisement"
    exit 1
}

envsubst <yamls/netconfig.yaml | oc apply -f - || {
    echo "Failed to apply netconfig"
    exit 1
}

# Extract passwords from OSPdO
oc get secret tripleo-passwords -n $OSPDO_NAMESPACE -o json | jq -r '.data["tripleo-overcloud-passwords.yaml"]' | base64 -d >"${PASSWORD_FILE}" || {
    echo "ERROR: Failed to extract passwords from OSPdO"
    exit 1
}

# oc rsh openstackclient cat ./home/cloud-admin/.config/openstack/clouds.yaml

# oc run mariadb-client -q --image ${MARIADB_IMAGE}\
#   -it --rm --restart=Never --overrides="$RUN_OVERRIDES" /bin/bash

# permissions were wrong on the rabbitmq-cell1 pods mnesia folder for some reason
# changing the permission caused it to work
