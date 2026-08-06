#!/usr/bin/env bash
# Smoke-test every endpoint of the local Qwen3-VL worker against real fixtures.
# Usage: ./smoke_qwen.sh <dir-with-fixtures>   (default: this repo's ./fixtures)
set -uo pipefail
BASE="${BASE:-http://localhost:8124}"
FIX="${1:-$(cd "$(dirname "$0")" && pwd)/fixtures}"

j() { python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin), ensure_ascii=False, indent=2)[:1200])"; }

echo "── /health"
curl -s --max-time 20 "$BASE/health" | j || echo "worker not up"

echo; echo "── /critique  (founder's real outfit photo)"
time curl -s --max-time 900 -X POST "$BASE/critique" \
  -F "image=@$FIX/founder_outfit.jpg" | j

echo; echo "── /slots"
time curl -s --max-time 900 -X POST "$BASE/slots" \
  -F "image=@$FIX/founder_outfit.jpg" -F "premium=false" | j

echo; echo "── /same-person  (avatar vs avatar → expect same=true)"
time curl -s --max-time 600 -X POST "$BASE/same-person" \
  -F "render=@$FIX/his_avatar.png" -F "person=@$FIX/his_avatar.png" | j

echo; echo "── /same-person  (impostor render vs avatar → expect same=false)"
time curl -s --max-time 600 -X POST "$BASE/same-person" \
  -F "render=@$FIX/his_render.jpg" -F "person=@$FIX/his_avatar.png" | j

echo; echo "── /classify-item  (catalog Chelsea boot → expect shoes)"
time curl -s --max-time 600 -X POST "$BASE/classify-item" \
  -F "image=@$FIX/test_garment.png" | j

echo; echo "── /validate  (avatar + a garment flat-lay → expect [true, false])"
time curl -s --max-time 900 -X POST "$BASE/validate" \
  -F "images=@$FIX/his_avatar.png" -F "images=@$FIX/test_garment.png" | j

echo; echo "── /body-profile (height 183)"
time curl -s --max-time 900 -X POST "$BASE/body-profile" \
  -F "image=@$FIX/founder_outfit.jpg" -F "height_cm=183" | j
