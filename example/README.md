# Example: a hello-world actor from a Dockerfile

This builds a small HTTP server from `hello/Dockerfile` and runs it as a
Substrate actor on the Substrate app's cluster. It only needs the app (running,
with the icon filled in) and the `docker` and `kubectl` CLIs on the Mac. You
don't need a Docker daemon or a Substrate checkout.

```sh
example/run.sh
```

Then talk to the actor:

```sh
source example/env.sh
kubectl ate proxy actor hello-1 -a ate-hello   # serves localhost:8000
curl localhost:8000                            # in another terminal
# Hello, world from actor! (request 1)
```

Suspend it, then send another request. The request wakes the actor, and the
count continues, because the template snapshots process memory:

```sh
kubectl ate suspend actor hello-1 -a ate-hello
curl localhost:8000
# Hello, world from actor! (request 2)
```

Edit `hello/main.go` and run `run.sh` again to rebuild. Templates can't be
changed, so the script deletes and recreates the template and the actor.

Clean up with `example/cleanup.sh`. It deletes the actor, the template, the
atespace and the namespace, which frees the worker's memory.

## Files

- `hello/main.go`, `hello/Dockerfile`: the actor. It's a static Go binary on
  an empty image that listens on port 80, which is the port `kubectl ate proxy`
  forwards to. It serves `/readyz` for the wakeup probe.
- `workerpool.yaml`: the Kubernetes side. It holds the `ate-hello` namespace and
  a `WorkerPool` with one gVisor worker, labelled `workload: hello`.
- `actor-template.yaml`: the Substrate side. It holds the `hello`
  ActorTemplate in the `ate-hello` atespace, which picks workers by that label.
  It isn't a Kubernetes object: `kubectl ate create actor-template -f` creates
  it through the Substrate API.
- `env.sh`: points `docker`, `kubectl` and `kubectl-ate` at the app's VM.
- `run.sh`, `cleanup.sh`: the steps below.

## What run.sh does

1. Sets `DOCKER_HOST` to the VM's Docker socket, which the app forwards to
   `~/.ate-mac/lima/substrate/sock/docker.sock`. `docker build` then runs in
   the VM, and `docker push localhost:5101/hello` goes to the cluster's
   registry, which the kind node also pulls `localhost:5101/...` from.
2. Turns the tag into a digest reference (`localhost:5101/hello@sha256:...`),
   because templates require one.
3. Applies `workerpool.yaml`, reusing the worker image of the bundled counter
   demo's pool, and waits for the worker to start. The bundled image needs the
   counter demo, which is included unless it was built with `WITH_DEMO=0`.
4. Creates the atespace and the template, and waits for the golden snapshot.
   Substrate boots the template once and snapshots it, and actors start from
   that snapshot.
5. Creates actor `hello-1`. It starts out suspended, and the first request
   resumes it.

## Troubleshooting

- **The worker pod stays Pending.** The VM is out of memory. The counter
  demo's pool already reserves 3 GiB. Raise Memory in Settings and Restart, or
  free memory with `kubectl delete namespace ate-demo-counter`.
- **The proxy says `no ready atenet-router pods`.** Run
  `kubectl -n ate-system rollout restart deployment/atenet-router`. Its Envoy
  sidecar can get stuck unready after the router container restarts.
- **No golden snapshot.** Look at the worker with
  `kubectl -n ate-hello logs deployment/hello` and at the template with
  `kubectl ate get actor-template hello -a ate-hello -o yaml`.
