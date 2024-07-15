#!/bin/bash

usage() {
    echo "Usage: $0 <check|check-systemd|check-pcm|stop-systemd|stop-pcm|start-systemd>"
    echo "Description: This script starts or stops OSPdO services."
    echo ""
    echo "Commands:"
    echo "  check: Check if OpenStack services are running"
    echo "  check-systemd: Check if OpenStack systemd services are running"
    echo "  check-pcm: Check if OpenStack pacemaker services are running"
    echo "  stop-systemd: Stop OpenStack systemd services"
    echo "  stop-pcm: Stop OpenStack pacemaker services"
    echo "  start-systemd: Start OpenStack systemd services"

    exit 1
}
# shellcheck source=common.sh
. common.sh
. common-ospdo.sh

# Update the services list to be stopped
ServicesToStop=("tripleo_horizon.service"
    "tripleo_keystone.service"
    "tripleo_barbican_api.service"
    "tripleo_barbican_worker.service"
    "tripleo_barbican_keystone_listener.service"
    "tripleo_cinder_api.service"
    "tripleo_cinder_api_cron.service"
    "tripleo_cinder_scheduler.service"
    "tripleo_cinder_volume.service"
    "tripleo_cinder_backup.service"
    "tripleo_glance_api.service"
    "tripleo_manila_api.service"
    "tripleo_manila_api_cron.service"
    "tripleo_manila_scheduler.service"
    "tripleo_neutron_api.service"
    "tripleo_placement_api.service"
    "tripleo_nova_api_cron.service"
    "tripleo_nova_api.service"
    "tripleo_nova_conductor.service"
    "tripleo_nova_metadata.service"
    "tripleo_nova_scheduler.service"
    "tripleo_nova_vnc_proxy.service"
    "tripleo_aodh_api_cron.service"
    "tripleo_aodh_evaluator.service"
    "tripleo_aodh_listener.service"
    "tripleo_aodh_notifier.service"
    "tripleo_ceilometer_agent_central.service"
    "tripleo_ceilometer_agent_compute.service"
    "tripleo_ceilometer_agent_ipmi.service"
    "tripleo_ceilometer_agent_notification.service"
    "tripleo_ovn_cluster_northd.service"
    "tripleo_ironic_neutron_agent.service"
    "tripleo_ironic_api.service"
    "tripleo_ironic_inspector.service"
    "tripleo_ironic_conductor.service")

PacemakerResourcesToStop=("openstack-cinder-volume"
    "openstack-cinder-backup"
    "openstack-manila-share")

check_openstack() {
    ${OS_CLIENT} openstack server list --all-projects -c ID -c Status | grep -E '\| .+ing \|' && {
        echo "ERROR: Instances are still running"
        exit 1
    }
    echo "OK: No instances are in state transition"

    ${OS_CLIENT} openstack volume list --all-projects -c ID -c Status | grep -E '\| .+ing \|' | grep -vi error && {
        echo "ERROR: Volumes are still in state transition"
        exit 1
    }
    echo "OK: No volumes are in state transition"

    ${OS_CLIENT} openstack volume backup list --all-projects -c ID -c Status | grep -E '\| .+ing \|' | grep -vi error && {
        echo "ERROR: Volume backups are still in state transition"
        exit 1
    }
    echo "OK: No volume backups are in state transition"

    # may emit an error if there is no shared file system service
    ${OS_CLIENT} openstack share list --all-projects -c ID -c Status | grep -E '\| .+ing \|' | grep -vi error && {
        echo "ERROR: Shares are still in state transition"
        exit 1
    }
    echo "OK: No shares are in state transition"

    ${OS_CLIENT} openstack image list -c ID -c Status | grep -E '\| .+ing \|' && {
        echo "ERROR: Images are still in state transition"
        exit 1
    }
    echo "OK: No images are in state transition"
}

start_openstack_systemd_services() {
    echo "Starting systemd OpenStack services"
    for service in "${ServicesToStop[@]}"; do
        for i in {1..3}; do
            SSH_CMD=CONTROLLER${i}_SSH
            if [ -n "${!SSH_CMD}" ]; then
                echo "Starting the $service in controller${i}"
                ${!SSH_CMD} sudo systemctl is-active "$service" || {
                    ${!SSH_CMD} sudo systemctl start "$service"
                }
            fi
        done
    done
}

stop_openstack_systemd_services() {
    echo "Stopping systemd OpenStack services"
    for service in "${ServicesToStop[@]}"; do
        for i in {1..3}; do
            SSH_CMD=CONTROLLER${i}_SSH
            if [ -n "${!SSH_CMD}" ]; then
                echo "Stopping the $service in controller${i}"
                ${!SSH_CMD} sudo systemctl is-active "$service" && {
                    ${!SSH_CMD} sudo systemctl stop "$service"
                }
            fi
        done
    done
}

check_openstack_systemd_services() {
    echo "Checking systemd OpenStack services"
    for service in "${ServicesToStop[@]}"; do
        for i in {1..3}; do
            SSH_CMD=CONTROLLER${i}_SSH
            if [ -n "${!SSH_CMD}" ]; then
                ${!SSH_CMD} systemctl show "$service" | grep ActiveState=inactive >/dev/null || {
                    echo "ERROR: Service $service still running on controller ${i}"
                    exit 1
                }
                echo "OK: Service $service is not running on controller ${i}"
            fi
        done
    done
}

stop_pcm_openstack_services() {
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

check_pcm_openstack_services() {
    echo "Checking pacemaker OpenStack services"
    for i in {1..3}; do
        SSH_CMD=CONTROLLER${i}_SSH
        if [ -n "${!SSH_CMD}" ]; then
            echo "Using controller $i to run pacemaker commands"
            for resource in "${PacemakerResourcesToStop[@]}"; do
                if ${!SSH_CMD} sudo pcs resource config "$resource" &>/dev/null; then
                    if ! ${!SSH_CMD} sudo pcs resource status "$resource" | grep Started; then
                        echo "OK: Service $resource is stopped"
                    else
                        echo "ERROR: Service $resource is started"
                    fi
                fi
            done
            break
        fi
    done
}

if [ $# -lt 1 ]; then
    echo "At least one command line argument is required."
    usage
fi

case $1 in
check)
    check_openstack
    ;;
check-systemd)
    check_openstack_systemd_services
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
start-systemd)
    start_openstack_systemd_services
    ;;
*)
    echo "Invalid command line argument."
    usage
    ;;
esac
