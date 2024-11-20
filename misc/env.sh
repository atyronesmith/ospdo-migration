#!/bin/bash

OSP18_NAMESPACE="openstack"
export OSP18_NAMESPACE

NG_NODES=$(oc get nodes -o name | cut -d ' ' -f 1 | sed 's#node/##g' | tr '\n' ' ')

OSP18_NODE1=$(echo "${NG_NODES}" | cut -d ' ' -f 1)
export OSP18_NODE1
OSP18_NODE2=$(echo "${NG_NODES}" | cut -d ' ' -f 2)
export OSP18_NODE2
OSP18_NODE3=$(echo "${NG_NODES}" | cut -d ' ' -f 3)
export OSP18_NODE3

