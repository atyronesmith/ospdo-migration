#!/bin/bash

CONTROLLER_NODE=$(oc get pods -o wide | grep launcher | awk {'print $7'})
NG_NODES=$(oc get nodes -o name | grep -v $CONTROLLER_NODE | sed 's#node/##g' | tr '\n' ' ')
NODE1=$(echo "${NG_NODES}" | cut -d ' ' -f 1)
NODE2=$(echo "${NG_NODES}" | cut -d ' ' -f 2)

cat << EOF > /tmp/node1_nncp.yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  labels:
    osp/interface: enp7s0
  name: enp7s0-${NODE1}
spec:
  desiredState:
    dns-resolver:
      config:
        search: []
        server:
        - 172.22.0.1
    interfaces:
    - description: internalapi vlan interface
      name: enp7s0.20
      state: up
      type: vlan
      vlan:
        base-iface: enp7s0
        id: 20
        reorder-headers: true
      ipv4:
        address:
        - ip: 172.17.0.5
          prefix-length: 24
        enabled: true
        dhcp: false
      ipv6:
        enabled: false
    - description: storage vlan interface
      name: enp7s0.21
      state: up
      type: vlan
      vlan:
        base-iface: enp7s0
        id: 21
        reorder-headers: true
      ipv4:
        address:
        - ip: 172.18.0.5
          prefix-length: 24
        enabled: true
        dhcp: false
      ipv6:
        enabled: false
    - description: tenant vlan interface
      name: enp7s0.22
      state: up
      type: vlan
      vlan:
        base-iface: enp7s0
        id: 22
        reorder-headers: true
      ipv4:
        address:
        - ip: 172.19.0.5
          prefix-length: 24
        enabled: true
        dhcp: false
      ipv6:
        enabled: false
    - description: storagemgmt vlan interface
      name: enp7s0.23
      state: up
      type: vlan
      vlan:
        base-iface: enp7s0
        id: 23
        reorder-headers: true
      ipv4:
        address:
        - ip: 172.20.0.5
          prefix-length: 24
        enabled: true
        dhcp: false
      ipv6:
        enabled: false
    - description: Configuring Bridge ospbr with interface enp1s0
      name: br-ctlplane
      mtu: 1500
      type: linux-bridge
      state: up
      bridge:
        options:
          stp:
            enabled: false
        port:
          - name: enp1s0
            vlan: {}
      ipv4:
        address:
        - ip: 172.22.0.51
          prefix-length: 24
        enabled: true
        dhcp: false
      ipv6:
        enabled: false
    - description: external bridge
      name: br-external
      type: linux-bridge
      mtu: 1500
      ipv6:
        enabled: false
      ipv4:
        enabled: false
      bridge:
        options:
          stp:
            enabled: false
        port:
        - name: enp6s0
  nodeSelector:
    kubernetes.io/hostname: ${NODE1}
    node-role.kubernetes.io/worker: ""
EOF

cat << EOF > /tmp/node2_nncp.yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  labels:
    osp/interface: enp7s0
  name: enp7s0-${NODE2}
spec:
  desiredState:
    dns-resolver:
      config:
        search: []
        server:
        - 172.22.0.1
    interfaces:
    - description: internalapi vlan interface
      name: enp7s0.20
      state: up
      type: vlan
      vlan:
        base-iface: enp7s0
        id: 20
        reorder-headers: true
      ipv4:
        address:
        - ip: 172.17.0.6
          prefix-length: 24
        enabled: true
        dhcp: false
      ipv6:
        enabled: false
    - description: storage vlan interface
      name: enp7s0.21
      state: up
      type: vlan
      vlan:
        base-iface: enp7s0
        id: 21
        reorder-headers: true
      ipv4:
        address:
        - ip: 172.18.0.6
          prefix-length: 24
        enabled: true
        dhcp: false
      ipv6:
        enabled: false
    - description: tenant vlan interface
      name: enp7s0.22
      state: up
      type: vlan
      vlan:
        base-iface: enp7s0
        id: 22
        reorder-headers: true
      ipv4:
        address:
        - ip: 172.19.0.6
          prefix-length: 24
        enabled: true
        dhcp: false
      ipv6:
        enabled: false
    - description: storagemgmt vlan interface
      name: enp7s0.23
      state: up
      type: vlan
      vlan:
        base-iface: enp7s0
        id: 23
        reorder-headers: true
      ipv4:
        address:
        - ip: 172.20.0.6
          prefix-length: 24
        enabled: true
        dhcp: false
      ipv6:
        enabled: false
    - description: Configuring Bridge ospbr with interface enp1s0
      name: br-ctlplane
      mtu: 1500
      type: linux-bridge
      state: up
      bridge:
        options:
          stp:
            enabled: false
        port:
          - name: enp1s0
            vlan: {}
      ipv4:
        address:
        - ip: 172.22.0.52
          prefix-length: 24
        enabled: true
        dhcp: false
      ipv6:
        enabled: false
    - description: external bridge
      name: br-external
      type: linux-bridge
      mtu: 1500
      ipv6:
        enabled: false
      ipv4:
        enabled: false
      bridge:
        options:
          stp:
            enabled: false
        port:
        - name: enp6s0
  nodeSelector:
    kubernetes.io/hostname: ${NODE2}
    node-role.kubernetes.io/worker: ""
EOF

oc apply -f /tmp/node1_nncp.yaml
oc apply -f /tmp/node2_nncp.yaml
