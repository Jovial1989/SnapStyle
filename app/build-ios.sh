#!/bin/sh
# Build the iOS release WITH cloud (Supabase) enabled.
#
# WHY THIS EXISTS: `flutter build ios --release` with no dart-defines silently
# falls back to the LOCAL Node dev server (http://10.0.2.2:4242). On a real
# device that host is unreachable, so every network call (analyze, generate…)
# times out after ~60s and the UI looks frozen. cloudEnabledProvider only turns
# true when SUPABASE_URL + SUPABASE_ANON_KEY are compiled in. Always build with
# this script for device/TestFlight builds.
#
# Usage:  ./build-ios.sh            # release for a physical device
#         ./build-ios.sh --debug    # debug flavour (attachable logs)
set -e

cd "$(dirname "$0")"
ENV_FILE="../backend/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found — can't read Supabase credentials." >&2
  exit 1
fi

# Supabase renamed the client key anon -> publishable; the app reads it as
# SUPABASE_ANON_KEY. Source both straight from the backend env.
SUPA_URL=$(grep '^SUPABASE_URL=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)
SUPA_KEY=$(grep '^SUPABASE_PUBLISHABLE_KEY=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)

if [ -z "$SUPA_URL" ] || [ -z "$SUPA_KEY" ]; then
  echo "ERROR: SUPABASE_URL or SUPABASE_PUBLISHABLE_KEY missing/empty in $ENV_FILE." >&2
  exit 1
fi

AMP_KEY=$(grep '^AMPLITUDE_API_KEY=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs || true)

MODE="--release"
[ "$1" = "--debug" ] && MODE="--debug"

echo "Building iOS $MODE with cloud → ${SUPA_URL}"
flutter build ios $MODE \
  --dart-define=SUPABASE_URL="$SUPA_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPA_KEY" \
  ${AMP_KEY:+--dart-define=AMPLITUDE_API_KEY="$AMP_KEY"}
