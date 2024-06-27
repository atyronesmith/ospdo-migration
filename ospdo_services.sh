#!/bin/bash

usage() {
    echo "Usage: $0 <start|stop>"
    echo "Description: This script starts or stops all OSPdO services."
    exit 1
}

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
    "tripleo_aodh_api.service"
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
    if ${CONTROLLER_SSH} openstack server list --all-projects -c ID -c Status | grep -E '\| .+ing \|'; then
        echo "ERROR: Instances are still running"
    else
        echo "OK: No instances are in state transition"
    fi
    if ${CONTROLLER_SSH} openstack volume list --all-projects -c ID -c Status | grep -E '\| .+ing \|' | grep -vi error; then
        echo "ERROR: Volumes are still in state transition"
    else
        echo "OK: No volumes are in state transition"
    fi
    if ${CONTROLLER_SSH} openstack volume backup list --all-projects -c ID -c Status | grep -E '\| .+ing \|' | grep -vi error; then
        echo "ERROR: Volume backups are still in state transition"
    else
        echo "OK: No volume backups are in state transition"
    fi
    if ${CONTROLLER_SSH} openstack share list --all-projects -c ID -c Status | grep -E '\| .+ing \|' | grep -vi error; then
        echo "ERROR: Shares are still in state transition"
    else
        echo "OK: No shares are in state transition"
    fi
    if ${CONTROLLER_SSH} openstack image list -c ID -c Status | grep -E '\| .+ing \|'; then 
        echo "ERROR: Images are still in state transition"
    else
        echo "OK: No images are in state transition"
    fi
}

stop_openstack_systemd_services() {
    echo "Stopping systemd OpenStack services"
    for service in ${ServicesToStop[*]}; do
        echo "Stopping the $service in controller"
        if ${CONTROLLER_SSH} sudo systemctl is-active "$service"; then
            ${CONTROLLER_SSH} sudo systemctl stop "$service"
        fi
    done
}

check_openstack_systemd_services() {
    echo "Checking systemd OpenStack services"
    for service in ${ServicesToStop[*]}; do
        if ! ${CONTROLLER_SSH} systemctl show "$service" | grep ActiveState=inactive >/dev/null; then
            echo "ERROR: Service $service still running on controller"
        else
            echo "OK: Service $service is not running on controller"
        fi
    done
}

stop_pcm_openstack_services() {
    echo "Stopping pacemaker OpenStack services"
    echo "Using controller to run pacemaker commands"
    for resource in ${PacemakerResourcesToStop[*]}; do
        if ${CONTROLLER_SSH} sudo pcs resource config "$resource" &>/dev/null; then
            echo "Stopping $resource"
            ${CONTROLLER_SSH} sudo pcs resource disable "$resource"
        else
            echo "Service $resource not present"
        fi
    done
}

check_pcm_openstack_services() {
    echo "Checking pacemaker OpenStack services"
    echo "Using controller to run pacemaker commands"
    for resource in ${PacemakerResourcesToStop[*]}; do
        if ${CONTROLLER_SSH} sudo pcs resource config "$resource" &>/dev/null; then
            if ! ${CONTROLLER_SSH} sudo pcs resource status "$resource" | grep Started; then
                echo "OK: Service $resource is stopped"
            else
                echo "ERROR: Service $resource is started"
            fi
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
