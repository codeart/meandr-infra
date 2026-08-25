#!/usr/bin/env bash
# `vc` and `vcs` — valkey-cli that already knows the TLS material and AUTH.
#
# The full invocation is four flags, three paths and a Secrets Manager
# round-trip, which nobody types correctly at 3am and which turns every
# diagnostic into a copy-paste from a doc.
#
# AUTH comes from the running config, not Secrets Manager: same value, no
# API call, and it still works when the thing you are debugging is the
# network. The files are root-only, so each wrapper re-execs under sudo
# rather than failing with a permission error that looks like a TLS one.
set -euo pipefail

cat >/usr/local/bin/vc <<'SH'
#!/bin/sh
# Data plane (6379). Usage: vc PING | vc INFO replication | vc --scan
[ -r /etc/valkey/tls/node.key ] || exec sudo /usr/local/bin/vc "$@"
exec valkey-cli --tls \
  --cacert /etc/valkey/tls/ca.crt \
  --cert /etc/valkey/tls/node.crt \
  --key /etc/valkey/tls/node.key \
  -a "$(awk '/^requirepass /{print $2; exit}' /etc/valkey/valkey.conf)" \
  --no-auth-warning "$@"
SH

cat >/usr/local/bin/vcs <<'SH'
#!/bin/sh
# Sentinel (26379). With no arguments, reports on THIS node's own fleet —
# each Sentinel monitors exactly one master, named for its fleet, and
# asking for the wrong name is the usual first mistake.
[ -r /etc/valkey/tls/node.key ] || exec sudo /usr/local/bin/vcs "$@"

FLEET="$(awk '/^sentinel monitor /{print $3; exit}' /etc/valkey/sentinel.conf)"
AUTH="$(awk '/^requirepass /{print $2; exit}' /etc/valkey/sentinel.conf)"

[ $# -eq 0 ] && set -- SENTINEL master "$FLEET"

exec valkey-cli --tls \
  --cacert /etc/valkey/tls/ca.crt \
  --cert /etc/valkey/tls/node.crt \
  --key /etc/valkey/tls/node.key \
  -a "$AUTH" --no-auth-warning -p 26379 "$@"
SH

chmod 0755 /usr/local/bin/vc /usr/local/bin/vcs

# Not /etc/profile.d — that is not sourced for the non-login shells SSM
# gives you, which is the same reason htop's config lives in /etc.
# Executables in PATH work regardless of how the shell was started.

echo "installed: vc (6379), vcs (26379, defaults to this node's fleet)"
