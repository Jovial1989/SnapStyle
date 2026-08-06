#!/usr/bin/env bash
# Restart the Qwen bench worker. Waits for the OLD process to actually exit
# before starting the new one — otherwise the dying process keeps answering
# /health and you end up testing stale code (cost me a bogus 404 once).
set -uo pipefail
cd "$(dirname "$0")"
LOG="${LOG:-/tmp/qwen_worker.log}"
pkill -f "uvicorn qwen_worker" 2>/dev/null
until ! pgrep -f "uvicorn qwen_worker" >/dev/null; do sleep 0.5; done
PYTORCH_ENABLE_MPS_FALLBACK=1 nohup ./.venv-qwen/bin/uvicorn qwen_worker:app \
  --host "${HOST:-127.0.0.1}" --port 8124 > "$LOG" 2>&1 &
until curl -s --max-time 3 http://127.0.0.1:8124/health 2>/dev/null | grep -q '"ok":true'; do sleep 3; done
echo "worker up → http://127.0.0.1:8124/  (log: $LOG)"
