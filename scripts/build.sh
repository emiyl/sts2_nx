#!/usr/bin/env bash
# build.sh -- end-to-end
#
#   1. weave the patch set into the game assemblies (Mono.Cecil)
#   2. NativeAOT-compile them to libsts2.so (ILC)
#   3. build the wrapper NRO (devkitA64)
#   4. assemble the SD layout
#
# Any stage can run alone: ./build.sh weave|aot|nro|stage
# No argument runs all four.
#
# The inherited drmariomania_nx scripts/ was not forked: build-godot.sh built
# an engine from source we do not have, and make-bootstrap-pck.py packed a
# project.godot that does not exist here. This replaces both.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW="${GAME_ASSEMBLIES:-$ROOT/aot/assemblies-raw}"
PATCHED="$ROOT/aot/assemblies-patched"
APK_DIR="${APK_DIR:-$ROOT/apk}"
OUT="$ROOT/dist"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need_dir() { [ -d "$1" ] || die "$2"; }
check_xml() { python3 "$ROOT/tools/xml_check.py" "$ROOT"; }

# ---------------------------------------------------------------- 1. weave --
do_weave() {
  say "weaving patches"
  check_xml
  python3 "$ROOT/tools/stamp_patchset.py" "$ROOT" 2>/dev/null || true
  python3 "$ROOT/tools/sh_check.py" "$ROOT" 2>/dev/null || true
  python3 "$ROOT/tools/abi_check.py" "$ROOT/source" 2>/dev/null || true
  python3 "$ROOT/tools/sandbox_check.py" "$ROOT/source" || die "unsandboxed path import"
  python3 "$ROOT/tools/bionic_abi.py" "$ROOT/source" 2>/dev/null || true
  python3 "$ROOT/tools/arity_check.py" "$ROOT/source" 2>/dev/null || true
  need_dir "$RAW" "no game assemblies at $RAW.
Extract them from your own Steam install (aot/README.md step 1), or point
GAME_ASSEMBLIES at them."

  command -v dotnet >/dev/null || die ".NET 9 SDK not found on PATH"

  dotnet build "$ROOT/patches/STS2Switch/STS2Switch.csproj" -c Release \
    -p:GameAssemblyDir="$RAW"

  local patch_dll
  patch_dll="$(find "$ROOT/patches/STS2Switch/bin/Release" -name STS2Switch.dll | head -1)"
  [ -n "$patch_dll" ] || die "STS2Switch.dll was not produced"

  rm -rf "$PATCHED"

  # --strict escalates Optional patches to required. It is NOT passed by
  # default, because passing it unconditionally is the same as not having
  # Optional at all -- which is what happened: a patch deliberately marked
  # Optional, for a type that might not exist, failed the build anyway.
  #
  # Non-optional patches still fail without it. --strict only changes what
  # happens to the ones that were declared as "may be absent".
  #
  # STS2_STRICT=--strict for a release build, where a silently dropped patch is
  # worth failing over.
  # That is the entire reason this is a build step rather than runtime Harmony.
  # The Android launcher's PatchHelper logs "FAILED {type}.{method}: method not
  # found" and carries on, and the result is a game that boots and then behaves
  # wrongly on a device with no console to read.
  dotnet run --project "$ROOT/tools/StS2Patcher" -c Release -- \
    --game "$RAW" --patches "$patch_dll" --out "$PATCHED" ${STS2_STRICT:-}
}

# ------------------------------------------------------------------ 2. aot --
do_aot_linux() {
  say "NativeAOT compile"
  check_xml
  [ "$(uname -s)" = Linux ] || die "NativeAOT build requires Linux; use the Lima VM on macOS."
  if [ "$(uname -m)" != x86_64 ] && [ "${STS2_ROSETTA:-0}" != 1 ]; then
    die "NativeAOT requires Linux x86_64 or an ARM64 Lima VM with Rosetta enabled."
  fi
  command -v dotnet >/dev/null || die ".NET SDK 9.0.317 not found on PATH"
  local sdk_version
  sdk_version="$(dotnet --version)"
  [ "$sdk_version" = 9.0.317 ] || die "this payload is pinned to .NET SDK 9.0.317 (found $sdk_version)."
  [ -n "${ANDROID_NDK:-}" ] || die "ANDROID_NDK is not set; point it at Android NDK r27c."
  [ -f "$ANDROID_NDK/source.properties" ] || die "ANDROID_NDK does not look like an extracted NDK: $ANDROID_NDK"
  grep -q 'Pkg.Revision = 27.2.12479018' "$ANDROID_NDK/source.properties" || die "this build is pinned to Android NDK r27c (27.2.12479018)."
  local ndk_bin="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
  [ -x "$ndk_bin/clang" ] || die "NDK clang not found at $ndk_bin/clang"
  export PATH="$ndk_bin:$PATH"

  need_dir "$RAW" "no game assemblies at $RAW; extract them first (see aot/README.md)."
  mkdir -p "$OUT"
  local gen
  gen="$(mktemp "${TMPDIR:-/tmp}/sts2nx-rd.XXXXXX")"
  trap 'rm -f "${gen:-}"' EXIT
  IN="$RAW" OUT="$OUT" PROJECT_ROOT="$ROOT" AOT_RD_XML="$gen" \
    bash "$ROOT/scripts/docker-entry.sh"
}

do_aot_macos() {
  local vm=sts2nx-build
  command -v limactl >/dev/null || die "Lima is required on macOS. Install it with: brew install lima lima-additional-guestagents"

  if [ -d "$HOME/.lima/$vm" ]; then
    limactl start "$vm"
  else
    say "creating Linux build VM with Lima"
    limactl start --name="$vm" --vm-type=vz --arch=aarch64 --rosetta \
      --cpus=8 --memory=16 --disk=100 \
      --mount-only "$ROOT:w" template:ubuntu-24.04
  fi

  say "preparing pinned Linux AOT toolchain"
  limactl shell "$vm" bash -s -- "$ROOT" <<'LIMA_BUILD'
set -euo pipefail
PROJECT_ROOT="$1"
DOTNET_ROOT="$HOME/.dotnet-x64"
ANDROID_NDK="$HOME/android-ndk-r27c"
if ! command -v curl >/dev/null || ! command -v unzip >/dev/null || ! command -v python3 >/dev/null; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl unzip python3
fi

if ! dpkg --print-foreign-architectures | grep -qx amd64; then
  sudo dpkg --add-architecture amd64
fi
sudo python3 - <<'PY'
from pathlib import Path
for path in Path('/etc/apt/sources.list.d').glob('*.sources'):
    text = path.read_text()
    if 'ports.ubuntu.com' in text:
        text = text.replace('Types: deb\n', 'Types: deb\nArchitectures: arm64\n')
        path.write_text(text)
Path('/etc/apt/sources.list.d/amd64.sources').write_text('''Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Architectures: amd64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: noble-security
Components: main restricted universe multiverse
Architectures: amd64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
''')
PY
sudo apt-get update
sudo apt-get install -y libc6:amd64 libgcc-s1:amd64 libstdc++6:amd64 zlib1g:amd64 libicu74:amd64 libssl3:amd64

if [ ! -x "$DOTNET_ROOT/dotnet" ]; then
  mkdir -p "$DOTNET_ROOT"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  bash /tmp/dotnet-install.sh --version 9.0.317 --architecture x64 --install-dir "$DOTNET_ROOT"
fi

if [ ! -x "$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]; then
  curl -fsSL https://dl.google.com/android/repository/android-ndk-r27c-linux.zip -o /tmp/android-ndk-r27c.zip
  unzip -q /tmp/android-ndk-r27c.zip -d "$HOME"
  rm /tmp/android-ndk-r27c.zip
fi

export DOTNET_ROOT ANDROID_NDK
export PATH="$DOTNET_ROOT:$PATH"
export STS2_ROSETTA=1
bash "$PROJECT_ROOT/scripts/build.sh" aot
LIMA_BUILD
}

do_aot() {
  case "$(uname -s)" in
    Linux)
      do_aot_linux
      ;;
    Darwin)
      do_aot_macos
      ;;
    *)
      die "AOT build is supported on Linux x86_64 or macOS (through Lima)."
      ;;
  esac
}

# ------------------------------------------------------------------ 3. nro --
do_nro() {
  say "building the wrapper"
  [ -n "${DEVKITPRO:-}" ] || die "DEVKITPRO not set:
  export DEVKITPRO=/opt/devkitpro"
  make -C "$ROOT" -j"$(nproc 2>/dev/null || echo 4)"
}

# ---------------------------------------------------------------- 4. stage --
do_stage() {
  say "assembling the SD layout"
  mkdir -p "$OUT"

  [ -f "$ROOT/sts2.nro" ] && cp "$ROOT/sts2.nro" "$OUT/"

  if [ -d "$APK_DIR" ]; then
    local lib="$APK_DIR/lib/arm64-v8a"
    for f in libgodot_android.so libc++_shared.so \
             libGodotFmod.android.template_release.arm64.so \
             libspine_godot.android.template_release.arm64.so; do
      if [ -f "$lib/$f" ]; then cp "$lib/$f" "$OUT/"; else echo "  MISSING: $f"; fi
    done

    # These two are under assets/native/, NOT lib/arm64-v8a/ -- the launcher
    # extracts them at runtime. Single easiest thing to miss when assembling
    # by hand, which is most of why this script exists.
    for f in libfmod.so libfmodstudio.so; do
      if [ -f "$APK_DIR/assets/native/$f" ]; then
        cp "$APK_DIR/assets/native/$f" "$OUT/"
      else
        echo "  MISSING: $f  (assets/native/ in the APK, not lib/)"
      fi
    done

    [ -d "$APK_DIR/assets" ] && cp -r "$APK_DIR/assets" "$OUT/"
  else
    echo "  APK_DIR unset or absent; skipping engine/GDExtension staging"
  fi

  local so
  so="$(find "$ROOT/aot/bin" -name '*.so' -path '*publish*' 2>/dev/null | head -1)"
  [ -n "$so" ] && cp "$so" "$OUT/libsts2.so"

  # override.cfg sits NEXT TO THE PCK, not in assets/.
  #
  # Godot has two code paths and takes exactly one. With --main-pack, which is
  # what the wrapper passes:
  #
  #   _load_settings_text(p_main_pack.get_base_dir().path_join("override.cfg"))
  #
  # so it reads <dir containing sts2.pck>/override.cfg. The "res://override.cfg"
  # string also in the binary belongs to the directory-project path, which we
  # never take. Both strings are present in libgodot_android.so; only one is
  # reachable here.
  #
  # Copied only if absent: it is meant to be edited on the card one setting at
  # a time, and clobbering those edits every build would defeat the point.
  if [ -f "$ROOT/dist_template/override.cfg" ]; then
    if [ -f "$OUT/override.cfg" ]; then
      echo "  keeping your existing override.cfg"
    else
      cp "$ROOT/dist_template/override.cfg" "$OUT/override.cfg"
      echo "  staged override.cfg next to the pck (all settings commented out)"
    fi
  fi

  say "staged in $OUT"
  echo "Still needed, from your own Steam install:"
  echo "  sts2.pck   -- the launcher APK carries no game content"
  echo
  echo "Then copy $OUT/* into /switch/<any-name>/ on the SD card."
  echo "The directory name does not matter; app_paths.c discovers it."
}

case "${1:-all}" in
  weave) do_weave ;;
  aot)   do_aot ;;
  nro)   do_nro ;;
  stage) do_stage ;;
  all)   do_weave; do_aot; do_nro; do_stage ;;
  *)     die "usage: scripts/build.sh [weave|aot|nro|stage]" ;;
esac
