#!/bin/bash

. common.sh

CREDENTIAL_KEYS0=$(grep <"${PASSWORD_FILE}" ' KeystoneCredential0:' | awk -F ': ' '{ print $2; }'|base64 -w 0)
export CREDENTIAL_KEYS0
CREDENTIAL_KEYS1=$(grep <"${PASSWORD_FILE}" ' KeystoneCredential1:' | awk -F ': ' '{ print $2; }'|base64 -w 0) 
export CREDENTIAL_KEYS1
FERNET_KEYS0=$(grep <"${PASSWORD_FILE}" ' KeystoneFernetKey0:' | awk -F ': ' '{ print $2; }'|base64 -w 0)
export FERNET_KEYS0
FERNET_KEYS1=$(grep <"${PASSWORD_FILE}" ' KeystoneFernetKey1:' | awk -F ': ' '{ print $2; }'|base64 -w 0)
export FERNET_KEYS1

echo "Creating keys..."
if ! envsubst <yamls/openstack-secret.yaml | oc apply -f -; then
    echo "Failed to apply openstack-secret.yaml"
    exit 1
fi

echo "Deploy Identity service"
oc patch openstackcontrolplane openstack --type=merge --patch '
spec:
  keystone:
    enabled: true
    apiOverride:
      route: {}
    template:
      override:
        service:
          internal:
            metadata:
              annotations:
                metallb.universe.tf/address-pool: internalapi-osp18
                metallb.universe.tf/allow-shared-ip: internalapi-osp18
                metallb.universe.tf/loadBalancerIPs: 172.17.0.80
            spec:
              type: LoadBalancer
      databaseInstance: openstack
      secret: osp-secret
'

oc patch openstackcontrolplane openstack --type=merge --patch '
spec:
  barbican:
    enabled: true
    apiOverride:
      route: {}
    template:
      databaseInstance: openstack
      databaseAccount: barbican
      rabbitMqClusterName: rabbitmq
      secret: osp-secret
      simpleCryptoBackendSecret: osp-secret
      serviceAccount: barbican
      serviceUser: barbican
      passwordSelectors:
        service: BarbicanPassword
        simplecryptokek: BarbicanSimpleCryptoKEK
      barbicanAPI:
        replicas: 1
        override:
          service:
            internal:
              metadata:
                annotations:
                  metallb.universe.tf/address-pool: internalapi-osp18
                  metallb.universe.tf/allow-shared-ip: internalapi-osp18
                  metallb.universe.tf/loadBalancerIPs: 172.17.0.80
              spec:
                type: LoadBalancer
      barbicanWorker:
        replicas: 1
      barbicanKeystoneListener:
        replicas: 1
'