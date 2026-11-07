#!/system/bin/sh
MODDIR=${0%/*}
umask 077
LOG="$MODDIR/load.log"

if [ -f "$MODDIR/.boot" ]; then
    printf '%s\n' 'Previous load was interrupted; module disabled.' > "$LOG"
    touch "$MODDIR/disable"
    rm -f "$MODDIR/.boot"
    exit 1
fi

{
    date
    printf 'kernel: %s\n' "$(uname -r)"
} > "$LOG"
EXPECTED_RELEASE=$(cat "$MODDIR/kernel-release")
if [ "$(uname -r)" != "$EXPECTED_RELEASE" ]; then
    printf 'Kernel mismatch; expected %s. Module disabled.\n' "$EXPECTED_RELEASE" >> "$LOG"
    touch "$MODDIR/disable"
    exit 1
fi
if grep -q '^rekernel_x ' /proc/modules; then
    printf '%s\n' 'rekernel_x is already loaded.' >> "$LOG"
    exit 0
fi

touch "$MODDIR/.boot"
if insmod "$MODDIR/rekernel_x.ko" >> "$LOG" 2>&1; then
    printf '%s\n' 'insmod succeeded; verify events and optional free-async hooks separately.' >> "$LOG"
    STATUS=0
else
    STATUS=$?
    printf 'insmod failed, exit=%s\n' "$STATUS" >> "$LOG"
fi
dmesg 2>/dev/null | grep -iE 'rekernel|rkx|unknown symbol|version magic|disagrees about version|protected symbol|module verification|signature|cfi failure' | tail -n 80 >> "$LOG"
rm -f "$MODDIR/.boot"
exit "$STATUS"
