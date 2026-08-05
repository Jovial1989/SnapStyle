#!/usr/bin/env bash
# Run the worker in the FOREGROUND and stop the pod when it goes quiet.
#
# The card costs $0.69/h whether it renders or waits, and a render takes under
# three seconds. At development volume that is over 99% idle — the difference
# between roughly $40 and roughly $500 a month is entirely "did anyone remember
# to press stop". Remembering is not a plan, so the pod stops itself.
#
#   nohup bash /workspace/SnapStyle/vton-local/hybrid/autostop.sh &> /workspace/logs/autostop.log &
#
# The worker exits on its own after VTON_IDLE_EXIT_SEC with an empty queue; this
# wrapper then asks RunPod to stop the pod. Stopping keeps the disk and the
# network volume — `gpu.sh up` brings the same pod back with the weights still
# there. It is not `terminate`, which would destroy them.
#
# Everything the pod needs to identify itself is already in its environment
# (RUNPOD_POD_ID). Authentication is tried three ways because which one a given
# template ships with varies, and a wrapper that cannot stop the pod is the one
# failure that costs real money — so it says so loudly instead of exiting 0.
set -u

APP="${APP:-/workspace/SnapStyle/vton-local/hybrid}"
LOG="${LOG:-/workspace/logs/vton.log}"
VENV="${VENV:-/workspace/venv}"

[ -f /workspace/env.sh ] && . /workspace/env.sh
cd "$APP" || { echo "FAIL: $APP missing"; exit 1; }
mkdir -p "$(dirname "$LOG")"

pkill -f worker_jobs.py 2>/dev/null
sleep 2

export SUPABASE_URL="${SUPABASE_URL:-https://tnirnwapfgckfypvtooj.supabase.co}"
export HF_HOME="${HF_HOME:-/workspace/huggingface}"
export VTON_STEPS="${VTON_STEPS:-20}"
# Fifteen minutes: long enough to survive thinking between two taps in the app,
# short enough that a forgotten session costs cents.
export VTON_IDLE_EXIT_SEC="${VTON_IDLE_EXIT_SEC:-900}"

echo "[autostop] worker up, idle exit at ${VTON_IDLE_EXIT_SEC}s" >&2
"$VENV/bin/python" worker_jobs.py 2>&1 | tee -a "$LOG"
code=${PIPESTATUS[0]}
echo "[autostop] worker exited ($code)" >&2

POD="${RUNPOD_POD_ID:-}"
if [ -z "$POD" ]; then
  echo "[autostop] WARNING: RUNPOD_POD_ID unset — CANNOT STOP THE POD, it is still billing" >&2
  exit 1
fi

stop_ok=0
if command -v runpodctl >/dev/null 2>&1; then
  runpodctl stop pod "$POD" && stop_ok=1
fi
if [ "$stop_ok" = 0 ] && [ -n "${RUNPOD_API_KEY:-}" ]; then
  # REST first, then the older GraphQL mutation, since which of the two an
  # account can reach has changed over time.
  curl -fsS -X POST "https://rest.runpod.io/v1/pods/$POD/stop" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" >/dev/null && stop_ok=1
  if [ "$stop_ok" = 0 ]; then
    curl -fsS -X POST "https://api.runpod.io/graphql?api_key=$RUNPOD_API_KEY" \
      -H 'Content-Type: application/json' \
      -d "{\"query\":\"mutation{podStop(input:{podId:\\\"$POD\\\"}){id desiredStatus}}\"}" \
      >/dev/null && stop_ok=1
  fi
fi

if [ "$stop_ok" = 1 ]; then
  echo "[autostop] pod $POD stopped" >&2
else
  echo "[autostop] WARNING: every stop method failed — POD $POD IS STILL BILLING." >&2
  echo "[autostop] Put RUNPOD_API_KEY in /workspace/env.sh, or stop it in the console." >&2
  exit 1
fi
