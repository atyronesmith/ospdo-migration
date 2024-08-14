#!/bin/bash

. common.sh
. common-ospdo.sh

# Adopt the dataplane interface

stop_infra_services_5_1() {
    PacemakerResourcesToStop=("openstack-cinder-volume"
        "openstack-cinder-backup"
        "openstack-manila-share")

    echo "Stopping pacemaker OpenStack services"
    for i in {1..3}; do
        SSH_CMD=CONTROLLER${i}_SSH
        if [ -n "${!SSH_CMD}" ]; then
            echo "Using controller $i to run pacemaker commands "
            for resource in "${PacemakerResourcesToStop[@]}"; do
                if ${!SSH_CMD} sudo pcs resource config "$resource" &>/dev/null; then
                    echo "Stopping $resource"
                    ${!SSH_CMD} sudo pcs resource disable "$resource"
                else
                    echo "Service $resource not present"
                fi
            done
            break
        fi
    done
}

adopt_compute_service_5_2() {
    PODIFIED_DB_ROOT_PASSWORD=$(oc get -o json secret/osp-secret -n "${OSP18_NAMESPACE}" | jq -r .data.DbRootPassword | base64 -d)

    # Take the private ssh key (id_ra) from the /home/cloud-admin/.ssh/ directory of the openstackclient pod and create a secret in the osp18 namespace
    oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
    name: dataplane-adoption-secret
    namespace: ${OSP18_NAMESPACE}
data:
    ssh-privatekey: |
$(oc exec -n "${OSPDO_NAMESPACE}" -t openstackclient openstackclient -- cat /home/cloud-admin/.ssh/id_rsa | base64 | sed 's/^/        /')
EOF

    echo "Check if the nova-migration-ssh-key secret exists"
    oc get secret nova-migration-ssh-key || {
        (
            echo "Creating nova-migration-ssh-key secret"
            cd "$(mktemp -d)" || exit
            ssh-keygen -f ./id -t ecdsa-sha2-nistp521 -N ''
            oc create secret generic nova-migration-ssh-key \
                -n "${OSP18_NAMESPACE}" \
                --from-file=ssh-privatekey=id \
                --from-file=ssh-publickey=id.pub \
                --type kubernetes.io/ssh-auth
            rm -f id*
        )
    }

    oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: nova-extra-config
  namespace: ${OSP18_NAMESPACE}
data:
  19-nova-compute-cell1-workarounds.conf: |
    [workarounds]
    disable_compute_service_check_for_ffu=true
EOF

    #Create a secret for the subscription manager and a secret for the Red Hat registry
    oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: subscription-manager
  namespace: ${OSP18_NAMESPACE}
data:
  username: echo ${SUBSCRIPTION_MANAGER_USERNAME} | base64
  password: echo ${SUBSCRIPTION_MANAGER_PASSWORD} | base64
---
apiVersion: v1
kind: Secret
metadata:
  name: redhat-registry
  namespace: ${OSP18_NAMESPACE}
data:
  username: echo ${REDHAT_REGISTRY_USERNAME} | base64
  password: echo ${REDHAT_REGISTRY_PASSWORD} | base64
EOF

    envsubst <yamls/openstackdataplanenodeset.yaml | oc apply -f - || {
        echo "Failed to apply openstackdataplanenodeset.yaml"
        exit 1
    }

}

download_nic_templates() {
    oc get -n "${OSPDO_NAMESPACE}" cm tripleo-tarball-config-deploy -ojson | jq -r '.binaryData."tarball-config.tar.gz"' | base64 -d | tar tzvf -
}

get_ovn_info() {
    oc -n openstack exec -c openstackclient openstackclient -- ssh compute-1.ctlplane sudo ovs-vsctl -f json --columns=external_ids list Open | jq -r '.data[0][0][1][]|join("=")'
    # oc -n openstack rsh -c openstackclient openstackclient ssh compute-1.ctlplane sudo ovs-vsctl list Open . | sed -n -E 's/.*ovn-bridge-mappings="([^"]+).*/\1/p'
    # oc -n openstack rsh -c openstackclient openstackclient ssh compute-1.ctlplane sudo ovs-vsctl list Open . | sed -n -E 's/.*ovn-bridge=([^,]+).*/\1/p'
    # oc -n openstack rsh -c openstackclient openstackclient ssh compute-1.ctlplane sudo ovs-vsctl list Open . | sed -n -E 's/.*ovn-encap-type=([^,]+).*/\1/p'

}

case $1 in
5.1)
    stop_infra_services_5_1
    ;;
5.2)
    adopt_compute_service_5_2
    ;;
ovninfo)
    get_ovn_info
    ;;
*)
    echo "Invalid argument"
    exit 1
    ;;
esac
