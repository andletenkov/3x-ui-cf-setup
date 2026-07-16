#!/usr/bin/env bats
#
# Unit tests for anonymize.sh.
#
# Run with:
#   bats tests/anonymize.bats
#
# Stubs out all system-mutating commands (systemctl, sysctl, iptables,
# timedatectl, apt-get, netfilter-persistent) via tests/stubs/ on PATH, and
# sources anonymize.sh without executing main() (guarded by the BASH_SOURCE
# check at the bottom of the script). No root privileges or real system
# changes are required. File-path constants (SYSCTL_CONF, RESOLVED_CONF,
# SSHD_BANNER_CONF) are plain global vars, so tests override them to
# BATS_TEST_TMPDIR paths after sourcing, same pattern used in
# tests/install.bats for NGINX_SITE etc.

setup() {
  export PATH="${BATS_TEST_DIRNAME}/stubs:$PATH"
  export SCRIPT="${BATS_TEST_DIRNAME}/../anonymize.sh"

  # shellcheck disable=SC1090
  source "$SCRIPT"

  # Redirect every file this script touches into the per-test tmpdir.
  SYSCTL_CONF="${BATS_TEST_TMPDIR}/99-anonymize.conf"
  RESOLVED_CONF="${BATS_TEST_TMPDIR}/resolved-99-anonymize.conf"
  SSHD_BANNER_CONF="${BATS_TEST_TMPDIR}/99-no-banner.conf"
  BBR_SYSCTL_CONF="${BATS_TEST_TMPDIR}/98-bbr.conf"

  # Isolate the stateful iptables stub per test.
  export IPTABLES_STATE_FILE="${BATS_TEST_TMPDIR}/iptables-state"
  : > "$IPTABLES_STATE_FILE"

  require_root() { :; }
}

# ---------------------------------------------------------------------------
# harden_ntp / unharden_ntp
# ---------------------------------------------------------------------------

@test "harden_ntp succeeds via timedatectl when chrony is absent" {
  run harden_ntp
  [ "$status" -eq 0 ]
}

@test "harden_ntp prefers chrony when chronyd is on PATH" {
  local fake_bin="${BATS_TEST_TMPDIR}/fakebin"
  mkdir -p "$fake_bin"
  cat > "${fake_bin}/chronyd" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${fake_bin}/chronyd"
  PATH="${fake_bin}:$PATH" run harden_ntp
  [ "$status" -eq 0 ]
}

@test "unharden_ntp is a no-op that always succeeds" {
  run unharden_ntp
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# harden_dns / unharden_dns
# ---------------------------------------------------------------------------

@test "harden_dns skips gracefully when systemd-resolved is not present" {
  # The stubbed `systemctl` always exits 0 for any args, including
  # `list-unit-files systemd-resolved.service`, so this test intentionally
  # overrides systemctl to simulate resolved being absent.
  systemctl() { [[ "$1" == "list-unit-files" ]] && return 1; return 0; }
  run harden_dns
  [ "$status" -eq 0 ]
  [ ! -f "$RESOLVED_CONF" ]
}

@test "harden_dns writes DoT config when systemd-resolved is present" {
  systemctl() { return 0; }
  run harden_dns
  [ "$status" -eq 0 ]
  [ -f "$RESOLVED_CONF" ]
  grep -q "DNSOverTLS=yes" "$RESOLVED_CONF"
  grep -q "1.1.1.1#cloudflare-dns.com" "$RESOLVED_CONF"
}

@test "unharden_dns removes the resolved config if present" {
  systemctl() { return 0; }
  : > "$RESOLVED_CONF"
  run unharden_dns
  [ "$status" -eq 0 ]
  [ ! -f "$RESOLVED_CONF" ]
}

@test "unharden_dns is a no-op when nothing was configured" {
  run unharden_dns
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# harden_sysctl / unharden_sysctl
# ---------------------------------------------------------------------------

@test "harden_sysctl writes expected directives including icmp_echo_ignore_all" {
  run harden_sysctl
  [ "$status" -eq 0 ]
  [ -f "$SYSCTL_CONF" ]

  grep -q "net.ipv4.icmp_echo_ignore_all = 1" "$SYSCTL_CONF"
  grep -q "net.ipv4.conf.all.accept_redirects = 0" "$SYSCTL_CONF"
  grep -q "net.ipv4.conf.all.accept_source_route = 0" "$SYSCTL_CONF"
  grep -q "net.ipv4.conf.all.rp_filter = 1" "$SYSCTL_CONF"
  grep -q "net.ipv4.tcp_syncookies = 1" "$SYSCTL_CONF"
  grep -q "net.ipv4.ip_default_ttl = 64" "$SYSCTL_CONF"
}

@test "unharden_sysctl removes the sysctl config if present" {
  : > "$SYSCTL_CONF"
  run unharden_sysctl
  [ "$status" -eq 0 ]
  [ ! -f "$SYSCTL_CONF" ]
}

@test "unharden_sysctl is a no-op when nothing was configured" {
  run unharden_sysctl
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# harden_ping_block / unharden_ping_block -- two-way ICMP echo block
# ---------------------------------------------------------------------------

@test "harden_ping_block adds INPUT and OUTPUT echo-request DROP rules" {
  run harden_ping_block
  [ "$status" -eq 0 ]

  grep -q "INPUT" "$IPTABLES_STATE_FILE"
  grep -q "OUTPUT" "$IPTABLES_STATE_FILE"
  grep -q "echo-request" "$IPTABLES_STATE_FILE"
  grep -q "anonymize-icmp-block" "$IPTABLES_STATE_FILE"
}

@test "harden_ping_block is idempotent (no duplicate rules on rerun)" {
  harden_ping_block
  local first_count
  first_count="$(wc -l < "$IPTABLES_STATE_FILE" | tr -d ' ')"

  run harden_ping_block
  [ "$status" -eq 0 ]

  local second_count
  second_count="$(wc -l < "$IPTABLES_STATE_FILE" | tr -d ' ')"
  [ "$first_count" = "$second_count" ]
}

@test "harden_ping_block skips gracefully when iptables is absent" {
  local empty_path="${BATS_TEST_TMPDIR}/emptypath"
  mkdir -p "$empty_path"
  PATH="$empty_path" run harden_ping_block
  [ "$status" -eq 0 ]
  [[ "$output" == *"iptables not found"* ]]
}

@test "unharden_ping_block removes the ICMP block rules" {
  harden_ping_block
  grep -q "anonymize-icmp-block" "$IPTABLES_STATE_FILE"

  run unharden_ping_block
  [ "$status" -eq 0 ]
  ! grep -q "anonymize-icmp-block" "$IPTABLES_STATE_FILE"
}

# ---------------------------------------------------------------------------
# harden_ttl / unharden_ttl
# ---------------------------------------------------------------------------

@test "harden_ttl adds a POSTROUTING TTL-set rule" {
  run harden_ttl
  [ "$status" -eq 0 ]
  grep -q "POSTROUTING" "$IPTABLES_STATE_FILE"
  grep -q "TTL" "$IPTABLES_STATE_FILE"
  grep -q "anonymize-ttl-normalize" "$IPTABLES_STATE_FILE"
}

@test "harden_ttl is idempotent (no duplicate rules on rerun)" {
  harden_ttl
  local first_count
  first_count="$(wc -l < "$IPTABLES_STATE_FILE" | tr -d ' ')"

  run harden_ttl
  [ "$status" -eq 0 ]

  local second_count
  second_count="$(wc -l < "$IPTABLES_STATE_FILE" | tr -d ' ')"
  [ "$first_count" = "$second_count" ]
}

@test "unharden_ttl removes the TTL rule" {
  harden_ttl
  grep -q "anonymize-ttl-normalize" "$IPTABLES_STATE_FILE"

  run unharden_ttl
  [ "$status" -eq 0 ]
  ! grep -q "anonymize-ttl-normalize" "$IPTABLES_STATE_FILE"
}

# ---------------------------------------------------------------------------
# harden_banners / unharden_banners
# ---------------------------------------------------------------------------

@test "harden_banners writes an sshd Banner none config" {
  run harden_banners
  [ "$status" -eq 0 ]
  [ -f "$SSHD_BANNER_CONF" ]
  grep -q "Banner none" "$SSHD_BANNER_CONF"
}

@test "unharden_banners removes the sshd banner config" {
  : > "$SSHD_BANNER_CONF"
  run unharden_banners
  [ "$status" -eq 0 ]
  [ ! -f "$SSHD_BANNER_CONF" ]
}

# ---------------------------------------------------------------------------
# enable_bbr / disable_bbr
# ---------------------------------------------------------------------------

@test "enable_bbr writes fq/bbr sysctl config" {
  run enable_bbr
  [ "$status" -eq 0 ]
  [ -f "$BBR_SYSCTL_CONF" ]
  grep -q "net.core.default_qdisc = fq" "$BBR_SYSCTL_CONF"
  grep -q "net.ipv4.tcp_congestion_control = bbr" "$BBR_SYSCTL_CONF"
}

@test "enable_bbr reports success when active congestion control reads back as bbr" {
  export SYSCTL_STUB_CONGESTION_CONTROL=bbr
  run enable_bbr
  [ "$status" -eq 0 ]
  [[ "$output" == *"BBR enabled"* ]]
}

@test "enable_bbr warns if active congestion control did not switch to bbr" {
  export SYSCTL_STUB_CONGESTION_CONTROL=cubic
  run enable_bbr
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"not bbr"* ]]
}

@test "enable_bbr skips gracefully when the tcp_bbr module cannot be loaded" {
  export MODPROBE_SHOULD_FAIL=1
  run enable_bbr
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not load the tcp_bbr kernel module"* ]]
  [ ! -f "$BBR_SYSCTL_CONF" ]
}

@test "disable_bbr removes the BBR config and reverts congestion control" {
  enable_bbr
  [ -f "$BBR_SYSCTL_CONF" ]

  run disable_bbr
  [ "$status" -eq 0 ]
  [ ! -f "$BBR_SYSCTL_CONF" ]
}

@test "disable_bbr is a no-op when BBR was never enabled" {
  run disable_bbr
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# uninstall_all -- full revert sequence
# ---------------------------------------------------------------------------

@test "uninstall_all reverts everything a full run would have applied" {
  harden_ntp
  systemctl() { return 0; }
  harden_dns
  harden_sysctl
  harden_ping_block
  harden_ttl
  harden_banners
  enable_bbr

  [ -f "$RESOLVED_CONF" ]
  [ -f "$SYSCTL_CONF" ]
  [ -f "$SSHD_BANNER_CONF" ]
  [ -f "$BBR_SYSCTL_CONF" ]
  grep -q "anonymize-icmp-block" "$IPTABLES_STATE_FILE"
  grep -q "anonymize-ttl-normalize" "$IPTABLES_STATE_FILE"

  run uninstall_all
  [ "$status" -eq 0 ]

  [ ! -f "$RESOLVED_CONF" ]
  [ ! -f "$SYSCTL_CONF" ]
  [ ! -f "$SSHD_BANNER_CONF" ]
  [ ! -f "$BBR_SYSCTL_CONF" ]
  ! grep -q "anonymize-icmp-block" "$IPTABLES_STATE_FILE"
  ! grep -q "anonymize-ttl-normalize" "$IPTABLES_STATE_FILE"
}

@test "uninstall_all requires root" {
  # Un-stub require_root for this one test to verify the real guard fires.
  unset -f require_root
  run bash -c "source '${SCRIPT}'; uninstall_all"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Run this script as root"* ]]
}

# ---------------------------------------------------------------------------
# main() dispatch
# ---------------------------------------------------------------------------

@test "main --uninstall routes to uninstall_all" {
  harden_sysctl
  [ -f "$SYSCTL_CONF" ]

  run main --uninstall
  [ "$status" -eq 0 ]
  [ ! -f "$SYSCTL_CONF" ]
}

@test "print_limitations documents what cannot be fixed from inside the VPS" {
  run print_limitations
  [ "$status" -eq 0 ]
  [[ "$output" == *"IP/ASN reputation"* ]]
  [[ "$output" == *"Reverse DNS"* ]]
  [[ "$output" == *"WebRTC leaks"* ]]
}
