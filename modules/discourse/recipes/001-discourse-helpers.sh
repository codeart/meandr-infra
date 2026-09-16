#!/usr/bin/env bash
# `dsc` — the launcher from anywhere, as root. `dsc rebuild app` after an
# app.yml edit, `dsc enter app` for a rails console, `dsc logs app`.
#
# A helper, NOT a rebuild trigger: recipes re-apply whenever their content
# changes, and a rebuild takes the forum down for ten minutes. Rebuilds
# stay a deliberate `dsc rebuild app` over an SSM session.
set -euo pipefail

cat >/usr/local/bin/dsc <<'SH'
#!/bin/sh
[ "$(id -u)" -eq 0 ] || exec sudo /usr/local/bin/dsc "$@"
cd /var/discourse && exec ./launcher "$@"
SH
chmod 0755 /usr/local/bin/dsc
