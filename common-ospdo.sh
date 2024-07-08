#!/bin/bash

OSPDO_PROJECT="openstack"

oc project "$OSPDO_PROJECT" >/dev/null 2>&1 || {
    echo "Failed to switch to project $OSPDO_PROJECT"
    return 1
}   

# Get the name of the OCP node where the OSP Controller VM is running
# For this POC, we only deploy a single controller VM
# TODO - deploy with 3 controller VM and scale down to 1 VM
CONTROLLER_NODE=$(oc get pod -n "$OSPDO_PROJECT" -l kubevirt.io=virt-launcher -o jsonpath='{.items[0].metadata.labels.kubevirt\.io/nodeName}')
# Fail if CONTROLLER_NODE is an empty string
if [[ -z "$CONTROLLER_NODE" ]]; then
    echo "Failed to get the name of the OCP node where the OSP Controller VM is running"
    return 1
fi

# TODO -- extract env information automatically
# shellcheck disable=SC2034
CONTROLLER_SSH="oc rsh -c openstackclient openstackclient ssh controller-0.ctlplane"

# shellcheck disable=SC2034
MARIADB_IMAGE=registry.redhat.io/rhosp-dev-preview/openstack-mariadb-rhel9:18.0

# shellcheck disable=SC2034
SOURCE_DB_ROOT_PASSWORD=$(grep <"${PASSWORD_FILE}" ' MysqlRootPassword:' | awk -F ': ' '{ print $2; }')

# shellcheck disable=SC2034
SOURCE_MARIADB_IP=172.17.0.160

# shellcheck disable=SC2034
RUN_OVERRIDES='{"apiVersion":"v1","metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"[{\"name\": \"internalapi-static\",\"namespace\": \"openstack\", \"ips\":[\"172.17.0.99/24\"]}]"}}, "spec":{"nodeName": "ostest-master-0"}}'

OSPDO_INTERNAL_API_NET="internal_api"

# shellcheck disable=SC2034
readarray -t OSPDO_COMPUTE < <(oc get osipset/compute -ojson | jq -S '.status.hosts|keys[]')
# shellcheck disable=SC2034
readarray -t OSPDO_CONTROLLER < <(oc get osipset/controller -ojson | jq -S '.status.hosts|keys[]')
# shellcheck disable=SC2034
readarray -t OSPDO_COMPUTE_IP < <(oc get osipset/compute -ojson | jq -S '.status.hosts[].ipaddresses.'"$OSPDO_INTERNAL_API_NET"'')
# shellcheck disable=SC2034
readarray -t OSPDO_CONTROLLER_IP < <(oc get osipset/controller -ojson | jq -S '.status.hosts[].ipaddresses.'"$OSPDO_INTERNAL_API_NET"'')

# shellcheck disable=SC2034
STORAGE_CLASS=$(oc get pvc openstackclient-hosts -o jsonpath='{.spec.storageClassName}')
