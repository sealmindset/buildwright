#!/bin/bash
# Capture forensic artifacts for a Buildwright-suspected desktop freeze.
#
# Why: a hard WindowServer / main-thread stall can freeze the whole desktop
# WITHOUT leaving a JetsamEvent or spindump (logging itself stalls). This probe
# grabs the evidence that post-hoc forensics can't recover: a live stack sample
# of Buildwright's main thread, a system spindump, WindowServer CPU, and the
# memory/tmux state -- so the NEXT freeze produces proof instead of a mystery.
#
# WHEN TO RUN: the instant Buildwright starts to stutter, or immediately after
# you break a freeze (the tail of the stall is still visible). It's fast.
#
# Usage:
#   Scripts/bw-freeze-probe.sh [sample_seconds]      # default 3s
#   sudo Scripts/bw-freeze-probe.sh [sample_seconds] # ALSO samples WindowServer
#                                                    # + full system spindump
#
# The WindowServer sample and the system-wide spindump need root. Without sudo
# the probe still captures everything it can and tells you what it skipped.

set -uo pipefail   # NOT -e: a freeze means some captures will fail; keep going.

DUR="${1:-3}"
TS="$(date +%Y%m%d-%H%M%S)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist/freeze-reports/freeze-$TS"
mkdir -p "$OUT"

log() { printf '%s\n' "$*" | tee -a "$OUT/00-summary.txt"; }
have() { command -v "$1" >/dev/null 2>&1; }

IS_ROOT=0; [ "$(id -u)" = "0" ] && IS_ROOT=1

log "=== Buildwright freeze probe @ $(date) ==="
log "output dir: $OUT"
log "sample duration: ${DUR}s   running as root: $([ $IS_ROOT = 1 ] && echo yes || echo NO)"
[ $IS_ROOT = 0 ] && log "  (re-run with sudo to also capture WindowServer + full spindump)"
log ""

# --- Find the Buildwright process (the GUI app, not this script) -------------
BW_PID="$(pgrep -x Buildwright | head -1)"
if [ -z "$BW_PID" ]; then
  BW_PID="$(pgrep -f '/Buildwright.app/' | head -1)"
fi
if [ -n "$BW_PID" ]; then
  log "Buildwright PID: $BW_PID"
else
  log "Buildwright PID: NOT RUNNING (still capturing system state)"
fi
log ""

# --- 1. Sample Buildwright's threads (the key artifact; no root needed) ------
# A beachball = the main thread stuck in some call. The sample shows exactly
# where. This is the single most valuable capture.
if [ -n "$BW_PID" ] && have sample; then
  log "[1/8] sampling Buildwright ($BW_PID) for ${DUR}s -> 01-sample-buildwright.txt"
  sample "$BW_PID" "$DUR" -file "$OUT/01-sample-buildwright.txt" >/dev/null 2>&1 \
    && log "      done" || log "      sample FAILED (process gone or denied)"
else
  log "[1/8] skip Buildwright sample (not running)"
fi
log ""

# --- 2. WindowServer CPU + sample (sample needs root) -----------------------
WS_PID="$(pgrep -x WindowServer | head -1)"
log "[2/8] WindowServer (PID ${WS_PID:-?}) CPU snapshot -> 02-windowserver.txt"
{
  echo "# WindowServer + top CPU consumers at $(date)"
  ps -axo pid,%cpu,%mem,rss,command | sort -nrk2 | head -15
} > "$OUT/02-windowserver.txt" 2>&1
if [ -n "$WS_PID" ] && [ $IS_ROOT = 1 ] && have sample; then
  log "      sampling WindowServer ${DUR}s (root)"
  sample "$WS_PID" "$DUR" -file "$OUT/02-windowserver-sample.txt" >/dev/null 2>&1 \
    && log "      WindowServer sample done" || log "      WindowServer sample failed"
else
  log "      WindowServer stack sample SKIPPED (needs sudo)"
fi
log ""

# --- 3. System-wide spindump (root = all procs; else this process only) -----
if have spindump; then
  if [ $IS_ROOT = 1 ]; then
    log "[3/8] full-system spindump (${DUR}s) -> 03-spindump.txt"
    spindump -o "$OUT/03-spindump.txt" 1 "$DUR" >/dev/null 2>&1 \
      && log "      done" || log "      spindump failed"
  else
    log "[3/8] spindump SKIPPED (needs sudo for system-wide capture)"
  fi
else
  log "[3/8] spindump not available"
fi
log ""

# --- 4. Memory pressure / swap / compressor ---------------------------------
log "[4/8] memory state -> 04-memory.txt"
{
  echo "# $(date)"; echo "## sysctl vm.swapusage"; sysctl vm.swapusage 2>&1
  echo; echo "## vm_stat"; vm_stat 2>&1
  echo; echo "## memory_pressure (free %)"; memory_pressure 2>&1 | tail -6
} > "$OUT/04-memory.txt"
log ""

# --- 5. Full process table by memory + by CPU -------------------------------
log "[5/8] process tables -> 05-processes.txt"
{
  echo "# top 25 by RSS @ $(date)"
  ps -axo pid,ppid,%cpu,%mem,rss,etime,command | sort -nrk5 | head -25
  echo; echo "# top 25 by CPU"
  ps -axo pid,ppid,%cpu,%mem,rss,etime,command | sort -nrk3 | head -25
} > "$OUT/05-processes.txt"
log ""

# --- 6. tmux / Claude agent census (the standing-army check) ----------------
log "[6/8] tmux + Claude agents -> 06-tmux-agents.txt"
{
  echo "# tmux sessions @ $(date)"; tmux list-sessions 2>&1
  echo; echo "# tmux windows + sizes (width >~350 or 2x others = the scramble bug)"
  for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
    echo "## session $s"
    tmux list-windows -t "$s": -F "#{window_id} #{window_width}x#{window_height} #{window_name}" 2>&1
  done
  echo; echo "# Claude agent count + total RSS"
  ps -axo pid,rss,command | grep -E '[c]laude |/[c]laude| 2\.1\.1[0-9]' \
    | awk '{c++; r+=$2} END{printf "agents~=%d  total_RSS=%.1f GB\n", c, r/1024/1024}'
} > "$OUT/06-tmux-agents.txt"
log ""

# --- 7. Recently written crash/hang/jetsam reports --------------------------
log "[7/8] recent diagnostic reports (last 30 min) -> 07-diag-reports.txt"
{
  echo "# DiagnosticReports modified in last 30 min @ $(date)"
  find /Library/Logs/DiagnosticReports "$HOME/Library/Logs/DiagnosticReports" \
    -type f -mmin -30 2>/dev/null -exec ls -lt {} + 2>/dev/null | head -30
} > "$OUT/07-diag-reports.txt"
log ""

# --- 8. Unified log: real hang/jetsam/memorystatus signals (root only) ------
# Note: grep for whole-word signals; "hang" alone false-matches "changed".
if [ $IS_ROOT = 1 ] && have log; then
  log "[8/8] unified log (last 5 min: hang/jetsam/memorystatus) -> 08-unifiedlog.txt"
  log show --last 5m --predicate \
    'eventMessage CONTAINS "memorystatus" OR eventMessage CONTAINS "jetsam" OR eventMessage CONTAINS[c] "not responding" OR eventMessage CONTAINS[c] "watchdog" OR eventMessage CONTAINS[c] "hang_event" OR eventMessage CONTAINS[c] "stackshot"' \
    > "$OUT/08-unifiedlog.txt" 2>&1
  log "      $(grep -c . "$OUT/08-unifiedlog.txt" 2>/dev/null) lines"
else
  log "[8/8] unified-log scan SKIPPED (needs sudo)"
fi
log ""

# --- bundle it up -----------------------------------------------------------
TAR="$ROOT/dist/freeze-reports/freeze-$TS.tar.gz"
tar -czf "$TAR" -C "$ROOT/dist/freeze-reports" "freeze-$TS" 2>/dev/null \
  && log "bundled: $TAR"

log ""
log "=== DONE ==="
log "Read first:  $OUT/01-sample-buildwright.txt   (where the main thread was stuck)"
log "Then:        $OUT/00-summary.txt  +  02..08"
[ $IS_ROOT = 0 ] && log "For the FULL picture next time:  sudo $0 $DUR"
