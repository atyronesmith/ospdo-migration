#!/bin/bash

if ! oc patch openstackcontrolplane openstack --type=merge --patch '
spec:
  neutron:
    enabled: true
    apiOverride:
      route: {}
    template:
      override:
        service:
          internal:
            metadata:
              annotations:
                metallb.universe.tf/address-pool: internalapi-rhoso
                metallb.universe.tf/allow-shared-ip: internalapi-rhoso
                metallb.universe.tf/loadBalancerIPs: 172.17.0.80
            spec:
              type: LoadBalancer
      databaseInstance: openstack
      databaseAccount: neutron
      secret: osp-secret
      networkAttachments:
      - internalapi-rhoso
'; then
    echo "Failed to apply neutron enable to openstackcontrolplane"
    exit 1
fi

oc wait --for=condition=Ready pod --selector=service=neutron --timeout=30s || {
    echo "ERROR: Failed to start neutron service."
    exit 1
}

NEUTRON_API_POD=$(oc get pods -l service=neutron | tail -n 1 | cut -f 1 -d' ')
oc exec -t "$NEUTRON_API_POD" -c neutron-api -- cat /etc/neutron/neutron.conf || {
    echo "ERROR: Failed to get neutron.conf from neutron-api pod"
    exit 1
}

openstack service list | grep network || {
    echo "ERROR: Failed to list network service"
    exit 1
}

openstack endpoint list | grep network || {
    echo "ERROR: Failed to list network endpoint"
    exit 1
}   

oc exec -i openstackclient -- openstack network create network1 || {
    echo "ERROR: Failed to create network1"
    exit 1
}

oc exec -i openstackclient -- openstack subnet create --network network1 --subnet-range 10.0.0.0/24 subnet || {
    echo "ERROR: Failed to create subnet"
    exit 1
}

oc exec -i openstackclient -- openstack router create router1 || {
    echo "ERROR: Failed to create router1"
    exit 1
}

oc exec -i openstackclient -- openstack router delete router1 || {
    echo "ERROR: Failed to delete router1"
    exit 1
}

oc exec -i openstackclient -- openstack network delete network1 || {
    echo "ERROR: Failed to delete network1"
    exit 1
}
