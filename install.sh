#!/usr/bin/env bash
# ============================================================================
# Perceptor VM agent — one-command setup.
#
#   ./install.sh                 # asks you the 3 values, writes .env, starts it
#
# Or non-interactive (CI / automation / re-runs) — pass them as env vars:
#   EDGE_ENDPOINT=https://lgtm.runtheday.com \
#   PROJECT_TOKEN=ptk_xxx \
#   VM_NAME=project-alpha-vm-1 \
#   ./install.sh
#
# Safe to re-run: if .env already exists it is reused (pass --reconfigure to
# re-enter values). Nothing is pushed anywhere; the agent only dials OUT.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

say()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

RECONFIGURE=0
SNAPSHOT_ONLY=0
case "${1:-}" in
  --reconfigure)   RECONFIGURE=1 ;;
  --snapshot-only) SNAPSHOT_ONLY=1 ;;
esac

# ── 0. prerequisites ────────────────────────────────────────────────────────
# Skipped for --snapshot-only: the snapshot timer is pure systemd and has
# nothing to do with Docker — failing it on "Docker daemon unreachable" would
# be a confusing lie.
if [ "$SNAPSHOT_ONLY" -eq 0 ]; then
  command -v docker >/dev/null 2>&1 || die "Docker isn't installed. See https://docs.docker.com/engine/install/"
  docker compose version >/dev/null 2>&1 || die "The Docker Compose plugin is missing. Install 'docker-compose-plugin'."
  docker info >/dev/null 2>&1 || die "Can't talk to the Docker daemon. Is it running, and do you have permission (try sudo, or add yourself to the 'docker' group)?"
fi

# ── host process snapshot (optional — needs root) ───────────────────────────
# Installs a systemd timer that writes a periodic `ps` snapshot to journald,
# which this agent already tails (/var/log/journal is mounted). It's what fills
# the "Process snapshot" panel on the htop-style dashboard.
#
# It's a LOG, not metrics, on purpose: per-process metrics are a cardinality
# bomb (one series per PID, and PIDs churn constantly) — ~20 lines every 2min
# is flat cardinality instead, and still answers "what was hot at 14:05?".
#
# BEST-EFFORT BY DESIGN: the agent needs no root, so a box where you cannot
# sudo must still end up with a working agent — just no snapshot panel. Never
# let this step fail the install. Skip it entirely with SKIP_SNAPSHOT=1.
install_snapshot() {
  [ "${SKIP_SNAPSHOT:-0}" = "1" ] && { say "Skipping the process snapshot (SKIP_SNAPSHOT=1)."; return 0; }
  command -v systemctl >/dev/null 2>&1 || {
    warn "No systemd on this host — skipping the process snapshot. The agent is fine without it."; return 0; }

  local SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    if sudo -n true 2>/dev/null; then
      SUDO="sudo"
    elif [ -t 0 ]; then
      say "The process snapshot installs a systemd timer — sudo may ask for your password."
      SUDO="sudo"
    else
      warn "Skipping the process snapshot: it needs root, and sudo isn't available non-interactively."
      warn "Install it later with:  make snapshot"
      return 0
    fi
  fi

  # &&-chained so a failure short-circuits and is reported once by the caller.
  $SUDO install -m 755 snapshot/perceptor-ps-snapshot /usr/local/bin/perceptor-ps-snapshot &&
  $SUDO install -m 644 snapshot/perceptor-ps-snapshot.service /etc/systemd/system/perceptor-ps-snapshot.service &&
  $SUDO install -m 644 snapshot/perceptor-ps-snapshot.timer   /etc/systemd/system/perceptor-ps-snapshot.timer &&
  $SUDO systemctl daemon-reload &&
  $SUDO systemctl enable --now perceptor-ps-snapshot.timer >/dev/null 2>&1 &&
  $SUDO systemctl start perceptor-ps-snapshot.service &&   # fire one now, don't wait 2min for the first
  say "Process snapshot installed — every 2 min into journald, shipped by the agent."
}

if [ "$SNAPSHOT_ONLY" -eq 1 ]; then
  install_snapshot || die "Couldn't install the process snapshot."
  exit 0
fi

# ── 1. gather config ────────────────────────────────────────────────────────
if [ -f .env ] && [ "$RECONFIGURE" -eq 0 ]; then
  say "Using existing .env (run './install.sh --reconfigure' to change the values)."
else
  say "Let's configure this VM's agent. Three values — get the first two from your platform admin."
  echo

  # Prompt only for values not already supplied via the environment.
  if [ -z "${EDGE_ENDPOINT:-}" ]; then
    read -rp "1) Edge URL (where telemetry is sent, e.g. https://lgtm.runtheday.com): " EDGE_ENDPOINT
  fi
  if [ -z "${PROJECT_TOKEN:-}" ]; then
    read -rp "2) Project token (starts with ptk_ — keep it secret): " PROJECT_TOKEN
  fi
  if [ -z "${VM_NAME:-}" ]; then
    read -rp "3) A name for THIS machine (e.g. project-alpha-vm-1): " VM_NAME
  fi

  # light validation — catch the obvious mistakes, don't be pedantic
  [ -n "$EDGE_ENDPOINT" ] || die "Edge URL can't be empty."
  [ -n "$PROJECT_TOKEN" ] || die "Project token can't be empty."
  [ -n "$VM_NAME" ]       || die "VM name can't be empty."
  case "$EDGE_ENDPOINT" in http://*|https://*) ;; *) die "Edge URL must start with http:// or https:// (got: $EDGE_ENDPOINT)";; esac
  case "$PROJECT_TOKEN" in ptk_*) ;; *) warn "Heads up: project tokens usually start with 'ptk_'. Double-check you pasted the right one.";; esac

  # back up an existing .env before overwriting
  [ -f .env ] && cp .env ".env.bak.$(date +%s)" && say "Backed up your previous .env"

  umask 077   # .env holds a secret — don't create it world-readable
  cat > .env <<EOF
# Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Holds a secret — keep private.
EDGE_ENDPOINT=$EDGE_ENDPOINT
PROJECT_TOKEN=$PROJECT_TOKEN
VM_NAME=$VM_NAME
EOF
  say "Wrote .env (permissions 600)."
fi

# ── 2. start it ─────────────────────────────────────────────────────────────
echo
say "Starting the agent..."
docker compose up -d

# ── 3. host process snapshot (best-effort — never fails the install) ────────
echo
install_snapshot || warn "Process snapshot setup didn't complete — the agent is unaffected. Retry with: make snapshot"

# ── 4. tell them how to check it ────────────────────────────────────────────
VM_NAME_SHOW="$(grep -E '^VM_NAME=' .env | cut -d= -f2-)"
cat <<EOF

$(say "Done — the agent is running.")

  Watch it collect + export (look for NO 'Exporting failed' lines):
      docker compose logs -f agent        (or: make logs)

  In your project's Grafana, after ~30s:
      Mimir:  node_uname_info{vm="$VM_NAME_SHOW"}     -> host metrics flowing
      Loki:   {telemetry_source="infra", vm="$VM_NAME_SHOW"}  -> host logs

  Container LOGS are opt-in: add  labels: { perceptor.enable: "true" }  to a
  service in its own compose to ship that container's logs. Metrics are automatic.

  Manage it:  make logs | make status | make down | make update
EOF
