#!/bin/bash

# Get the name of the OCP node where the OSP Controller VM is running
# For this POC, we only deploy a single controller VM
# TODO - deploy with 3 controller VM and scale down to 1 VM
CONTROLLER_NODE=$(oc get pod -n "$OSPDO_NAMESPACE" -l kubevirt.io=virt-launcher -o jsonpath='{.items[0].metadata.labels.kubevirt\.io/nodeName}')
# Fail if CONTROLLER_NODE is an empty string
[[ -n "$CONTROLLER_NODE" ]] || {
    echo "Failed to get the name of the OCP node where the OSP Controller VM is running"
    return 1
}
export CONTROLLER_NODE

# TODO -- extract env information automatically
# shellcheck disable=SC2034
CONTROLLER_SSH="oc rsh -n $OSPDO_NAMESPACE -c openstackclient openstackclient ssh controller-0.ctlplane"
export CONTROLLER_SSH

CONTROLLER1_SSH="oc -n $OSPDO_NAMESPACE rsh -c openstackclient openstackclient ssh controller-0.ctlplane"
export CONTROLLER1_SSH
CONTROLLER2_SSH=
export CONTROLLER2_SSH
CONTROLLER3_SSH=
export CONTROLLER3_SSH

OSPDO_INTERNAL_API_NET="internalapi"
export OSPDO_INTERNAL_API_NET

# shellcheck disable=SC2034
readarray -t OSPDO_COMPUTE < <(oc get -n $OSPDO_NAMESPACE osipset/compute -ojson | jq -S '.status.hosts|keys[]')
# shellcheck disable=SC2034
readarray -t OSPDO_CONTROLLER < <(oc get -n $OSPDO_NAMESPACE  osipset/controller -ojson | jq -S '.status.hosts|keys[]')
# shellcheck disable=SC2034
readarray -t OSPDO_COMPUTE_IP < <(oc get -n $OSPDO_NAMESPACE osipset/compute -ojson | jq -S '.status.hosts[].ipaddresses.'"$OSPDO_INTERNAL_API_NET"'')
# shellcheck disable=SC2034
readarray -t OSPDO_CONTROLLER_IP < <(oc get -n $OSPDO_NAMESPACE osipset/controller -ojson | jq -S '.status.hosts[].ipaddresses.'"$OSPDO_INTERNAL_API_NET"'')

# shellcheck disable=SC2034
STORAGE_CLASS=$(oc get -n $OSPDO_NAMESPACE pvc openstackclient-hosts -o jsonpath='{.spec.storageClassName}')
export STORAGE_CLASS
