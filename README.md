# palworld-server-flux

The Palworld server image we run on Flux: [`thijsvanloef/palworld-server-docker`](https://github.com/thijsvanloef/palworld-server-docker)
plus the ability to notice that the server has stopped being a server.

Same game, same env vars, same `PalWorldSettings.ini`, same everything the
dashboard already knows how to configure. Published as
`runonflux/palworld-server-flux:latest`.

## Why it exists

Palworld has two ways of going down that leave every signal the platform can see
in perfect shape. Both are on record in the palwatch log a customer sent with a
support ticket in August 2026, 22 hours of one-minute samples from a 16 GB
server:

**A. The server stalls.** Resident memory climbs from 3.0 GB to 5.1 GB over
twenty hours, and then the game stops draining its own UDP socket: the receive
queue on the game port climbs to 110 KB and sticks there, inbound packets drop to
zero, the REST API stops answering. The process is alive the whole time. Nobody
can join. Only a restart clears it.

**B. The world unloads.** In the space of a single sample, resident memory drops
by 1.1 to 1.4 GB, the server's own uptime counter restarts from zero, metrics stop
reporting a world — with the same PID throughout. The REST API still answers 200
and the game port still accepts connections, so players connect and get a black
screen. It never recovers. It happened three times in two hours at 1.8 to 2.3 GB
of memory used, so it is neither the leak nor the RAM limit.

In both states the container is healthy by every measure anything upstream of it
uses:

| signal | what it checks | mode A | mode B |
| --- | --- | --- | --- |
| upstream `HEALTHCHECK` | `pgrep PalServer-Linux` | passes | passes |
| our `/api/palworld-status` probe | a UDP ping to the game port | fails | **passes** |
| FluxOS | is the container running | passes | passes |

FluxOS has no health-driven restart at all: it acts on a container *exiting*.
So the only way to recover a server that is up but not serving is for something
inside the container to notice and end it. That is what this image adds.

## What it adds

### 1. A health probe (`scripts/flux-guard.sh`)

Samples the server once a minute and needs the same verdict three times in a row
before it believes it. The full decision table is unit tested in
`tests/test-flux.sh`:

| verdict | when |
| --- | --- |
| `stalled` | the game's UDP receive queue is at or above `FLUX_GUARD_RXQ_BYTES` (mode A, the socket half) |
| `unresponsive` | `/v1/api/info` stopped answering (mode A, the API half) |
| `worldless` | the API answers but `/v1/api/metrics` does not, or reports 0 fps, or its uptime counter went **backwards**, or the world save vanished from disk (mode B) |
| `ok` | none of the above |

Three things it deliberately will not do:

- **It never convicts on a 401.** A server whose ini has no `AdminPassword` set
  rejects our REST calls, which from the outside looks exactly like a dead API.
  Restarting on that would bounce a perfectly healthy world every few minutes. On
  a 401 the REST-derived rules are switched off, an hourly warning goes into the
  log, and only the socket and save-file checks stay live — neither needs
  credentials.
- **It never acts before the server has been seen working once** since boot, and
  never in the first `FLUX_GUARD_MIN_UPTIME` seconds. Loading a large world takes
  minutes, and a server that comes up broken is not made better by a restart loop.
- **It never saves.** In every state that gets it here the in-memory world is
  already gone or frozen, and asking a broken server to save risks writing that
  emptiness over the customer's last good save. What a kill costs is the interval
  since the last autosave, which was lost the moment the fault happened.

`flux-guard.sh --check` runs one sample and exits non-zero when unhealthy. That is
also the image's `HEALTHCHECK`, replacing `pgrep`, so `docker inspect` finally
agrees with what the players see. It restarts nothing by itself.

### 2. A scheduled restart that actually restarts (`scripts/flux-reboot.sh`)

Upstream's `auto_reboot.sh` asks the server to save and then refuses to shut down
if the save failed. On a server that is leaking, frozen or worldless — the only
servers a nightly restart matters for — the save is exactly what fails, so the
restart silently does nothing on the nights it is needed.

Ours warns the players, saves **only if the world is still loaded and ticking**,
asks the server to shut down, and then stops asking: after
`FLUX_REBOOT_GRACEFUL_WAIT` seconds it kills the process, and PID 1 ends the
container within `FLUX_RESTART_GRACE` seconds of that. It never silently skips.

`auto_reboot.sh` in this image is a symlink to it, and that is the path upstream's
`start.sh` writes into the crontab, so **an app spec that already schedules a
nightly restart picks this up with no change to the spec**.

### 3. The admin password fix (upstream PR #931)

Upstream authenticates every container-side REST call as `admin:${ADMIN_PASSWORD}`
— the env var. We deploy with `DISABLE_GENERATE_SETTINGS=true` so that customer
edits survive a reboot, which means the password the customer sets lands in
`PalWorldSettings.ini` and the env var stays empty. Every one of those calls gets
a 401: the nightly restart, the backups, and the graceful save on `docker stop`.

[PR #931](https://github.com/thijsvanloef/palworld-server-docker/pull/931) is ours
and still open. Rather than vendor a patch that would go stale against every new
base image, `flux-entrypoint.sh` reads the ini and exports `ADMIN_PASSWORD` before
handing over to upstream's `init.sh`, which fixes upstream's own code paths on
whatever base version we happen to be pinned to. `ADMIN_PASSWORD` still wins
whenever it is set, so nothing changes for a setup that already works. When the PR
merges this becomes redundant and harmless.

It also makes the `ADMIN_PASSWORD=$(sed ...)` prefix we inject into the cron
expression from the website unnecessary. Leave it: it sets the same value from the
same file, and removing it is a spec change for 179 live servers.

## How the container actually restarts

Nothing inside a container can restart it. What the guard and the scheduled
reboot do is *end* it, and the platform brings it back:

- **live FluxOS (7.3.0)**: our Palworld components carry the `g:` flag
  (`containerData: g:/palworld/Pal/Saved`), so Docker's own restart policy is
  `no` and recovery comes from the `masterSlaveApps` loop, a 30 second cycle that
  starts the container again on the same node — and therefore the same IP and
  ports — while FDM still points there.
- **FluxOS 8.x**: `appReconciler` restarts on the Docker `die` event under an
  effective `always` policy, with a backoff ladder.

Neither reads the exit code today, so a deliberate restart could just as well exit
0. It exits **42** anyway: the intent belongs on the record, and the day a policy
honours exit codes (`on-failure`) a deliberate restart must not look like a clean
stop.

PID 1 is `flux-entrypoint.sh`, which runs upstream's `init.sh` as a child rather
than replacing it, so every upstream behaviour is untouched — including the
SIGTERM handler that saves the world when FluxOS stops the container for a
redeploy. `tests/test-entrypoint.sh` proves that signal still gets through.

## Configuration

Everything upstream supports works unchanged. On top of it:

| variable | default | meaning |
| --- | --- | --- |
| `FLUX_GUARD_ENABLED` | `true` | run the probe at all |
| `FLUX_GUARD_INTERVAL` | `60` | seconds between samples |
| `FLUX_GUARD_FAILURES` | `3` | consecutive bad samples before acting |
| `FLUX_GUARD_RXQ_BYTES` | `65536` | UDP receive queue that counts as stalled (a healthy server peaks around 17 KB; the frozen ones sat at 90 to 110 KB) |
| `FLUX_GUARD_MIN_UPTIME` | `300` | seconds after boot during which nothing is acted on |
| `FLUX_GUARD_DRY_RUN` | `false` | log the verdict and never act |
| `FLUX_RESTART_GRACE` | `60` | seconds PID 1 waits for a polite exit before ending the container itself |
| `FLUX_REBOOT_GRACEFUL_WAIT` | `90` | seconds the scheduled restart waits for the server to shut itself down |
| `FLUX_GUARD_LOG` | `/palworld/Pal/Saved/flux-guard.log` | persistent log, capped at 2000 lines |

The log is written to the app volume on purpose: it is the only copy that survives
the restart it describes, and the customer can read it from the dashboard's file
browser.

`FLUX_GUARD_DRY_RUN=true` is the way to introduce this to a fleet. It reports what
it would have done and touches nothing.

## Build and test

```bash
./tests/test-flux.sh                                   # pure logic, no docker
docker build -t palworld-server-flux:local .
./tests/test-entrypoint.sh palworld-server-flux:local  # PID 1 + guard, with a stub server
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh
```

`tests/test-entrypoint.sh` stands a fake Palworld in front of the guard — a
process with the right name and the two REST endpoints served from a file — and
then makes the world disappear underneath it, which is the mode B signature from
the ticket. It asserts the container ends with exit 42 and says why. No five
gigabyte download involved.

## Releases

`.github/workflows/rebuild-on-new-release.yml` follows upstream's **stable**
releases only (`vX.Y.Z`). Upstream's `:latest` and `:dev` move whenever their main
branch moves; a Flux app pinned to a rolling tag gets rebuilt onto unreleased code
and every customer's server restarted with it. The workflow reads the newest
stable tag daily, compares it with the `org.opencontainers.image.base.version`
label on our published image, and only builds when there is something new. A push
to `main` always builds. Pull requests run the tests and publish nothing.

Needs `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` as repository secrets.

## Rolling it out

1. Build, then run a server on the new image with `FLUX_GUARD_DRY_RUN=true` and
   read `flux-guard.log` for a few days. False positives are the only real risk
   here, and dry run is how you find them without restarting anyone.
2. Point the marketplace app at the new image
   (`cloudadminmaster/flux-app-palworld.json`, `repotag`). New deploys only.
3. Existing servers need their own spec updated, which only the owner can sign.
   The dashboard's "Server update available" flow
   (`palworldwebsitemaster/src/config/serverMaintenance.js`) is the machinery for
   that, but it only knows how to offer env changes today; offering an image
   change is the piece that has to be written.
