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
  few minutes. Any new REST-derived rule has to sit behind the `auth_ok` gate. The
  one thing that convicts *because* of a 401 is the resident-memory collapse, and
  only there: when the API does answer it knows more about the world than the
  allocator does, so a server reporting fps must never be convicted by its memory.
- **Three strikes are not the only speed.** `flux_worldless_is_proven` says when a
  single sample already settles it (no serverfps plus either an uptime counter that
  restarted or a collapse in resident memory), and that path also skips the
  countdown — there is nobody in an unloaded world to announce to. Keep it pure,
  keep it conjunctive: either half on its own convicts working servers. And it is
  gated on `auth_ok`: behind a 401 the memory reading is all there is, so it
  convicts but never on a single sample.
- **The early wake in `flux_guard_wait` is an edge on purpose.** Resident memory
  is watched through the wait between samples so a collapse does not sit unnoticed
  for most of a minute, but a fall the full sample then calls healthy stays a fall
  on every later glance. As a level it wakes every `FLUX_GUARD_RSS_POLL` seconds
  forever, one REST call each: 15 wakes in 15 seconds with the edge removed. It is
  also only armed while no verdict has strikes, so three strikes keeps meaning
  three minutes.
- **Not every restart is the container's fault.** `flux_restart_counts_against_budget`
  keeps world unloads and the nightly reboot out of `FLUX_RESTART_MAX_ATTEMPTS`,
  because ending the container costs a nine minute SteamCMD install and cannot fix
  a game bug that only reproduces on one save. It matches on the leading word of
  the reason string, which is why the guard's reason starts with the verdict.
- **`flux_rest` trusts `%{http_code}` only when curl exited 0.** A server that
  sends its headers and then stops leaves curl exiting 28 with the code already
  set to 200 and an empty body — which reads as "answered, and reports no world",
  turning a stalled server into a world unload. Wrong word, wrong announcement,
  and now the wrong side of the restart budget.
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
  Anything written elsewhere is gone on redeploy — and anything written *there* is
  the customer's disk. `flux_prune_crash_dumps` is the only thing in here that
  deletes: newest `FLUX_CRASH_KEEP` kept, `crashinfo-*` only, once per generation.

## Related

- Upstream PR [#931](https://github.com/thijsvanloef/palworld-server-docker/pull/931),
  which this image carries until it merges.
- The dashboard that configures these servers writes `PalWorldSettings.ini` and the
  app spec's environment; an env baseline there decides what a customer is offered
  as a "server update", and it is the only way a change reaches an existing server,
  since only the app owner can sign a spec update.
