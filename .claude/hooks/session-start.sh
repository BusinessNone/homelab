#!/usr/bin/env bash
# Checks SSH reachability of the Mac mini at session start.
# Prints a clear status line — does NOT fail the session if unreachable.

MAC_MINI="benvollmer@192.168.10.15"
TIMEOUT=5

echo "==> Checking SSH connectivity to Mac mini (${MAC_MINI})..."

if ssh -o ConnectTimeout="${TIMEOUT}" \
       -o BatchMode=yes \
       -o StrictHostKeyChecking=accept-new \
       "${MAC_MINI}" "echo ok" 2>/dev/null | grep -q "^ok$"; then
  echo "✅  Mac mini is reachable via SSH (${MAC_MINI})"
else
  echo "⚠️   Mac mini NOT reachable via SSH (${MAC_MINI})"
  echo "    Check: VPN/network connectivity, SSH service, and that the host is awake."
fi
