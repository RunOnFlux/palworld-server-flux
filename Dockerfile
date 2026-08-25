# Palworld server image for Flux.
#
# A thin layer over thijsvanloef/palworld-server-docker: same game, same
# configuration surface, same env vars. What it adds is the ability to notice that
# the server has stopped being a server and to end the container so the platform
# rebuilds it — see README.md for the two failure modes this exists for.
#
# The base is pinned to an upstream STABLE release (vX.Y.Z), never :latest and
# never :dev. .github/workflows/rebuild-on-new-release.yml bumps this
# automatically when upstream cuts a release, passing the tag as
# --build-arg PALWORLD_VERSION; the default below is the fallback for local
# builds. Override with: docker build --build-arg PALWORLD_VERSION=v2.7.2 .
ARG PALWORLD_VERSION=v2.7.2
FROM thijsvanloef/palworld-server-docker:${PALWORLD_VERSION}

# Repeated after FROM: an ARG declared before it is out of scope afterwards.
ARG PALWORLD_VERSION=v2.7.2
ARG FLUX_IMAGE_VERSION=dev

COPY scripts/flux-lib.sh scripts/flux-guard.sh scripts/flux-reboot.sh scripts/flux-entrypoint.sh /home/steam/server/

# The game's own sample settings file, used only to build the very first
# PalWorldSettings.ini on a brand new server — at that point the install has not
# run yet, so the game's copy is not on disk. From the second boot onward the
# game's own file is preferred, so this going stale costs nothing.
COPY scripts/PalWorldSettings.default.ini /home/steam/server/PalWorldSettings.default.ini

# auto_reboot.sh is the path upstream's start.sh writes into the crontab. Pointing
# it at ours means an app spec that already schedules a nightly restart picks up
# the new behaviour with no change to the spec at all.
RUN chmod 0755 /home/steam/server/flux-lib.sh \
                /home/steam/server/flux-guard.sh \
                /home/steam/server/flux-reboot.sh \
                /home/steam/server/flux-entrypoint.sh && \
    chmod 0644 /home/steam/server/PalWorldSettings.default.ini && \
    ln -sf /home/steam/server/flux-reboot.sh /home/steam/server/auto_reboot.sh

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION} \
    FLUX_BASE_VERSION=${PALWORLD_VERSION}

# The probe: on, one sample a minute, three strikes before it believes anything,
# and no action at all during the first five minutes or before the server has been
# seen working once. Once it decides, it warns the players in game and waits a
# minute, which also gives a server that is recovering the chance to say so.
# FLUX_GUARD_DRY_RUN=true logs the verdict and never acts.
ENV FLUX_GUARD_ENABLED=true \
    FLUX_GUARD_INTERVAL=60 \
    FLUX_GUARD_FAILURES=3 \
    FLUX_GUARD_RXQ_BYTES=65536 \
    FLUX_GUARD_MIN_UPTIME=300 \
    FLUX_GUARD_RESTART_DELAY=60 \
    FLUX_GUARD_DRY_RUN=false

# Restarts happen inside the container: PID 1 supervises the server and starts a
# fresh one in place, without the platform being involved. The platform is the
# fallback — after MAX_ATTEMPTS restarts inside WINDOW seconds the container ends
# instead, because a server that cannot stay up needs rebuilding, not restarting.
# FLUX_RESTART_MODE=container skips straight to ending the container every time.
# GRACE is how long a requested restart may take before the supervisor stops
# waiting for a polite exit.
ENV FLUX_RESTART_MODE=process \
    FLUX_RESTART_MAX_ATTEMPTS=5 \
    FLUX_RESTART_WINDOW=3600 \
    FLUX_RESTART_BACKOFF=10 \
    FLUX_RESTART_GRACE=60

# Upstream's health check is `pgrep PalServer-Linux`, which is true in both of the
# states this image exists to catch: the process is always there. Ours asks the
# same questions the guard does, so `docker inspect` and any future health-driven
# orchestration see what the players see. It does not restart anything by itself.
HEALTHCHECK --start-period=15m --interval=60s --timeout=20s --retries=3 \
    CMD /home/steam/server/flux-guard.sh --check || exit 1

ENTRYPOINT ["/home/steam/server/flux-entrypoint.sh"]
