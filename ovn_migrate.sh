#!/bin/bash
# shellcheck source=common.sh
. common.sh
. common-ospdo.sh

OVSDB_IMAGE=registry.redhat.io/rhosp-dev-preview/openstack-ovn-base-rhel9:18.0
export OVSDB_IMAGE
SOURCE_OVSDB_IP=172.17.0.160 # TODO - get this from the source OVN DB
export SOURCE_OVSDB_IP

usage() {
    echo "Usage: $0 <migrate|stop-osp18-ovn|stop-ospdo-ovn>"
    exit 1
}

prepare_for_osp18_ovn_start() {
    echo "Stopping ovn services in OSP 18"
    if ! oc patch openstackcontrolplane openstack --type=merge --patch '
spec:
  ovn:
    enabled: false
    template:
      ovnDBCluster:
        ovndbcluster-nb:
          dbType: NB
          storageRequest: 10G
          networkAttachment: internalapi-osp18
        ovndbcluster-sb:
          dbType: SB
          storageRequest: 10G
          networkAttachment: internalapi-osp18
      ovnNorthd:
        replicas: 0
      ovnController:
        networkAttachment: tenant-osp18
        nodeSelector:
          node: non-existing-node-name
'; then
        echo "ERROR: Failed to patch openstackcontrolplane to stop ovn services"
        exit 1
    fi

    echo "Waiting for OVN NB DB pods to stop"
    if ! oc wait --for=delete pod --selector=service=ovsdbserver-nb --timeout=30s; then
        echo "ERROR: Failed to stop OVN NB DB pod"
        exit 1
    fi

}

migrate() {
    echo "Creating ovn-data-cert secret"
    envsubst <yamls/ovn-data-cert.yaml | oc apply -f - >/dev/null || {
        echo "ERROR: Failed to create ovn-data-cert secret"
        exit 1
    }

    echo "Creating ovn-data-pvc"
    envsubst <yamls/ovn-data-pvc.yaml | oc apply -f - || {
        echo "Failed to set apply ovn-data-pvc"
        exit 1
    }

    echo "Creating ovn-copy-data-pod"
    envsubst <yamls/ovn-copy-data-pod.yaml | oc apply -f - || {
        echo "Failed to set apply ovn-copy-data-pod"
        exit 1
    }

    echo "Waiting for ovn-copy-data pod to start"
    oc -n "${OSP18_NAMESPACE}" wait --for=condition=Ready pod/ovn-copy-data --timeout=30s || {
        echo "ERROR: ovn-copy-data pod did not start"
        exit 1
    }

    echo "Create backup of NB DB"
    oc -n "${OSP18_NAMESPACE}" exec ovn-copy-data -- bash -c "ovsdb-client backup --ca-cert=/etc/pki/tls/misc/ca.crt --private-key=/etc/pki/tls/misc/tls.key --certificate=/etc/pki/tls/misc/tls.crt ssl:$SOURCE_OVSDB_IP:6641 > /backup/ovs-nb.db" || {
        echo "ERROR: Failed to backup OVN NB DB"
        exit 1
    }

    echo "Create backup of SB DB"
    oc exec ovn-copy-data -- bash -c "ovsdb-client backup --ca-cert=/etc/pki/tls/misc/ca.crt --private-key=/etc/pki/tls/misc/tls.key --certificate=/etc/pki/tls/misc/tls.crt ssl:$SOURCE_OVSDB_IP:6642 > /backup/ovs-sb.db" || {
        echo "ERROR: Failed to backup OVN SB DB"
        exit 1
    }

    echo "Starting ovn service in OSP 18"
    oc patch openstackcontrolplane openstack --type=merge --patch '
spec:
  ovn:
    enabled: true
    template:
      ovnDBCluster:
        ovndbcluster-nb:
          dbType: NB
          storageRequest: 10G
          networkAttachment: internalapi-osp18
        ovndbcluster-sb:
          dbType: SB
          storageRequest: 10G
          networkAttachment: internalapi-osp18
      ovnNorthd:
        replicas: 0
      ovnController:
        networkAttachment: tenant-osp18
        nodeSelector:
          node: non-existing-node-name
'
    # Need to wait for the pods to be created
    #hack
    sleep 5

    echo "Waiting for OVN NB DB pods to start"
    if ! oc wait --for=jsonpath='{.status.phase}'=Running pod --selector=service=ovsdbserver-nb; then
        echo "ERROR: Failed to start OVN NB DB pod"
        exit 1
    fi

    echo "Waiting for OVN SB DB pods to start"
    if ! oc wait --for=jsonpath='{.status.phase}'=Running pod --selector=service=ovsdbserver-sb; then
        echo "ERROR: Failed to start OVN SB DB pod"
        exit 1
    fi

    # TODO -- wait for svc to start

    echo "Getting OVN NB DB IPs in OSP 18"
    if ! PODIFIED_OVSDB_NB_IP=$(oc get svc --selector "statefulset.kubernetes.io/pod-name=ovsdbserver-nb-0" -ojsonpath='{.items[0].spec.clusterIP}'); then
        echo "ERROR: Failed to get OVN NB DB IP"
        exit 1
    fi

    echo "Getting OVN SB DB IPs in OSP 18"
    if ! PODIFIED_OVSDB_SB_IP=$(oc get svc --selector "statefulset.kubernetes.io/pod-name=ovsdbserver-sb-0" -ojsonpath='{.items[0].spec.clusterIP}'); then
        echo "ERROR: Failed to get OVN SB DB IP"
        exit 1
    fi

    echo "Converting OVN NB DB schema"
    if ! oc exec ovn-copy-data -- bash -c "ovsdb-client get-schema --ca-cert=/etc/pki/tls/misc/ca.crt --private-key=/etc/pki/tls/misc/tls.key \
     --certificate=/etc/pki/tls/misc/tls.crt ssl:$PODIFIED_OVSDB_NB_IP:6641 > /backup/ovs-nb.ovsschema && ovsdb-tool convert /backup/ovs-nb.db /backup/ovs-nb.ovsschema"; then
        echo "ERROR: Failed to convert OVN NB DB"
        exit 1
    fi

    echo "Converting OVN SB DB schema"
    if ! oc exec ovn-copy-data -- bash -c "ovsdb-client get-schema --ca-cert=/etc/pki/tls/misc/ca.crt --private-key=/etc/pki/tls/misc/tls.key \
     --certificate=/etc/pki/tls/misc/tls.crt ssl:$PODIFIED_OVSDB_SB_IP:6642 > /backup/ovs-sb.ovsschema && ovsdb-tool convert /backup/ovs-sb.db /backup/ovs-sb.ovsschema"; then
        echo "ERROR: Failed to convert OVN SB DB"
        exit 1
    fi

    echo "Restoring OVN NB DB from OSPdO to OSP 18"
    if ! oc exec ovn-copy-data -- bash -c "ovsdb-client restore --ca-cert=/etc/pki/tls/misc/ca.crt --private-key=/etc/pki/tls/misc/tls.key \
   --certificate=/etc/pki/tls/misc/tls.crt ssl:$PODIFIED_OVSDB_NB_IP:6641 < /backup/ovs-nb.db"; then
        echo "ERROR: Failed to restore OVN NB DB"
        exit 1
    fi

    echo "Restoring OVN SB DB from OSPdO to OSP 18"
    if ! oc exec ovn-copy-data -- bash -c "ovsdb-client restore --ca-cert=/etc/pki/tls/misc/ca.crt --private-key=/etc/pki/tls/misc/tls.key \
    --certificate=/etc/pki/tls/misc/tls.crt ssl:$PODIFIED_OVSDB_SB_IP:6642 < /backup/ovs-sb.db"; then
        echo "ERROR: Failed to restore OVN SB DB"
        exit 1
    fi

    if ! oc exec -it ovsdbserver-nb-0 -- ovn-nbctl show; then
        echo "ERROR: OVN NB DB not running with correct schema"
        exit 1
    fi

    if ! oc exec -it ovsdbserver-sb-0 -- ovn-sbctl list Chassis; then
        echo "ERROR: OVN SB DB not running with correct schema"
        exit 1
    fi

    echo "Patching openstackcontrolplane to enable ovnNorthd"
    if ! oc patch openstackcontrolplane openstack --type=merge --patch '
spec:
  ovn:
    enabled: true
    template:
      ovnNorthd:
        replicas: 1
'; then
        echo "ERROR: Failed to patch openstackcontrolplane"
        exit 1
    fi

    echo "Waiting for OVN Northd pods to start"
    if ! oc wait --for=jsonpath='{.status.phase}'=Running pod --selector=service=ovn-northd; then
        echo "ERROR: Failed to start ovn-northd pod"
        exit 1
    fi

    echo "Start ovncontroller"
    if ! oc patch openstackcontrolplane openstack --type=json -p="[{'op': 'remove', 'path': '/spec/ovn/template/ovnController/nodeSelector'}]"; then
        echo "ERROR: Failed to patch openstackcontrolplane to enable ovncontroller"
        exit 1
    fi
}

stop_ospdo_ovn() {
    ServicesToStop=("tripleo_ovn_cluster_north_db_server.service"
        "tripleo_ovn_cluster_south_db_server.service")

    echo "Stopping systemd OpenStack services"
    for service in "${ServicesToStop[@]}"; do
        if ${CONTROLLER_SSH} sudo systemctl is-active "$service"; then
            ${CONTROLLER_SSH} sudo systemctl stop "$service"
        fi
    done

    echo "Checking systemd OpenStack services"
    for service in "${ServicesToStop[@]}"; do
        if ! ${CONTROLLER_SSH} systemctl show "$service" | grep ActiveState=inactive >/dev/null; then
            echo "ERROR: Service $service still running on controller"
        else
            echo "OK: Service $service is not running on controller"
        fi
    done
}

# Check if at least one command line argument is provided
if [ $# -lt 1 ]; then
    echo "At least one command line argument is required."
    usage
fi

case $1 in
migrate)
    prepare_for_osp18_ovn_start
    migrate
    stop_ospdo_ovn
    ;;
stop-osp18-ovn)
    prepare_for_osp18_ovn_start
    ;;
stop-ospdo-ovn)
    stop_ospdo_ovn
    ;;
*)
    echo "Invalid command line argument."
    usage
    ;;
esac
