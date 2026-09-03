#!/usr/bin/env bash
# Apply the self-telemetry backport to openhop_core 1.1.1 on Shaker Watch.
#
# Backports openhop_core dev commit 3513bab ("answer the self form of telemetry
# requests") onto the 1.1.1 monolithic frame_server.py layout, so the node stops
# rejecting Home Assistant's 4-byte CMD_SEND_TELEMETRY_REQ with ILLEGAL_ARG.
#
# Safe to re-run. Verifies the target is the exact stock 1.1.1 file before
# touching it, keeps a timestamped backup, and rolls back if the service does
# not come up. Run with: sudo ./apply-selftelem.sh   (or ./apply-selftelem.sh --revert)

set -euo pipefail

TARGET=/opt/openhop_repeater/venv/lib/python3.13/site-packages/openhop_core/companion/frame_server.py
PATCHED="$(dirname "$0")/frame_server.py"
STOCK_SHA=e9e8e8edcc894578a20af7d18bef7cf14b34ddfcdc19995a5be403b1dbffa616
PATCHED_SHA=8d06f6138131f2934b292a47022540d2796303fddd808ad6c3a990972d8fe7ac
BACKUP_GLOB="${TARGET}.stock-*"

sha() { sha256sum "$1" | cut -d' ' -f1; }

if [[ $EUID -ne 0 ]]; then echo "error: run with sudo" >&2; exit 1; fi

# --- revert -----------------------------------------------------------------
if [[ "${1:-}" == "--revert" ]]; then
  backup=$(ls -1t $BACKUP_GLOB 2>/dev/null | head -1 || true)
  [[ -n "$backup" ]] || { echo "error: no backup found matching $BACKUP_GLOB" >&2; exit 1; }
  echo "restoring $backup"
  cp -p "$backup" "$TARGET"
  find "$(dirname "$TARGET")/__pycache__" -name 'frame_server*.pyc' -delete 2>/dev/null || true
  systemctl restart openhop-repeater
  sleep 3
  systemctl is-active --quiet openhop-repeater && echo "reverted; service active" || { echo "service did NOT come up" >&2; exit 1; }
  exit 0
fi

# --- preflight --------------------------------------------------------------
[[ -f "$PATCHED" ]] || { echo "error: patched file not found at $PATCHED" >&2; exit 1; }
[[ -f "$TARGET"  ]] || { echo "error: target not found at $TARGET" >&2; exit 1; }

if [[ "$(sha "$PATCHED")" != "$PATCHED_SHA" ]]; then
  echo "error: $PATCHED does not match the expected patched checksum" >&2; exit 1
fi

cur=$(sha "$TARGET")
if [[ "$cur" == "$PATCHED_SHA" ]]; then
  echo "already patched; nothing to do."; exit 0
fi
if [[ "$cur" != "$STOCK_SHA" ]]; then
  echo "error: target is neither stock 1.1.1 nor the expected patch." >&2
  echo "       expected stock $STOCK_SHA" >&2
  echo "       found          $cur" >&2
  echo "       openhop_core was probably upgraded -- re-derive the patch first." >&2
  exit 1
fi

# --- apply ------------------------------------------------------------------
backup="${TARGET}.stock-$(date +%Y%m%d-%H%M%S)"
echo "backing up stock file -> $backup"
cp -p "$TARGET" "$backup"

echo "installing patched frame_server.py"
install -m 0644 -o root -g root "$PATCHED" "$TARGET"
find "$(dirname "$TARGET")/__pycache__" -name 'frame_server*.pyc' -delete 2>/dev/null || true

echo "restarting openhop-repeater"
systemctl restart openhop-repeater
sleep 5

if ! systemctl is-active --quiet openhop-repeater; then
  echo "service failed to start -- rolling back" >&2
  cp -p "$backup" "$TARGET"
  find "$(dirname "$TARGET")/__pycache__" -name 'frame_server*.pyc' -delete 2>/dev/null || true
  systemctl restart openhop-repeater
  echo "rolled back. Check: journalctl -u openhop-repeater -n 50" >&2
  exit 1
fi

echo
echo "service is active. Watching 30s for a self-telemetry push..."
if timeout 30 journalctl -u openhop-repeater -f -n 0 2>/dev/null \
     | grep -m1 "Self telemetry push sent"; then
  echo "SUCCESS: the node is answering self-telemetry."
else
  echo "no push seen in 30s. Home Assistant polls on its configured interval,"
  echo "so give it longer, then check:"
  echo "  journalctl -u openhop-repeater | grep 'Self telemetry push'"
fi
echo
echo "revert any time with: sudo $0 --revert"
