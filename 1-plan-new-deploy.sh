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
    oc patch osnetconfig openstacknetconfig --type json -p '[{"op": "replace", "path": "/spec/attachConfigurations/'$i'/nodeNetworkConfigurationPolicy/nodeSelector", "value": {"kubernetes.io/hostname": "'"$CONTROLLER_NODE"'"} } ]'
done

# Get the names of the other two nodes that we will use for NG
NG_NODES=$(oc get nodes -o name -l kubernetes.io/hostname!="$CONTROLLER_NODE" | sed 's#node/##g' | tr '\n' ' ')
RHOSO_NODE1=$(echo "${NG_NODES}" | cut -d ' ' -f 1)
export RHOSO_NODE1
RHOSO_NODE2=$(echo "${NG_NODES}" | cut -d ' ' -f 2)
export RHOSO_NODE2

oc label nodes "${RHOSO_NODE1}" type=openstack || {
    echo "Failed to label node1"
    exit 1
}
oc label nodes "${RHOSO_NODE2}" type=openstack || {
    echo "Failed to label node2"
    exit 1
}

# create and apply custom NNCPs for RHOSO
# the NNCPs should obey the labels applied above
envsubst <yamls/node1-nncp.yaml | oc apply -f - || {
    echo "Failed to set apply node1-nncp.yaml"
    exit 1
}
envsubst <yamls/node2-nncp.yaml | oc apply -f - || {
    echo "Failed to set apply node2-nncp.yaml"
    exit 1
}

oc apply -f yamls/nads.yaml || {
    echo "Failed to apply net-attach-def..."
    exit 1
}

# Install the RHOSO operators
(cd "$install_yaml_dir" || exit && BMO_SETUP=false NETWORK_ISOLATION=false make openstack)

# install_yaml doesn't install metallb with the above parameters
# install it now
if [ "$(oc get pod --no-headers=true -l component=speaker -n metallb-system | wc -l)" -ne 3 ]; then
    # Install metallb
    (cd "$install_yaml_dir" || exit && BMO_SETUP=false NETWORK_ISOLATION=false make metallb)
fi

# Make sure OVNKubernetes IPForwarding is enabled
oc patch network.operator cluster -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"ipForwarding": "Global"}}}}}' --type=merge || {
    echo "Failed to patch network.operator"
    exit 1
}

oc apply -f yamls/ipaddresspools.yaml || {
    echo "Failed to apply ipaddresspool"
    exit 1
}
oc apply -f yamls/l2advertisement.yaml || {
    echo "Failed to apply l2advertisement"
    exit 1
}

oc apply -f yamls/netconfig.yaml || {
    echo "Failed to apply netconfig"
    exit 1
}

# oc rsh openstackclient cat ./home/cloud-admin/.config/openstack/clouds.yaml


# oc run mariadb-client -q --image ${MARIADB_IMAGE}\
#   -it --rm --restart=Never --overrides="$RUN_OVERRIDES" /bin/bash



# permissions were wrong on the rabbitmq-cell1 pods mnesia folder for some reason
# changing the permission caused it to work
