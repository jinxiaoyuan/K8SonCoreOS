#!/bin/bash

if [[ -s k8s.env ]]; then
    source k8s.env
else
    echo "Error: env config file <k8s.env> not exists..."
    exit 1
fi

ssl_dir="/etc/kubernetes/ssl"
apicrt_key_name="apiserver-key.pem"
apicrt_name="apiserver.pem"


if ! [[ -s ${ssl_dir}/ca.pem && -s ${ssl_dir}/${apicrt_key_name} && -s ${ssl_dir}/${apicrt_name} ]]; then
   sh gen_cert_for_k8s.sh ${ssl_dir} || exit 1
fi

sudo chmod 600 ${ssl_dir}/*-key.pem
sudo chown root:root ${ssl_dir}/*-key.pem

sudo mkdir -p /etc/flannel/ /run/flannel/
cat <<EOF > /etc/flannel/options.env
FLANNELD_IFACE=${ADVERTISE_IP}
FLANNELD_ETCD_ENDPOINTS=${ETCD_ENDPOINTS}
EOF

cat <<EOF > /etc/systemd/system/flanneld.service.d/40-ExecStartPre-symlink.conf
[Service]
ExecStartPre=/usr/bin/ln -sf /etc/flannel/options.env /run/flannel/options.env
EOF

# In order for flannel to manage the pod network in the cluster, Docker needs to be configured to use it.
## All we need to do is require that flanneld is running prior to Docker starting.
# Note: If the pod-network is being managed independently, this step can be skipped.
## See kubernetes networking for more detail.
cat <<EOF > /etc/systemd/system/docker.service.d/40-flannel.conf
[Unit]
Requires=flanneld.service
After=flanneld.service
EOF

############ kubelet ############
cat <<EOF > /etc/systemd/system/kubelet.service
[Service]
ExecStartPre=/usr/bin/mkdir -p /etc/kubernetes/manifests

Environment=KUBELET_VERSION=${K8S_VER}
ExecStart=/usr/lib/coreos/kubelet-wrapper \\
  --api-servers=http://127.0.0.1:8080 \\
  --network-plugin-dir=/etc/kubernetes/cni/net.d \\
  --network-plugin=${NETWORK_PLUGIN} \\
  --register-schedulable=false \\
  --allow-privileged=true \\
  --config=/etc/kubernetes/manifests \\
  --hostname-override=${ADVERTISE_IP} \\
  --cluster-dns=${DNS_SERVICE_IP} \\
  --cluster-domain=cluster.local
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

############ calico-node ###########
cat <<EOF > /etc/systemd/system/calico-node.service
[Unit]
Description=Calico per-host agent
Requires=network-online.target
After=network-online.target

[Service]
Slice=machine.slice
Environment=CALICO_DISABLE_FILE_LOGGING=true
Environment=HOSTNAME=${ADVERTISE_IP}
Environment=IP=${ADVERTISE_IP}
Environment=FELIX_FELIXHOSTNAME=${ADVERTISE_IP}
Environment=CALICO_NETWORKING=false
Environment=NO_DEFAULT_POOLS=true
Environment=ETCD_ENDPOINTS=${ETCD_ENDPOINTS}
ExecStart=/usr/bin/rkt run --inherit-env --stage1-from-dir=stage1-fly.aci \\
--volume=modules,kind=host,source=/lib/modules,readOnly=false \\
--mount=volume=modules,target=/lib/modules \\
--trust-keys-from-https quay.io/calico/node:v0.19.0

KillMode=mixed
Restart=always
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF


sudo systemctl daemon-reload
# curl -X PUT -d "value={\"Network\":\"$POD_NETWORK\",\"Backend\":{\"Type\":\"vxlan\"}}" "$ETCD_SERVER/v2/keys/coreos.com/network/config"