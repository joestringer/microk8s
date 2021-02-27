#!/usr/bin/env bash

set -e

source $SNAP/actions/common/utils.sh

CA_CERT=/snap/core18/current/etc/ssl/certs/ca-certificates.crt

ARCH=$(arch)
# TODO: Remove when Cilium v1.10 is released
if ! [ "${ARCH}" = "amd64" ]; then
  echo "Cilium is not available for ${ARCH}" >&2
  exit 1
fi

echo "Restarting kube-apiserver"
refresh_opt_in_config "allow-privileged" "true" kube-apiserver
restart_service apiserver

# Reconfigure kubelet/containerd to pick up the new CNI config and binary.
echo "Restarting kubelet"
refresh_opt_in_config "cni-bin-dir" "\${SNAP_DATA}/opt/cni/bin/" kubelet
restart_service kubelet

set_service_not_expected_to_start flanneld
run_with_sudo preserve_env snapctl stop "${SNAP_NAME}.daemon-flanneld"
remove_vxlan_interfaces

if grep -qE "bin_dir.*SNAP}\/" $SNAP_DATA/args/containerd-template.toml; then
  echo "Restarting containerd"
  run_with_sudo "${SNAP}/bin/sed" -i 's;bin_dir = "${SNAP}/opt;bin_dir = "${SNAP_DATA}/opt;g' "$SNAP_DATA/args/containerd-template.toml"
  run_with_sudo preserve_env snapctl restart "${SNAP_NAME}.daemon-containerd"
fi

echo "Enabling Cilium"

read -ra CILIUM_VERSION <<< "$1"

if [ -f "${SNAP_DATA}/bin/cilium" ]
then
  echo "Cilium is already installed, use microk8s.cilium to upgrade."
else
  SOURCE_URI="https://github.com/cilium/cilium-cli/releases/latest/download/"
  NAMESPACE=kube-system

  echo "Fetching the latest cilium command line client."
  run_with_sudo mkdir -p "${SNAP_DATA}/tmp/cilium"
  (cd "${SNAP_DATA}/tmp/cilium"
  run_with_sudo "${SNAP}/usr/bin/curl" --cacert $CA_CERT -L $SOURCE_URI/cilium-linux-${ARCH}.tar.gz -o "$SNAP_DATA/tmp/cilium/cilium.tar.gz"
  run_with_sudo gzip -f -d "$SNAP_DATA/tmp/cilium/cilium.tar.gz"
  run_with_sudo tar -xf "$SNAP_DATA/tmp/cilium/cilium.tar")

  run_with_sudo mkdir -p "$SNAP_DATA/bin/"
  run_with_sudo mv "$SNAP_DATA/tmp/cilium/cilium" "$SNAP_DATA/bin/cilium"
  run_with_sudo chmod +x "$SNAP_DATA/bin"
  run_with_sudo chmod +x "$SNAP_DATA/bin/cilium"

  # TODO: Remove when Cilium v1.10 is released
  run_with_sudo mv "$SNAP_DATA/args/cni-network/cni.conf" "$SNAP_DATA/args/cni-network/10-kubenet.conf" 2>/dev/null || true
  run_with_sudo mv "$SNAP_DATA/args/cni-network/flannel.conflist" "$SNAP_DATA/args/cni-network/20-flanneld.conflist" 2>/dev/null || true

  ${SNAP}/microk8s-status.wrapper --wait-ready >/dev/null
  if [ -z "$CILIUM_VERSION" ]; then
    KUBECONFIG="$SNAP_DATA/credentials/client.config" ${SNAP_DATA}/bin/cilium install --wait
  else
    KUBECONFIG="$SNAP_DATA/credentials/client.config" ${SNAP_DATA}/bin/cilium install --wait --version "v$(echo $CILIUM_VERSION | sed 's/^v//')"
  fi

  # TODO: Remove when Cilium v1.10 is released
  if [ -e "$SNAP_DATA/args/cni-network/cni.yaml" ]
  then
    "$SNAP/kubectl" "--kubeconfig=$SNAP_DATA/credentials/client.config" delete -f "$SNAP_DATA/args/cni-network/cni.yaml"
    # give a bit slack before moving the file out, sometimes it gives out this error "rpc error: code = Unknown desc = checkpoint in progress".
    sleep 2s
    run_with_sudo mv "$SNAP_DATA/args/cni-network/cni.yaml" "$SNAP_DATA/args/cni-network/cni.yaml.disabled"
  fi

  run_with_sudo rm -rf -- "$SNAP_DATA/tmp/cilium"

  KUBECONFIG="$SNAP_DATA/credentials/client.config" ${SNAP_DATA}/bin/cilium status --wait
fi

echo "Cilium is enabled"
