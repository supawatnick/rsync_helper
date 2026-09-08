#!/bin/sh
# rsync-loop.sh — the core loop used inside the rsync-helper pod.
# Extracted from the pod manifests so it can be reviewed / tested outside k8s.
# In production, the loop lives inside the pod `args` (self-contained pod).
#
# Environment variables (optional overrides):
#   SRC_PATH    source dir            (default: /src)
#   DST_PATH    destination dir       (default: /dst)
#   INTERVAL    sleep between runs    (default: 300)
#   TIMEOUT     rsync --timeout       (default: 10)
#   LOG_FILE    history log path      (default: /var/log/rsync/sync-history.log)

SRC="${SRC_PATH:-/src}"
DST="${DST_PATH:-/dst}"
INTERVAL="${INTERVAL:-300}"
TIMEOUT="${TIMEOUT:-10}"
LOG_DIR="$(dirname "${LOG_FILE:-/var/log/rsync/sync-history.log}")"
LOG_FILE="${LOG_FILE:-$LOG_DIR/sync-history.log}"

mkdir -p "$LOG_DIR"
ITER=0

echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] rsync-helper started (interval: ${INTERVAL}s, log: $LOG_FILE)" | tee -a "$LOG_FILE"

while true; do
  ITER=$((ITER+1))
  TS=$(date '+%Y-%m-%d %H:%M:%S %Z')

  {
    echo ""
    echo "========================================================"
    echo "[$TS] ITERATION #$ITER starting"
    echo "========================================================"

    echo ""
    echo "[$TS] Files BEFORE sync:"
    echo "  $SRC/ ($(ls "$SRC/" 2>/dev/null | wc -l) entries):"
    ls -la "$SRC/" 2>/dev/null | tail -n +2 | awk '{print "    " $0}'
    echo "  $DST/ ($(ls "$DST/" 2>/dev/null | wc -l) entries):"
    ls -la "$DST/" 2>/dev/null | tail -n +2 | awk '{print "    " $0}'

    echo ""
    echo "[$TS] Running rsync (avzPi --delete --timeout=$TIMEOUT)..."
    RSYNC_OUT=$(rsync -avzPi --delete --timeout="$TIMEOUT" "$SRC/" "$DST/" 2>&1)
    RSYNC_EXIT=$?
    echo "$RSYNC_OUT"

    echo ""
    echo "[$TS] === CHANGE SUMMARY ==="
    NEW=$(echo "$RSYNC_OUT" | grep -c '^>f++++++++++')
    MOD=$(echo "$RSYNC_OUT" | grep -E '^>f\.' | grep -vc '^>f++++++++++')
    DEL=$(echo "$RSYNC_OUT" | grep -c '^\*deleting')
    DIRCHG=$(echo "$RSYNC_OUT" | grep -c '^\.d')
    TOTAL_BYTES=$(echo "$RSYNC_OUT" | grep '^total size' | awk '{print $4, "bytes"}')
    echo "  New files:      $NEW"
    echo "  Modified files: $MOD"
    echo "  Deleted files:  $DEL"
    echo "  Dir changes:    $DIRCHG"
    echo "  Total size:     $TOTAL_BYTES"

    [ "$NEW" -gt 0 ] && {
      echo ""
      echo "[$TS] NEW files copied:"
      echo "$RSYNC_OUT" | grep '^>f++++++++++' | awk '{print "  + " $2, "(size:", $4 ")"}'
    }
    [ "$MOD" -gt 0 ] && {
      echo ""
      echo "[$TS] MODIFIED files:"
      echo "$RSYNC_OUT" | grep -E '^>f\.' | grep -v '^>f++++++++++' | awk '{print "  ~ " $2, "[" $1 "]"}'
    }
    [ "$DEL" -gt 0 ] && {
      echo ""
      echo "[$TS] DELETED files:"
      echo "$RSYNC_OUT" | grep '^\*deleting' | awk '{print "  - " $4}'
    }

    if [ "$RSYNC_EXIT" -ne 0 ]; then
      echo ""
      echo "[$TS] !! RSYNC EXIT CODE: $RSYNC_EXIT (FAILED) !!"
      ERRORS=$(echo "$RSYNC_OUT" | grep -iE "failed|error|permission denied|no space" | head -5)
      if [ -n "$ERRORS" ]; then
        echo "  Errors found:"
        echo "$ERRORS" | sed 's/^/    /'
      fi
    else
      echo ""
      echo "[$TS] Rsync exit code: 0 (SUCCESS)"
    fi

    echo ""
    echo "[$TS] Files AFTER sync:"
    echo "  $DST/ ($(ls "$DST/" 2>/dev/null | wc -l) entries):"
    ls -la "$DST/" 2>/dev/null | tail -n +2 | awk '{print "    " $0}'

    echo ""
    echo "[$TS] MD5 integrity check:"
    SRC_FILES=$(ls "$SRC/" | sort)
    DST_FILES=$(ls "$DST/" | sort)
    if [ "$SRC_FILES" = "$DST_FILES" ]; then
      INTEGRITY_OK=1
      INTEGRITY_COUNT=0
      for f in $SRC_FILES; do
        if [ -f "$SRC/$f" ] && [ -f "$DST/$f" ]; then
          S=$(md5sum "$SRC/$f" | awk '{print $1}')
          D=$(md5sum "$DST/$f" | awk '{print $1}')
          if [ "$S" = "$D" ]; then
            echo "  OK       $f"
            INTEGRITY_COUNT=$((INTEGRITY_COUNT+1))
          else
            echo "  MISMATCH $f (src:$S dst:$D)"
            INTEGRITY_OK=0
          fi
        fi
      done
      if [ "$INTEGRITY_OK" -eq 1 ]; then
        echo "  [ALL $INTEGRITY_COUNT FILES OK - data integrity verified]"
      else
        echo "  [INTEGRITY CHECK FAILED]"
      fi
    else
      echo "  File lists differ:"
      diff <(ls "$SRC/") <(ls "$DST/") | sed 's/^/    /'
    fi

    echo ""
    echo "[$TS] ITERATION #$ITER done. Sleeping ${INTERVAL}s..."
    echo "========================================================"
  } | tee -a "$LOG_FILE"

  sleep "$INTERVAL"
done