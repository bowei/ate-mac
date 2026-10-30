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

`make dmg` scripts Finder to lay out the DMG window, so macOS may ask once to
let your terminal control Finder. Eject any mounted volume named Substrate
first.

`make test` runs the app's unit tests.

`make image` runs the Substrate kind dev flow (`hack/create-kind-cluster.sh`
and `ate-setup deploy ate-system --kind`) against the Docker daemon in a Lima
VM under `build/lima`. It then exports the VM disk as `build/substrate.qcow2`,
converting it in a second, short-lived Lima VM so the host needs no qemu.
`WITH_DEMO=0` leaves out the counter demo. `KEEP_VM=1` keeps the build VM.

The build slims the cluster for a laptop. It removes kind's observability stack
(the otel collector, Prometheus and Jaeger) and turns telemetry export off,
runs one replica of `ate-api-server` and `ate-idp-server`, and deletes the
bucket-init job once it has run. `WITH_OBSERVABILITY=1` keeps the
observability stack.

## Use

Drag `Substrate.app` to Applications. The app is ad-hoc signed, so the first
time, right-click it and choose Open.

Click the menu bar icon to open the status panel:

- The panel shows the VM's CPU and memory, and each pod's health, CPU and
  memory, grouped into Substrate, Workers and Kubernetes. It refreshes every
  2 seconds while open.
- **Start** creates the VM from the bundled image on first use, then boots it.
  The icon fills in once every pod in `ate-system` is healthy.
- **Copy Shell Setup** copies the `KUBECONFIG` and `PATH` exports for
  `kubectl` and the bundled `kubectl-ate`.
- **Restart** stops the VM, forcing it if the guest doesn't shut down, and
  starts it again.
- **Reset** deletes the VM and recreates it from the bundled image. Use it after
  installing a newer build.
- **Settings** sets CPUs and memory (applied on next start) and disk size
  (applied on next reset). The defaults are 4 CPUs, 6 GiB of memory and a
  40 GiB disk. The disk file only grows as the guest uses it.

```sh
eval "$(pbpaste)"
kubectl-ate create actor my-counter-1 -a ate-demo-counter --template counter
kubectl-ate proxy actor my-counter-1 -a ate-demo-counter
```

To build and run your own actor from a Dockerfile, see
[`example/`](example/README.md).

A watchdog restarts the VM when the guest stops answering commands for a
minute, such as after the Mac sleeps. A cluster that is still starting doesn't
count. If the guest hangs again within ten minutes of a watchdog restart, the
watchdog gives up and the menu suggests Restart or Reset. Its actions go to
`app.log`.

State lives in `~/.ate-mac`: the Lima instance, the kubeconfig and `app.log`.
Quitting the app leaves the VM running. Use Stop and Quit to stop it too.

## How it works

- `lima/build.yaml` is the build VM: Ubuntu with rootful Docker, no host mounts.
- `guest/` is installed into the image. `ate-mac-boot.service` starts the kind
  node and then the registry on every boot, and restores the sysctls that a
  node restart loses.
- `app/Resources/ate-mac-stats.py` ships in the app. The app pipes it into the
  guest on every poll to get each pod's health, CPU and memory, and the VM's
  CPU and memory. A pod counts as healthy when Kubernetes reports it Ready and
  the node runs a ready sandbox for it, because right after boot the pod status
  still shows the state from before shutdown.
- `lima/runtime.yaml.tmpl` is the VM the app creates from the image. It
  forwards only the kube API server port and the Docker socket
  (`~/.ate-mac/lima/substrate/sock/docker.sock`).
- The app shells out to the bundled `limactl` with `LIMA_HOME=~/.ate-mac/lima`,
  so it never touches your own Lima instances.

The app icon is `ate-logo-with-border.png`, from the Substrate logo, Yolo the
octopus by Nan Hockin. The logo is licensed under Apache-2.0 or CC-BY-4.0; see
`logo/LICENSE` in the Substrate checkout.

The kind certificates expire a year after `make image`. Rebuild before then.
