# E2E smoke-test image: a real, systemd-booted Ubuntu 22.04 so the scripts
# under test can install and start REAL services (3x-ui, nginx, Caddy) the
# same way they would on a production VPS. This is deliberately NOT a stub
# environment -- the entire point of this test tier is to catch drift between
# our assumptions about external systems (3x-ui's API shapes, GitHub release
# formats, Caddy/nginx runtime behavior) and what they actually do.
#
# Run with: docker run --privileged --cgroupns=host \
#   -v /sys/fs/cgroup:/sys/fs/cgroup:rw <image>
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
      systemd systemd-sysv \
      curl gnupg2 ca-certificates lsb-release \
      python3 python3-pip sqlite3 openssl jq iproute2 \
      && apt-get clean && rm -rf /var/lib/apt/lists/*

# Mask units that fail/hang in containers and aren't needed for these tests.
RUN systemctl mask systemd-udevd.service systemd-udevd-kernel.socket \
      systemd-udevd-control.socket getty.target getty-static.service \
      systemd-logind.service 2>/dev/null || true

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
