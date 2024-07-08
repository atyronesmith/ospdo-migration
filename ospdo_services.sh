#!/bin/bash

usage() {
    echo "Usage: $0 <start|stop>"
    echo "Description: This script starts or stops all OSPdO services."
    exit 1
}
# shellcheck source=common.sh
. common.sh

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

CONTROLLER_SSH="oc rsh -c openstackclient openstackclient ssh controller-0.ctlplane"

check_openstack() {
    ${CONTROLLER_SSH} openstack server list --all-projects -c ID -c Status | grep -E '\| .+ing \|' || {
        echo "ERROR: Instances are still running"
        exit 1
    }
    echo "OK: No instances are in state transition"
    ${CONTROLLER_SSH} openstack volume list --all-projects -c ID -c Status | grep -E '\| .+ing \|' | grep -vi error || {
        echo "ERROR: Volumes are still in state transition"
        exit 1
    }
    echo "OK: No volumes are in state transition"
    ${CONTROLLER_SSH} openstack volume backup list --all-projects -c ID -c Status | grep -E '\| .+ing \|' | grep -vi error || {
        echo "ERROR: Volume backups are still in state transition"
        exit 1
    }
    echo "OK: No volume backups are in state transition"
    ${CONTROLLER_SSH} openstack share list --all-projects -c ID -c Status | grep -E '\| .+ing \|' | grep -vi error || {
        echo "ERROR: Shares are still in state transition"
        exit 1
    }
    echo "OK: No shares are in state transition"
    ${CONTROLLER_SSH} openstack image list -c ID -c Status | grep -E '\| .+ing \|' || {
        echo "ERROR: Images are still in state transition"
        exit 1
    }
    echo "OK: No images are in state transition"
}

stop_openstack_systemd_services() {
    echo "Stopping systemd OpenStack services"
    for service in "${ServicesToStop[@]}"; do
        echo "Stopping the $service in controller"
        ${CONTROLLER_SSH} sudo systemctl is-active "$service" && {
            ${CONTROLLER_SSH} sudo systemctl stop "$service"
        }
    done
}

check_openstack_systemd_services() {
    echo "Checking systemd OpenStack services"
    for service in "${ServicesToStop[@]}"; do
        ${CONTROLLER_SSH} systemctl show "$service" | grep ActiveState=inactive >/dev/null || {
            echo "ERROR: Service $service still running on controller"
            exit 1
        }
            echo "OK: Service $service is not running on controller"
        
    done
}

stop_pcm_openstack_services() {
    echo "Stopping pacemaker OpenStack services"
    echo "Using controller to run pacemaker commands"
    for resource in "${PacemakerResourcesToStop[@]}"; do
        ${CONTROLLER_SSH} sudo pcs resource config "$resource" &>/dev/null
    done
}

check_pcm_openstack_services() {
    echo "Checking pacemaker OpenStack services"
    echo "Using controller to run pacemaker commands"
    for resource in "${PacemakerResourcesToStop[@]}"; do
        ${CONTROLLER_SSH} sudo pcs resource config "$resource" &>/dev/null && {
            ${CONTROLLER_SSH} sudo pcs resource status "$resource" | grep Started || {
                echo "ERROR: Service $resource is running"
            }
        }
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
