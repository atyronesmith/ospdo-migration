#!/bin/bash

. common.sh

usage() {
  echo "Usage: $0 <adopt-identry-server|adopt-key-manager|adopt-networking|adopt-object-storage|all>"
  echo "Description: This script adopts the OpenStack services."
  echo ""
  echo "Commands:"
  echo "  adopt-identry-server: Adopt the Identity service"
  echo "  adopt-key-manager: Adopt the Key Manager service"
  echo "  adopt-networking: Adopt the Networking service"
  echo "  adopt-object-storage: Adopt the Object Storage service"
  echo "  all: Adopt all the OpenStack services"
  exit 1
}

CREDENTIAL_KEYS0=$(grep <"${PASSWORD_FILE}" ' KeystoneCredential0:' | awk -F ': ' '{ print $2; }' | base64 -w 0)
export CREDENTIAL_KEYS0
CREDENTIAL_KEYS1=$(grep <"${PASSWORD_FILE}" ' KeystoneCredential1:' | awk -F ': ' '{ print $2; }' | base64 -w 0)
export CREDENTIAL_KEYS1
FERNET_KEYS0=$(grep <"${PASSWORD_FILE}" ' KeystoneFernetKey0:' | awk -F ': ' '{ print $2; }' | base64 -w 0)
export FERNET_KEYS0
FERNET_KEYS1=$(grep <"${PASSWORD_FILE}" ' KeystoneFernetKey1:' | awk -F ': ' '{ print $2; }' | base64 -w 0)
export FERNET_KEYS1

# Create an alias to use openstack command in the adopted deployment:
#alias openstack="oc exec -t openstackclient -- openstack"

adopt_identry_service_4_1() {
  echo "Creating keys..."
  envsubst <yamls/openstack-secret.yaml | oc apply -f - || {
    echo "Failed to apply openstack-secret.yaml"
    exit 1
  }

  echo "Deploy Identity service"
  oc -n "${OSP18_NAMESPACE}" patch openstackcontrolplane openstack --type=merge --patch '
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
  echo "Wait for openstackcontrolplane to be Ready"
  oc wait openstackcontrolplane openstack -n ${OSP18_NAMESPACE} --for condition=Ready --timeout=600s || {
    echo "Failed to wait for openstackcontrolplane to be Ready"
    exit 1
  }

  # Clean up old services and endpoints that still point to the old control plane, excluding the Identity service and its endpoints
  $OS_CLIENT openstack endpoint list | grep keystone | awk '/admin/{ print $2; }' | xargs -t $OS_CLIENT openstack endpoint delete || true

  for service in aodh heat heat-cfn barbican cinderv3 glance manila manilav2 neutron nova placement swift ironic-inspector ironic; do
    $OS_CLIENT openstack service list | awk "/ $service /{ print \$2; }" | xargs -t $OS_CLIENT openstack service delete || true
  done

  $OS_CLIENT openstack endpoint list | grep keystone || {
    echo "ERROR: Keystone endpoint is missing"
    exit 1
  }
}

adopt_key_manager_4_2() {
  oc -n "${OSP18_NAMESPACE}" patch openstackcontrolplane openstack --type=merge --patch '
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
  # Wait for barbican pods to start
  for component in barbican-api barbican-worker keystone-listener; do
    while ! oc get pod --selector='service=barbican,component='$component'' -n ${OSP18_NAMESPACE} | grep "$component"; do sleep 10; done
  done

  # Wait for barbican pods to be ready
  for component in barbican-api barbican-worker keystone-listener; do
    oc wait --for=jsonpath='{.status.phase}'=Running pod --selector='service=barbican,component='$component'' -n ${OSP18_NAMESPACE} || {
      echo "ERROR: Failed to start barbican: $component"
      exit 1
    }
  done

  $OS_CLIENT openstack endpoint list | grep key-manager
  $OS_CLIENT openstack service list | grep key-manager | grep barbican || {
    echo "ERROR: Failed to create key-manager service"
    exit 1
  }
  $OS_CLIENT openstack secret list | grep key-manager

}

adopt_networking_4_3() {
  oc -n ${OSP18_NAMESPACE} patch openstackcontrolplane openstack --type=merge --patch '
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
                metallb.universe.tf/address-pool: internalapi-osp18
                metallb.universe.tf/allow-shared-ip: internalapi-osp18
                metallb.universe.tf/loadBalancerIPs: 172.17.0.80
            spec:
              type: LoadBalancer
      databaseInstance: openstack
      databaseAccount: neutron
      secret: osp-secret
      networkAttachments:
      - internalapi-osp18
'

  echo "Wait for Neutron pod to start"
  while ! oc get pod --selector=service=neutron -n ${OSP18_NAMESPACE} | grep neutron; do sleep 10; done

  echo "Wait for Neutron pod to be ready"
  oc -n ${OSP18_NAMESPACE} wait --for=jsonpath='{.status.phase}'=Running pod --selector=service=neutron || {
    echo "ERROR: Failed to start neutron pod"
    exit 1
  }

  NEUTRON_API_POD=$(oc get pods -l service=neutron -o jsonpath='{.items[0].metadata.name}')
  oc exec -t "$NEUTRON_API_POD" -c neutron-api -- cat /etc/neutron/neutron.conf

  $OS_CLIENT openstack service list | grep network || {
    echo "ERROR: Failed to create network service"
    exit 1
  }
  $OS_CLIENT openstack endpoint list | grep network || {
    echo "ERROR: Failed to create network endpoint"
    exit 1
  }

  $OS_CLIENT openstack network create net || {
    echo "ERROR: Failed to create network"
    exit 1
  }
  $OS_CLIENT openstack subnet create --network net --subnet-range 10.0.0.0/24 subnet || {
    echo "ERROR: Failed to create subnet"
    exit 1
  }
  $OS_CLIENT openstack router create router || {
    echo "ERROR: Failed to create router"
    exit 1
  }
  # TODO cleanup
}

adopting_object_storage_4_4() {
  # Create the swift-conf secret, containing the swift.conf file
  oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: swift-conf
  namespace: ${OSP18_NAMESPACE}
type: Opaque
data:
  swift.conf: $($CONTROLLER1_SSH sudo cat /var/lib/config-data/puppet-generated/swift/etc/swift/swift.conf | base64 -w0)
EOF
  # Create the swift-ring-files configmap, containing the Object Storage service ring files
  oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: swift-ring-files
binaryData:
  swiftrings.tar.gz: $($CONTROLLER1_SSH "cd /var/lib/config-data/puppet-generated/swift/etc/swift && tar cz *.builder *.ring.gz backups/ | base64 -w0")
  account.ring.gz: $($CONTROLLER1_SSH "base64 -w0 /var/lib/config-data/puppet-generated/swift/etc/swift/account.ring.gz")
  container.ring.gz: $($CONTROLLER1_SSH "base64 -w0 /var/lib/config-data/puppet-generated/swift/etc/swift/container.ring.gz")
  object.ring.gz: $($CONTROLLER1_SSH "base64 -w0 /var/lib/config-data/puppet-generated/swift/etc/swift/object.ring.gz")
EOF

  # the networkAttachments must match how swift was configured in OSPdO
  #
  # shellcheck disable=SC2016
  oc -n ${OSP18_NAMESPACE} patch openstackcontrolplane openstack --type=merge --patch '
spec:
  swift:
    enabled: true
    template:
      memcachedInstance: memcached
      swiftRing:
        ringReplicas: 1
      swiftStorage:
        replicas: 0
        networkAttachments:
        - storagemgmt-osp18
        storageClass: ${STORAGE_CLASS}
        storageRequest: 10Gi
      swiftProxy:
        secret: osp-secret
        replicas: 1
        passwordSelectors:
          service: SwiftPassword
        serviceUser: swift
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
        networkAttachments:
        - storagemgmt-osp18
'

  echo "Wait for Swift pod to start"
  while ! oc get pod --selector=service=swift -n ${OSP18_NAMESPACE} | grep swift; do sleep 10; done

  echo "Wait for Swift pod to be ready"
  oc -n ${OSP18_NAMESPACE} wait --for=jsonpath='{.status.phase}'=Running pod --selector=service=swift || {
    echo "ERROR: Failed to start neutron pod"
    exit 1
  }

  sleep 5
  
  test_string="Hello World!"
  echo "$test_string" >obj
  oc -n ${OSP18_NAMESPACE} cp obj openstackclient:/tmp/obj || {
    echo "ERROR: Failed to copy object to openstackclient"
    exit 1
  }

  echo "Creating container"
  $OS_CLIENT openstack container create test || {
    echo "ERROR: Failed to create container"
    exit 1
  }
  echo "Creating object"
  $OS_CLIENT openstack object create test /tmp/obj || {
    echo "ERROR: Failed to create object"
    exit 1
  }
  echo "Saving object"
  ts=$($OS_CLIENT openstack object save test /tmp/obj --file -) || {
    echo "ERROR: Failed to save object to file"
    exit 1
  }
  [ "$ts" == "$test_string" ] || {
    echo "ERROR: Saved object is incorrect"
    exit 1
  }
}

adopt_image_service_4_5() {
  oc patch openstackcontrolplane openstack --type=merge --patch-file=yamls/glance_swift.patch

  echo "Wait for Glance pod to start"
  while ! oc get pod --selector=service=glance -n ${OSP18_NAMESPACE} | grep glance; do sleep 10; done

  echo "Wait for Glance pod to be ready"
  oc -n ${OSP18_NAMESPACE} wait --for=jsonpath='{.status.phase}'=Running pod --selector=service=glance || {
    echo "ERROR: Failed to start glance pod"
    exit 1
  }
  echo "Check for glance service"
  $OS_CLIENT openstack service list | grep image || {
    echo "ERROR: Failed to create image service"
    exit 1
  }
  echo "Check for glance endpoint"
  $OS_CLIENT openstack endpoint list | grep image || {
    echo "ERROR: Failed to create image endpoint"
    exit 1
  }
  echo "Check for images"
  $OS_CLIENT openstack image list || {
    echo "ERROR: Failed to list images"
    exit 1
  }
}

# Adopt the Placement service
adopt_placement_4_6() {
  oc patch openstackcontrolplane openstack --type=merge --patch '
spec:
  placement:
    enabled: true
    apiOverride:
      route: {}
    template:
      databaseInstance: openstack
      databaseAccount: placement
      secret: osp-secret
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
'
  echo "Wait for Glance pod to start"
  while ! oc get pod --selector=service=placement -n ${OSP18_NAMESPACE} | grep placement; do sleep 10; done

  echo "Wait for Glance pod to be ready"
  oc -n ${OSP18_NAMESPACE} wait --for=jsonpath='{.status.phase}'=Running pod --selector=service=placement || {
    echo "ERROR: Failed to start glance pod"
    exit 1
  }

  #Even with the pod ready neet to wait
  sleep 10

  $OS_CLIENT openstack endpoint list | grep placement

  # TODO document difference between docs
  # added Interace column to allow selection of type 'public'
  # initial problem with cert error
  # the problem was that the allowed-shared-ip network was incorrect
  # Checking the svc, oc get svc placement-internal -oyaml, showed that the loadbalancer was pending...
  PLACEMENT_PUBLIC_URL=$($OS_CLIENT openstack endpoint list -c 'Service Name' -c 'Service Type' -c 'Interface' -c URL | grep placement | grep public | awk '{ print $8; }')
  oc exec -t openstackclient -- curl "$PLACEMENT_PUBLIC_URL"

  # With OpenStack CLI placement plugin installed:
  $OS_CLIENT openstack resource class list || {
    echo "ERROR: Failed to list resource classes"
    exit 1
  }

  #sh-5.1$ openstack resource class list
  # SSL exception connecting to https://overcloud.osptest.test.metalkube.org:13778/placement/: HTTPSConnectionPool(host='overcloud.osptest.test.metalkube.org', port=13778): Max retries exceeded with url: /placement/ (Caused by SSLError(SSLCertVerificationError(1, '[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get local issuer certificate (_ssl.c:1133)')))
}

# Adopt the Compute service
adopt_compute_service_4_7() {
  oc patch openstackcontrolplane openstack -n ${OSP18_NAMESPACE} --type=merge --patch '
spec:
  nova:
    enabled: true
    apiOverride:
      route: {}
    template:
      secret: osp-secret
      apiServiceTemplate:
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
        customServiceConfig: |
          [workarounds]
          disable_compute_service_check_for_ffu=true
      metadataServiceTemplate:
        enabled: true # deploy single nova metadata on the top level
        override:
          service:
            metadata:
              annotations:
                metallb.universe.tf/address-pool: internalapi-osp18
                metallb.universe.tf/allow-shared-ip: internalapi-osp18
                metallb.universe.tf/loadBalancerIPs: 172.17.0.80
            spec:
              type: LoadBalancer
        customServiceConfig: |
          [workarounds]
          disable_compute_service_check_for_ffu=true
      schedulerServiceTemplate:
        customServiceConfig: |
          [workarounds]
          disable_compute_service_check_for_ffu=true
      cellTemplates:
        cell0:
          conductorServiceTemplate:
            customServiceConfig: |
              [workarounds]
              disable_compute_service_check_for_ffu=true
        cell1:
          metadataServiceTemplate:
            enabled: false # enable here to run it in a cell instead
            override:
                service:
                  metadata:
                    annotations:
                      metallb.universe.tf/address-pool: internalapi-osp18
                      metallb.universe.tf/allow-shared-ip: internalapi-osp18
                      metallb.universe.tf/loadBalancerIPs: 172.17.0.80
                  spec:
                    type: LoadBalancer
            customServiceConfig: |
              [workarounds]
              disable_compute_service_check_for_ffu=true
          conductorServiceTemplate:
            customServiceConfig: |
              [workarounds]
              disable_compute_service_check_for_ffu=true
'

  echo "Wait for Nova pod to start"
  while ! oc get pod --selector=service=nova-api -n ${OSP18_NAMESPACE} | grep nova-api; do sleep 10; done

  echo "Wait for Nova pod to be ready"
  oc -n ${OSP18_NAMESPACE} wait --for=jsonpath='{.status.phase}'=Running pod --selector=service=nova-api || {
    echo "ERROR: Failed to start nova pod"
    exit 1
  }

  $OS_CLIENT openstack endpoint list | grep nova || {
    echo "ERROR: Failed to create nova endpoint"
    exit 1
  }
  $OS_CLIENT openstack server list || {
    echo "ERROR: Failed to list servers"
    exit 1
  }

  # . ~/.source_cloud_exported_variables
  # echo $PULL_OPENSTACK_CONFIGURATION_NOVAMANAGE_CELL_MAPPINGS
  # oc rsh nova-cell0-conductor-0 nova-manage cell_v2 list_cells | grep -F '| cell1 |'
}

adopt_block_storage_4_8() {
  NG_NODES=$(oc get nodes -o name -l kubernetes.io/hostname!="$CONTROLLER_NODE" | sed 's#node/##g' | tr '\n' ' ')
  OSP18_NODE1=$(echo "${NG_NODES}" | cut -d ' ' -f 1)
  export OSP18_NODE1

  oc create secret generic nfs-conf-secret --from-file=yamls/nfs.conf || {
    echo "Failed to create nfs-conf-secret"
    exit
  }

  # oc label nodes "${OSP18_NODE1}" openstack.org/cinder-lvm="" || {
  #   echo "Failed to label node1"
  #   exit 1
  # }

  # oc apply -f yamls/iscsid-mc.yaml || {
  #   echo "Failed to apply iscsid-mc.yaml"
  #   exit 1
  # }

  $CONTROLLER1_SSH sudo cat /var/lib/config-data/puppet-generated/cinder/etc/cinder/cinder.conf >cinder.conf
  oc patch openstackcontrolplane openstack -n ${OSP18_NAMESPACE} --type=merge --patch-file=yamls/cinder.patch
}

adopt_dashboard_service_4_9() {
  oc patch openstackcontrolplane openstack -n ${OSP18_NAMESPACE} --type=merge --patch '
spec:
  horizon:
    enabled: true
    apiOverride:
      route: {}
    template:
      memcachedInstance: memcached
      secret: osp-secret  
'

  echo "Wait for Horizon pod to start"
  while ! oc get pod --selector=service=horizon -n ${OSP18_NAMESPACE} | grep horizon; do sleep 10; done

  echo "Wait for Horizon pod to be ready"
  oc -n ${OSP18_NAMESPACE} wait --for=jsonpath='{.status.phase}'=Running pod --selector=service=horizon || {
    echo "ERROR: Failed to start horizon pod"
    exit 1
  }

}

case $1 in
adopt-identry-service| 4_1)
  adopt_identry_service_4_1
  ;;
adopt-key-manager | 4_2)
  adopt_key_manager_4_2
  ;;
adopt-networking | 4_3)
  adopt_networking_4_3
  ;;
adopt-object-storage | 4_4)
  adopting_object_storage_4_4
  ;;
adopt-image-service | 4_5)
  adopt_image_service_4_5
  ;;
adopt-placement | 4_6)
  adopt_placement_4_6
  ;;
adopt-compute | 4_7)
  adopt_compute_service_4_7
  ;;
adopt-block-storage | 4_8)
  adopt_block_storage_4_8
  ;;
adopt-dashboard | 4_9)
  adopt_dashboard_service_4_9
  ;;
all)
  adopt_identry_service_4_1
  adopt_key_manager_4_2
  adopt_networking_4_3
  adopting_object_storage_4_4
  ;;
*)
  echo "Invalid command line argument. <$1>"
  usage
  ;;
esac
