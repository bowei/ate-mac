#!/usr/bin/env bash
# Starts the kind node and the registry on every boot, in that order. Both have
# their restart policy turned off so the node always gets the first address on
# the kind network, which is the one its certificates and etcd were set up with.
set -o errexit -o nounset -o pipefail

node="kind-control-plane"
registry="kind-registry"

ate-ctr start "${node}"
ate-ctr start "${registry}"

# A restarted node container gets a fresh network namespace, so sysctls set by
# hack/create-kind-cluster.sh are gone. gVisor pod-to-pod networking needs them.
ate-ctr exec "${node}" sysctl -w net.ipv4.conf.all.proxy_arp=1
ate-ctr exec "${node}" sysctl -e -w net.ipv6.conf.all.proxy_ndp=1
