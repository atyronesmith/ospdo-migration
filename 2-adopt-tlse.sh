#!/bin/bash

. common.sh

# For OSPdO installed by director-dev-tools, the server host runs the freeipa server as a container...
IPA_SSH="podman exec -ti freeipa-server"

#To locate the CA certificate and key, list all the certificates inside your NSSDB:
$IPA_SSH certutil -L -d /etc/pki/pki-tomcat/alias || {
    echo "Unable to list certificates..."
    exit 1
}

# Certificate Nickname                                         Trust Attributes
#                                                              SSL,S/MIME,JAR/XPI

# caSigningCert cert-pki-ca                                    CTu,Cu,Cu
# ocspSigningCert cert-pki-ca                                  u,u,u
# subsystemCert cert-pki-ca                                    u,u,u
# auditSigningCert cert-pki-ca                                 u,u,Pu
# Server-Cert cert-pki-ca                                      u,u,u

# Export the certificate and key from the /etc/pki/pki-tomcat/alias directory:
$IPA_SSH pk12util -o /tmp/freeipa.p12 -n 'caSigningCert cert-pki-ca' \
    -d /etc/pki/pki-tomcat/alias -k /etc/pki/pki-tomcat/alias/pwdfile.txt \
    -w /etc/pki/pki-tomcat/alias/pwdfile.txt || {
    echo "Unable to extract caSigningCert..."
    exit 1
}

# Create the secret that contains the root CA
oc get secret rootca-internal -n ${OSP18_NAMESPACE} >/dev/null 2>&1 || {
    oc create secret generic rootca-internal -n ${OSP18_NAMESPACE} || {
        echo "Unable to create secret rootca-internal..."
        exit 1
    }
}

oc patch secret rootca-internal -n ${OSP18_NAMESPACE} -p="{\"data\":{\"ca.crt\": \
    \"$($IPA_SSH openssl pkcs12 -in /tmp/freeipa.p12 -passin file:/etc/pki/pki-tomcat/alias/pwdfile.txt \
    -nokeys | openssl x509 | base64 -w 0)\"}}" || {
    echo "Unable to patch secret ca.crt."
    exit 1
}

oc patch secret rootca-internal -n ${OSP18_NAMESPACE} -p="{\"data\":{\"tls.crt\": \
    \"$($IPA_SSH openssl pkcs12 -in /tmp/freeipa.p12 -passin file:/etc/pki/pki-tomcat/alias/pwdfile.txt \
    -nokeys | openssl x509 | base64 -w 0)\"}}" || {
    echo "Unable to patch secret tls.crt."
    exit 1
}

OPENSSL_OPTION_NOENC='-noenc'
$IPA_SSH openssl version | grep '1.1.1' >/dev/null 2>&1 && {
    OPENSSL_OPTION_NOENC='-nodes'
}

# openssl pkcs12 version is 1.1.1 in what is deployed
#  documentation assumes version 3+
oc patch secret rootca-internal -n ${OSP18_NAMESPACE} -p="{\"data\":{\"tls.key\": \
    \"$($IPA_SSH openssl pkcs12 -in /tmp/freeipa.p12 -passin file:/etc/pki/pki-tomcat/alias/pwdfile.txt \
    -nocerts "${OPENSSL_OPTION_NOENC}" | openssl rsa | base64 -w 0)\"}}" || {
    echo "Unable to patch secret tls.crt."
    exit 1
}

envsubst <yamls/issuer.yaml | oc apply -f - || {
    echo "Unable to apply Issuer!"
    exit 1
}

issuer_status=$(oc get issuers -n ${OSP18_NAMESPACE} -o jsonpath='{.items[0].status.conditions[0].status}') || {
    echo "Failed to get issuers status."
    exit 1
}

[[ "$issuer_status" == "True" ]] && echo "Issuer Ready" || echo "Issuer status is not True"



