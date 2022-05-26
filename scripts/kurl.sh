#!/bin/bash

# These should be passed in via custom_provisioning_env
#APP='puppet-application-manager'
#CHANNEL='standalone'

set -e

################################
# Ensure packages are up to date
#echo " * Upgrade packages"
#sudo yum upgrade -y
# Can't do this right now because kURL v2022.05.19-0 doesn't have rhel 8.6
# support, and this basically transforms the rhel-8.4 iso we start with to
# 8.6, as far as the installer script is concerned.

#############################
# Install Kubernetes via Kurl
echo " * Installing Kubernetes via Kurl"
echo " * Installing ${APP}-${CHANNEL}"
curl -sSLO "https://kurl.sh/bundle/${APP}-${CHANNEL}.tar.gz"
tar xzf "${APP}-${CHANNEL}.tar.gz"
rm "${APP}-${CHANNEL}.tar.gz"

cat << EOF > patch.yaml
apiVersion: cluster.kurl.sh/v1beta1
kind: Installer
metadata:
  name: patch
spec:
  # Disable Prometheus. Not necessary for testing and reduces resource requirements.
  prometheus:
    version: ''
EOF

sudo -E bash install.sh airgap preserve-selinux-config installer-spec-file=patch.yaml

# Stop pods and Kubelet before shutdown. The packer build fills the disk with 0s to compress the
# image, which otherwise causes Kubelet to start erasing unused images that we still need. Other
# pods may also be paused in an unexpected state if left running.
echo " * Draining node"
kubectl drain localhost.localdomain --delete-local-data --ignore-daemonsets

echo " * Stopping kubelet"
systemctl stop kubelet
systemctl disable kubelet

if [ "$(pgrep -c -f /usr/bin/containerd-shim-runc-v2)" != "0" ]; then
  echo " * Clearing out any old containers"
  systemctl start containerd
  mapfile -t ready_pods < <(crictl pods -q --state ready)
  for p in "${ready_pods[@]}"; do
    crictl stopp "${p}" || true
  done
  mapfile -t pods < <(crictl pods -q)
  for p in "${pods[@]}"; do
    crictl rmp -f "${p}" || true
  done
fi

echo " * Stopping containerd"
systemctl stop containerd
systemctl disable containerd

echo " * Preparing kubernetes restart init script"
mv /tmp/restart_k8s.sh /usr/sbin/restart_k8s.sh
mv /tmp/check_k8s_restart_state.sh /usr/sbin/check_k8s_restart_state.sh
mv /tmp/bash_profile_k8s_status.sh /usr/sbin/bash_profile_k8s_status.sh
chown root:root /usr/sbin/restart_k8s.sh /usr/sbin/check_k8s_restart_state.sh /usr/sbin/bash_profile_k8s_status.sh
chmod 755 /usr/sbin/restart_k8s.sh /usr/sbin/check_k8s_restart_state.sh /usr/sbin/bash_profile_k8s_status.sh

cat > "/usr/lib/systemd/system/k8s-restart.service" <<SERVICE
[Unit]
Description=Kubernetes network restart for abs checkout
After=network-online.target rc-local.service
Wants=network-online.target rc-local.service

[Service]
Type=oneshot
RemainAfterExit=true
Environment=KUBECONFIG=/root/.kube/config
ExecStart=/usr/sbin/restart_k8s.sh

[Install]
WantedBy=multi-user.target
SERVICE
systemctl enable k8s-restart.service

echo " * Modifying ekco-reboot.service to depend on k8s-restart.service"
sed -i -e '/After=containerd.service/ a After=k8s-restart.service' /etc/systemd/system/ekco-reboot.service

###################################################
# Provide login k8s status and password reset info.

sed -i "$ a \\\n/usr/sbin/bash_profile_k8s_status.sh" /root/.bash_profile
