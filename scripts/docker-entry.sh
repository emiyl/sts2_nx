#!/usr/bin/env bash
# docker-entry.sh -- weave + AOT inside the container.
#
# Mounts:
#   /in    your game assemblies, read-only (sts2.dll and friends from Steam,
#          GodotSharp.dll extracted from the launcher's libassembly-store.so)
#   /out   where libsts2.so is written
#
# Nothing from /in is copied out. The only thing that leaves is the compiled
# native image, which is yours and stays yours -- it is a reproduction of the
# game's own code in a different form, so it belongs on your SD card and
# nowhere else.

set -euo pipefail

# Lookup mode: `docker run ... sts2nx-aot list ModelDb` prints the real types
# and methods matching a pattern. Use it when the weave cannot resolve a target
# -- guessing costs a full weave per attempt.
if [ "${1:-}" = "list" ]; then
  shift
  [ $# -ge 1 ] || { echo "usage: ... sts2nx-aot list <pattern>" >&2; exit 2; }
  exec dotnet run --project /src/tools/StS2Patcher -c Release -- \
    --game "${IN:-/in}" --list-types "$1"
fi

# Dumps the GodotSharp API needed to write the NativeAOT entry point. Godot's
# SDK normally supplies GodotPlugins.Game.Main with the
# [UnmanagedCallersOnly(EntryPoint = "godotsharp_game_main_init")] export, but
# that assembly only exists when building under Godot.NET.Sdk with PublishAot,
# so it is in neither the shipped game nor the launcher.
if [ "${1:-}" = "bootstrap-info" ]; then
  exec dotnet run --project /src/tools/StS2Patcher -c Release -- \
    --game "${IN:-/in}" --bootstrap-info
fi

IN="${IN:-/in}"
OUT="${OUT:-/out}"
ROOT="${PROJECT_ROOT:-/src}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$IN" ]  || die "mount your assemblies at $IN (docker run -v /path:/in:ro ...)"
mkdir -p "$OUT"

# ---------------------------------------------------------------- preflight --
say "checking inputs"

missing=0
for f in sts2.dll GodotSharp.dll; do
  if [ -f "$IN/$f" ]; then
    printf '  %-20s %s\n' "$f" "ok"
  else
    printf '  %-20s %s\n' "$f" "MISSING"
    missing=1
  fi
done

if [ "$missing" = 1 ]; then
  cat >&2 <<'EOF'

sts2.dll        from your own Steam install (the game's managed assembly).
                It is NOT in the launcher APK -- the launcher downloads game
                content from Steam at runtime.

GodotSharp.dll  from the launcher APK, NOT from Steam:

                  python3 tools/extract_assembly_store.py \
                    libassembly-store.so ./out GodotSharp.dll

                Steam's copy is built against the DESKTOP engine; the
                libgodot_android.so on your SD card is the launcher's custom
                Android build. GodotSharp carries the interop surface the
                engine binds against, so a mismatch shows up as missing
                methods at runtime rather than as a clean load error.
EOF
  exit 1
fi

# Everything sts2.dll references has to be resolvable. Report rather than
# guess: an assembly ILC cannot resolve fails late and unhelpfully.
count=$(find "$IN" -maxdepth 1 -name '*.dll' | wc -l)
echo "  ${count} assemblies in $IN"

# ------------------------------------------------------------------- weave --
# Fingerprint the patch sources into SwitchLog before they are compiled, so the
# payload announces which patch set it is. Three rounds were lost to logs from
# a payload built before the fix under test; "the expected line is missing" is
# an ambiguous signal, a printed id is not.
if command -v python3 >/dev/null; then
  python3 "$ROOT/tools/stamp_patchset.py" "$ROOT" || true
fi

say "weaving patches"

WORK=/tmp/work
rm -rf "$WORK"; mkdir -p "$WORK/raw"
cp "$IN"/*.dll "$WORK/raw/"

dotnet build "$ROOT/patches/STS2Switch/STS2Switch.csproj" -c Release \
  -p:GameAssemblyDir="$WORK/raw" --nologo

PATCH_DLL="$(find "$ROOT/patches/STS2Switch/bin/Release" -name STS2Switch.dll | head -1)"
[ -n "$PATCH_DLL" ] || die "STS2Switch.dll was not produced"

set +e
# No --nologo here: dotnet run forwards unrecognised options past the `--` to
# the program, which rejects them. It is valid on build and publish only.
dotnet run --project "$ROOT/tools/StS2Patcher" -c Release -- \
  --game "$WORK/raw" --patches "$PATCH_DLL" --out "$WORK/patched" ${STS2_STRICT:-}
weave_rc=$?
set -e

if [ $weave_rc -eq 2 ]; then
  cat >&2 <<'EOF'

StS2Patcher rejected its own arguments -- this is a bug in docker-entry.sh, not
a problem with your assemblies or the patch set. The weaver never ran.
EOF
  exit 2
fi

if [ $weave_rc -eq 3 ]; then
  cat >&2 <<'EOF'

StS2Patcher crashed rather than reporting a weave failure. The stack trace is
above. This is a bug in the tool, not a problem with your assemblies or the
patch names.
EOF
  exit 3
fi

if [ $weave_rc -ne 0 ]; then
  cat >&2 <<'EOF'

The weave failed, which means a patch target could not be resolved.

That is the intended behaviour, not a bug: the alternative is the Android
launcher's, which logs "FAILED {type}.{method}: method not found" and carries
on, giving a game that boots and then behaves wrongly on a device with no
console to read.

The output above names each unresolved target and lists the candidates it did
find. Correct the name in patches/STS2Switch/ and re-run. Target names came
from the launcher's own patch set, so they are right for the build it targeted
-- a game update can still move them.
EOF
  exit 1
fi

# ------------------------------------------------------------------ filter --
#
# The weave output is the WHOLE desktop app: the game assemblies plus the
# entire .NET runtime that shipped alongside them. ILC must see only the first
# group.
#
# Referencing the desktop System.Private.CoreLib next to the SDK's net9.0
# framework gives "the type X exists in both System.Private.CoreLib and
# System.Runtime", and once the compiler is confused about CoreLib it loses
# System.String and System.Void as well -- a dozen errors that all trace back
# to one duplicate.
#
# Framework-ness is decided by asking the SDK rather than by a hardcoded list:
# anything in the Microsoft.NETCore.App reference pack is the runtime's to
# supply. System.Private.* is implementation-only, never appears in the ref
# pack, and so has to be named explicitly.
say "selecting AOT inputs"

DOTNET_ROOT="${DOTNET_ROOT:-$(dirname "$(readlink -f "$(command -v dotnet)")")}"
REFPACK="$(ls -d "$DOTNET_ROOT"/packs/Microsoft.NETCore.App.Ref/*/ref/net*/ 2>/dev/null | tail -1)"
[ -n "$REFPACK" ] || die "could not locate the Microsoft.NETCore.App reference pack under $DOTNET_ROOT"
echo "  framework list: $REFPACK"

rm -rf "$WORK/refs"; mkdir -p "$WORK/refs"
kept=0; dropped=0

for f in "$WORK/patched"/*.dll; do
  n="$(basename "$f")"

  if [ -f "$REFPACK/$n" ]; then dropped=$((dropped+1)); continue; fi

  case "$n" in
    System.Private.*)
      dropped=$((dropped+1)); continue ;;
    clr*|coreclr.dll|hostfxr.dll|hostpolicy.dll|mscordaccore*|mscordbi.dll|mscorrc.dll|msquic.dll|Microsoft.DiaSymReader.Native.*|steam_api64.dll|System.IO.Compression.Native.dll)
      dropped=$((dropped+1)); continue ;;
    WindowsBase.dll|System.Windows.dll|Vortice.*|SharpGen.*)
      dropped=$((dropped+1)); continue ;;
  esac

  cp "$f" "$WORK/refs/"
  kept=$((kept+1))
done

echo "  kept $kept, dropped $dropped"
ls "$WORK/refs" | sed 's/^/    /'

[ -f "$WORK/refs/sts2.dll" ]       || die "sts2.dll was filtered out -- bug in the filter"
[ -f "$WORK/refs/GodotSharp.dll" ] || die "GodotSharp.dll was filtered out -- bug in the filter"

# The weave rewrites sts2.dll to call into STS2Switch, so both the patch
# assembly and the attributes assembly it references must reach ILC. Missing
# either gives "Failed to load assembly 'STS2Switch'" from ilc, several steps
# removed from the actual cause.
for req in STS2Switch.dll STS2Switch.Attributes.dll; do
  [ -f "$WORK/refs/$req" ] || die "$req is missing from the AOT inputs.
StS2Patcher should have carried it from the patch build directory into
--out. Check for a 'carried into output' line in the weave output above."
done

# ------------------------------------------------------- generated roots --
#
# ILC treats <Assembly Name="X"> for an assembly not in the compilation as a
# HARD ERROR, not something to skip. Hand-maintaining that list means every
# wrong guess is a failed build several minutes in -- GodotSharpEditor,
# System.Text.Json, FmodSharp, fmod_godot, spine-godot and SpineGodotSharp all
# failed this way in turn.
#
# So it is generated from what is actually being compiled. Rooting all of them
# is what we want regardless: aot/README.md's advice is to start broad and
# narrow once the game boots.
say "generating assembly roots"

# Root ONLY the assemblies that need it, not everything in the reference set.
#
# "Root everything" was the first approach and it is wrong for third-party
# code. Rooting an assembly forces ILC to compile EVERY type in it, including
# ones nothing references -- and some of those do not compile. Steamworks.NET
# is the concrete case: it contains SteamNetworkingConfigValue_t.OptionValue,
# an explicit-layout union whose fields overlap at offset 0, and ILC rejects it
# with "Failed to load type 'OptionValue' ... because of field offset '0'".
# Nothing in the game needed that type; rooting the assembly dragged it in.
#
# The assemblies that genuinely need wholesale rooting are the ones reached
# REFLECTIVELY, where the trimmer cannot see the reference:
#
#   sts2         ModelDb.Init reflects over AllAbstractModelSubtypes; every
#                model type is reached only that way (docs/PATCH_PORT.md)
#   GodotSharp   ClassDB lookups, signal binding, [Export] discovery, and the
#                [UnmanagedCallersOnly] exports NativeLib=Shared emits --
#                including godotsharp_game_main_init, which the engine dlsyms
#   STS2Switch   woven calls are static and visible, but the patch assembly is
#                tiny and a missing root here is a silent behaviour change
#
# Everything else is reached by ordinary static calls from sts2.dll, so normal
# reachability trimming handles it correctly and compiles only what is used.
#
# ROOT_ALL=1 restores the old behaviour for debugging a suspected trim
# casualty.
say_roots() { echo "  $1"; }

GEN="${AOT_RD_XML:-$ROOT/aot/rd.generated.xml}"
{
  echo '<Directives xmlns="http://schemas.microsoft.com/netfx/2013/01/metadata">'
  echo '  <Application>'
  echo '    <!-- GENERATED by scripts/docker-entry.sh; edits are overwritten.'
  echo '         Hand-written directives live in rd.xml. -->'
  for f in "$WORK/refs"/*.dll; do
    n="$(basename "$f" .dll)"
    if [ "${ROOT_ALL:-0}" = "1" ]; then
      # Root everything EXCEPT assemblies known not to survive it.
      #
      # ROOT_ALL existed as the escape hatch for "is this a trim casualty?",
      # but it could not actually be run: rooting Steamworks.NET forces ILC to
      # compile SteamNetworkingConfigValue_t.OptionValue, an explicit-layout
      # union whose fields overlap at offset 0, and ILC rejects it outright.
      # So the one switch for settling the question failed the build instead of
      # answering it.
      #
      # The deny-list keeps it usable. Anything here is excluded from the
      # blanket rooting and falls back to normal reachability trimming, which
      # is what it was getting anyway.
      case "$n" in
        Steamworks.NET)
          echo "    <!-- $n excluded from ROOT_ALL: explicit-layout union ILC rejects -->" ;;
        *)
          echo "    <Assembly Name=\"$n\" Dynamic=\"Required All\" />" ;;
      esac
      continue
    fi
    case "$n" in
      sts2|GodotSharp|STS2Switch)
        echo "    <Assembly Name=\"$n\" Dynamic=\"Required All\" />" ;;
    esac
  done
  echo '  </Application>'
  echo '</Directives>'
} > "$GEN"

echo "  $(grep -c '<Assembly' "$GEN") assembly roots -> $GEN"
grep -oE 'Name="[^"]+"' "$GEN" | sed 's/Name="/    /;s/"//' 

# --------------------------------------------------------------------- aot --
say "NativeAOT compile"

dotnet publish "$ROOT/aot/sts2.aot.csproj" -c Release \
  -r linux-bionic-arm64 --self-contained --nologo \
  -p:AotReferenceDir="$WORK/refs" \
  -p:GeneratedRdXmlPath="$GEN"

# The shim is sts2_aot_root, so the emitted library is named after it, not
# after the game. Match on any .so under publish/ rather than a fixed name.
SO="$(find "$ROOT/aot" -name '*.so' -path '*publish*' | head -1)"
[ -n "$SO" ] || die "ILC produced no .so -- check the output above"
echo "  ILC output: $SO"

cp "$SO" "$OUT/libsts2.so"

# ------------------------------------------------------------------ verify --
# ILC succeeding is not the same as producing a usable payload. The two things
# that decide it -- architecture, and whether godotsharp_game_main_init is
# exported -- are invisible in the build log, and getting either wrong presents
# on hardware as "the game does nothing" with nothing to go on.
say "verifying output"
python3 "$ROOT/tools/check_aot_so.py" "$OUT/libsts2.so" || {
  echo
  echo "The payload built but is not usable. Details above." >&2
  exit 1
}

say "done"
ls -la "$OUT/libsts2.so"
cat <<'EOF'

Copy libsts2.so next to sts2.nro on the SD card.

If the game boots to a menu with content missing -- fewer cards, absent relics
-- compare the ModelDb phase-1/phase-2 counts in sts2_debug.log against a
desktop run. Lower numbers mean model types were trimmed away and aot/rd.xml
needs widening. That failure is silent by design in the engine, which is why
those counters are logged.
EOF
