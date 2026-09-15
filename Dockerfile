# Build image for the gattsnap diff Action.
#
# Only the diff half of gattsnap is built here, and that is the whole point:
# `diff` is pure Swift with no radio, no CoreBluetooth and no permission model,
# so it runs on any GitHub-hosted Linux runner. `capture` needs a physical
# adapter and a physical peripheral, and belongs on a self-hosted runner or a
# developer's desk.

FROM swift:6.1-noble AS build
WORKDIR /src
COPY Package.swift ./
COPY Sources ./Sources
# SwiftPM validates every target's path at manifest load, including test targets
# it is not being asked to build, so Tests/ has to be present even though
# --product gattsnap never compiles it.
COPY Tests ./Tests
# -c release matters more than it looks: the image is rebuilt on every run of a
# Dockerfile-based action, and a debug build of the whole package is the slowest
# thing in the job.
RUN swift build -c release --product gattsnap --static-swift-stdlib

FROM ubuntu:24.04
# git is not incidental — the base snapshot is read out of the repository with
# `git show`, which is what makes this a pull-request diff rather than a
# comparison of two files someone had to stage by hand.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/.build/release/gattsnap /usr/local/bin/gattsnap
COPY scripts/action-entrypoint.sh /usr/local/bin/action-entrypoint.sh
RUN chmod +x /usr/local/bin/action-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/action-entrypoint.sh"]
