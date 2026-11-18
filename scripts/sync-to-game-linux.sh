#!/usr/bin/env bash
# Copies ./bots from this repo into Dota 2's vscripts/bots and applies the
# Linux case-sensitivity patch (lowercase file names and require paths).
# Run without sudo. Restart the lobby (or Dota) after syncing.
#
# Override the target with: DOTA_BOTS_DIR=/path/to/vscripts/bots ./scripts/sync-to-game-linux.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$repo_root/bots"

if [ -z "${DOTA_BOTS_DIR:-}" ]; then
  for p in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/debian-installation"; do
    if [ -d "$p/steamapps/common/dota 2 beta/game/dota/scripts/vscripts" ]; then
      DOTA_BOTS_DIR="$p/steamapps/common/dota 2 beta/game/dota/scripts/vscripts/bots"
      break
    fi
  done
fi
if [ -z "${DOTA_BOTS_DIR:-}" ]; then
  echo "Dota 2 vscripts folder not found; set DOTA_BOTS_DIR." >&2
  exit 1
fi

# Safety: only ever replace a folder literally named vscripts/bots.
case "$DOTA_BOTS_DIR" in
  */scripts/vscripts/bots) ;;
  *) echo "Refusing to write to unexpected path: $DOTA_BOTS_DIR" >&2; exit 1 ;;
esac
if [ -L "$DOTA_BOTS_DIR" ]; then
  echo "$DOTA_BOTS_DIR is a symlink; remove it first." >&2
  exit 1
fi

tmp="$(mktemp -d "${DOTA_BOTS_DIR}.tmp.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cp -r "$src/." "$tmp/"
python3 -I "$repo_root/scripts/linux_case_patch.py" "$tmp"

rm -rf "$DOTA_BOTS_DIR"
mv "$tmp" "$DOTA_BOTS_DIR"
trap - EXIT

echo "Synced $(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo '?')$(git -C "$repo_root" diff --quiet 2>/dev/null || echo '+dirty') -> $DOTA_BOTS_DIR"
