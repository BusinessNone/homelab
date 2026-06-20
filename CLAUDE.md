# Homelab — Claude Code Reference

## Purpose

Infrastructure-as-code for a headless Mac mini M4 running as a local AI inference and automation appliance. The Mac mini serves:

- **Ollama** — native Metal-accelerated LLM inference (qwen3:8b and other models)
- **imessage-exporter** — iMessage backup/export
- **Tailscale / Headscale** — private mesh VPN for remote access
- **SSH + Screen Sharing** — remote management

## Repo Layout

```
mac-mini/
  macminisetup.sh   # Idempotent setup script for the Mac mini
.claude/
  settings.json     # Claude Code permissions and hooks
  hooks/
    session-start.sh  # Checks SSH reachability of the Mac mini
```

## Mac Mini

| Property | Value |
|---|---|
| Host | `ben@192.168.10.15` |
| Hardware | Mac mini M4 (headless) |
| OS | macOS (latest) |
| User | `ben` |

## Conventions

- **Idempotent scripts** — every step checks current state before making changes
- **DRY_RUN mode** — all scripts default to `DRY_RUN=true`; run with `DRY_RUN=false` to apply
- **Verified changes** — every `run`/`sudo_run` is followed by a `verify` call that fails fast
- **Timestamped logs** — scripts write logs to `./logs/` with ISO-8601 timestamps
- **No sudo surprises** — `sudo_run` always prints the exact command and pauses for confirmation (in live mode)

## Common Commands (run on Mac mini via SSH)

```bash
# Power settings
pmset -g                         # show current power config
pmset -g custom                  # show per-source settings

# Ollama
ollama list                      # list pulled models
ollama ps                        # show running models
ollama run qwen3:8b              # interactive inference

# Tailscale
tailscale status                 # show VPN peers and IP
tailscale ping macmini           # latency to a peer

# Services
launchctl list | grep ollama     # check Ollama LaunchAgent
launchctl list com.apple.screensharing  # check Screen Sharing

# Homebrew
brew list                        # installed formulae/casks
brew outdated                    # available upgrades
```

## Running the Setup Script

```bash
# Dry run (safe, default)
DRY_RUN=true bash mac-mini/macminisetup.sh

# Live run — applies changes
DRY_RUN=false bash mac-mini/macminisetup.sh
```

Edit the config block at the top of `macminisetup.sh` before running:
- `MINI_USER` — macOS account short name
- `OLLAMA_MODELS` — models to pull
- `HEADSCALE_URL` — your Headscale control-plane URL
- `HEADSCALE_HOSTNAME` — node hostname in Headscale
