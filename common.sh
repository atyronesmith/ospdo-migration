#!/bin/bash

PASSWORD_FILE="tripleo-passwords.yaml"
export PASSWORD_FILE

OSP18_NAMESPACE="osp18"
export OSP18_NAMESPACE

OSPDO_NAMESPACE="openstack"
export OSPDO_NAMESPACE

# oc project "$OSP18_NAMESPACE" >/dev/null 2>&1 || {
#     oc create namespace "$OSP18_NAMESPACE" || {
#         echo "Failed to create project $OSP18_NAMESPACE"
#         exit 1
#     }
# }
