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
  username: $(echo -n "${SUBSCRIPTION_MANAGER_USERNAME}" | base64)
  password: $(echo -n "${SUBSCRIPTION_MANAGER_PASSWORD}" | base64)
---
apiVersion: v1
kind: Secret
metadata:
  name: redhat-registry
  namespace: ${OSP18_NAMESPACE}
data:
  username: $(echo -n "${REDHAT_REGISTRY_USERNAME}" | base64)
  password: $(echo -n "${REDHAT_REGISTRY_PASSWORD}" | base64)
EOF

# missing from documentation
    LIBVIRT_PASSWORD=$(grep <"${PASSWORD_FILE}" ' LibvirtTLSPassword:' | awk -F ': ' '{ print $2; }')

    oc apply -f - <<EOF
apiVersion: v1
data:
 LibvirtPassword: $(echo -n "${LIBVIRT_PASSWORD}" | base64)
kind: Secret
metadata:
 name: libvirt-secret
 namespace: ${OSP18_NAMESPACE}
type: Opaque
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
    oc -n openstack exec -c openstackclient openstackclient -- \
        ssh compute-1.ctlplane sudo ovs-vsctl -f json --columns=external_ids list Open |
        jq -r '.data[0][0][1][]|join("=")' | sed -n -E 's/^(ovn.*)+=(.*)+/edpm_\1: \2/p' |
        grep -v -e ovn-remote -e encap-tos -e openflow -e ofctrl
}

get_baremetal_nodes() {
    oc -n openstack get openstackbaremetalsets.osp-director.openstack.org -ojson | jq '.items[0].status.baremetalHosts'
}

get_node_info() {
    oc -n openstack get openstackbaremetalsets.osp-director.openstack.org -ojson | jq '.items[0].status.baremetalHosts'
    oc -n openstack get openstacknetconfigs.osp-director.openstack.org -ojson | jq -r '.items[0].spec | "Dns Servers : ", .dnsServers'
    oc -n openstack get openstackbaremetalsets.osp-director.openstack.org -ojson | jq '.items[0].status.baremetalHosts.ipaddresses'
    oc -n openstack get openstackbaremetalsets.osp-director.openstack.org -ojson |
        jq -r '.items[0].spec | "role_networks:", "  - \(.networks | to_entries[] | .value)"'
}

gen_nodes() {
    oc -n openstack get openstackbaremetalsets.osp-director.openstack.org -ojson |
        jq -r '.items[0].status.baremetalHosts| "nodes:", keys[] as $k | .[$k].ipaddresses as $a | 
         "  \($k):", 
         "    hostName: \($k)", 
         "    ansible:",
         "      ansibleHost: \($a["ctlplane"] | sub("/\\d+"; ""))",
         "    networks:", ($a | to_entries[] | "    - name: \(.key) \n      fixedIP: \(.value | sub("/\\d+"; ""))\n      subnetName: subnet1")'
}

validation() {
    oc apply -f - <<EOF
apiVersion: dataplane.openstack.org/v1beta1
kind: OpenStackDataPlaneService
metadata:
  name: pre-adoption-validation
  namespace: ${OSP18_NAMESPACE}
spec:
  playbook: osp.edpm.pre_adoption_validation
  tlsCerts:
    default: 
      contents:
        - dnsnames
        - ips
      networks:
        - ctlplane
      issuer: osp-rootca-issuer-internal
  caCerts: combined-ca-bundle
  edpmServiceType: nova
EOF

    oc apply -f - <<EOF
apiVersion: dataplane.openstack.org/v1beta1
kind: OpenStackDataPlaneDeployment
metadata:
  name: openstack-pre-adoption
  namespace: ${OSP18_NAMESPACE}
spec:
  nodeSets:
  - openstack
  servicesOverride:
  - pre-adoption-validation
EOF

    watch oc get pod -l app=openstackansibleee

}

adoption_cleanup() {
    oc apply -f - <<EOF
apiVersion: dataplane.openstack.org/v1beta1
kind: OpenStackDataPlaneService
metadata:
  name: tripleo-cleanup
spec:
  playbook: osp.edpm.tripleo_cleanup
EOF

    oc apply -f - <<EOF
apiVersion: dataplane.openstack.org/v1beta1
kind: OpenStackDataPlaneDeployment
metadata:
  namespace: ${OSP18_NAMESPACE}
  name: tripleo-cleanup
spec:
  nodeSets:
  - openstack
  servicesOverride:
  - tripleo-cleanup
EOF
}

adopt_dataplane() {
    oc apply -f - <<EOF
apiVersion: dataplane.openstack.org/v1beta1
kind: OpenStackDataPlaneDeployment
metadata:
  name: openstack
  namespace: ${OSP18_NAMESPACE}
spec:
  nodeSets:
  - openstack
EOF

# watch oc get pod -l app=openstackansibleee
# oc logs -l app=openstackansibleee -f --max-log-requests 20
}

verify_networking_services() {
  oc exec openstackclient -- openstack network agent list
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
nodeinfo)
    get_node_info
    ;;
gennodes)
    gen_nodes
    ;;
nics)
    download_nic_templates
    ;;
adopt)
    adopt_dataplane
    ;;
*)
    echo "Invalid argument"
    exit 1
    ;;
esac
