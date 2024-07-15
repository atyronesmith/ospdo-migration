#!/bin/bash
# shellcheck source=common.sh
. common.sh
. common-ospdo.sh

usage() {
    echo "Usage: $0 [-h] [-d] <command> <args>"
    echo "  -h  Display this help message"
    echo "  -d  Enable debug mode"
    echo " "
    echo "  retrieve-topology | 3_1 : Retrieve the OSPdO topology"
    echo "  deploy-backend-services | 3_2 : Deploy the backend services"
    echo "  stop-osp-services | 3_5 : Stop the OSP services"
    echo "  create-mariadb-copy-data | cmcd <namespace> <network> <target_node> : Create MariaDB data"
    echo "  delete-mariadb-copy-data | dmcd <namespace> : Delete MariaDB data"
    echo "  migrate-mariadb | 3_6 : Migrate MariaDB"
}

OVSDB_IMAGE=registry.redhat.io/rhosp-dev-preview/openstack-ovn-base-rhel9:18.0
export OVSDB_IMAGE

SOURCE_OVSDB_IP=172.17.0.160 # TODO - get this from the source OVN DB
export SOURCE_OVSDB_IP

SOURCE_DB_ROOT_PASSWORD=$(grep <"${PASSWORD_FILE}" ' MysqlRootPassword:' | awk -F ': ' '{ print $2; }') || {
    echo "Failed to get the source DB root password"
    exit 1
}
export SOURCE_DB_ROOT_PASSWORD

SOURCE_MARIADB_IP=172.17.0.160
export SOURCE_MARIADB_IP

MARIADB_IMAGE=registry.redhat.io/rhosp-dev-preview/openstack-mariadb-rhel9:18.0
export MARIADB_IMAGE

MARIADB_CLIENT_ANNOTATIONS='--annotations=k8s.v1.cni.cncf.io/networks='"$OSPDO_INTERNAL_API_NET"''
export MARIADB_CLIENT_ANNOTATIONS

#RUN_OVERRIDES='{"apiVersion":"a1","metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"[{\"name\": \"internalapi-static\",\"namespace\": \"openstack\", \"ips\":[\"172.17.0.99/24\"]}]"}}, "spec":{"nodeName": "ostest-master-0"}}'
RUN_OVERRIDES='{"apiVersion":"v1","metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"[{\"name\": \"internalapi-osp18\",\"namespace\": \"'"$OSP18_NAMESPACE"'\"}]"}}, "spec":{"nodeSelector": {"type" : "openstack"}}}'

retrieve_topology_3_1() {
    # Get the list of databases from the source MariaDB
    echo "Show OSPdO databases"
    PULL_OPENSTACK_CONFIGURATION_DATABASES="$(oc run mariadb-client -q --image "${MARIADB_IMAGE}" \
        -i --rm --restart=Never --overrides="$RUN_OVERRIDES" -n "${OSP18_NAMESPACE}" -- mysql -rsh "$SOURCE_MARIADB_IP" -uroot -p"$SOURCE_DB_ROOT_PASSWORD" -e 'SHOW databases;')"
    export PULL_OPENSTACK_CONFIGURATION_DATABASES
    echo "$PULL_OPENSTACK_CONFIGURATION_DATABASES"

    #  --overrides='{ "apiVersion": "v1","metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"[{\"name\": \"internalapi-static\",\"namespace\": \"openstack\", \"ips\":[\"172.17.0.99/24\"]}]"}}, "spec":{"nodeName": "ostest-master-0"}}' -- \

    # Run mysqlcheck on the original database to look for inaccuracies
    echo "Running mysqlcheck on the source MariaDB"
    PULL_OPENSTACK_CONFIGURATION_MYSQLCHECK_NOK="$(oc run mariadb-client -q --image "${MARIADB_IMAGE}" \
        -i --rm --restart=Never --overrides="$RUN_OVERRIDES" -n "${OSP18_NAMESPACE}" -- mysqlcheck --all-databases -h "$SOURCE_MARIADB_IP" -u root -p"$SOURCE_DB_ROOT_PASSWORD" | grep -v OK)"
    export PULL_OPENSTACK_CONFIGURATION_MYSQLCHECK_NOK
    echo "$PULL_OPENSTACK_CONFIGURATION_MYSQLCHECK_NOK"

    # Get the Compute service (nova) cells mappings from the database:
    echo "Get the Compute service (nova) cells mappings from the database"
    PULL_OPENSTACK_CONFIGURATION_NOVADB_MAPPED_CELLS="$(oc run mariadb-client -q --image "${MARIADB_IMAGE}" \
        -i --rm --restart=Never --overrides="$RUN_OVERRIDES" -n "${OSP18_NAMESPACE}" -- mysql -rsh "${SOURCE_MARIADB_IP}" -uroot -p"${SOURCE_DB_ROOT_PASSWORD}" nova_api -e \
        'select uuid,name,transport_url,database_connection,disabled from cell_mappings;')"
    export PULL_OPENSTACK_CONFIGURATION_NOVADB_MAPPED_CELLS
    echo "$PULL_OPENSTACK_CONFIGURATION_NOVADB_MAPPED_CELLS"

    # Get the hostnames of the nova-compute services from the database
    echo "Get the hostnames of the nova-compute services from the database"
    PULL_OPENSTACK_CONFIGURATION_NOVA_COMPUTE_HOSTNAMES="$(oc run mariadb-client -q --image "${MARIADB_IMAGE}" \
        -i --rm --restart=Never --overrides="$RUN_OVERRIDES" -n "${OSP18_NAMESPACE}" -- mysql -rsh "$SOURCE_MARIADB_IP" -uroot -p"$SOURCE_DB_ROOT_PASSWORD" nova_api -e \
        "select host from nova.services where services.binary='nova-compute';")"
    export PULL_OPENSTACK_CONFIGURATION_NOVA_COMPUTE_HOSTNAMES
    echo "$PULL_OPENSTACK_CONFIGURATION_NOVA_COMPUTE_HOSTNAMES"

    # Get the cell mappings from the nova-manage cell_v2 list_cells command
    echo "Get the cell mappings from the nova-manage cell_v2 list_cells command"
    PULL_OPENSTACK_CONFIGURATION_NOVAMANAGE_CELL_MAPPINGS="$($CONTROLLER_SSH sudo podman exec -it nova_api nova-manage cell_v2 list_cells)"
    export PULL_OPENSTACK_CONFIGURATION_NOVAMANAGE_CELL_MAPPINGS
    echo "$PULL_OPENSTACK_CONFIGURATION_NOVAMANAGE_CELL_MAPPINGS"

    # Get the SR-IOV agents from the database
    echo "Get the SR-IOV agents from the database"
    SRIOV_AGENTS=$(oc run mariadb-client -q --image "${MARIADB_IMAGE}" -it --rm --restart=Never --overrides="$RUN_OVERRIDES" -- mysql -rsh "$SOURCE_MARIADB_IP" \
        -uroot -p"$SOURCE_DB_ROOT_PASSWORD" ovs_neutron -e "select host, configurations from agents where agents.binary='neutron-sriov-nic-agent';")

    # Store exported variables for future use
    cat >~/.source_cloud_exported_variables <<EOF
PULL_OPENSTACK_CONFIGURATION_DATABASES="$PULL_OPENSTACK_CONFIGURATION_DATABASES"
PULL_OPENSTACK_CONFIGURATION_MYSQLCHECK_NOK="$PULL_OPENSTACK_CONFIGURATION_MYSQLCHECK_NOK"
PULL_OPENSTACK_CONFIGURATION_NOVADB_MAPPED_CELLS="$PULL_OPENSTACK_CONFIGURATION_NOVADB_MAPPED_CELLS"
PULL_OPENSTACK_CONFIGURATION_NOVA_COMPUTE_HOSTNAMES="$PULL_OPENSTACK_CONFIGURATION_NOVA_COMPUTE_HOSTNAMES"
PULL_OPENSTACK_CONFIGURATION_NOVAMANAGE_CELL_MAPPINGS="$PULL_OPENSTACK_CONFIGURATION_NOVAMANAGE_CELL_MAPPINGS"
SRIOV_AGENTS="$SRIOV_AGENTS"
EOF
    chmod 0600 ~/.source_cloud_exported_variables

    #TODO
    # Optional: If there are neutron-sriov-nic-agent agents running in the deployment, get its configuration:

}

deploy_backend_services_3_2() {

    envsubst <yamls/osp-secret.yaml | oc apply -f - || {
        echo "Failed to create osp-secret"
        exit 1
    }

    ADMIN_PASSWORD=$(grep <"${PASSWORD_FILE}" ' AdminPassword:' | awk -F ': ' '{ print $2; }')

    AODH_PASSWORD=$(grep <"${PASSWORD_FILE}" ' AodhPassword:' | awk -F ': ' '{ print $2; }')
    BARBICAN_PASSWORD=$(grep <"${PASSWORD_FILE}" ' BarbicanPassword:' | awk -F ': ' '{ print $2; }')
    BARBICANKEK_PASSWORD=$(grep <"${PASSWORD_FILE}" ' BarbicanSimpleCryptoKek:' | awk -F ': ' '{ print $2; }')
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
    MYSQLROOT_PASSWORD=$(grep <"${PASSWORD_FILE}" ' MysqlRootPassword:' | awk -F ': ' '{ print $2; }')

    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "AdminPassword=$ADMIN_PASSWORD"

    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "AodhPassword=$AODH_PASSWORD"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "BarbicanPassword=$BARBICAN_PASSWORD"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "BarbicanSimpleCryptoKEK=$BARBICANKEK_PASSWORD"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "CeilometerMeteringSecret=$CEILOMETER_METERING_SECRET"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "CeilometerPassword=$CEILOMETER_PASSWORD"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "CinderPassword=$CINDER_PASSWORD"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "CongressPassword=$CONGRESS_PASSWORD"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "DesignatePassword=$DESIGNATE_PASSWORD"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "DbRootPassword=$MYSQLROOT_PASSWORD"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "GlancePassword=$GLANCE_PASSWORD"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "HeatAuthEncryptionKey=$HEAT_AUTH_ENCRYPTION_KEY"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "HeatPassword=$HEAT_PASSWORD"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "IronicPassword=$IRONIC_PASSWORD"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "IronicInspectorPassword=$IRONIC_PASSWORD"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "ManilaPassword=$MANILA_PASSWORD"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "NeutronPassword=$NEUTRON_PASSWORD"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "NovaPassword=$NOVA_PASSWORD"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "OctaviaPassword=$OCTAVIA_PASSWORD"
    oc set data secret/osp-secret -n ${OSP18_NAMESPACE} "PlacementPassword=$PLACEMENT_PASSWORD"

    envsubst <yamls/openstackcontrolplane.yaml | oc apply -f - || {
        echo "Failed to apply openstackcontrolplane"
        exit 1
    }

    #TODO wait for Ready
    oc wait openstackcontrolplane openstack -n ${OSP18_NAMESPACE} --for condition=Ready --timeout=600s || {
        echo "Failed to wait for openstackcontrolplane to be Ready"
        exit 1
    }

    oc wait pod openstack-galera-0 -n ${OSP18_NAMESPACE} --for=jsonpath='{.status.phase}'=Running --timeout=30s || {
        echo "ERROR: Galera pod did not start"
        exit 1
    }

    oc wait pod openstack-cell1-galera-0 -o -n ${OSP18_NAMESPACE} --for=jsonpath='{.status.phase}'=Running --timeout=30s || {
        echo "ERROR: Galera cell1 pod did not start"
        exit 1
    }
}

stop_osp_services_3_5() {
    ./ospdo_services.sh check-openstack
    ./ospdo_services.sh stop-systemd
    ./ospdo_services.sh check-systemd
    ./ospdo_services.sh stop-pcm
    ./ospdo_services.sh check-pcm
}
# Function to delete MariaDB data
# This function checks if the pod 'mariadb-copy-data' and the persistent volume claim 'mariadb-data' exist,
# and deletes them if they do.
delete_mariadb_data() {
    local ns=$1

    oc get pod mariadb-copy-data -n "${ns}" >/dev/null 2>&1 && {
        oc delete pod mariadb-copy-data -n "${ns}"
    }
    oc get pvc mariadb-data -n "${ns}" >/dev/null 2>&1 && {
        oc delete pvc mariadb-data -n "${ns}"
    }
}

# Function to create MariaDB data Pod
# This function checks if the PVC (Persistent Volume Claim) 'mariadb-data' exists. If not, it creates the PVC using 'mariadb-copy-data-pvc.yaml' template.
# It then checks if the pod 'mariadb-copy-data' exists. If not, it creates the pod using 'mariadb-copy-data-pod.yaml' template.
# After that, it checks the WSREP (Write Set Replication) status of each database node specified in the 'SOURCE_GALERA_MEMBERS' array.
# If the WSREP status is 'Synced' for all nodes, the function returns successfully.
# If any error occurs during the process, appropriate error messages are displayed and the function exits with a non-zero status code.

create_mariadb_data() {
    local ns=$1
    local network=$2
    local target_node=$3

    oc get pvc mariadb-data -n "${ns}" >/dev/null 2>&1 || {
        export NAMESPACE="$ns"
        export STORAGE_CLASS="${STORAGE_CLASS}"
        # shellcheck disable=SC2016
        envsubst '$NAMESPACE,$STORAGE_CLASS' <yamls/mariadb-copy-data-pvc.yaml | oc apply -f -
        oc wait --for=jsonpath='{status.phase}'=Bound --timeout=30s pvc/mariadb-data -n "${ns}" || {
            echo "ERROR: PVC mariadb-copy-data-pvc did not bind"
            exit 1
        }
    }

    oc get pod mariadb-copy-data -n "${ns}" >/dev/null 2>&1 || {
        export NAMESPACE="$ns"
        export NETWORK="$network"
        export TARGET_NODE="$target_node"
        export IMAGE=${MARIADB_IMAGE}
        # TODO need to automate the allocation of an IP address for mariadb-copy-data pod
        # shellcheck disable=SC2016
        envsubst '$NAMESPACE,$NETWORK,$TARGET_NODE,$IMAGE' <yamls/mariadb-copy-data-pod.yaml | oc apply -f - || {
            echo "ERROR: Failed to create mariadb-copy-data pod"
            exit 1
        }
        oc wait --for condition=Ready --timeout=30s pod/mariadb-copy-data -n "${ns}" || {
            echo "ERROR: mariadb-copy-data pod did not start"
            exit 1
        }
    }

}

migrate_mariadb_3_6() {
    PODIFIED_MARIADB_IP=$(oc get svc --selector "mariadb/name=openstack" -ojsonpath='{.items[0].spec.clusterIP}' -n ${OSP18_NAMESPACE})
    PODIFIED_CELL1_MARIADB_IP=$(oc get svc --selector "mariadb/name=openstack-cell1" -ojsonpath='{.items[0].spec.clusterIP}' -n ${OSP18_NAMESPACE})
    PODIFIED_DB_ROOT_PASSWORD=$(oc get -o json secret/osp-secret -n "${OSP18_NAMESPACE}" | jq -r .data.DbRootPassword | base64 -d)

    # The CHARACTER_SET and collation should match the source DB
    # if the do not then it will break foreign key relationships
    # for any tables that are created in the future as part of db sync
    CHARACTER_SET=utf8
    COLLATION=utf8_general_ci

    declare -A SOURCE_GALERA_MEMBERS

    create_mariadb_data "${OSPDO_NAMESPACE}" "${OSPDO_INTERNAL_API_NET}" "${CONTROLLER_NODE}" || {
        echo "Failed to create mariadb-copy-data pod"
        exit 1
    }

    # oc get osnetconfig -o jsonpath='{.items[0].spec.reservations}'
    SOURCE_GALERA_MEMBERS=(
        ["controller-0"]=172.17.0.160
        # ...
    )

    for i in "${!SOURCE_GALERA_MEMBERS[@]}"; do
        echo "Checking for the database node $i WSREP status Synced"
        oc rsh -n "${OSPDO_NAMESPACE}" mariadb-copy-data mysql \
            -h "${SOURCE_GALERA_MEMBERS[$i]}" -uroot -p"$SOURCE_DB_ROOT_PASSWORD" \
            -e "show global status like 'wsrep_local_state_comment'" |
            grep -qE "\bSynced\b"
    done

    echo "Show OSPdO databases"
    oc rsh -n "${OSPDO_NAMESPACE}" mariadb-copy-data mysql -h "${SOURCE_MARIADB_IP}" -uroot -p"${SOURCE_DB_ROOT_PASSWORD}" -e "SHOW databases;"

    # List databases on podified database
    echo "Show OSP 18 databases"
    oc run mariadb-client -n ${OSP18_NAMESPACE} --image "$MARIADB_IMAGE" -i --rm --restart=Never -- \
        mysql -rsh "$PODIFIED_MARIADB_IP" -uroot -p"$PODIFIED_DB_ROOT_PASSWORD" -e 'SHOW databases;'
    oc run mariadb-client --image "$MARIADB_IMAGE" -i --rm --restart=Never -- \
        mysql -rsh "$PODIFIED_CELL1_MARIADB_IP" -uroot -p"$PODIFIED_DB_ROOT_PASSWORD" -e 'SHOW databases;'

    #
    # Create a dump of all databases on the source MariaDB
    echo "Dumping OSPdO databases"
    oc rsh -n "${OSPDO_NAMESPACE}" mariadb-copy-data <<EOF
  mysql -h"${SOURCE_MARIADB_IP}" -uroot -p"${SOURCE_DB_ROOT_PASSWORD}" \
  -N -e "show databases" | grep -E -v "schema|mysql|gnocchi" | \
  while read dbname; do
    echo "Dumping \${dbname}";
    mysqldump -h"${SOURCE_MARIADB_IP}" -uroot -p"${SOURCE_DB_ROOT_PASSWORD}" \
      --single-transaction --complete-insert --skip-lock-tables --lock-tables=0 \
      "\${dbname}" > /backup/"\${dbname}".sql;
   done
EOF

    # Restore the databases from .sql files into the control plane MariaDB:
    oc rsh mariadb-copy-data <<EOF
  # db schemas to rename on import
  declare -A db_name_map
  db_name_map['nova']='nova_cell1'
  db_name_map['ovs_neutron']='neutron'
  db_name_map['ironic-inspector']='ironic_inspector'

  # db servers to import into
  declare -A db_server_map
  db_server_map['default']=${PODIFIED_MARIADB_IP}
  db_server_map['nova_cell1']=${PODIFIED_CELL1_MARIADB_IP}

  # db server root password map
  declare -A db_server_password_map
  db_server_password_map['default']=${PODIFIED_DB_ROOT_PASSWORD}
  db_server_password_map['nova_cell1']=${PODIFIED_DB_ROOT_PASSWORD}

  cd /backup
  for db_file in \$(ls *.sql); do
    db_name=\$(echo \${db_file} | awk -F'.' '{ print \$1; }')
    if [[ -v "db_name_map[\${db_name}]" ]]; then
      echo "renaming \${db_name} to \${db_name_map[\${db_name}]}"
      db_name=\${db_name_map[\${db_name}]}
    fi
    db_server=\${db_server_map["default"]}
    if [[ -v "db_server_map[\${db_name}]" ]]; then
      db_server=\${db_server_map[\${db_name}]}
    fi
    db_password=\${db_server_password_map['default']}
    if [[ -v "db_server_password_map[\${db_name}]" ]]; then
      db_password=\${db_server_password_map[\${db_name}]}
    fi
    echo "creating \${db_name} in \${db_server}"
    mysql -h"\${db_server}" -uroot "-p\${db_password}" -e \
      "CREATE DATABASE IF NOT EXISTS \${db_name} DEFAULT \
      CHARACTER SET ${CHARACTER_SET} DEFAULT COLLATE ${COLLATION};"
    echo "importing \${db_name} into \${db_server}"
    mysql -h "\${db_server}" -uroot "-p\${db_password}" "\${db_name}" < "\${db_file}"
  done

  mysql -h "\${db_server_map['default']}" -uroot -p"\${db_server_password_map['default']}" -e \
    "update nova_api.cell_mappings set name='cell1' where name='default';"
  mysql -h "\${db_server_map['nova_cell1']}" -uroot -p"\${db_server_password_map['nova_cell1']}" -e \
    "delete from nova_cell1.services where host not like '%nova-cell1-%' and services.binary != 'nova-compute';"
EOF

    . ~/.source_cloud_exported_variables

    # use 'oc exec' and 'mysql -rs' to maintain formatting
    dbs=$(oc -n "${OSP18_NAMESPACE}" exec openstack-galera-0 -c galera -- mysql -rs -uroot "-p$PODIFIED_DB_ROOT_PASSWORD" -e 'SHOW databases;')
    echo "$dbs" | grep -Eq '\bkeystone\b' || {
        echo "ERROR: keystone database not found"
        exit 1
    }
    echo "$dbs" | grep -Eq '\bneutron\b' || {
        echo "ERROR: neutron database not found"
        exit 1
    }
    # ensure nova cell1 db is extracted to a separate db server and renamed from nova to nova_cell1
    c1dbs=$(oc -n "${OSP18_NAMESPACE}" exec openstack-cell1-galera-0 -c galera -- mysql -rs -uroot "-p$PODIFIED_DB_ROOT_PASSWORD" -e 'SHOW databases;')
    echo "$c1dbs" | grep -Eq '\bnova_cell1\b'

    # ensure default cell renamed to cell1, and the cell UUIDs retained intact
    novadb_mapped_cells=$(oc -n ${OSP18_NAMESPACE} exec openstack-galera-0 -c galera -- mysql -rs -uroot "-p$PODIFIED_DB_ROOT_PASSWORD" \
        nova_api -e 'select uuid,name,transport_url,database_connection,disabled from cell_mappings;')
    uuidf='\S{8,}-\S{4,}-\S{4,}-\S{4,}-\S{12,}'
    left_behind=$(comm -23 \
        <(echo $PULL_OPENSTACK_CONFIGURATION_NOVADB_MAPPED_CELLS | grep -oE " $uuidf \S+") \
        <(echo $novadb_mapped_cells | tr -s "| " " " | grep -oE " $uuidf \S+"))
    changed=$(comm -13 \
        <(echo $PULL_OPENSTACK_CONFIGURATION_NOVADB_MAPPED_CELLS | grep -oE " $uuidf \S+") \
        <(echo $novadb_mapped_cells | tr -s "| " " " | grep -oE " $uuidf \S+"))
    # shellcheck disable=SC2046,SC2086
    test $(grep -Ec ' \S+$' <<<$left_behind) -eq 1
    # shellcheck disable=SC2086
    default=$(grep -E ' default$' <<<$left_behind)
    # shellcheck disable=SC2046,SC2086
    test $(grep -Ec ' \S+$' <<<$changed) -eq 1
    # shellcheck disable=SC2086
    grep -qE " $(awk '{print $1}' <<<$default) cell1$" <<<$changed

    # ensure the registered Compute service name has not changed
    novadb_svc_records=$(oc -n "${OSP18_NAMESPACE}" exec openstack-cell1-galera-0 -c galera -- mysql -rs -uroot "-p$PODIFIED_DB_ROOT_PASSWORD" \
        nova_cell1 -e "select host from services where services.binary='nova-compute' order by host asc;")
    # shellcheck disable=SC2086
    diff -Z <(echo $novadb_svc_records) <(echo $PULL_OPENSTACK_CONFIGURATION_NOVA_COMPUTE_HOSTNAMES)

    delete_mariadb_data "${OSPDO_NAMESPACE}"
}

# 3.7 steps 1..2
# Prepare the OVN DBs copy dir and the adoption helper pod
#  (pick the storage requests to fit the OVN databases sizes)
create_ovn_copy_data_pod_1__2() {
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
}

# 3.7 step 4 Backup OVN databases on a TLS everywhere environment.
backup_ovn_dbs_3__4() {
    echo "Create backup of NB DB"
    oc -n "${OSP18_NAMESPACE}" exec ovn-copy-data -- bash -c "ovsdb-client backup --ca-cert=/etc/pki/tls/misc/ca.crt --private-key=/etc/pki/tls/misc/tls.key --certificate=/etc/pki/tls/misc/tls.crt ssl:$SOURCE_OVSDB_IP:6641 > /backup/ovs-nb.db" || {
        echo "ERROR: Failed to backup OVN NB DB"
        exit 1
    }

    echo "Create backup of SB DB"
    oc -n ${OSP18_NAMESPACE} exec ovn-copy-data -- bash -c "ovsdb-client backup --ca-cert=/etc/pki/tls/misc/ca.crt --private-key=/etc/pki/tls/misc/tls.key --certificate=/etc/pki/tls/misc/tls.crt ssl:$SOURCE_OVSDB_IP:6642 > /backup/ovs-sb.db" || {
        echo "ERROR: Failed to backup OVN SB DB"
        exit 1
    }
}

# 3.7 steps 5..6 Start the control plane OVN database services prior to import, keeping northd/ovn-controller stopped.
start_ovn_dbs_5__6() {
    echo "Starting ovn service in OSP 18"
    oc -n ${OSP18_NAMESPACE} patch openstackcontrolplane openstack --type=merge --patch '
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
    while ! oc get pod --selector=service=ovsdbserver-nb -n ${OSP18_NAMESPACE} | grep ovsdbserver-nb; do sleep 10; done

    echo "Waiting for OVN NB DB pods to start"
    oc wait --for=jsonpath='{.status.phase}'=Running pod --selector=service=ovsdbserver-nb -n ${OSP18_NAMESPACE} || {
        echo "ERROR: Failed to start OVN NB DB pod"
        exit 1
    }

    while ! oc get pod --selector=service=ovsdbserver-sb -n ${OSP18_NAMESPACE} | grep ovsdbserver-sb; do sleep 10; done

    echo "Waiting for OVN SB DB pods to start"
    oc wait --for=jsonpath='{.status.phase}'=Running pod --selector=service=ovsdbserver-sb -n ${OSP18_NAMESPACE} || {
        echo "ERROR: Failed to start OVN SB DB pod"
        exit 1
    }
}

# 3.7 steps 7..9 Update the OVN DB schemas to the OSP 18 version.
update_ovn_db_schemas_7__9() {
    while ! oc get svc --selector "statefulset.kubernetes.io/pod-name=ovsdbserver-nb-0" -n ${OSP18_NAMESPACE} | grep ovsdbserver-nb; do sleep 10; done

    echo "Getting OVN NB DB IPs in OSP 18"
    PODIFIED_OVSDB_NB_IP=$(oc -n ${OSP18_NAMESPACE} get svc --selector "statefulset.kubernetes.io/pod-name=ovsdbserver-nb-0" -ojsonpath='{.items[0].spec.clusterIP}') || {
        echo "ERROR: Failed to get OVN NB DB IP"
        exit 1
    }

    while ! oc get svc --selector "statefulset.kubernetes.io/pod-name=ovsdbserver-sb-0" -n ${OSP18_NAMESPACE} | grep ovsdbserver-sb; do sleep 10; done

    echo "Getting OVN SB DB IPs in OSP 18"
    PODIFIED_OVSDB_SB_IP=$(oc -n ${OSP18_NAMESPACE} get svc --selector "statefulset.kubernetes.io/pod-name=ovsdbserver-sb-0" -ojsonpath='{.items[0].spec.clusterIP}') || {
        echo "ERROR: Failed to get OVN SB DB IP"
        exit 1
    }

    echo "Converting OVN NB DB schema"
    oc -n ${OSP18_NAMESPACE} exec ovn-copy-data -- bash -c "ovsdb-client get-schema --ca-cert=/etc/pki/tls/misc/ca.crt --private-key=/etc/pki/tls/misc/tls.key \
     --certificate=/etc/pki/tls/misc/tls.crt ssl:$PODIFIED_OVSDB_NB_IP:6641 > /backup/ovs-nb.ovsschema && ovsdb-tool convert /backup/ovs-nb.db /backup/ovs-nb.ovsschema" || {
        echo "ERROR: Failed to convert OVN NB DB"
        exit 1
    }

    echo "Converting OVN SB DB schema"
    oc -n ${OSP18_NAMESPACE} exec ovn-copy-data -- bash -c "ovsdb-client get-schema --ca-cert=/etc/pki/tls/misc/ca.crt --private-key=/etc/pki/tls/misc/tls.key \
     --certificate=/etc/pki/tls/misc/tls.crt ssl:$PODIFIED_OVSDB_SB_IP:6642 > /backup/ovs-sb.ovsschema && ovsdb-tool convert /backup/ovs-sb.db /backup/ovs-sb.ovsschema" || {
        echo "ERROR: Failed to convert OVN SB DB"
        exit 1
    }
}

# 3.7 steps 10..12 Restore the OVN DBs from OSPdO to OSP 18.
restore_ovn_dbs_10__12() {
    echo "Restoring OVN NB DB from OSPdO to OSP 18"
    oc -n ${OSP18_NAMESPACE} exec ovn-copy-data -- bash -c "ovsdb-client restore --ca-cert=/etc/pki/tls/misc/ca.crt --private-key=/etc/pki/tls/misc/tls.key \
   --certificate=/etc/pki/tls/misc/tls.crt ssl:$PODIFIED_OVSDB_NB_IP:6641 < /backup/ovs-nb.db" || {
        echo "ERROR: Failed to restore OVN NB DB"
        exit 1
    }

    echo "Restoring OVN SB DB from OSPdO to OSP 18"
    oc -n ${OSP18_NAMESPACE} exec ovn-copy-data -- bash -c "ovsdb-client restore --ca-cert=/etc/pki/tls/misc/ca.crt --private-key=/etc/pki/tls/misc/tls.key \
    --certificate=/etc/pki/tls/misc/tls.crt ssl:$PODIFIED_OVSDB_SB_IP:6642 < /backup/ovs-sb.db" || {
        echo "ERROR: Failed to restore OVN SB DB"
        exit 1
    }

    oc -n ${OSP18_NAMESPACE} exec -it ovsdbserver-nb-0 -- ovn-nbctl show || {
        echo "ERROR: OVN NB DB not running with correct schema"
        exit 1
    }

    oc -n ${OSP18_NAMESPACE} exec -it ovsdbserver-sb-0 -- ovn-sbctl list Chassis || {
        echo "ERROR: OVN SB DB not running with correct schema"
        exit 1
    }
}

# 3.7 steps 13..14 Patch the openstackcontrolplane to enable ovnNorthd and start the ovncontroller.
start_northd_13__14() {
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

    while ! oc get pod --selector=service=ovn-northd -n ${OSP18_NAMESPACE} | grep ovn-northd; do sleep 10; done

    echo "Waiting for OVN Northd pods to start"
    oc -n ${OSP18_NAMESPACE} wait --for=jsonpath='{.status.phase}'=Running pod --selector=service=ovn-northd || {
        echo "ERROR: Failed to start ovn-northd pod"
        exit 1
    }

    echo "Start ovncontroller"
    oc -n ${OSP18_NAMESPACE} patch openstackcontrolplane openstack --type=json -p="[{'op': 'remove', 'path': '/spec/ovn/template/ovnController/nodeSelector'}]" || {
        echo "ERROR: Failed to patch openstackcontrolplane to enable ovncontroller"
        exit 1
    }

}

# 3.7 step 15 Delete the ovn-copy-data pod and the ovn-data-pvc.
delete_ovn_copy_data_15() {
    echo "Deleting ovn-copy-data pod"
    oc delete pod ovn-copy-data || {
        echo "ERROR: Failed to delete ovn-copy-data pod"
        exit 1
    }
    echo "Deleting ovn-data-pvc"
    oc delete pvc ovn-data || {
        echo "ERROR: Failed to delete ovn-data-pvc"
        exit 1
    }
    #    echo "Deleting ovn-data-cert secret"
    #    oc delete secret ovn-data-cert
}

# 3.7 step 16 Stop the OVN services in OSPdO.
stop_ospdo_ovn_svcs_16() {
    ServicesToStop=("tripleo_ovn_cluster_north_db_server.service"
        "tripleo_ovn_cluster_south_db_server.service")

    echo "Stopping systemd OpenStack services"
    for service in "${ServicesToStop[@]}"; do
        for i in {1..3}; do
            SSH_CMD=CONTROLLER${i}_SSH
            if [ -n "${!SSH_CMD}" ]; then
                echo "Stopping the $service in controller $i"
                if ${!SSH_CMD} sudo systemctl is-active "$service"; then
                    ${!SSH_CMD} sudo systemctl stop "$service"
                fi
            fi
        done
    done

    echo "Checking systemd OpenStack services"
    for service in "${ServicesToStop[@]}"; do
        for i in {1..3}; do
            SSH_CMD=CONTROLLER${i}_SSH
            if [ ! -z "${!SSH_CMD}" ]; then
                if ! ${!SSH_CMD} systemctl show "$service" | grep ActiveState=inactive >/dev/null; then
                    echo "ERROR: Service $service still running on controller $i"
                else
                    echo "OK: Service $service is not running on controller $i"
                fi
            fi
        done
    done
}

case $1 in
migrate)
    check_openstack
    ;;
retrieve-topology | 3_1)
    retrieve_topology_3_1
    ;;
deploy-backen-services | 3_2)
    deploy_backend_services_3_2
    ;;
stop-osp-services | 3_5)
    stop_osp_services_3_5
    ;;
create-mariadb-copy-data | cmcd)
    [ $# -lt 4 ] && {
        usage
        exit 1
    }
    create_mariadb_data "$2" "$3" "$4"
    ;;
delete-mariadb-copy-data | dmcd)
    [ $# -lt 2 ] && {
        usage
        exit 1
    }
    delete_mariadb_data "$2"
    ;;
migrate-mariadb | 3_6)
    migrate_mariadb_3_6
    ;;
create-ovn-copy-data | 3_7_1)
    create_ovn_copy_data_pod_1__2
    ;;
delete-ovn-copy-data | 3_7_15)
    delete_ovn_copy_data_15
    ;;
migrate-ovn-data | 3_7)
    create_ovn_copy_data_pod_1__2
    backup_ovn_dbs_3__4
    start_ovn_dbs_5__6
    update_ovn_db_schemas_7__9
    restore_ovn_dbs_10__12
    start_northd_13__14
    delete_ovn_copy_data_15
    stop_ospdo_ovn_svcs_16
    ;;
all)
    retrieve_topology_3_1
    deploy_backend_services_3_2
    stop_osp_services_3_5
    create_mariadb_data "${OSPDO_NAMESPACE}" "${OSPDO_INTERNAL_API_NET}" "${CONTROLLER_NODE}"
    migrate_mariadb_3_6
    create_ovn_copy_data_pod_1__2
    backup_ovn_dbs_3__4
    start_ovn_dbs_5__6
    update_ovn_db_schemas_7__9
    restore_ovn_dbs_10__12
    start_northd_13__14
    delete_ovn_copy_data_15
    stop_ospdo_ovn_svcs_16
    ;;
*)
    echo "Invalid command line argument. <$1>"
    usage
    ;;
esac
