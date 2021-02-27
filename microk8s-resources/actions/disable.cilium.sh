#!/usr/bin/env bash

set -e

source $SNAP/actions/common/utils.sh

echo "Disabling Cilium"

KUBECONFIG="$SNAP_DATA/credentials/client.config" "$SNAP_DATA/bin/cilium" uninstall --wait

cilium=$(wait_for_service_shutdown "kube-system" "k8s-app=cilium")
if [[ $cilium == fail ]]
then
  echo "Cilium did not shut down on time. Proceeding."
fi

cilium=$(wait_for_service_shutdown "kube-system" "name=cilium-operator")
if [[ $cilium == fail ]]
then
  echo "Cilium operator did not shut down on time. Proceeding."
fi
run_with_sudo rm -f "$SNAP_DATA/args/cni-network/05-cilium.conf"
run_with_sudo rm -f "$SNAP_DATA/bin/cilium"
run_with_sudo rm -rf -- "$SNAP_DATA/var/run/cilium"
if $SNAP/sbin/ip link show "cilium_vxlan"
then
  echo "Deleting old cilium_vxlan link"
  run_with_sudo $SNAP/sbin/ip link delete "cilium_vxlan"
fi

# TODO: Remove when users have upgraded to this microk8s release
run_with_sudo rm -f "$SNAP_DATA/args/cni-network/05-cilium-cni.conf"
run_with_sudo rm -f "$SNAP_DATA/opt/cni/bin/cilium-cni"
run_with_sudo rm -rf -- $SNAP_DATA/bin/cilium-*
run_with_sudo rm -f "$SNAP_DATA/actions/cilium.yaml"
run_with_sudo rm -rf -- "$SNAP_DATA/actions/cilium"
run_with_sudo rm -rf -- "$SNAP_DATA/sys/fs/bpf"

if [ -e "$SNAP_DATA/var/lock/ha-cluster" ] && [ -e "$SNAP_DATA/args/cni-network/cni.yaml.disabled" ]
then
  echo "Restarting default cni"
  run_with_sudo mv "$SNAP_DATA/args/cni-network/cni.yaml.disabled" "$SNAP_DATA/args/cni-network/cni.yaml"
  "$SNAP/kubectl" "--kubeconfig=$SNAP_DATA/credentials/client.config" apply -f "$SNAP_DATA/args/cni-network/cni.yaml"
else
  echo "Restarting flanneld"
  set_service_expected_to_start flanneld

  run_with_sudo preserve_env snapctl start "${SNAP_NAME}.daemon-flanneld"
fi
echo "Cilium is terminating"
