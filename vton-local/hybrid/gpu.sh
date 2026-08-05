#!/usr/bin/env bash
# Bring the render GPU up for a session and put it away afterwards.
#
#   gpu.sh up        start the pod, pull the repo, start the worker (auto-stops)
#   gpu.sh down      stop it now (keeps the disk and the weights)
#   gpu.sh status    state, uptime, and what this session has cost so far
#   gpu.sh ssh       shell in, on whatever port it came back on
#   gpu.sh logs      tail the worker log
#
# WHY THIS EXISTS. A pod left running costs $0.69/h — about $500 a month — and a
# render takes under three seconds, so at development volume nearly all of that
# buys idling. Starting the pod per session and stopping it after brings that to
# roughly the cost of the hours actually spent testing.
#
# THE PORT CHANGES EVERY TIME THE POD STARTS. Three separate times in one session
# the ssh command was the thing that was wrong, not the pod — so `up` reads the
# current host and port from the API and caches them, and `ssh`/`logs` use the
# cache instead of a number pasted from an old note.
#
# Config lives OUTSIDE the repo (it holds an API key):
#   ~/.config/looktok/runpod.env
#     RUNPOD_API_KEY=...      # console → Settings → API Keys
#     RUNPOD_POD_ID=...       # the pod's id, from its page URL
#     SSH_KEY=~/.ssh/id_ed25519
set -uo pipefail

CFG="${RUNPOD_ENV:-$HOME/.config/looktok/runpod.env}"
CACHE="$HOME/.config/looktok/runpod.state"
RATE="${GPU_HOURLY:-0.69}"

[ -f "$CFG" ] || {
  cat >&2 <<EOF
FAIL: no config at $CFG

  mkdir -p ~/.config/looktok
  cat > $CFG <<'ENV'
RUNPOD_API_KEY=your-key
RUNPOD_POD_ID=your-pod-id
SSH_KEY=$HOME/.ssh/id_ed25519
ENV
  chmod 600 $CFG
EOF
  exit 1
}
set -a; . "$CFG"; set +a
: "${RUNPOD_API_KEY:?set in $CFG}" "${RUNPOD_POD_ID:?set in $CFG}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
mkdir -p "$(dirname "$CACHE")"

api() {  # api <METHOD> <path>
  local body code
  body=$(curl -sS -o /dev/stdout -w '\n%{http_code}' -X "$1" \
    "https://rest.runpod.io/v1$2" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" -H 'Content-Type: application/json')
  code=${body##*$'\n'}
  body=${body%$'\n'*}
  case "$code" in
    2*) printf '%s' "$body"; return 0 ;;
    401|403)
      # Learned the hard way: the RUNPOD_API_KEY that RunPod injects INTO a pod is
      # not an account key and cannot manage pods — it 403s here, and the pod's
      # own runpodctl ships unauthenticated. This needs a key from
      # console.runpod.io → Settings → API Keys.
      echo "FAIL: RunPod rejected the key ($code). It must be an ACCOUNT key from" >&2
      echo "      Settings → API Keys — a pod-injected key cannot control pods." >&2
      return 1 ;;
    404) echo "FAIL: pod $RUNPOD_POD_ID not found (terminated, or wrong id)" >&2; return 1 ;;
    *)   echo "FAIL: RunPod API returned $code" >&2; return 1 ;;
  esac
}

pod_json() { api GET "/pods/$RUNPOD_POD_ID"; }

# The REST shape has moved around; read it with python rather than assuming a
# field path, and say what was actually returned when it does not parse.
parse_ssh() {
  python3 - "$@" <<'PY'
import json, sys
d = json.load(sys.stdin)
status = d.get("desiredStatus") or d.get("status") or "?"
host, port = None, None
for pm in (d.get("portMappings") or []) if isinstance(d.get("portMappings"), list) else []:
    if str(pm.get("privatePort")) == "22":
        host, port = pm.get("ip") or pm.get("publicIp"), pm.get("publicPort")
if port is None and isinstance(d.get("portMappings"), dict):
    port = d["portMappings"].get("22")
for rt in (d.get("runtime") or {}).get("ports", []) or []:
    if str(rt.get("privatePort")) == "22":
        host, port = rt.get("ip"), rt.get("publicPort")
host = host or d.get("publicIp") or d.get("ip")
print(f"{status}\t{host or ''}\t{port or ''}")
PY
}

read_state() { [ -f "$CACHE" ] && . "$CACHE"; }

refresh() {  # wait until ssh details exist, cache them
  for _ in $(seq 60); do
    IFS=$'\t' read -r st host port < <(pod_json | parse_ssh) || true
    if [ -n "${host:-}" ] && [ -n "${port:-}" ]; then
      printf 'HOST=%s\nPORT=%s\nSTARTED=%s\n' "$host" "$port" "$(date +%s)" > "$CACHE"
      echo "$st"
      return 0
    fi
    sleep 5
  done
  echo "FAIL: pod has no ssh port after 5 min (state: ${st:-unknown})" >&2
  return 1
}

case "${1:-status}" in
up)
  echo "starting pod $RUNPOD_POD_ID …"
  api POST "/pods/$RUNPOD_POD_ID/start" >/dev/null || {
    echo "FAIL: start rejected — check the balance first, that is what ended the last session" >&2
    exit 1; }
  refresh >/dev/null || exit 1
  read_state
  echo "pod up at $HOST:$PORT"
  # `up` is not done when the API says running: the weights still have to load.
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 \
      -i "$SSH_KEY" -p "$PORT" "root@$HOST" \
      'cd /workspace/SnapStyle && git pull -q --ff-only; \
       mkdir -p /workspace/logs; \
       nohup bash /workspace/SnapStyle/vton-local/hybrid/autostop.sh \
         >> /workspace/logs/autostop.log 2>&1 & \
       sleep 1; echo "[gpu] worker starting; it will stop the pod after 15 min idle"'
  echo "ready. renders go through the queue as usual; \`gpu.sh logs\` to watch."
  ;;
down)
  api POST "/pods/$RUNPOD_POD_ID/stop" >/dev/null && echo "stopped (disk and weights kept)"
  read_state
  if [ -n "${STARTED:-}" ]; then
    h=$(python3 -c "print(f'{($(date +%s)-$STARTED)/3600:.2f}')")
    echo "session: ${h}h ≈ \$$(python3 -c "print(f'{$h*$RATE:.2f}')")"
  fi
  rm -f "$CACHE"
  ;;
status)
  IFS=$'\t' read -r st host port < <(pod_json | parse_ssh) || {
    echo "FAIL: cannot read pod (bad key, or pod deleted)" >&2; exit 1; }
  echo "pod:    $RUNPOD_POD_ID"
  echo "state:  $st"
  [ -n "$host" ] && echo "ssh:    root@$host -p $port"
  read_state
  if [ -n "${STARTED:-}" ]; then
    h=$(python3 -c "print(f'{($(date +%s)-$STARTED)/3600:.2f}')")
    echo "uptime: ${h}h ≈ \$$(python3 -c "print(f'{$h*$RATE:.2f}')") at \$$RATE/h"
  fi
  ;;
ssh)
  read_state || { echo "FAIL: no cached host — run \`gpu.sh up\` first" >&2; exit 1; }
  shift || true
  exec ssh -i "$SSH_KEY" -p "$PORT" "root@$HOST" "$@"
  ;;
logs)
  read_state || { echo "FAIL: no cached host — run \`gpu.sh up\` first" >&2; exit 1; }
  exec ssh -i "$SSH_KEY" -p "$PORT" "root@$HOST" \
    'tail -f /workspace/logs/vton.log /workspace/logs/autostop.log'
  ;;
*)
  sed -n '2,20p' "$0" >&2
  exit 2
  ;;
esac
