#!/usr/bin/env bash
set -euo pipefail

# Captures the 8 App Store marketing screenshots by driving the app's
# DEBUG-only demo mode (-DemoData -DemoRoute <route>) through each route on a
# 6.9"-class simulator. Re-runnable: reuses an already-booted/created
# simulator, overwrites existing PNGs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="$ROOT_DIR/StackTrackerPro.xcodeproj"
SCHEME="StackTrackerPro"
BUNDLE_ID="com.gyndok.stacktrackerpro"
DERIVED_DATA="$ROOT_DIR/tools/screenshots/.build"
OUT_DIR="$ROOT_DIR/marketing/screenshots"
FALLBACK_DEVICE_NAME="Screenshot 6.9"

mkdir -p "$OUT_DIR"

echo "==> Finding newest iOS runtime"
RUNTIME_ID=$(xcrun simctl list runtimes -j | jq -r '
  [.runtimes[] | select(.isAvailable) | select(.identifier | contains("iOS"))]
  | sort_by(.version) | last | .identifier')
if [ -z "$RUNTIME_ID" ] || [ "$RUNTIME_ID" = "null" ]; then
  echo "ERROR: no available iOS runtime found" >&2
  exit 1
fi
RUNTIME_NAME=$(xcrun simctl list runtimes -j | jq -r --arg id "$RUNTIME_ID" '.runtimes[] | select(.identifier == $id) | .name')
echo "    runtime: $RUNTIME_NAME ($RUNTIME_ID)"

echo "==> Picking device"
UDID=$(xcrun simctl list devices available -j | jq -r --arg rt "$RUNTIME_ID" '
  .devices[$rt][]? | select(.name | test("Pro Max")) | .udid' | head -1)

if [ -z "$UDID" ]; then
  # Reuse a previously created fallback device by name if one exists.
  UDID=$(xcrun simctl list devices available -j | jq -r --arg rt "$RUNTIME_ID" --arg name "$FALLBACK_DEVICE_NAME" '
    .devices[$rt][]? | select(.name == $name) | .udid' | head -1)
fi

if [ -z "$UDID" ]; then
  echo "    no 'Pro Max' device found; creating fallback \"$FALLBACK_DEVICE_NAME\""
  if xcrun simctl list devicetypes | grep -q "iPhone 17 Pro Max ("; then
    DEVICETYPE="iPhone 17 Pro Max"
  else
    # Fall back to the largest available iPhone device type on this machine.
    DEVICETYPE=$(xcrun simctl list devicetypes \
      | grep -o '^iPhone [^(]*Pro Max' | head -1 | sed -E 's/ +$//')
    if [ -z "$DEVICETYPE" ]; then
      DEVICETYPE=$(xcrun simctl list devicetypes \
        | grep -o '^iPhone [^(]*' | sed -E 's/ +$//' | head -1)
    fi
  fi
  echo "    device type: $DEVICETYPE"
  UDID=$(xcrun simctl create "$FALLBACK_DEVICE_NAME" "$DEVICETYPE" "$RUNTIME_ID")
fi

DEVICE_NAME_ACTUAL=$(xcrun simctl list devices available -j | jq -r --arg rt "$RUNTIME_ID" --arg udid "$UDID" '
  .devices[$rt][] | select(.udid == $udid) | .name')
echo "    using device: $DEVICE_NAME_ACTUAL ($UDID)"

echo "==> Building Debug (derivedDataPath: $DERIVED_DATA)"
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  | tail -20

APP_PATH=$(find "$DERIVED_DATA/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name "*.app" | head -1)
if [ -z "$APP_PATH" ]; then
  echo "ERROR: could not locate built .app under $DERIVED_DATA/Build/Products/Debug-iphonesimulator" >&2
  exit 1
fi
echo "    app: $APP_PATH"

echo "==> Booting simulator"
BOOT_STATE=$(xcrun simctl list devices available -j | jq -r --arg udid "$UDID" '
  .devices[][] | select(.udid == $udid) | .state')
if [ "$BOOT_STATE" != "Booted" ]; then
  xcrun simctl boot "$UDID"
fi
xcrun simctl bootstatus "$UDID" -b

echo "==> Setting status bar"
xcrun simctl status_bar "$UDID" override \
  --time "9:41" \
  --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4 --operatorName ""

echo "==> Installing app"
xcrun simctl install "$UDID" "$APP_PATH"

ROUTES=(graph metrics capture hands dictation chat results share)

for i in "${!ROUTES[@]}"; do
  N=$((i + 1))
  ROUTE="${ROUTES[$i]}"
  IDX=$(printf "%02d" "$N")
  DEST="$OUT_DIR/$IDX-$ROUTE.png"
  echo "==> Capturing $IDX-$ROUTE"
  rm -f "$DEST"
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -DemoData -DemoRoute "$ROUTE"
  sleep 3
  xcrun simctl io "$UDID" screenshot "$DEST"
done

echo "==> Clearing status bar"
xcrun simctl status_bar "$UDID" clear

echo ""
echo "==> Screenshot summary"
printf "%-20s %-8s %-8s\n" "FILE" "WIDTH" "HEIGHT"
for f in "$OUT_DIR"/*.png; do
  W=$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}')
  H=$(sips -g pixelHeight "$f" | awk '/pixelHeight/{print $2}')
  printf "%-20s %-8s %-8s\n" "$(basename "$f")" "$W" "$H"
  if [ "$W" != "1320" ] || [ "$H" != "2868" ]; then
    echo "WARNING: not 1320x2868"
  fi
done

echo ""
echo "Done. Device: $DEVICE_NAME_ACTUAL ($UDID)"
