# Points docker, kubectl and kubectl-ate at the Substrate app's VM. run.sh
# and cleanup.sh source this; source it yourself to run the commands by hand:
#
#   source example/env.sh
#
# ATE_MAC_STATE overrides the state directory (default ~/.ate-mac).
# SUBSTRATE_APP overrides where Substrate.app is (default /Applications).

ATE_MAC_STATE="${ATE_MAC_STATE:-${HOME}/.ate-mac}"
SUBSTRATE_APP="${SUBSTRATE_APP:-/Applications/Substrate.app}"

export KUBECONFIG="${ATE_MAC_STATE}/kubeconfig"
# The app forwards the VM's Docker socket here, so docker builds and pushes
# run inside the VM.
export DOCKER_HOST="unix://${ATE_MAC_STATE}/lima/substrate/sock/docker.sock"
export PATH="${SUBSTRATE_APP}/Contents/Resources/bin:${PATH}"
