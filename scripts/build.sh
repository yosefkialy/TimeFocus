#!/bin/bash
# Direct swiftc build (no SwiftPM / Xcode required).
#
#   scripts/build.sh                 # build everything (release flags)
#   scripts/build.sh EncoderCheck    # build one executable and its module deps
#   BUILD_DIR=/tmp/x scripts/build.sh FocusSelfTest
#
# Modules are compiled whole-module (-wmo) into one object file each and linked
# statically into every executable that needs them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD_DIR:-$ROOT/.build-swiftc}"
SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx14.0"
OPT="${OPT:--O}"
SWIFTC=(xcrun swiftc -sdk "$SDK" -target "$TARGET" -swift-version 5 "$OPT" -wmo -g
        -enable-bare-slash-regex)

# Timestamps can't see a compiler/SDK update: modules from another compiler don't import, and objects would keep the
# old SDK's API references. Start clean whenever the toolchain changes.
TOOLCHAIN="$(xcrun swiftc --version 2>&1 | head -1); SDK $(xcrun --show-sdk-version) ($(xcrun --show-sdk-build-version))"
if [[ "$(cat "$BUILD/toolchain" 2>/dev/null)" != "$TOOLCHAIN" ]]; then
  rm -rf "$BUILD/mods" "$BUILD/obj" "$BUILD/bin"
fi
mkdir -p "$BUILD/mods" "$BUILD/obj" "$BUILD/bin"
echo "$TOOLCHAIN" > "$BUILD/toolchain"

module_deps() {
  case "$1" in
    FocusTransformer) echo "" ;;
    FocusML) echo "" ;;
    FocusCore) echo "FocusTransformer FocusML" ;;
    *) echo "unknown module $1" >&2; exit 1 ;;
  esac
}

exe_deps() {
  case "$1" in
    TimeFocusApp) echo "FocusTransformer FocusML FocusCore" ;;
    FocusSelfTest) echo "FocusTransformer FocusML FocusCore" ;;
    EncoderCheck) echo "FocusTransformer" ;;
    TFWatchdog) echo "" ;;
    *) echo "unknown executable $1" >&2; exit 1 ;;
  esac
}

link_flags() {
  local mods="$1"
  local flags=(-framework Accelerate)
  if [[ " $mods " == *" FocusCore "* ]]; then
    flags+=(-lsqlite3 -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit
            -framework Vision -framework IOKit -framework UserNotifications -framework Carbon
            -framework NaturalLanguage -framework SwiftUI -framework Charts -framework ServiceManagement
            -Xlinker -weak_framework -Xlinker FoundationModels)
  fi
  echo "${flags[@]}"
}

sources_of() { find "$ROOT/Sources/$1" -name '*.swift' | sort; }

# Output file name of an executable target (the watchdog must not contain "TimeFocus" in its process name).
exe_output_name() {
  case "$1" in
    TFWatchdog) echo "tf-watchdog" ;;
    *) echo "$1" ;;
  esac
}

needs_rebuild() { # target_file, source_dir, dep objs...
  local out="$1"; shift
  local srcdir="$1"; shift
  [[ -f "$out" ]] || return 0
  if [[ -n "$(find "$srcdir" -name '*.swift' -newer "$out" -print -quit)" ]]; then return 0; fi
  for dep in "$@"; do [[ "$dep" -nt "$out" ]] && return 0; done
  return 1
}

build_module() {
  local name="$1"
  local deps; deps="$(module_deps "$name")"
  local depobjs=() d
  for d in $deps; do build_module "$d"; depobjs+=("$BUILD/obj/$d.o"); done
  local out="$BUILD/obj/$name.o"
  if needs_rebuild "$out" "$ROOT/Sources/$name" ${depobjs[@]+"${depobjs[@]}"}; then
    echo "==> module $name"
    # shellcheck disable=SC2046
    "${SWIFTC[@]}" -parse-as-library -module-name "$name" \
      -emit-module -emit-module-path "$BUILD/mods/$name.swiftmodule" \
      -I "$BUILD/mods" -c $(sources_of "$name") -o "$out"
  fi
}

build_exe() {
  local name="$1"
  local deps; deps="$(exe_deps "$name")"
  local objs=() d
  for d in $deps; do build_module "$d"; objs+=("$BUILD/obj/$d.o"); done
  local out; out="$BUILD/bin/$(exe_output_name "$name")"
  local extra=()
  # Executables using @main need -parse-as-library; main.swift-style ones must not use it.
  if ! find "$ROOT/Sources/$name" -name 'main.swift' | grep -q .; then extra+=(-parse-as-library); fi
  if needs_rebuild "$out" "$ROOT/Sources/$name" ${objs[@]+"${objs[@]}"}; then
    echo "==> executable $name"
    # Run from $BUILD: swiftc writes the executable's debug module (<name>-1.swiftmodule…) to the working directory.
    # shellcheck disable=SC2046
    (cd "$BUILD" && "${SWIFTC[@]}" ${extra[@]+"${extra[@]}"} -module-name "$name" -I "$BUILD/mods" \
      $(sources_of "$name") ${objs[@]+"${objs[@]}"} $(link_flags "$deps") -o "$out")
  fi
}

if [[ $# -eq 0 ]]; then
  set -- TFWatchdog EncoderCheck FocusSelfTest TimeFocusApp
fi
for t in "$@"; do
  case "$t" in
    FocusTransformer|FocusML|FocusCore) build_module "$t" ;;
    *) build_exe "$t" ;;
  esac
done
echo "build ok -> $BUILD/bin"
