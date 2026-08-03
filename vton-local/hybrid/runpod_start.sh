#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Hybrid VTON worker — RunPod bootstrap.
#
#   export GITHUB_TOKEN=ghp_xxx          # only for a private repo
#   bash runpod_start.sh
#
# Safe to re-run: every step is idempotent and skips itself when already done,
# so a restart after the first setup reaches uvicorn in seconds rather than
# repeating a 3 GB download.
#
# EVERYTHING lands in /workspace — RunPod's network volume. The container
# filesystem (/, /root, /usr/lib/python3/...) is ephemeral: it is wiped on every
# pod stop, which is why the venv, the pip cache and the HF weights all live on
# the volume instead of where pip would put them by default.
#
# The web terminal kills its children when the tab closes. Either run this
# inside `tmux` (recommended) or start it with DAEMON=1.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── config (override by exporting before the call) ───────────────────────────
WORKSPACE="${WORKSPACE:-/workspace}"
REPO_URL="${REPO_URL:-https://github.com/Jovial1989/SnapStyle.git}"
REPO_DIR="${REPO_DIR:-$WORKSPACE/SnapStyle}"
BRANCH="${BRANCH:-main}"
APP_SUBDIR="${APP_SUBDIR:-vton-local/hybrid}"
PORT="${PORT:-8125}"
VENV="${VENV:-$WORKSPACE/venv}"
DAEMON="${DAEMON:-0}"

# torch 2.5.1 is not a preference — xformers 0.0.28.post3 is compiled against
# that exact ABI. A mismatched pair imports fine and then dies at the first
# attention call with an undefined-symbol error.
TORCH_VER="2.5.1"
TVISION_VER="0.20.1"
TAUDIO_VER="2.5.1"
CUDA_CHANNEL="https://download.pytorch.org/whl/cu124"

log()  { echo -e "\033[1;36m[INFO]\033[0m  $(date +%H:%M:%S)  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $(date +%H:%M:%S)  $*"; }
die()  { echo -e "\033[1;31m[FAIL]\033[0m  $(date +%H:%M:%S)  $*" >&2; exit 1; }

trap 'die "aborted at line $LINENO"' ERR

# ── 0. sanity ────────────────────────────────────────────────────────────────
log "GPU check"
command -v nvidia-smi >/dev/null || die "nvidia-smi missing — this is not a GPU pod"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader \
  || die "nvidia-smi failed — the GPU is not visible to this container"

[ -d "$WORKSPACE" ] || die "$WORKSPACE does not exist — attach a network volume to this pod"

# ── 1. persistent environment ────────────────────────────────────────────────
# Written to a file so an SSH session or a later `docker exec` inherits the same
# paths instead of silently re-downloading 10 GB of weights into the ephemeral
# system disk (the classic "why is my pod out of space" on RunPod).
ENV_FILE="$WORKSPACE/env.sh"
cat > "$ENV_FILE" <<EOF
export HF_HOME=$WORKSPACE/huggingface
export PIP_CACHE_DIR=$WORKSPACE/.cache/pip
export TORCHINDUCTOR_CACHE_DIR=$WORKSPACE/.cache/inductor
export VTON_OFFLOAD=0
export VTON_XFORMERS=1
export PATH=$VENV/bin:\$PATH
EOF
# shellcheck source=/dev/null
source "$ENV_FILE"
mkdir -p "$HF_HOME" "$PIP_CACHE_DIR" "$WORKSPACE/logs"
log "env persisted to $ENV_FILE (HF_HOME=$HF_HOME)"

# ── 2. system libraries ──────────────────────────────────────────────────────
# mediapipe links libGL and glib even with the headless OpenCV build. These live
# on the ephemeral disk, so they must be reinstalled on every pod start — the
# dpkg check keeps that to ~1 s once they are cached by apt.
if ! dpkg -s libgl1 libglib2.0-0 >/dev/null 2>&1; then
  log "installing system libraries (libgl1, libglib2.0-0)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends libgl1 libglib2.0-0 >/dev/null
else
  log "system libraries already present — skipping"
fi

# ── 3. source ────────────────────────────────────────────────────────────────
# The token is NEVER written into .git/config. That file lives on the network
# volume and would outlive the pod, the token, and your memory of putting it
# there. A credential helper that reads the env var at call time leaks nothing.
if [ -n "${GITHUB_TOKEN:-}" ]; then
  GIT_CRED_HELPER='!f() { echo username=x-access-token; echo "password=$GITHUB_TOKEN"; }; f'
else
  GIT_CRED_HELPER=""
fi

if [ -d "$REPO_DIR/.git" ]; then
  log "repo exists — pulling $BRANCH"
  cd "$REPO_DIR"
  [ -n "$GIT_CRED_HELPER" ] && git config credential.helper "$GIT_CRED_HELPER"
  git fetch --quiet origin "$BRANCH"
  git checkout --quiet "$BRANCH"
  git reset --hard --quiet "origin/$BRANCH"   # pod-side edits are never precious
else
  log "cloning $REPO_URL"
  git clone --quiet --branch "$BRANCH" --depth 1 "$REPO_URL" "$REPO_DIR" 2>/dev/null || {
    [ -n "$GIT_CRED_HELPER" ] || die "clone failed — private repo? export GITHUB_TOKEN first"
    git -c "credential.helper=$GIT_CRED_HELPER" clone --quiet --branch "$BRANCH" \
        --depth 1 "$REPO_URL" "$REPO_DIR"
    git -C "$REPO_DIR" config credential.helper "$GIT_CRED_HELPER"
  }
fi

APP_DIR="$REPO_DIR/$APP_SUBDIR"
[ -f "$APP_DIR/main.py" ] || die "$APP_DIR/main.py not found — is $APP_SUBDIR committed and pushed?"
cd "$APP_DIR"
log "app at $APP_DIR ($(git -C "$REPO_DIR" rev-parse --short HEAD))"

# ── 4. python environment ────────────────────────────────────────────────────
# A venv ON THE VOLUME. Installing into the image's site-packages works exactly
# once: the next pod start finds an empty disk and repeats the whole 3 GB
# install. This is the single biggest restart-time win available here.
if [ ! -x "$VENV/bin/python" ]; then
  log "creating venv at $VENV"
  python3 -m venv "$VENV"
fi
# shellcheck source=/dev/null
source "$VENV/bin/activate"
python -m pip install --quiet --upgrade pip setuptools wheel
log "python $(python -V 2>&1 | cut -d' ' -f2) from $(command -v python)"

# ── 5. torch: force the exact cu124 build ────────────────────────────────────
# The pod's default template ships torch 2.0. Nothing in the pipeline works on
# it, so this is a hard replace, not an upgrade-if-newer.
CURRENT_TORCH="$(python -c 'import torch;print(torch.__version__)' 2>/dev/null || echo none)"
if [[ "$CURRENT_TORCH" == "$TORCH_VER+cu124" ]]; then
  log "torch $CURRENT_TORCH already correct — skipping"
else
  log "upgrading PyTorch: $CURRENT_TORCH → $TORCH_VER+cu124 (a few minutes, ~2.5 GB)"
  pip install --quiet \
    "torch==$TORCH_VER" "torchvision==$TVISION_VER" "torchaudio==$TAUDIO_VER" \
    --index-url "$CUDA_CHANNEL"
fi

# A constraints file so the NEXT pip call cannot quietly pull a PyPI torch over
# the cu124 one while resolving some transitive dependency. This is the failure
# that looks like "it worked yesterday": same code, CPU-only wheel underneath.
CONSTRAINTS="$WORKSPACE/pip-constraints.txt"
cat > "$CONSTRAINTS" <<EOF
torch==$TORCH_VER
torchvision==$TVISION_VER
torchaudio==$TAUDIO_VER
EOF

# ── 6. project dependencies ──────────────────────────────────────────────────
log "installing requirements-cuda.txt"
pip install --quiet -r requirements-cuda.txt -c "$CONSTRAINTS"

# hf_transfer is in requirements, but the host may export the flag while the
# package fails to build on some platform. huggingface_hub treats that as fatal
# instead of falling back to plain HTTP, so prove it imports or turn the flag
# off — a slower download beats an aborted one.
if [ "${HF_HUB_ENABLE_HF_TRANSFER:-0}" = "1" ] && ! python -c "import hf_transfer" 2>/dev/null; then
  warn "hf_transfer unavailable — disabling accelerated download"
  export HF_HUB_ENABLE_HF_TRANSFER=0
  echo "export HF_HUB_ENABLE_HF_TRANSFER=0" >> "$ENV_FILE"
fi

# ── 7. verify before spending GPU time ───────────────────────────────────────
# Fail here, loudly, rather than 20 minutes later inside a render.
log "verifying the stack"
python - <<'PY'
import sys, torch
print(f"  torch      {torch.__version__}")
print(f"  cuda avail {torch.cuda.is_available()}")
if not torch.cuda.is_available():
    sys.exit("torch cannot see the GPU — wrong wheel (CPU/cu118) or a driver mismatch")
print(f"  device     {torch.cuda.get_device_name(0)}")
print(f"  vram       {torch.cuda.get_device_properties(0).total_memory / 2**30:.1f} GiB")
try:
    import xformers, xformers.ops  # ops import is what surfaces an ABI mismatch
    print(f"  xformers   {xformers.__version__}")
except Exception as e:
    sys.exit(f"xformers is broken against torch {torch.__version__}: {e}")
import diffusers, transformers, mediapipe, cv2
print(f"  diffusers  {diffusers.__version__}")
print(f"  mediapipe  {mediapipe.__version__} (solutions: {hasattr(mediapipe, 'solutions')})")
if not hasattr(mediapipe, "solutions"):
    sys.exit("mediapipe lacks the legacy solutions API — pin 0.10.21")
PY

# ── 8. weights ───────────────────────────────────────────────────────────────
# Idempotent: snapshot_download hits the HF_HOME cache and returns instantly
# once the weights are on the volume, so this costs nothing on a restart.
log "prefetching weights into $HF_HOME (first run: several minutes)"
python prefetch.py

# ── 9. serve ─────────────────────────────────────────────────────────────────
export VTON_WARMUP=1   # load + a 2-step throwaway render before opening the port
LOGFILE="$WORKSPACE/logs/vton.log"

cat <<EOF

  ready — starting uvicorn on 0.0.0.0:$PORT

  RunPod only routes ports declared in the pod's template. If $PORT is not in
  this pod's exposed list, nothing outside will reach it — either add it and
  restart the pod, or tunnel over the SSH you already have:

      ssh -L $PORT:localhost:$PORT root@<pod-ip> -p <ssh-port> -i ~/.ssh/id_ed25519

EOF

if [ "$DAEMON" = "1" ]; then
  log "daemon mode — logging to $LOGFILE"
  nohup uvicorn main:app --host 0.0.0.0 --port "$PORT" \
        --workers 1 --timeout-keep-alive 75 >>"$LOGFILE" 2>&1 &
  echo $! > "$WORKSPACE/logs/vton.pid"
  log "pid $(cat "$WORKSPACE/logs/vton.pid") — follow with: tail -f $LOGFILE"
else
  # exec: uvicorn replaces this shell, so Ctrl-C and pod signals reach it
  # directly instead of orphaning the server behind a wrapper process.
  exec uvicorn main:app --host 0.0.0.0 --port "$PORT" \
       --workers 1 --timeout-keep-alive 75
fi
