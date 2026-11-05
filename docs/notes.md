# Random notes

```sh
eval "$(pbpaste)"
kubectl-ate create actor my-counter-1 -a ate-demo-counter --template counter
kubectl-ate proxy actor my-counter-1 -a ate-demo-counter
```

A watchdog restarts the VM when the guest stops answering commands for a
minute, such as after the Mac sleeps. A cluster that is still starting doesn't
count. If the guest hangs again within ten minutes of a watchdog restart, the
watchdog gives up and the menu suggests Restart or Reset. Its actions go to
`app.log`.

State lives in `~/.ate-mac`: the Lima instance, the kubeconfig and `app.log`.
Quitting the app leaves the VM running. Use Stop and Quit to stop it too.

## How it works

- `lima/build.yaml` is the build VM: Ubuntu with rootful Docker, and no host
  mounts beyond the Substrate checkout that `build-image.sh` adds for the
  duration of the build.
- `scripts/shim/docker` is the `docker` the build sees. It runs docker in the
  build VM over `limactl shell`, so the Mac needs no container CLI.
- `guest/` is installed into the image. `ate-ctr` is the container engine the
  image carries; the boot service, `ate-mac-stats.py` and the app all call it
  instead of `docker`, so moving to another engine is a change to `ate-ctr` and
  `lima/build.yaml`. `ate-mac-boot.service` starts the kind node and then the
  registry on every boot, and restores the sysctls that a node restart loses.
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
