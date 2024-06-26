#!/bin/bash

#KUBECONFIG=/root/ostest-working/kubeconfig

usage() {
    echo "Usage: $0 [-h] [-d] path_to_install_yamls"
    echo "  -h  Display this help message"
    echo "  -d  Enable debug mode"
    echo "  path_to_install_yamls path to install_yamls"
}

while getopts "dh" opt; do
    case ${opt} in
    d)
        set -x
        ;;
    h)
        usage
        exit 0
        ;;
    \?)
        echo "Invalid Option: -$OPTARG" 1>&2
        exit 1
        ;;
    esac
done

shift $((OPTIND - 1))

if [ "$#" -ne 1 ]; then
    usage
    exit 1
fi

install_yaml_dir=$(realpath "$1")

PASSWORD_FILE="tripleo-passwords.yaml"

# Set the OpenShift project to "openstack" and fail on error
oc project openstack || {
    echo "Failed to set OpenShift project to openstack"
    exit 1
}

# Get the name of the OCP node where the OSP Controller VM is running
# For this POC, we only deploy a single controller VM
# TODO - deploy with 3 controller VM and scale down to 1 VM
CONTROLLER_NODE=$(oc get pod -n openstack -l kubevirt.io=virt-launcher -o jsonpath='{.items[0].metadata.labels.kubevirt\.io/nodeName}')
# Fail if CONTROLLER_NODE is an empty string
if [[ -z "$CONTROLLER_NODE" ]]; then
    echo "Failed to get the name of the OCP node where the OSP Controller VM is running"
    exit 1
fi

# Remove OSPdO NNCPs from the other two nodes which are not running the controller VM
for i in br-ctlplane br-ex br-osp; do
    oc patch osnetconfig openstacknetconfig --type json -p '[{"op": "replace", "path": "/spec/attachConfigurations/'$i'/nodeNetworkConfigurationPolicy/nodeSelector", "value": {"kubernetes.io/hostname": "'"$CONTROLLER_NODE"'"} } ]'
done

# Get the names of the other two nodes that we will use for NG
NG_NODES=$(oc get nodes -o name -l kubernetes.io/hostname!="$CONTROLLER_NODE" | sed 's#node/##g' | tr '\n' ' ')
NODE1=$(echo "${NG_NODES}" | cut -d ' ' -f 1)
export NODE1
NODE2=$(echo "${NG_NODES}" | cut -d ' ' -f 2)
export NODE2

# create an apply custom NNCPs for NG
envsubst <node1-nncp.yaml | oc apply -f - || {
    echo "Failed to set apply node1-nncp.yaml"
    exit 1
}
envsubst <node2-nncp.yaml | oc apply -f - || {
    echo "Failed to set apply node2-nncp.yaml"
    exit 1
}

if ! oc apply -f nads.yaml; then
  echo "Failed to apply net-attach-def..."
  exit 1
fi

# Install the RHOSO operators
(cd "$install_yaml_dir" || exit && BMO_SETUP=false NETWORK_ISOLATION=false make openstack)

if [ "$(oc get pod --no-headers=true -l component=speaker -n metallb-system | wc -l)" -ne 3 ]; then
    # Install metallb
    (cd "$install_yaml_dir" || exit && BMO_SETUP=false NETWORK_ISOLATION=false make metallb)
fi

# Make sure OVNKubernetes IPForwarding is enabled
oc patch network.operator cluster -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"ipForwarding": "Global"}}}}}' --type=merge

oc apply -f ipaddresspools.yaml || {
    echo "Failed to apply ipaddresspool"
    exit 1
}
oc apply -f l2advertisement.yaml || {
    echo "Failed to apply l2advertisement"
    exit 1
}

oc label nodes "${NODE1}" type=openstack
oc label nodes "${NODE2}" type=openstack

# Extract passwords from OSPdO
oc get secret tripleo-passwords -o json | jq -r '.data["tripleo-overcloud-passwords.yaml"]' | base64 -d >"${PASSWORD_FILE}"

oc rsh openstackclient cat ./home/cloud-admin/.config/openstack/clouds.yaml
#j6t6l5drnxnfsrhlw92qdbj68

# k8s.v1.cni.cncf.io/networks: '[{"name": "ctlplane-static", "namespace": "openstack",
#   "ips": ["172.22.0.251/24"]}, {"name": "external-static", "namespace": "openstack",
#   "ips": ["10.0.0.251/24"]}, {"name": "internalapi-static", "namespace": "openstack",
#   "ips": ["172.17.0.251/24"]}]'

IPA_SSH="podman exec -ti freeipa-server"
# For OSPdO installed by director-dev-tools, the server host runs the freeipa server as a container...

#To locate the CA certificate and key, list all the certificates inside your NSSDB:
$IPA_SSH certutil -L -d /etc/pki/pki-tomcat/alias

# Certificate Nickname                                         Trust Attributes
#                                                              SSL,S/MIME,JAR/XPI

# caSigningCert cert-pki-ca                                    CTu,Cu,Cu
# ocspSigningCert cert-pki-ca                                  u,u,u
# subsystemCert cert-pki-ca                                    u,u,u
# auditSigningCert cert-pki-ca                                 u,u,Pu
# Server-Cert cert-pki-ca                                      u,u,u

# Export the certificate and key from the /etc/pki/pki-tomcat/alias directory:
if ! $IPA_SSH pk12util -o /tmp/freeipa.p12 -n 'caSigningCert cert-pki-ca' \
    -d /etc/pki/pki-tomcat/alias -k /etc/pki/pki-tomcat/alias/pwdfile.txt \
    -w /etc/pki/pki-tomcat/alias/pwdfile.txt; then
    echo "Unable to extract caSigningCert..."
    exit 1
fi

# Create the secret that contains the root CA
if ! oc get secret rootca-internal >/dev/null 2>&1; then
    oc create secret generic rootca-internal
fi

OPENSSL_OPTION_NOENC='-noenc'
if $IPA_SSH openssl version | grep '1.1.1' >/dev/null 2>&1; then
    OPENSSL_OPTION_NOENC='-nodes'
fi

if ! oc patch secret rootca-internal -n openstack -p="{\"data\":{\"ca.crt\": \
    \"$($IPA_SSH openssl pkcs12 -in /tmp/freeipa.p12 -passin file:/etc/pki/pki-tomcat/alias/pwdfile.txt \
    -nokeys | openssl x509 | base64 -w 0)\"}}"; then
    echo "Unable to patch secret ca.crt."
    exit 1
fi

if ! oc patch secret rootca-internal -n openstack -p="{\"data\":{\"tls.crt\": \
    \"$($IPA_SSH openssl pkcs12 -in /tmp/freeipa.p12 -passin file:/etc/pki/pki-tomcat/alias/pwdfile.txt \
    -nokeys | openssl x509 | base64 -w 0)\"}}"; then
    echo "Unable to patch secret tls.crt."
    exit 1
fi

# openssl pkcs12 version is 1.1.1 in what is deployed
#  documentation assumes version 3+
if ! oc patch secret rootca-internal -n openstack -p="{\"data\":{\"tls.key\": \
    \"$($IPA_SSH openssl pkcs12 -in /tmp/freeipa.p12 -passin file:/etc/pki/pki-tomcat/alias/pwdfile.txt \
    -nocerts "${OPENSSL_OPTION_NOENC}" | openssl rsa | base64 -w 0)\"}}"; then
    echo "Unable to patch secret tls.crt."
    exit 1
fi

if ! issuer_status=$(oc get issuers -n openstack -o jsonpath='{.items[0].status.conditions[0].status}'); then
    echo "Failed to get issuers status."
    exit 1
fi

if [[ "$issuer_status" == "True" ]]; then
    echo "Issuer Ready"
else
    echo "Issuer status is not True"
fi

# TODO - Stop and disable the certmonger service on all data plane nodes, and stop tracking all certificates managed by the service:

# TODO -- extract env information automatically
CONTROLLER_SSH="oc rsh openstackclient ssh controller-0.ctlplane"
export CONTROLLER_SSH
MARIADB_IMAGE=registry.redhat.io/rhosp-dev-preview/openstack-mariadb-rhel9:18.0
export MARIADB_IMAGE
SOURCE_DB_ROOT_PASSWORD=$(grep <"${PASSWORD_FILE}" ' MysqlRootPassword:' | awk -F ': ' '{ print $2; }')
export SOURCE_DB_ROOT_PASSWORD
SOURCE_MARIADB_IP=172.22.0.160
export SOURCE_MARIADB_IP
RUN_OVERRIDES='{"apiVersion":"v1","metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"[{\"name\": \"internalapi-static\",\"namespace\": \"openstack\", \"ips\":[\"172.17.0.99/24\"]}]"}}, "spec":{"nodeName": "ostest-master-0"}}'

if ! oc apply -f issuer.yaml; then
    echo "Unable to apply Issuer!"
    exit 1
fi


PULL_OPENSTACK_CONFIGURATION_DATABASES=$(oc run mariadb-client -q --image ${MARIADB_IMAGE} \
    -i --rm --restart=Never --overrides="$RUN_OVERRIDES" --mysql -rsh "$SOURCE_MARIADB_IP" -uroot -p"$SOURCE_DB_ROOT_PASSWORD" -e 'SHOW databases;')
echo "$PULL_OPENSTACK_CONFIGURATION_DATABASES"

#  --overrides='{ "apiVersion": "v1","metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"[{\"name\": \"internalapi-static\",\"namespace\": \"openstack\", \"ips\":[\"172.17.0.99/24\"]}]"}}, "spec":{"nodeName": "ostest-master-0"}}' -- \

PULL_OPENSTACK_CONFIGURATION_MYSQLCHECK_NOK=$(oc run mariadb-client -q --image ${MARIADB_IMAGE} \
    -i --rm --restart=Never --overrides="$RUN_OVERRIDES" --mysqlcheck --all-databases -h "$SOURCE_MARIADB_IP" -u root -p"$SOURCE_DB_ROOT_PASSWORD" | grep -v OK)
export PULL_OPENSTACK_CONFIGURATION_MYSQLCHECK_NOK
echo "$PULL_OPENSTACK_CONFIGURATION_MYSQLCHECK_NOK"

PULL_OPENSTACK_CONFIGURATION_NOVADB_MAPPED_CELLS=$(oc run mariadb-client -q --image ${MARIADB_IMAGE} \
    -i --rm --restart=Never --overrides="$RUN_OVERRIDES" -- mysql -rsh "${SOURCE_MARIADB_IP}" -uroot -p"${SOURCE_DB_ROOT_PASSWORD}" nova_api -e \
    'select uuid,name,transport_url,database_connection,disabled from cell_mappings;')
export PULL_OPENSTACK_CONFIGURATION_NOVADB_MAPPED_CELLS
echo "$PULL_OPENSTACK_CONFIGURATION_NOVADB_MAPPED_CELLS"

PULL_OPENSTACK_CONFIGURATION_NOVA_COMPUTE_HOSTNAMES=$(oc run mariadb-client -q --image ${MARIADB_IMAGE} \
    -i --rm --restart=Never --overrides="$RUN_OVERRIDES" -- mysql -rsh "$SOURCE_MARIADB_IP" -uroot -p"$SOURCE_DB_ROOT_PASSWORD" nova_api -e \
    "select host from nova.services where services.binary='nova-compute';")
export PULL_OPENSTACK_CONFIGURATION_NOVA_COMPUTE_HOSTNAMES
echo "$PULL_OPENSTACK_CONFIGURATION_NOVA_COMPUTE_HOSTNAMES"

PULL_OPENSTACK_CONFIGURATION_NOVAMANAGE_CELL_MAPPINGS=$($CONTROLLER_SSH sudo podman exec -it nova_api nova-manage cell_v2 list_cells)
export PULL_OPENSTACK_CONFIGURATION_NOVAMANAGE_CELL_MAPPINGS
echo "$PULL_OPENSTACK_CONFIGURATION_NOVAMANAGE_CELL_MAPPINGS"

cat >~/.source_cloud_exported_variables <<EOF
PULL_OPENSTACK_CONFIGURATION_DATABASES=$(oc run mariadb-client -q --image ${MARIADB_IMAGE} \
    -i --rm --restart=Never --overrides="$RUN_OVERRIDES" -- mysql -rsh "$SOURCE_MARIADB_IP" -uroot -p"$SOURCE_DB_ROOT_PASSWORD" -e 'SHOW databases;')
PULL_OPENSTACK_CONFIGURATION_MYSQLCHECK_NOK=$(oc run mariadb-client -q --image ${MARIADB_IMAGE} \
        -i --rm --restart=Never --overrides="$RUN_OVERRIDES" -- mysqlcheck --all-databases -h "$SOURCE_MARIADB_IP" -u root -p"$SOURCE_DB_ROOT_PASSWORD" | grep -v OK)
PULL_OPENSTACK_CONFIGURATION_NOVADB_MAPPED_CELLS=$(oc run mariadb-client -q --image ${MARIADB_IMAGE} \
        -i --rm --restart=Never --overrides="$RUN_OVERRIDES" -- mysql -rsh "${SOURCE_MARIADB_IP}" -uroot -p"${SOURCE_DB_ROOT_PASSWORD}" nova_api -e \
        'select uuid,name,transport_url,database_connection,disabled from cell_mappings;')
PULL_OPENSTACK_CONFIGURATION_NOVA_COMPUTE_HOSTNAMES=$(oc run mariadb-client -q --image ${MARIADB_IMAGE} \
        -i --rm --restart=Never --overrides="$RUN_OVERRIDES" -- mysql -rsh "$SOURCE_MARIADB_IP" -uroot -p"$SOURCE_DB_ROOT_PASSWORD" nova_api -e \
        "select host from nova.services where services.binary='nova-compute';")
CONTROLLER_SSH="oc rsh -c openstackclient openstackclient ssh controller-0.ctlplane"
PULL_OPENSTACK_CONFIGURATION_NOVAMANAGE_CELL_MAPPINGS=$($CONTROLLER_SSH sudo podman exec -it nova_api nova-manage cell_v2 list_cells)
EOF
chmod 0600 ~/.source_cloud_exported_variables

#TODO
# Optional: If there are neutron-sriov-nic-agent agents running in the deployment, get its configuration:

oc run mariadb-client -q --image ${MARIADB_IMAGE} -it --rm --restart=Never --overrides="$RUN_OVERRIDES"-- mysql -rsh "$SOURCE_MARIADB_IP" -uroot -p"$SOURCE_DB_ROOT_PASSWORD"ovs_neutron -e "select host, configurations from agents where agents.binary='neutron-sriov-nic-agent';"

# oc run mariadb-client -q --image ${MARIADB_IMAGE}\
#   -it --rm --restart=Never --overrides="$RUN_OVERRIDES" /bin/bash

ADMIN_PASSWORD=$(grep <"${PASSWORD_FILE}" ' AdminPassword:' | awk -F ': ' '{ print $2; }')

AODH_PASSWORD=$(grep <"${PASSWORD_FILE}" ' AodhPassword:' | awk -F ': ' '{ print $2; }')
BARBICAN_PASSWORD=$(grep <"${PASSWORD_FILE}" ' BarbicanPassword:' | awk -F ': ' '{ print $2; }')
CEILOMETER_METERING_SECRET=$(grep <"${PASSWORD_FILE}" ' CeilometerMeteringSecret:' | awk -F ': ' '{ print $2; }')
CEILOMETER_PASSWORD=$(grep <"${PASSWORD_FILE}" ' CeilometerPassword:' | awk -F ': ' '{ print $2; }')
CINDER_PASSWORD=$(grep <"${PASSWORD_FILE}" ' CinderPassword:' | awk -F ': ' '{ print $2; }')
CONGRESS_PASSWORD=$(grep <"${PASSWORD_FILE}" ' CongressPassword:' | awk -F ': ' '{ print $2; }')
DESIGNATE_PASSWORD=$(grep <"${PASSWORD_FILE}" ' DesignatePassword:' | awk -F ': ' '{ print $2; }')
GLANCE_PASSWORD=$(grep <"${PASSWORD_FILE}" ' GlancePassword:' | awk -F ': ' '{ print $2; }')
HEAT_AUTH_ENCRYPTION_KEY=$(grep <"${PASSWORD_FILE}" ' HeatAuthEncryptionKey:' | awk -F ': ' '{ print $2; }')
HEAT_PASSWORD=$(grep <"${PASSWORD_FILE}" ' HeatPassword:' | awk -F ': ' '{ print $2; }')
IRONIC_PASSWORD=$(grep <"${PASSWORD_FILE}" ' IronicPassword:' | awk -F ': ' '{ print $2; }')
MANILA_PASSWORD=$(grep <"${PASSWORD_FILE}" ' ManilaPassword:' | awk -F ': ' '{ print $2; }')
NEUTRON_PASSWORD=$(grep <"${PASSWORD_FILE}" ' NeutronPassword:' | awk -F ': ' '{ print $2; }')
NOVA_PASSWORD=$(grep <"${PASSWORD_FILE}" ' NovaPassword:' | awk -F ': ' '{ print $2; }')
OCTAVIA_PASSWORD=$(grep <"${PASSWORD_FILE}" ' OctaviaPassword:' | awk -F ': ' '{ print $2; }')
PLACEMENT_PASSWORD=$(grep <"${PASSWORD_FILE}" ' PlacementPassword:' | awk -F ': ' '{ print $2; }')
SWIFT_PASSWORD=$(grep <"${PASSWORD_FILE}" ' SwiftPassword:' | awk -F ': ' '{ print $2; }')
MYSQLROOT_PASSWORD=$(grep <"${PASSWORD_FILE}" ' MysqlRootPassword:' | awk -F ': ' '{ print $2; }')

oc set data secret/osp-secret "AdminPassword=$ADMIN_PASSWORD"

oc set data secret/osp-secret "AodhPassword=$AODH_PASSWORD"
oc set data secret/osp-secret "BarbicanPassword=$BARBICAN_PASSWORD"
oc set data secret/osp-secret "CeilometerMeteringSecret=$CEILOMETER_METERING_SECRET"
oc set data secret/osp-secret "CeilometerPassword=$CEILOMETER_PASSWORD"
oc set data secret/osp-secret "CinderPassword=$CINDER_PASSWORD"
oc set data secret/osp-secret "CongressPassword=$CONGRESS_PASSWORD"
oc set data secret/osp-secret "DesignatePassword=$DESIGNATE_PASSWORD"
oc set data secret/osp-secret "DbRootPassword=$MYSQLROOT_PASSWORD"
oc set data secret/osp-secret "GlancePassword=$GLANCE_PASSWORD"
oc set data secret/osp-secret "HeatAuthEncryptionKey=$HEAT_AUTH_ENCRYPTION_KEY"
oc set data secret/osp-secret "HeatPassword=$HEAT_PASSWORD"
oc set data secret/osp-secret "IronicPassword=$IRONIC_PASSWORD"
oc set data secret/osp-secret "IronicInspectorPassword=$IRONIC_PASSWORD"
oc set data secret/osp-secret "ManilaPassword=$MANILA_PASSWORD"
oc set data secret/osp-secret "NeutronPassword=$NEUTRON_PASSWORD"
oc set data secret/osp-secret "NovaPassword=$NOVA_PASSWORD"
oc set data secret/osp-secret "OctaviaPassword=$OCTAVIA_PASSWORD"
oc set data secret/osp-secret "PlacementPassword=$PLACEMENT_PASSWORD"
oc set data secret/osp-secret "SwiftPassword=$SWIFT_PASSWORD"

oc apply -f openstackcontrolplane.yaml

#TODO wait for Ready
oc wait openstackcontrolplane openstack --for condition=Ready --timeout=600s


# permissions were wrong on the rabbitmq-cell1 pods mnesia folder for some reason
# changing the permission caused it to work
