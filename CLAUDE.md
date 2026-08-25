# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Docker packaging repo** — not an application. It wraps the upstream
`thijsvanloef/palworld-server-docker` image so a Palworld server on
[Flux](https://runonflux.io/) can recover from the two failures that leave the
container, the process and every platform health signal looking perfectly fine
while nobody can play (README, "Why it exists"). Five shell scripts, a Dockerfile,
two test suites.

The rule that shapes everything here: **the container supervises its own server**.
PID 1 runs upstream's `init.sh` as a child and starts a fresh generation when it
ends, the same shape as the `lloesche/valheim-server` image we run for Valheim.
Ending the container is the fallback for a server that will not stay up, because
the platform path is slower and conditional: FluxOS has no health-driven restart
at all, it only reacts to a container exiting, and for our `g:` components that
means the 30 second `masterSlaveApps` loop rather than Docker's restart policy.

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

- `scripts/flux-entrypoint.sh` — PID 1 and the supervisor. Exports `ADMIN_PASSWORD`
  from the ini, then loops: start a generation (`setsid ./init.sh` + the guard),
  wait, sweep the whole process group, start the next one. Never `exec`, so the
  exit is ours to control. Forwards signals so `docker stop` still reaches
  upstream's save-on-SIGTERM handler and is never followed by a restart. Exit 42 =
  we gave up on restarting in place and want the container rebuilt.
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
  if it were not, the supervisor would read it as a restart nobody asked for.
- **Never signal your own process group.** `sweep_generation` kills
  `-${init_pgid}`, which is PID 1's own group if `setsid` did not take. It checks,
  and falls back to killing named children. Getting this wrong kills the container
  every time a generation ends.
- **Every generation gets a fresh guard.** Its state (seen-healthy, previous
  uptime, strike counts) must not carry across a restart, and a probe that dies
  silently leaves the server unprotected, so the supervisor restarts it too.
- Upstream's `start.sh` only writes the reboot crontab when **both**
  `AUTO_REBOOT_ENABLED` and `REST_API_ENABLED` are true. The latter defaults to
  true in the image, and we do not set it — worth remembering before concluding a
  server should have been restarting.
- The persistent volume is only `/palworld/Pal/Saved` (`containerData: g:/palworld/Pal/Saved`).
  Anything written elsewhere is gone on redeploy.

## Related

- Upstream PR [#931](https://github.com/thijsvanloef/palworld-server-docker/pull/931),
  which this image carries until it merges.
- The dashboard that configures these servers writes `PalWorldSettings.ini` and the
  app spec's environment; an env baseline there decides what a customer is offered
  as a "server update", and it is the only way a change reaches an existing server,
  since only the app owner can sign a spec update.
