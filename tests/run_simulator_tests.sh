#!/bin/bash
# 模拟器测试 runner：smoke（截图巡访）/ autotest（进程内自测）。
# 握手协议：app 写 <container>/tmp/<mode>/now-<name> → 本脚本截图 → 写回 ack-<name>。
set -euo pipefail
udid=$1
mode=$2
case "$mode" in
  smoke) argument=-autoSmoke; names="01-home 02-export 03-manifest 04-pc-guide" ;;
  autotest) argument=-autoTest; names= ;;
  *) echo "Unknown test mode: $mode" >&2; exit 1 ;;
esac
container=$(xcrun simctl get_app_container "$udid" com.tokeiyo929.photoexport data)
directory="$container/tmp/$mode"
mkdir -p "$directory" "$mode"
rm -f "$mode"/*.png  # 清掉上次运行残留的截图，防旧图掩盖缺页
rm -f "$directory"/done.txt "$directory"/result.txt "$directory"/now-* "$directory"/ack-*
pid=
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  cp "$directory"/*.txt "$mode/" 2>/dev/null || true
}
trap cleanup EXIT
xcrun simctl terminate "$udid" com.tokeiyo929.photoexport 2>/dev/null || true
xcrun simctl launch --console "$udid" com.tokeiyo929.photoexport "$argument" > "$mode-console.txt" 2>&1 &
pid=$!
# smoke 含真实小导出，默认放宽到 720s；mock 门禁用 PE_POLL_SECONDS 缩短。
poll_seconds=${PE_POLL_SECONDS:-720}
for ((second=0; second<poll_seconds; second++)); do
  for name in $names; do
    if [ -f "$directory/now-$name" ] && [ ! -f "$directory/ack-$name" ]; then
      xcrun simctl io "$udid" screenshot "$mode/$name.png"
      : > "$directory/ack-$name"
    fi
  done
  if [ -f "$directory/done.txt" ]; then break; fi
  if ! kill -0 "$pid" 2>/dev/null; then echo "App exited before completion" >&2; exit 1; fi
  sleep 1
done
test -f "$directory/done.txt" || { echo "Test timed out" >&2; exit 1; }
test "$(cat "$directory/done.txt")" = PASS
grep -qx 'RESULT: ALL PASS' "$directory/result.txt"
if grep -q '^FAIL' "$directory/result.txt"; then cat "$directory/result.txt"; exit 1; fi
for name in $names; do test -s "$mode/$name.png"; done
# 即使已写 PASS，随后异常退出或挂起仍必须失败。
for ((second=0; second<10; second++)); do
  if ! kill -0 "$pid" 2>/dev/null; then break; fi
  sleep 1
done
if kill -0 "$pid" 2>/dev/null; then echo "App did not exit after completion" >&2; exit 1; fi
wait "$pid"
pid=
cat "$directory/result.txt"
