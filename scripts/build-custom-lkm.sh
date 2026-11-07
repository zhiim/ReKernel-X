#!/usr/bin/env bash
# Build against an already built device kernel; do not use a generic DDK tree.
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "Usage: EXPECTED_KERNEL_RELEASE=<uname -r> bash $0 KERNEL_SRC KERNEL_OUT CLANG_BIN [OUTPUT_DIR]" >&2
  exit 2
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_SRC="$(realpath "$1")"
KERNEL_OUT="$(realpath "$2")"
CLANG_BIN="$(realpath "$3")"
OUTPUT_DIR="$(realpath -m "${4:-${REPO_DIR}/out-custom}")"
: "${EXPECTED_KERNEL_RELEASE:?Set this to the complete uname -r from the phone}"
RKX_VERSION="${RKX_VERSION:-custom}"
[[ "$EXPECTED_KERNEL_RELEASE" =~ ^[a-zA-Z0-9._+-]+$ ]] || fail 'Invalid kernel release'
[[ "$RKX_VERSION" =~ ^[a-zA-Z0-9._+-]+$ ]] || fail 'Invalid RKX_VERSION'
[[ "$KERNEL_SRC" != *[[:space:]]* && "$KERNEL_OUT" != *[[:space:]]* && "$OUTPUT_DIR" != *[[:space:]]* ]] || fail 'Kbuild paths must not contain whitespace'

# check tools needed for compiling
for tool in make python3 modinfo; do
  command -v "$tool" >/dev/null || fail "Missing tool: $tool"
done
for tool in clang ld.lld llvm-nm llvm-strip; do
  [[ -x "$CLANG_BIN/$tool" ]] || fail "Missing target toolchain executable: $CLANG_BIN/$tool"
done

[[ -f "$KERNEL_SRC/drivers/android/binder_internal.h" ]] || fail 'Target Binder headers missing'
[[ -s "$KERNEL_OUT/.config" ]] || fail 'Target .config missing; first build the device kernel'
[[ -s "$KERNEL_OUT/include/generated/compile.h" ]] || fail 'Target compile.h missing; first build the device kernel'
[[ -s "$KERNEL_OUT/vmlinux" ]] || fail 'Target vmlinux missing; a full kernel build is required'
for key in MODULES MODVERSIONS ANDROID_VENDOR_HOOKS KPROBES; do
  grep -qx "CONFIG_${key}=y" "$KERNEL_OUT/.config" || fail "CONFIG_${key}=y is required"
done
if grep -qx 'CONFIG_MODULE_SIG_FORCE=y' "$KERNEL_OUT/.config"; then
  fail 'Target requires trusted module signatures; this helper creates unsigned modules'
fi
CONFIG_HASH="$(sha256sum "$KERNEL_OUT/.config" | cut -d ' ' -f 1)"
CLANG_BANNER="$("$CLANG_BIN/clang" --version | head -n 1)"
grep -Fq -- "$CLANG_BANNER" "$KERNEL_OUT/include/generated/compile.h" || fail 'Clang differs from the target kernel compiler'

export PATH="$CLANG_BIN:$PATH"
export ARCH=arm64 LLVM=1 LLVM_IAS=1
MAKE_ARGS=("O=$KERNEL_OUT" LLVM=1 LLVM_IAS=1 CC=clang HOSTCC=clang HOSTCXX=clang++)
# Preserve the original build's command-line device configuration, if any.
if [[ -n "${KERNEL_MAKE_FLAGS:-}" ]]; then
  read -r -a DEVICE_FLAGS <<< "$KERNEL_MAKE_FLAGS"
  for flag in "${DEVICE_FLAGS[@]}"; do
    [[ "$flag" =~ ^CONFIG_[A-Z0-9_]+=(y|m|n)$ ]] || fail "Invalid device flag: $flag"
  done
  MAKE_ARGS+=("${DEVICE_FLAGS[@]}")
fi
ACTUAL_RELEASE="$(make -s -C "$KERNEL_SRC" "${MAKE_ARGS[@]}" kernelrelease)"
[[ "$ACTUAL_RELEASE" == "$EXPECTED_KERNEL_RELEASE" ]] || fail "Kernel release is $ACTUAL_RELEASE, expected $EXPECTED_KERNEL_RELEASE"

# An Image-only Android build may emit vmlinux.symvers without Module.symvers.
# Binder and the other required exports are built into this device kernel.
if [[ ! -s "$KERNEL_OUT/Module.symvers" ]]; then
  [[ -s "$KERNEL_OUT/vmlinux.symvers" ]] || fail 'No target symbol CRCs; modules_prepare alone is insufficient'
  cp "$KERNEL_OUT/vmlinux.symvers" "$KERNEL_OUT/Module.symvers"
fi

mkdir -p "$OUTPUT_DIR"
STAGE="$(mktemp -d "$OUTPUT_DIR/.rkx-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$REPO_DIR/LKM-Source" "$STAGE/source"
# Do not inherit objects from another kernel build.
make -C "$KERNEL_SRC" "${MAKE_ARGS[@]}" "M=$STAGE/source" clean
make -C "$KERNEL_SRC" "${MAKE_ARGS[@]}" modules_prepare
[[ "$(sha256sum "$KERNEL_OUT/.config" | cut -d ' ' -f 1)" == "$CONFIG_HASH" ]] || fail 'Kernel preparation changed the original configuration; rebuild the target kernel first'
make -C "$KERNEL_SRC" "${MAKE_ARGS[@]}" "M=$STAGE/source" "RKX_VERSION=$RKX_VERSION" modules
[[ "$(sha256sum "$KERNEL_OUT/.config" | cut -d ' ' -f 1)" == "$CONFIG_HASH" ]] || fail 'Kernel configuration changed during module build'

KO="$STAGE/source/rekernel_x.ko"
[[ -s "$KO" ]] || fail 'Module was not generated'
VERMAGIC="$(modinfo -F vermagic "$KO")"
[[ "${VERMAGIC%% *}" == "$EXPECTED_KERNEL_RELEASE" ]] || fail "Unexpected vermagic: $VERMAGIC"

# modpost may only warn about missing CRCs in some Android trees. Reject them.
# Also check the actual generated protection list, rather than inferring that
# CONFIG_MODULE_SIG_PROTECT rejects every unsigned module.
python3 - "$KO" "$KERNEL_OUT" "$CLANG_BIN/llvm-nm" <<'PY'
import pathlib
import re
import struct
import subprocess
import sys

ko, out, nm = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
blob = ko.read_bytes()
if blob[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', blob, 18)[0] != 183:
    sys.exit('ERROR: Expected an ELF64 little-endian AArch64 module')
imports = set()
for line in subprocess.check_output([nm, '--undefined-only', str(ko)], text=True).splitlines():
    fields = line.split()
    if len(fields) == 2 and fields[0] == 'U':
        imports.add(fields[1])
symbols = {}
for line in (out / 'Module.symvers').read_text().splitlines():
    fields = line.split()
    if len(fields) >= 2:
        symbols[fields[1]] = int(fields[0], 16)
missing = imports - symbols.keys()
if missing:
    sys.exit('ERROR: Imports absent from target Module.symvers: ' + ', '.join(sorted(missing)))

# struct modversion_info in this arm64 kernel is { unsigned long crc; char name[56]; }.
shoff = struct.unpack_from('<Q', blob, 40)[0]
shsize, shnum, shstrndx = struct.unpack_from('<HHH', blob, 58)
sections = [struct.unpack_from('<IIQQQQIIQQ', blob, shoff + i * shsize) for i in range(shnum)]
names_header = sections[shstrndx]
names = blob[names_header[4]:names_header[4] + names_header[5]]
versions = {}
for section in sections:
    name = names[section[0]:].split(b'\0', 1)[0]
    if name != b'__versions':
        continue
    data = blob[section[4]:section[4] + section[5]]
    if len(data) % 64:
        sys.exit('ERROR: Unexpected modversion record format')
    for offset in range(0, len(data), 64):
        crc = struct.unpack_from('<Q', data, offset)[0]
        symbol = data[offset + 8:offset + 64].split(b'\0', 1)[0].decode()
        versions[symbol] = crc
for symbol in imports | {'module_layout'}:
    if symbol not in versions or symbol not in symbols or versions[symbol] != symbols[symbol]:
        sys.exit('ERROR: Missing or mismatched target CRC for ' + symbol)
config = (out / '.config').read_text().splitlines()
if 'CONFIG_CFI_CLANG=y' in config:
    defined = subprocess.check_output([nm, '--defined-only', str(ko)], text=True)
    if not re.search(r'\b__cfi_check$', defined, re.M):
        sys.exit('ERROR: Target enables Clang CFI but module has no __cfi_check')
if 'CONFIG_MODULE_SIG_PROTECT=y' in config:
    header = out / 'include/generated/gki_module_protected.h'
    # This kernel emits the headers in kernel/, not include/generated/.
    if not header.exists():
        header = out / 'kernel/gki_module_protected.h'
    if not header.exists():
        sys.exit('ERROR: Cannot audit the target generated GKI protection list')
    protected = set(re.findall(r'"([A-Za-z0-9_]+)"', header.read_text()))
    denied = imports & protected
    if denied:
        sys.exit('ERROR: Module needs protected symbols: ' + ', '.join(sorted(denied)))
print(f'Checked {len(imports)} imports, target CRCs, CFI and GKI protection')
PY

PACKAGE="$STAGE/package"
mkdir "$PACKAGE"
cp "$REPO_DIR/template/module.prop" "$PACKAGE/"
sed -i "s/@VERSION@/$RKX_VERSION/g; s/@VERSION_CODE@/1/g; /^updateJson=/d; s|^description=.*|description=ReKernel-X for $EXPECTED_KERNEL_RELEASE|" "$PACKAGE/module.prop"
cp "$REPO_DIR/template-custom/"*.sh "$PACKAGE/"
cp "$KO" "$PACKAGE/rekernel_x.ko"
llvm-strip --strip-debug "$PACKAGE/rekernel_x.ko"
printf '%s\n' "$EXPECTED_KERNEL_RELEASE" > "$PACKAGE/kernel-release"
{
  printf 'kernel_release=%s\nvermagic=%s\ncompiler=%s\n' "$EXPECTED_KERNEL_RELEASE" "$VERMAGIC" "$CLANG_BANNER"
  printf 'config_sha256=%s\n' "$CONFIG_HASH"
  printf 'module_source_commit=%s\n' "$(git -C "$REPO_DIR" rev-parse HEAD)"
  printf 'module_source_dirty=%s\n' "$(git -C "$REPO_DIR" status --porcelain -- LKM-Source scripts/build-custom-lkm.sh template-custom | wc -l | tr -d ' ')"
  sha256sum "$KERNEL_OUT/Module.symvers" | sed "s|$KERNEL_OUT/||"
} > "$PACKAGE/build-info.txt"

ZIP_PATH="$OUTPUT_DIR/ReKernel-X-$RKX_VERSION-$EXPECTED_KERNEL_RELEASE.zip"
[[ ! -e "$ZIP_PATH" ]] || fail "Output exists: $ZIP_PATH; choose another RKX_VERSION or directory"
python3 - "$PACKAGE" "$ZIP_PATH" <<'PY'
import pathlib
import sys
import zipfile
root = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], 'x', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(root.iterdir()):
        archive.write(path, path.name)
PY
printf 'Created: %s\n' "$ZIP_PATH"
printf 'Build checks passed. Device loading and event delivery still require testing.\n'
