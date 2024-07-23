#!/bin/bash

PASSWORD_FILE="tripleo-passwords.yaml"
export PASSWORD_FILE

OSP18_NAMESPACE="osp18"
export OSP18_NAMESPACE

OSPDO_NAMESPACE="openstack"
export OSPDO_NAMESPACE

# shellcheck disable=SC2034
#OS_CLIENT="oc rsh -n $OSPDO_NAMESPACE -c openstackclient openstackclient "
OS_CLIENT="oc exec -t openstackclient -- "
export OS_CLIENT

# oc project "$OSP18_NAMESPACE" >/dev/null 2>&1 || {
#     oc create namespace "$OSP18_NAMESPACE" || {
#         echo "Failed to create project $OSP18_NAMESPACE"
#         exit 1
#     }
# }
