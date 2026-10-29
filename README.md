# PLUGIN REPO TEMPLATE

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

This is the template for new [Agent Substrate](https://github.com/agent-substrate/substrate)
plugin repositories. Name the repository for the plugin API it implements and
then its backend, as described in
[Plugins](https://github.com/agent-substrate/substrate/blob/8f0237461a0bd05492ef345b0e7b7ff2ed3c07f5/docs/dev/code-layout.md#plugins),
and replace this file with a README for the plugin.
=======
# ate-mac

A macOS menu-bar app that runs a local Agent Substrate on kind, inside a Lima
VM it brings along. Personal and experimental. Apple Silicon only.

Actors run under gVisor. The VM has no nested virtualization, so the microVM
sandbox class is not available.

## Build

Needs `limactl`, `docker` (the CLI only), `kubectl`, Go, and Xcode, plus a
Substrate checkout at `../s` (or set `SUBSTRATE_SRC`).

```sh
make image   # slow: builds a VM, installs Substrate into it, exports its disk
make dmg     # builds build/Substrate.app and build/Substrate.dmg
```

`make image` runs the Substrate kind dev flow (`hack/create-kind-cluster.sh`
and `ate-setup deploy ate-system --kind`) against the Docker daemon in a Lima
VM under `build/lima`. It then exports the VM disk as `build/substrate.qcow2`,
converting it in a second, short-lived Lima VM so the host needs no qemu.
`WITH_DEMO=0` leaves out the counter demo. `KEEP_VM=1` keeps the build VM.

## Use

Drag `Substrate.app` to Applications. The app is ad-hoc signed, so the first
time, right-click it and choose Open.

From the menu-bar icon:

- **Start** creates the VM from the bundled image on first use, then boots it.
  The icon fills in once every workload in `ate-system` is ready.
- **Copy Shell Setup** copies the `KUBECONFIG` and `PATH` exports for
  `kubectl` and the bundled `kubectl-ate`.
- **Reset** deletes the VM and recreates it from the bundled image. Use it after
  installing a newer build.
- **Settings** sets CPUs and memory (applied on next start) and disk size
  (applied on next reset).

```sh
eval "$(pbpaste)"
kubectl-ate create actor my-counter-1 -a ate-demo-counter --template counter
kubectl-ate proxy actor my-counter-1 -a ate-demo-counter
```

State lives in `~/.ate-mac`: the Lima instance, the kubeconfig and `app.log`.
Quitting the app leaves the VM running. Use Stop and Quit to stop it too.

## How it works

- `lima/build.yaml` is the build VM: Ubuntu with rootful Docker, no host mounts.
- `guest/` is installed into the image. `ate-mac-boot.service` starts the kind
  node and then the registry on every boot, and restores the sysctls that a
  node restart loses. `ate-mac-status` reports readiness to the app.
- `lima/runtime.yaml.tmpl` is the VM the app creates from the image. It
  forwards only the kube API server port and the Docker socket
  (`~/.ate-mac/lima/substrate/sock/docker.sock`).
- The app shells out to the bundled `limactl` with `LIMA_HOME=~/.ate-mac/lima`,
  so it never touches your own Lima instances.

The kind certificates expire a year after `make image`. Rebuild before then.
