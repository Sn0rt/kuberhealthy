#!/bin/bash

set -e

usage() {
    cat <<EOF
Generate certificate suitable for use with an Istio webhook service.

This script uses k8s' CertificateSigningRequest API to a generate a
certificate signed by k8s CA suitable for use with webhook
services. This requires permissions to create and approve CSR. See
https://kubernetes.io/docs/tasks/tls/managing-tls-in-a-cluster for
detailed explantion and additional instructions.

The server key/cert k8s CA cert are stored in a k8s secret.

usage: ${0} [OPTIONS]

The following flags are required.

       --service          Service name of webhook.
       --namespace        Namespace where webhook service and secret reside.
       --secret           Secret name for CA certificate and server certificate/key pair.
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case ${1} in
        --service)
            service="$2"
            shift
            ;;
        --secret)
            secret="$2"
            shift
            ;;
        --namespace)
            namespace="$2"
            shift
            ;;
        *)
            usage
            ;;
    esac
    shift
done

[ -z ${service} ] && service=kuberhealthy-webhook
[ -z ${secret} ] && secret=kuberhealthy-webhook-secrets
[ -z ${namespace} ] && namespace=kuberhealthy

if [ ! -x "$(command -v openssl)" ]; then
    echo "Unable to find openssl binary"
    exit 1
fi

csrName=${service}.${namespace}
tmpdir=$(mktemp -d)
echo "Creating certificate data in temp directory: ${tmpdir}"

cat <<EOF >> ${tmpdir}/csr.conf
[ req ]
req_extensions = v3_req
distinguished_name = req_distinguished_name

[ req_distinguished_name ]

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${service}
DNS.2 = ${service}.${namespace}
DNS.3 = ${service}.${namespace}.svc
EOF

echo "Creating new CA data for $(kubectl config current-context):"

openssl genrsa -out ${tmpdir}/server-key.pem 2048
openssl req -new -key ${tmpdir}/server-key.pem -subj "/CN=${service}.${namespace}.svc" -out ${tmpdir}/server.csr -config ${tmpdir}/csr.conf

# Clean-up any previously created CSRs for our service.
echo "Deleting previous certificate signing request with name ${csrName}:"
echo "kubectl delete csr ${csrName}"
kubectl delete csr ${csrName} 2>/dev/null || true

# Create a server cert and key CSR and send to k8s API
echo "Creating certificate signing request in cluster:"
cat <<EOF | kubectl create -f -
apiVersion: certificates.k8s.io/v1beta1
kind: CertificateSigningRequest
metadata:
  name: ${csrName}
spec:
  groups:
  - system:authenticated
  request: $(cat ${tmpdir}/server.csr | base64 | tr -d '\n')
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF

# Verify CSR has been created.
while true; do
    echo "kubectl get csr ${csrName} | grep ${csrName}"
    kubectl get csr ${csrName} | grep ${csrName}
    if [ "$?" -eq 0 ]; then
        break
    fi
done

# Approve and fetch the signed certificate.
echo "kubectl certificate approve ${csrName}"
kubectl certificate approve ${csrName}

# Verify certificate has been signed.
for x in $(seq 10); do
    echo "kubectl get csr ${csrName} -o jsonpath='{.status.certificate}'"
    serverCert=$(kubectl get csr ${csrName} -o jsonpath='{.status.certificate}')
    if [[ ${serverCert} != '' ]]; then
        break
    fi
    sleep 1
done
if [[ ${serverCert} == '' ]]; then
    echo "ERROR: After approving csr ${csrName}, the signed certificate did not appear on the resource. Giving up after 10 attempts." >&2
    exit 1
fi
echo ${serverCert} | openssl base64 -d -A -out ${tmpdir}/server-cert.pem

# Create the secret with CA cert and server cert and key data.
echo "Creating secret with name ${secret}:"
echo "kubectl create secret generic ${secret} --from-file=key.pem=${tmpdir}/server-key.pem --from-file=cert.pem=${tmpdir}/server-cert.pem --dry-run=client -o yaml | kubectl -n ${namespace} apply -f -"
kubectl create secret generic ${secret} \
        --from-file=key.pem=${tmpdir}/server-key.pem \
        --from-file=cert.pem=${tmpdir}/server-cert.pem \
        --dry-run=client -o yaml |
    kubectl -n ${namespace} apply -f -

if [ ! command -v jq >/dev/null 2>&1 ]
then
    cat << EOF

Copy the CA data and replace the CA_BUNDLE value in validating-webhook.yaml and mutating-webhook.yaml
You can display this data with the following command:
    
    kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.certificate-authority-data}'
EOF
else
    cat << EOF

Copy the CA data and replace the CA_BUNDLE value in validating-webhook.yaml and mutating-webhook.yaml
You can display this data with the following command:

    kubectl config view --raw --flatten -o json | jq -r '.clusters[] | select(.name == "'$(kubectl config current-context)'") | .cluster."certificate-authority-data"'
EOF
fi