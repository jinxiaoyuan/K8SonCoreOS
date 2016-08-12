#!/bin/bash
# Create by Jin Xiaoyuan at 2016-07-13 14:25


if [[ -s k8s.env ]]; then
    source k8s.env
else
    echo "Error: env config file <k8s.env> not exists..."
    exit 1
fi

DIR_OUT="${1:-k8s_sslkeys}"
mkdir -p ${DIR_OUT}
API_SERVER_SSLCNF="${DIR_OUT}/openssl.cnf"
WORKER_SSLCNF="${DIR_OUT}/worker-openssl.cnf"


######### Create a Cluster Root CA ##############
# First, we need to create a new certificate authority which will be used to sign the rest of our certificates.
openssl genrsa -out ${DIR_OUT}/ca-key.pem 2048
openssl req -x509 -new -nodes -key ${DIR_OUT}/ca-key.pem -days 10000 -out ${DIR_OUT}/ca.pem -subj "/CN=kube-ca"


####### Kubernetes API Server Keypair ##############
# create a config file
cat <<EOF > ${API_SERVER_SSLCNF}
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
countryName = CN
[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
DNS.3 = kubernetes.default.svc
DNS.4 = kubernetes.default.svc.cluster.local
IP.1 = ${K8S_SERVICE_IP}
IP.2 = ${MASTER_HOST}
EOF

# Generate the API Server Keypair
openssl genrsa -out ${DIR_OUT}/apiserver-key.pem 2048
openssl req -new -key ${DIR_OUT}/apiserver-key.pem -out ${DIR_OUT}/apiserver.csr -subj "/CN=kube-apiserver" -config ${API_SERVER_SSLCNF}
openssl x509 -req -in ${DIR_OUT}/apiserver.csr -CA ${DIR_OUT}/ca.pem -CAkey ${DIR_OUT}/ca-key.pem -CAcreateserial -out ${DIR_OUT}/apiserver.pem -days 365 -extensions v3_req -extfile ${API_SERVER_SSLCNF}


####### Kubernetes Worker Keypairs ##############
# create a config file
cat <<EOF > ${WORKER_SSLCNF}
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
IP.1 = \$ENV::WORKER_IP
EOF

# Generate the Kubernetes Worker Keypairs
for worker_ip in ${!WORKERS[@]}; do
    worker_fqdn=${WORKERS[${worker_ip}]}
    openssl genrsa -out ${DIR_OUT}/${worker_fqdn}-worker-key.pem 2048
    WORKER_IP=${worker_ip} openssl req -new -key ${DIR_OUT}/${worker_fqdn}-worker-key.pem -out ${DIR_OUT}/${worker_fqdn}-worker.csr -subj "/CN=${worker_fqdn}" -config ${WORKER_SSLCNF}
    WORKER_IP=${worker_ip} openssl x509 -req -in ${DIR_OUT}/${worker_fqdn}-worker.csr -CA ${DIR_OUT}/ca.pem -CAkey ${DIR_OUT}/ca-key.pem -CAcreateserial -out ${DIR_OUT}/${worker_fqdn}-worker.pem -days 365 -extensions v3_req -extfile ${WORKER_SSLCNF}
done


####### Generate the Cluster Administrator Keypair ##########
openssl genrsa -out ${DIR_OUT}/admin-key.pem 2048
openssl req -new -key ${DIR_OUT}/admin-key.pem -out ${DIR_OUT}/admin.csr -subj "/CN=kube-admin"
openssl x509 -req -in ${DIR_OUT}/admin.csr -CA ${DIR_OUT}/ca.pem -CAkey ${DIR_OUT}/ca-key.pem -CAcreateserial -out ${DIR_OUT}/admin.pem -days 365


echo "All certificates were generated to ${DIR_OUT} "
ls -l ${DIR_OUT}