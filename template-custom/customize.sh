SKIPUNZIP=0

EXPECTED_RELEASE=$(cat "$MODPATH/kernel-release")
ACTUAL_RELEASE=$(uname -r)
[ "$(uname -m)" = "aarch64" ] || abort "! 此模块仅支持 arm64"
[ "$ACTUAL_RELEASE" = "$EXPECTED_RELEASE" ] || abort "! 内核不匹配：需要 $EXPECTED_RELEASE，当前 $ACTUAL_RELEASE"
[ -s "$MODPATH/rekernel_x.ko" ] || abort "! 缺少内核模块"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
ui_print "- 自定义内核版本匹配：$ACTUAL_RELEASE"
ui_print "- 重启后加载；结果记录在模块目录的 load.log"
