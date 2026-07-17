# Perceptor VM agent

Deploy this on a project's VM to ship the machine's host and container infra
— metrics and logs — into the project's tenant on the
[Perceptor platform](https://github.com/tkumar1918/perceptor-platform), where
it correlates with the project's app telemetry without being mistaken for it
(everything is tagged `telemetry_source=infra`).

- **One agent per VM.** A project on several VMs deploys it on each, with a
  unique `VM_NAME` per machine. One agent sees every container on the host,
  regardless of how many Compose stacks run there.
- **Push, outbound only.** The agent dials out to the platform edge over
  HTTPS and opens no inbound ports.
- **No central config change.** Onboarding a VM, or a new container on it,
  needs nothing edited on the platform server.

## Setup

```bash
git clone https://github.com/tkumar1918/perceptor-agent.git
cd perceptor-agent
./install.sh
```

`install.sh` checks Docker is ready, prompts for the three values below,
writes a private `.env` (mode 600), starts the agent, and installs the
[process snapshot](#the-process-snapshot) (the one optional step that needs
sudo). It's safe to re-run.

| Value | What it is | Where it comes from |
|---|---|---|
| Edge URL | the OTLP ingest URL — the same URL the project's apps push to | the platform operator, e.g. `https://lgtm.runtheday.com` |
| Project token | the ingest token — see [Which token?](#which-token-does-this-vm-use). Treat it like a password | `tenants.secrets.yaml` on the platform server |
| VM name | a name for this machine; becomes the `vm` label | you pick it — role + index, e.g. `project-alpha-web-1` |

The agent starts collecting immediately and picks up new containers
automatically. Non-interactive install (no prompts):

```bash
EDGE_ENDPOINT=https://lgtm.runtheday.com PROJECT_TOKEN=ptk_xxx VM_NAME=project-alpha-web-1 ./install.sh
```

Or by hand, without the script: `cp .env.example .env`, edit the three
values, `docker compose up -d`.

### Prerequisites

- Docker Engine + Compose plugin (`docker compose version` works).
- Outbound HTTPS to the platform edge.
- Permission to talk to the Docker daemon (the `docker` group is enough —
  the agent reads host paths via read-only container mounts and needs no
  root of its own).
- sudo is optional, used only for the process snapshot. Without it the
  install still succeeds; you just don't get the snapshot panel.

## Which token does this VM use?

The agent carries exactly one token, and that token alone decides which
tenant the whole machine's infra lands in. Choosing it is the only real
deploy decision:

| The VM belongs to… | Put this token in `.env` | Infra shows up in |
|---|---|---|
| one project (dedicated VM) | that project's token | the project's own tenant, beside its app telemetry |
| several projects (shared box) | the group's `_infra-<group>` token | a shared infra tenant, visible from every one of those projects' Grafana |

**Dedicated VM — the common case.** Use the project's token; the project's
existing Grafana org already shows the machine. Nothing to configure on the
platform.

**Shared VM.** One agent, one token — so "each project's token" isn't an
option, and using project A's token would file project B's containers under
A. Use a group instead:

1. On the platform, add a reserved tenant `_infra-<group>` and set
   `group: <group>` on each project sharing the box (see the platform's
   `tenants.example.yaml`), then `make render`.
2. Here, use the `_infra-<group>` token as `PROJECT_TOKEN` — the
   `_infra-<group>` line of `tenants.secrets.yaml`, not any project's line.
3. Each of those projects' Grafana orgs gains a read-only infra datasource
   (and the infra dashboards pre-wired to it) pointing at the shared tenant.

Rule of thumb: the tenant is the visibility boundary, and one token = one
tenant. If more than one project must see this VM's infra, it needs its own
group tenant — don't reuse a project's token to "share" a box. The full
identity scheme (tenant / token / service_name / vm) is documented in the
platform repo's `docs/identity-model.md`.

## Container logs are opt-in

Container logs are collected only if a container opts in — by default no
stdout is scraped, so the agent never slurps a third-party or app container's
logs (which may hold secrets or PII) just because it runs on the same VM.
A service opts in from its own compose file; the agent is never edited:

```yaml
# in the application's docker-compose, on its service:
labels:
  perceptor.enable: "true"            # collect THIS container's logs
  perceptor.service_name: "checkout"  # optional; defaults to the container name
```

Remove the label (or set it to anything but `"true"`) to stop collecting.
This gate applies to container **logs** only: host/system logs (journald),
host metrics, and per-container resource metrics (cadvisor) are always
collected — they're non-sensitive infra vitals and the point of the agent.
On a shared VM this gate matters most: one project's app logs never flow
just because it shares a host.

## The process snapshot

`install.sh` also installs a systemd timer that writes a top-20-by-CPU `ps`
snapshot to journald every 2 minutes. The agent already tails journald, so
the snapshot flows to Grafana with no extra config and fills the *Process
snapshot* panel on the htop-style dashboard — letting you scroll back and ask
"what was running at 14:05?".

It is deliberately a log, not metrics: per-process metrics are a cardinality
bomb (a series per PID, and PIDs churn), while ~20 short lines every 2
minutes is flat. It logs only the command name (`comm`), never the full argv
— command lines routinely carry secrets that must not land in a log backend.

Installing the timer is the one step that needs root, and it is best-effort:
if sudo isn't available the install still succeeds without it.

```bash
SKIP_SNAPSHOT=1 ./install.sh   # skip it entirely
make snapshot                  # install/re-install it later (needs sudo)
```

## Verify it's working

On the VM — the agent log should show exporting with no `Exporting failed`
lines:

```bash
docker compose logs -f agent
```

In the project's Grafana, after ~30s:

| Signal | Query |
|---|---|
| host (journald) logs | `{telemetry_source="infra", vm="<VM_NAME>"}` |
| host metrics | `node_uname_info{vm="<VM_NAME>"}` |
| container metrics | `container_last_seen{vm="<VM_NAME>"}` |
| systemd unit states | `node_systemd_unit_state{vm="<VM_NAME>"}` |
| process snapshot | `{job="systemd-journal", vm="<VM_NAME>"} \| container="" \|= "snapshot="` |

And the snapshot timer itself:

```bash
systemctl status perceptor-ps-snapshot.timer          # active/waiting?
journalctl -u perceptor-ps-snapshot.service -n 5      # the last snapshot
```

> **Filtering infra logs by container?** Use a `|` label filter, not the `{}`
> selector: `{job="docker", vm="..."} | container="x"`. Only
> `job`/`service_name`/`telemetry_source`/`vm` are real Loki stream labels on
> this path — `container` arrives as structured metadata, so putting it
> inside `{}` silently matches zero lines instead of erroring.

## What lands where

Everything goes to the token's tenant, with `telemetry_source=infra` and
`vm=<VM_NAME>` as real labels:

- all infra, isolated from app telemetry: `{telemetry_source="infra"}`
- one VM: `{telemetry_source="infra", vm="project-alpha-web-1"}`
- a container's infra logs and metrics share the same `container` label, so
  one dashboard variable filters both together.

App telemetry (the project's own SDK signals) never carries
`telemetry_source`, so the two streams never mix.

## Operating it

```bash
docker compose up -d          # apply changes to config.alloy or .env
docker compose down           # stop the agent
docker stats perceptor-agent  # resource usage
make update                   # git pull + restart (+ refresh the snapshot if installed)
make snapshot                 # (re)install the snapshot timer — needs sudo
```

`docker compose down` stops the agent only; the snapshot timer is a host
systemd unit and keeps writing to journald (with nobody shipping it). To stop
it too: `sudo systemctl disable --now perceptor-ps-snapshot.timer`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Exporting failed ... 401` | wrong or missing `PROJECT_TOKEN` — check it against `tenants.secrets.yaml` on the platform server |
| `Exporting failed ... connection refused / no such host` | `EDGE_ENDPOINT` unreachable — check the URL and the VM's outbound HTTPS |
| no container metrics/logs (host ones fine) | the container-stats mounts didn't attach — ensure `/run/containerd/containerd.sock` and `/sys/fs/cgroup` exist (both mounted by the compose); on non-containerd runtimes adjust the socket paths in `config.alloy` |
| nothing at all in Grafana | confirm you're on the project's org/datasources and `vm=` matches your `VM_NAME` exactly |
| `entry ... timestamp too old` on first start | expected and harmless — the agent backfills each container's recent stdout; lines older than the platform's reject window (~7 days) are refused while current data flows. It stops once caught up |

---

Part of the [Perceptor platform](https://github.com/tkumar1918/perceptor-platform).
The platform server runs its own self-monitoring agent (writing to a reserved
`_infra` tenant); this VM agent is the per-project counterpart.
