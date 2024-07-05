#!/bin/bash

OSPDO_PROJECT="openstack"

# Get the name of the OCP node where the OSP Controller VM is running
# For this POC, we only deploy a single controller VM
# TODO - deploy with 3 controller VM and scale down to 1 VM
CONTROLLER_NODE=$(oc get pod -n "$OSPDO_PROJECT" -l kubevirt.io=virt-launcher -o jsonpath='{.items[0].metadata.labels.kubevirt\.io/nodeName}')
# Fail if CONTROLLER_NODE is an empty string
if [[ -z "$CONTROLLER_NODE" ]]; then
    echo "Failed to get the name of the OCP node where the OSP Controller VM is running"
    exit 1
fi

# Get the names of the other two nodes that we will use for NG
NG_NODES=$(oc get nodes -o name -l kubernetes.io/hostname!="$CONTROLLER_NODE" | sed 's#node/##g' | tr '\n' ' ')
NODE1=$(echo "${NG_NODES}" | cut -d ' ' -f 1)
export NODE1
NODE2=$(echo "${NG_NODES}" | cut -d ' ' -f 2)
export NODE2

# TODO -- extract env information automatically
CONTROLLER_SSH="oc rsh -c openstackclient openstackclient ssh controller-0.ctlplane"

export CONTROLLER_SSH
MARIADB_IMAGE=registry.redhat.io/rhosp-dev-preview/openstack-mariadb-rhel9:18.0
export MARIADB_IMAGE
SOURCE_DB_ROOT_PASSWORD=$(grep <"${PASSWORD_FILE}" ' MysqlRootPassword:' | awk -F ': ' '{ print $2; }')
export SOURCE_DB_ROOT_PASSWORD
SOURCE_MARIADB_IP=172.17.0.160
export SOURCE_MARIADB_IP
# shellcheck disable=SC2089
RUN_OVERRIDES='{"apiVersion":"v1","metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"[{\"name\": \"internalapi-static\",\"namespace\": \"openstack\", \"ips\":[\"172.17.0.99/24\"]}]"}}, "spec":{"nodeName": "ostest-master-0"}}'
# shellcheck disable=SC2090
export RUN_OVERRIDES

OSPDO_INTERNAL_API_NET="internal_api"
export INTERNAL_API_NET

readarray -t OSPDO_COMPUTE < <(oc get osipset/compute -ojson | jq -S '.status.hosts|keys[]')
export OSPDO_COMPUTE
readarray -t OSPDO_CONTROLLER < <(oc get osipset/controller -ojson | jq -S '.status.hosts|keys[]')
export OSPDO_CONTROLLER
readarray -t OSPDO_COMPUTE_IP < <(oc get osipset/compute -ojson | jq -S '.status.hosts[].ipaddresses.'"$OSPDO_INTERNAL_API_NET"'')
export OSPDO_COMPUTE_IP
readarray -t OSPDO_CONTROLLER_IP < <(oc get osipset/controller -ojson | jq -S '.status.hosts[].ipaddresses.'"$OSPDO_INTERNAL_API_NET"'')
export OSPDO_CONTROLLER_IP

STORAGE_CLASS=$(oc get pvc persistence-rabbitmq-cell1-server-0 -o jsonpath='{.spec.storageClassName}')
export STORAGE_CLASS
