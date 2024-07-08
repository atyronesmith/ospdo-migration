#!/bin/bash
# shellcheck source=common.sh
. common.sh
.common-ospdo.sh

PODIFIED_MARIADB_IP=$(oc get svc --selector "mariadb/name=openstack" -ojsonpath='{.items[0].spec.clusterIP}')
PODIFIED_CELL1_MARIADB_IP=$(oc get svc --selector "mariadb/name=openstack-cell1" -ojsonpath='{.items[0].spec.clusterIP}')
PODIFIED_DB_ROOT_PASSWORD=$(oc get -o json secret/osp-secret | jq -r .data.DbRootPassword | base64 -d)

# The CHARACTER_SET and collation should match the source DB
# if the do not then it will break foreign key relationships
# for any tables that are created in the future as part of db sync
CHARACTER_SET=utf8
COLLATION=utf8_general_ci

declare -A SOURCE_GALERA_MEMBERS
SOURCE_GALERA_MEMBERS=(
    ["controller-0"]=172.17.0.160
    # ...
)

# Function to delete MariaDB data
# This function checks if the pod 'mariadb-copy-data' and the persistent volume claim 'mariadb-data' exist,
# and deletes them if they do.
delete_mariadb_data() {
    if oc get pod mariadb-copy-data; then
        oc delete pod mariadb-copy-data
    fi
    if oc get pvc mariadb-data; then
        oc delete pvc mariadb-data
    fi
}

# Function to create MariaDB data Pod
# This function checks if the PVC (Persistent Volume Claim) 'mariadb-data' exists. If not, it creates the PVC using 'mariadb-copy-data-pvc.yaml' template.
# It then checks if the pod 'mariadb-copy-data' exists. If not, it creates the pod using 'mariadb-copy-data-pod.yaml' template.
# After that, it checks the WSREP (Write Set Replication) status of each database node specified in the 'SOURCE_GALERA_MEMBERS' array.
# If the WSREP status is 'Synced' for all nodes, the function returns successfully.
# If any error occurs during the process, appropriate error messages are displayed and the function exits with a non-zero status code.


create_mariadb_data() {
    if ! oc get pvc mariadb-data; then
        envsubst <yamls/mariadb-copy-data-pvc.yaml | oc apply -f -
        if ! oc wait --for=jsonpath='{status.phase}'=Bound --timeout=30s - pvc/mariadb-data; then
            echo "ERROR: PVC mariadb-copy-data-pvc did not bind"
            exit 1
        fi
    fi

    if ! oc get pod mariadb-copy-data; then
        if ! envsubst <yamls/mariadb-copy-data-pod.yaml | oc apply -f -; then
            echo "ERROR: Failed to create mariadb-copy-data pod"
            exit 1
        fi
        if ! oc wait --for condition=Ready --timeout=30s pod/mariadb-copy-data; then
            echo "ERROR: mariadb-copy-data pod did not start"
            exit 1
        fi
    fi

    for i in "${!SOURCE_GALERA_MEMBERS[@]}"; do
        echo "Checking for the database node $i WSREP status Synced"
        oc rsh mariadb-copy-data mysql \
            -h "${SOURCE_GALERA_MEMBERS[$i]}" -uroot -p"$SOURCE_DB_ROOT_PASSWORD" \
            -e "show global status like 'wsrep_local_state_comment'" |
            grep -qE "\bSynced\b"
    done
}

create_mariadb_data

# List databases on source 
oc rsh mariadb-copy-data mysql -h "${SOURCE_MARIADB_IP}" -uroot -p"${SOURCE_DB_ROOT_PASSWORD}" -e "SHOW databases;"

# List databases on podified database
oc run mariadb-client --image "$MARIADB_IMAGE" -i --rm --restart=Never -- \
    mysql -rsh "$PODIFIED_MARIADB_IP" -uroot -p"$PODIFIED_DB_ROOT_PASSWORD" -e 'SHOW databases;'
oc run mariadb-client --image "$MARIADB_IMAGE" -i --rm --restart=Never -- \
    mysql -rsh "$PODIFIED_CELL1_MARIADB_IP" -uroot -p"$PODIFIED_DB_ROOT_PASSWORD" -e 'SHOW databases;'

# Create a dump of all databases on the source MariaDB
oc rsh mariadb-copy-data <<EOF
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

# Check if at least one command line argument is provided
if [ $# -lt 1 ]; then
    echo "At least one command line argument is required."
    usage
fi

case $1 in
migrate)
    check_openstack
    ;;
cleanup)
    delete_mariadb_data
    ;;
check-pcm)
    check_pcm_openstack_services
    ;;
stop-systemd)
    stop_openstack_systemd_services
    ;;
stop-pcm)
    stop_pcm_openstack_services
    ;;
start)
    echo "Starting OSPdO services..."
    # Add code to start OSPdO services here
    ;;
stop)
    echo "Stopping OSPdO services..."
    # Add code to stop OSPdO services here
    ;;
*)
    echo "Invalid command line argument."
    usage
    ;;
esac
