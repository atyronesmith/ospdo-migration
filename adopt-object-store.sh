#!/bin/bash

. common.sh

SWIFT_PASSWORD=$(grep <"${PASSWORD_FILE}" ' SwiftPassword:' | awk -F ': ' '{ print $2; }') || {
    echo "ERROR: Failed to get SwiftPassword from ${PASSWORD_FILE}"
    exit 1
}   

export SWIFT_PASSWORD

oc set data secret/osp-secret "SwiftPassword=$SWIFT_PASSWORD" || {
    echo "ERROR: Failed to set SwiftPassword in osp-secret"
    exit 1
}

envsubst <yamls/swift-secret.yaml | oc apply -f - || {
    echo "ERROR: Failed to apply swift-secret.yaml"
    exit 1
}

oc get secret swift-secret -o jsonpath='{.data.password}' | base64 -d > swift-password.txt || {
    echo "ERROR: Failed to get SwiftPassword from swift-secret"
    exit 1
}