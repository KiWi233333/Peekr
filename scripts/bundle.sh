#!/bin/bash
# Build Peekr and assemble a runnable .app bundle (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/Peekr.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Peekr" "$APP/Contents/MacOS/Peekr"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" || true

# --- Optional Chromium (CEF) shim --------------------------------------------
# 默认只打进 SMALL 原生件(libpeekr_cef.dylib + Peekr Helper.app);~280MB 的 Chromium
# 框架默认「首次运行时下载」、不进包,使默认 app 保持小巧。
# 设 PEEKR_CEF_BUNDLE=1 则改为「框架进包」模式(Electron 模型):框架随包签名+公证——这是
# renderer 能启动的必要条件,代价是包体 +~280MB(见下方 framework 进包块)。
#
# Auto-enabled when the CEF SDK is present, so a normal `make run` includes it
# without remembering flags: CEF_ROOT defaults to ~/cef-sdk/cef_binary_*minimal,
# and PEEKR_CEF defaults to "auto" (on iff the SDK is found). PEEKR_CEF=0 forces
# it off (e.g. CI, which has no SDK → Chromium stays unavailable, app unaffected).
if [ -z "${CEF_ROOT:-}" ]; then
  CEF_ROOT="$(ls -d "$HOME"/cef-sdk/cef_binary_*macosarm64*minimal 2>/dev/null | head -1 || true)"
fi
case "${PEEKR_CEF:-auto}" in
  auto) if [ -n "${CEF_ROOT:-}" ]; then PEEKR_CEF=1; else PEEKR_CEF=0; fi ;;
esac

HELPER_APP=""
BUNDLED_FW=""
if [ "$PEEKR_CEF" = "1" ] && [ -n "${CEF_ROOT:-}" ]; then
  echo "Building CEF shim (CEF_ROOT=$CEF_ROOT)…"
  cmake -S cef-shim -B cef-shim/build -DCEF_ROOT="$CEF_ROOT" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DUSE_SANDBOX=OFF >/dev/null
  cmake --build cef-shim/build -j"$(sysctl -n hw.ncpu)" >/dev/null
  mkdir -p "$APP/Contents/Frameworks"
  cp cef-shim/build/libpeekr_cef.dylib "$APP/Contents/Frameworks/"
  HELPER_APP="$APP/Contents/Frameworks/Peekr Helper.app"
  rm -rf "$HELPER_APP"; mkdir -p "$HELPER_APP/Contents/MacOS"
  cp cef-shim/build/peekr_helper "$HELPER_APP/Contents/MacOS/Peekr Helper"
  cat > "$HELPER_APP/Contents/Info.plist" <<'HPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Peekr Helper</string>
<key>CFBundleIdentifier</key><string>com.peekr.app.helper</string>
<key>CFBundleName</key><string>Peekr Helper</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
HPLIST
  echo "Bundled CEF shim + helper into $APP."

  # 框架进包(Electron 模型)——PEEKR_CEF_BUNDLE=1 时把 Chromium 框架拷进包内,随包一起
  # 签名+公证。这是 renderer 子进程能启动的关键:框架在包外(运行时下载)会让进程代码签名
  # 自校验失败(errSecCSReqFailed),renderer 永远起不来。代价是 base 包 +~280MB,所以
  # 默认关闭(默认仍走「首次运行时下载」的轻量模式)。
  if [ "${PEEKR_CEF_BUNDLE:-0}" = "1" ]; then
    SRC_FW="$CEF_ROOT/Release/Chromium Embedded Framework.framework"
    if [ -d "$SRC_FW" ]; then
      echo "Bundling Chromium framework into $APP (~280MB)…"
      rm -rf "$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
      cp -R "$SRC_FW" "$APP/Contents/Frameworks/"
      BUNDLED_FW="$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
    else
      echo "WARN: PEEKR_CEF_BUNDLE=1 but framework missing at $SRC_FW" >&2
    fi
  fi
fi

# Sign so WebKit + per-app data stores work. Prefer a real, stable signing
# identity over ad-hoc: macOS binds Automation/TCC grants (e.g. "allow Peekr to
# read Chrome's open tabs") to the sender's code signature. Ad-hoc's cdhash
# changes on every rebuild, so each `make run` silently revokes those grants and
# tab import breaks. A stable identity (Developer ID / Apple Development) keeps a
# constant designated requirement, so a granted permission sticks across builds.
#
# Override with PEEKR_SIGN_IDENTITY; otherwise auto-pick the first available
# stable identity; fall back to ad-hoc only when none exist.
if [ -n "${PEEKR_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$PEEKR_SIGN_IDENTITY"
else
  # `|| true`: with `set -o pipefail`, grep matching no identity (e.g. on CI, where
  # none exist) exits non-zero and would abort the script before the ad-hoc fallback
  # below ever runs. An empty IDENTITY is the intended "no identity" signal, not an error.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"(Developer ID Application|Apple Development)[^"]*"' \
    | head -1 | tr -d '"' || true)"
fi

# Resolve the base codesign args once. Distribution builds (PEEKR_HARDENED=1, set
# by the release pipeline) add the hardened runtime + a secure timestamp —
# notarization prerequisites. Local `make run` leaves it off, so signing stays
# offline-friendly and fast while still using a stable identity for TCC grants.
if [ -n "$IDENTITY" ]; then
  BASE=(--force --sign "$IDENTITY")
  if [ "${PEEKR_HARDENED:-0}" = "1" ]; then
    BASE+=(--options runtime)
    # 安全时间戳是「公证」的前置,但需联网时间戳服务、签多文件时易超时。本地验证(只看
    # renderer/签名结构,不提交公证)可设 PEEKR_NO_TIMESTAMP=1 跳过。正式公证务必带上。
    [ "${PEEKR_NO_TIMESTAMP:-0}" = "1" ] || BASE+=(--timestamp)
  fi
else
  echo "Note: no stable signing identity found — ad-hoc signing. Automation grants" >&2
  echo "      (browser-tab import) reset on each rebuild. Set PEEKR_SIGN_IDENTITY to a" >&2
  echo "      Developer ID / Apple Development identity to make grants stick." >&2
  BASE=(--force --sign -)
fi

# Entitlements (hardened distribution only): CEF helpers need the JIT relaxations;
# the CEF main app needs disable-library-validation to load the downloaded
# framework (app-cef.entitlements), else the plain WebKit entitlements.
HELPER_ENT=""; APP_ENT=""
if [ "${PEEKR_HARDENED:-0}" = "1" ] && [ -n "$IDENTITY" ]; then
  if [ -n "$BUNDLED_FW" ]; then
    # 框架进包路径:框架与 app 同 team 签名,故不需要 disable-library-validation。
    # 保持进程「纯同 team」,内核才能派生 validation category(renderer 才被放行)。
    HELPER_ENT="cef-shim/entitlements/helper-bundled.entitlements"
    APP_ENT="Resources/Peekr.entitlements"
  elif [ -n "$HELPER_APP" ]; then
    # 运行时下载路径:框架是包外的异 team / ad-hoc 签名,主程序需 disable-library-validation 才能加载。
    HELPER_ENT="cef-shim/entitlements/helper.entitlements"
    APP_ENT="cef-shim/entitlements/app-cef.entitlements"
  else
    APP_ENT="Resources/Peekr.entitlements"
  fi
fi

# 签一个目标。entitlements 以路径字符串传(空=无),避免展开空数组(bash 3.2 + set -u 会报错)。
# 硬化签名带 --timestamp 时会请求 Apple 时间戳服务;快速签很多文件常被限流报
# "The timestamp service is not available",故带退避重试(只在 hardened 路径需要)。
sign1() {
  local path="$1" ent="${2:-}"
  local args=("${BASE[@]}")
  [ -n "$ent" ] && args+=(--entitlements "$ent")
  if [ "${PEEKR_HARDENED:-0}" = "1" ]; then
    local n=0 max=6 out
    until out="$(codesign "${args[@]}" "$path" 2>&1)"; do
      n=$((n+1))
      if [ $n -ge $max ] || ! printf '%s' "$out" | grep -qi "timestamp"; then
        echo "$out" >&2; return 1
      fi
      echo "  timestamp 限流,${n}/$((max-1)) 退避重试: $(basename "$path")" >&2
      sleep $((n*3))
    done
  else
    codesign "${args[@]}" "$path" >/dev/null 2>&1 || true
  fi
}

# Inside-out:先签包内 CEF 各部件,最后签主 .app(它会密封 Contents/Frameworks)。
# 刻意不用 `--deep`(会破坏嵌套签名)。框架要先于 app 签:库 → 框架本体 → helper/dylib → app。
if [ -n "$BUNDLED_FW" ]; then
  for lib in "$BUNDLED_FW/Libraries/"*.dylib; do
    [ -f "$lib" ] && sign1 "$lib" ""
  done
  sign1 "$BUNDLED_FW" ""
fi
if [ -n "$HELPER_APP" ]; then
  sign1 "$APP/Contents/Frameworks/libpeekr_cef.dylib" ""
  sign1 "$HELPER_APP" "$HELPER_ENT"
fi
sign1 "$APP" "$APP_ENT"
echo "Signed $APP${IDENTITY:+ with \"$IDENTITY\"}"

echo "Built $APP"
