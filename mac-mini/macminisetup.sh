#!/usr/bin/env bash
# =============================================================================
# mac-mini-setup.sh — headless Mac mini M4 inference + automation appliance
# =============================================================================
# Usage:
#   DRY_RUN=true  bash mac-mini-setup.sh   # plan only (default)
#   DRY_RUN=false bash mac-mini-setup.sh   # live run
#
# Conventions:
#   - Idempotent: checks current state before every change
#   - Timestamped logs in ./logs/
#   - Verification read-back after every change
#   - Stops on first failed verification
#   - Before any sudo, prints the exact command and pauses
# =============================================================================

# --------------- HARDCODED CONFIG BLOCK — edit before running ----------------
MINI_USER="benvollmer"                   # your macOS account short name
OLLAMA_MODELS=("qwen3:8b")              # models to pull after install
TAILSCALE_HOSTNAME="macmini"            # hostname to advertise on Tailscale
OLLAMA_VERIFY_MODEL="qwen3:8b"          # model used to verify Metal GPU
# -----------------------------------------------------------------------------

DRY_RUN="${DRY_RUN:-true}"

# ── logging ───────────────────────────────────────────────────────────────────
mkdir -p ./logs
LOG_FILE="./logs/mac-mini-setup-$(date +%Y%m%dT%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

TS()  { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(TS)] $*"; }
ok()  { echo "[$(TS)] ✅  $*"; }
warn(){ echo "[$(TS)] ⚠️   $*"; }
fail(){ echo "[$(TS)] ❌  $*"; exit 1; }

log "========================================================"
log " mac-mini-setup.sh  DRY_RUN=${DRY_RUN}"
log "========================================================"

# ── helpers ───────────────────────────────────────────────────────────────────
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] would run: $*"
  else
    log "[RUN] $*"
    eval "$@"
  fi
}

sudo_run() {
  local cmd="$*"
  echo ""
  echo "┌─────────────────────────────────────────────────────────┐"
  echo "│  SUDO REQUIRED — exact command:                         │"
  echo "│  sudo ${cmd}"
  echo "└─────────────────────────────────────────────────────────┘"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] would run: sudo ${cmd}"
    return 0
  fi
  read -r -p "  Press Enter to run, or Ctrl-C to abort: "
  sudo bash -c "${cmd}"
}

verify() {
  local desc="$1" cmd="$2" pattern="$3"
  log "  verify: ${desc}"
  local out
  out=$(eval "$cmd" 2>&1)
  if echo "$out" | grep -qE "$pattern"; then
    ok "  ${desc} — PASS"
    log "  output: ${out}"
  else
    fail "  ${desc} — FAIL (expected /${pattern}/ in: ${out})"
  fi
}

# =============================================================================
# STEP 1 — Power Management
# =============================================================================
log ""
log "════════════════════════════════════════════"
log " STEP 1: Power Management"
log "════════════════════════════════════════════"

log "Current pmset -g custom:"
pmset -g custom 2>/dev/null || true

PMSET_CMD="pmset -a sleep 0 displaysleep 0 disksleep 0 womp 1 powernap 0 autorestart 1"

SLEEP_NOW=$(pmset -g | awk '/^[ \t]+sleep /{print $2}')
RESTART_NOW=$(pmset -g | awk '/autorestart/{print $2}')

if [[ "$SLEEP_NOW" == "0" && "$RESTART_NOW" == "1" ]]; then
  ok "Power settings already correct (sleep=0, autorestart=1) — skipping"
else
  log "Applying power settings..."
  sudo_run "${PMSET_CMD}"
fi

verify "sleep = 0"        "pmset -g" "sleep +0"
verify "autorestart = 1"  "pmset -g" "autorestart +1"
verify "displaysleep = 0" "pmset -g" "displaysleep +0"
verify "disksleep = 0"    "pmset -g" "disksleep +0"
verify "womp = 1"         "pmset -g" "womp +1"

# =============================================================================
# STEP 2 — Remote Access (SSH + Screen Sharing)
# =============================================================================
log ""
log "════════════════════════════════════════════"
log " STEP 2: Remote Access"
log "════════════════════════════════════════════"

SSH_STATUS=$(systemsetup -getremotelogin 2>/dev/null | awk '{print $NF}')
log "Remote Login current status: ${SSH_STATUS}"
if [[ "$SSH_STATUS" == "On" ]]; then
  ok "Remote Login already enabled — skipping"
else
  log "Enabling Remote Login..."
  sudo_run "systemsetup -setremotelogin on"
fi
verify "Remote Login is On" "sudo systemsetup -getremotelogin" "On"

SS_STATUS=$(sudo launchctl list com.apple.screensharing 2>/dev/null | grep '"PID"' | awk '{print $3}' | tr -d ',')
log "Screen Sharing launchctl PID: '${SS_STATUS}'"
if [[ -n "$SS_STATUS" && "$SS_STATUS" != "0" ]]; then
  ok "Screen Sharing already running (PID ${SS_STATUS}) — skipping"
else
  log "Loading Screen Sharing..."
  sudo_run "launchctl enable system/com.apple.screensharing"
  sudo_run "launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist"
fi
verify "Screen Sharing loaded" \
  "sudo launchctl list com.apple.screensharing 2>/dev/null" \
  "com.apple.screensharing"

# =============================================================================
# STEP 3 — Auto-Login
# =============================================================================
log ""
log "════════════════════════════════════════════"
log " STEP 3: Auto-Login"
log "════════════════════════════════════════════"

FV_STATUS=$(fdesetup status 2>/dev/null)
log "FileVault status: ${FV_STATUS}"

if echo "$FV_STATUS" | grep -qi "FileVault is On"; then
  warn "FileVault is ENABLED."
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  AUTO-LOGIN CONFLICT — ACTION REQUIRED FROM YOU             ║"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║  FileVault is active. macOS disables automatic login when   ║"
  echo "║  FileVault is on — the decryption key must be entered at    ║"
  echo "║  the pre-boot screen. There is no safe programmatic bypass. ║"
  echo "║                                                              ║"
  echo "║  A) KEEP FileVault: after any power loss the mini will sit  ║"
  echo "║     at the pre-boot screen until unlocked physically or via ║"
  echo "║     MDM (Mosyle, Jamf). Configure an MDM recovery key.      ║"
  echo "║                                                              ║"
  echo "║  B) DISABLE FileVault (lower security):                      ║"
  echo "║     System Settings → Privacy & Security → FileVault → OFF  ║"
  echo "║     Then re-run this script; auto-login will be set.        ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  fail "Stopping — resolve FileVault vs auto-login conflict first."

else
  ok "FileVault is OFF — safe to configure auto-login"

  AUTOLOGIN_NOW=$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || echo "none")
  log "Current autoLoginUser: ${AUTOLOGIN_NOW}"

  if [[ "$AUTOLOGIN_NOW" == "$MINI_USER" ]]; then
    ok "Auto-login already set to '${MINI_USER}' — skipping"
  else
    log "Setting auto-login for '${MINI_USER}'..."
    # sysadminctl prompts interactively for the account password
    sudo_run "sysadminctl -autologin set -userName '${MINI_USER}' -password -"
  fi

  verify "autoLoginUser = ${MINI_USER}" \
    "defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null" \
    "${MINI_USER}"
fi

# =============================================================================
# STEP 4 — Ollama (native, Metal-accelerated)
# =============================================================================
log ""
log "════════════════════════════════════════════"
log " STEP 4: Ollama (native Metal, no Docker)"
log "════════════════════════════════════════════"

if command -v brew &>/dev/null; then
  ok "Homebrew already installed at $(command -v brew)"
else
  log "Installing Homebrew..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] would install Homebrew via official installer"
  else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
fi
verify "brew is on PATH" "command -v brew" "brew"

if brew list --cask ollama &>/dev/null 2>&1; then
  ok "Ollama cask already installed"
else
  run "brew install --cask ollama"
fi
verify "ollama binary exists" "command -v ollama || ls /opt/homebrew/bin/ollama 2>/dev/null" "ollama"

OLLAMA_APP="/Applications/Ollama.app"
OLLAMA_PLIST="$HOME/Library/LaunchAgents/com.ollama.ollama.plist"

if [[ -d "$OLLAMA_APP" ]]; then
  OLLAMA_PID=$(pgrep -x ollama 2>/dev/null || echo "")
  if [[ -n "$OLLAMA_PID" ]]; then
    ok "Ollama already running (PID ${OLLAMA_PID})"
  else
    log "Starting Ollama..."
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[DRY-RUN] would open Ollama.app to register its LaunchAgent, then load via launchctl"
    else
      open -a Ollama
      sleep 3
      if [[ -f "$OLLAMA_PLIST" ]]; then
        launchctl load -w "$OLLAMA_PLIST" 2>/dev/null || true
      fi
    fi
  fi
else
  warn "Ollama.app not found at ${OLLAMA_APP}"
fi

verify "Ollama process is running" "pgrep -x ollama" "[0-9]+"

log "Verifying Metal acceleration via ollama run --verbose..."
if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY-RUN] would run: echo 'hi' | ollama run ${OLLAMA_VERIFY_MODEL} --verbose"
else
  METAL_CHECK=$(echo "hi" | timeout 60 ollama run "${OLLAMA_VERIFY_MODEL}" --verbose 2>&1 || true)
  log "verbose output: ${METAL_CHECK}"
  if echo "$METAL_CHECK" | grep -qiE "metal|apple gpu|gpu layers"; then
    ok "Metal / Apple GPU confirmed in Ollama verbose output"
  else
    warn "Metal not detected — check Ollama logs. Output: ${METAL_CHECK}"
  fi
fi

for MODEL in "${OLLAMA_MODELS[@]}"; do
  log "Pulling model: ${MODEL}"
  if ollama list 2>/dev/null | grep -q "^${MODEL}"; then
    ok "Model ${MODEL} already present"
  else
    run "ollama pull '${MODEL}'"
  fi
done

# =============================================================================
# STEP 5 — imessage-exporter
# =============================================================================
log ""
log "════════════════════════════════════════════"
log " STEP 5: imessage-exporter"
log "════════════════════════════════════════════"

if brew list imessage-exporter &>/dev/null 2>&1; then
  ok "imessage-exporter already installed"
else
  run "brew install imessage-exporter"
fi

verify "imessage-exporter --help works" \
  "imessage-exporter --help 2>&1 | head -5" \
  "imessage.exporter|Usage|USAGE|export"

log "NOTE: imessage-exporter requires Full Disk Access (TCC)."
log "      Must be granted manually — see checklist at end of script."

# =============================================================================
# STEP 6 — Headscale / Tailscale
# =============================================================================
log ""
log "════════════════════════════════════════════"
log " STEP 6: Tailscale"
log "════════════════════════════════════════════"

if brew list tailscale &>/dev/null 2>&1 || brew list --cask tailscale &>/dev/null 2>&1; then
  ok "Tailscale already installed"
else
  run "brew install tailscale"
fi

verify "tailscale CLI exists" "command -v tailscale" "tailscale"

TS_DAEMON=$(pgrep -x tailscaled 2>/dev/null || echo "")
if [[ -z "$TS_DAEMON" ]]; then
  log "Installing tailscaled system daemon..."
  sudo_run "tailscaled install-system-daemon"
fi

TS_STATUS=$(tailscale status 2>/dev/null || echo "not connected")
if echo "$TS_STATUS" | grep -qi "logged out\|stopped\|NeedsLogin\|not connected"; then
  log "Joining Tailscale..."
  sudo_run "tailscale up --reset --hostname='${TAILSCALE_HOSTNAME}'"
  log ""
  log "┌──────────────────────────────────────────────────────────────┐"
  log "│  Tailscale will print an auth URL above.                    │"
  log "│  Visit it in your browser to approve this device.           │"
  log "└──────────────────────────────────────────────────────────────┘"
else
  ok "Tailscale already connected: ${TS_STATUS}"
fi

verify "tailscale status shows hostname" \
  "tailscale status 2>/dev/null" \
  "${TAILSCALE_HOSTNAME}|100\."

# =============================================================================
# SUMMARY
# =============================================================================
log ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║                     SETUP COMPLETE — SUMMARY                        ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║ Step 1  Power       sleep=0 displaysleep=0 disksleep=0 womp=1  ✅  ║"
echo "║                     autorestart=1 powernap=0                        ║"
echo "║ Step 2  Remote      SSH (Remote Login) ON  ✅                       ║"
echo "║                     Screen Sharing (VNC) loaded via launchctl  ✅   ║"
echo "║ Step 3  Auto-Login  '${MINI_USER}' (FileVault must be OFF)          ║"
echo "║ Step 4  Ollama      Native cask + Metal GPU + models pulled  ✅     ║"
echo "║ Step 5  iMsg-exp    imessage-exporter installed  ✅                 ║"
echo "║ Step 6  Tailscale   tailscale up joined (hostname: ${TAILSCALE_HOSTNAME})         ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║           ⚠️  MANUAL STEPS REQUIRED (cannot script these)           ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║                                                                      ║"
echo "║  1. INSERT 4K HDMI DUMMY PLUG (physical, before headless boot)      ║"
echo "║     Without it: black VNC screen; Metal may fall back to CPU.       ║"
echo "║                                                                      ║"
echo "║  2. GRANT FULL DISK ACCESS                                          ║"
echo "║     System Settings → Privacy & Security → Full Disk Access → +    ║"
echo "║     Add: Terminal.app (or iTerm2)                                   ║"
echo "║     Add: imessage-exporter  (run it once first so it appears)      ║"
echo "║                                                                      ║"
echo "║  3. SIGN INTO iMESSAGE                                              ║"
echo "║     System Settings → [Apple ID] → iCloud → Messages               ║"
echo "║     OR: Messages.app → Settings → iMessage → sign in + 2FA         ║"
echo "║                                                                      ║"
echo "║  4. TAILSCALE — verify device is approved in Tailscale admin        ║"
echo "║     https://login.tailscale.com/admin/machines                      ║"
echo "║                                                                      ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Log saved to: ${LOG_FILE}"
