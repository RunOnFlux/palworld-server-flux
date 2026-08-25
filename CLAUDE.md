# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Docker packaging repo** — not an application. It wraps the upstream
`thijsvanloef/palworld-server-docker` image so a Palworld server on
[Flux](https://runonflux.io/) can recover from the two failures that leave the
container, the process and every platform health signal looking perfectly fine
while nobody can play (README, "Why it exists"). Five shell scripts, a Dockerfile,
two test suites.

The rule that shapes everything here: **nothing inside a container can restart it**.
Recovery means ending the container so the platform rebuilds it. FluxOS has no
health-driven restart; it only reacts to a container exiting.

## Commands

```bash
./tests/test-flux.sh                                   # pure logic, no docker, no server
docker build -t palworld-server-flux:local .
./tests/test-entrypoint.sh palworld-server-flux:local  # PID 1 + guard against a stub server
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh
```

CI (`.github/workflows/rebuild-on-new-release.yml`) runs shellcheck and the unit
tests on every push and PR, and rebuilds against upstream's newest **stable**
release (`vX.Y.Z` only, never `:latest`/`:dev`) when one appears. Needs
`DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`.

## The files

- `scripts/flux-entrypoint.sh` — PID 1. Exports `ADMIN_PASSWORD` from the ini,
  starts the guard, runs upstream's `init.sh` **as a child** (never `exec`, so the
  exit is ours to control), forwards signals to it, and guarantees the container
  ends within `FLUX_RESTART_GRACE` once a restart is requested. Exit 42 = we meant it.
- `scripts/flux-guard.sh` — the probe loop, and `--check` for the HEALTHCHECK.
- `scripts/flux-reboot.sh` — the scheduled restart. `auto_reboot.sh` is symlinked to
  it, which is the path upstream's `start.sh` bakes into the crontab, so existing app
  specs pick it up unchanged.
- `scripts/flux-lib.sh` — shared helpers. **Sourcing it must stay side-effect free**:
  the tests source it directly.

## Things that will bite you

- **`flux_classify` is pure on purpose.** Every input is an argument; it reads
  nothing from the system. That is what makes the whole decision table testable.
  Keep it that way, and add a case to `tests/test-flux.sh` for every rule change.
- **`flux_guard_sample` must never be called in a command substitution.** It
  carries state between samples (previous uptime, auth state, whether a save was
  ever seen). A subshell throws that away, and the uptime-went-backwards signal —
  which can only be seen by comparing two samples — is lost.
- **A 401 is not a dead server.** Convicting on it restarts healthy worlds every
  few minutes. Any new REST-derived rule has to sit behind the `auth_ok` gate.
- **Never make the recovery path save.** A worldless server asked to save can
  write that emptiness over the last good save. The scheduled reboot saves only
  after confirming fps > 0.
- **`/tmp` survives a container restart.** The restart marker is cleared on boot;
  if it were not, the deadline watcher would fire immediately and loop the server.
- Upstream's `start.sh` only writes the reboot crontab when **both**
  `AUTO_REBOOT_ENABLED` and `REST_API_ENABLED` are true. The latter defaults to
  true in the image, and we do not set it — worth remembering before concluding a
  server should have been restarting.
- The persistent volume is only `/palworld/Pal/Saved` (`containerData: g:/palworld/Pal/Saved`).
  Anything written elsewhere is gone on redeploy.

## Related

- `~/work/palworldwebsitemaster` — the dashboard that configures these servers;
  `src/config/serverMaintenance.js` holds the env baseline and the
  "Server update available" flow that is how an existing customer gets a change.
- `~/work/cloudadminmaster/flux-app-palworld.json` — the marketplace spec (new
  deploys only).
- Upstream PR [#931](https://github.com/thijsvanloef/palworld-server-docker/pull/931) — ours, open.
