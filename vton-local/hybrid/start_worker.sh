#!/usr/bin/env bash
# Start (or restart) the queue worker on the GPU box.
#
# Exists because ad-hoc `ssh "... &"` one-liners kept killing the old process and
# failing to start the replacement — the `&` bound to the wrong list — leaving no
# worker at all while pgrep briefly still matched one. Every job enqueued in that
# window went unclaimed and every Edge Function fell back to the hosted provider.
#
#   bash /workspace/start_worker.sh
#
# Requires SUPABASE_SERVICE_ROLE_KEY in the environment or in /workspace/env.sh.
set -u

APP="${APP:-/workspace/SnapStyle/vton-local/hybrid}"
LOG="${LOG:-/workspace/logs/vton.log}"
VENV="${VENV:-/workspace/venv}"

[ -f /workspace/env.sh ] && . /workspace/env.sh
cd "$APP" || { echo "FAIL: $APP missing"; exit 1; }
mkdir -p "$(dirname "$LOG")"

pkill -f worker_jobs.py 2>/dev/null
sleep 2

# COUNT THE LOG'S EXISTING LINES FIRST. The readiness check greps for 'warm',
# and the log is appended to across restarts — so grepping the whole tail matched
# the PREVIOUS run's 'warm' and reported ready while this process was still
# loading ~5 GB into VRAM. Jobs enqueued in that window were never claimed
# (observed: a failed row with attempts=0). Only lines past this offset count.
BEFORE=$(wc -l < "$LOG" 2>/dev/null || echo 0)

export SUPABASE_URL="${SUPABASE_URL:-https://tnirnwapfgckfypvtooj.supabase.co}"
export HF_HOME="${HF_HOME:-/workspace/huggingface}"
export VTON_STEPS="${VTON_STEPS:-20}"
setsid nohup "$VENV/bin/python" worker_jobs.py >> "$LOG" 2>&1 < /dev/null &
disown

# Warmup loads the weights and runs a throwaway render. Until it prints 'warm'
# the queue is NOT being consumed, so wait for it rather than assuming success.
for _ in $(seq 60); do
  if tail -n "+$((BEFORE + 1))" "$LOG" | grep -q '\[worker\] warm'; then
    echo "OK: worker warm, pid $(pgrep -f worker_jobs.py | head -1)"
    exit 0
  fi
  sleep 2
done
echo 'FAIL: worker did not warm within 120s'
tail -n "+$((BEFORE + 1))" "$LOG" | tail -5
exit 1
