#!/bin/bash
# run_simulator_tests.sh 的门禁：用 mock xcrun 走完 7 个场景，无 Mac 也能跑。
# pass/smoke-pass 必须 0 退出，其余场景必须非 0 退出。
set -uo pipefail
export PE_POLL_SECONDS=12  # timeout 场景依赖 runner 的轮询上限，缩短到 12s 保持门禁快速

fail_count=0
run_case() {
  local scenario=$1 expected=$2
  local testdir
  testdir=$(mktemp -d)
  export FIXTURE_CONTAINER="$testdir/container"
  export FIXTURE_CASE="$scenario"
  mkdir -p "$FIXTURE_CONTAINER/tmp/smoke" "$FIXTURE_CONTAINER/tmp/autotest" "$testdir/bin"
  cat > "$testdir/bin/xcrun" <<'MOCK'
#!/bin/bash
if [ "$1" = simctl ] && [ "$2" = get_app_container ]; then
  echo "$FIXTURE_CONTAINER"
  exit 0
fi
if [ "$1" = simctl ] && [ "$2" = terminate ]; then
  exit 0
fi
if [ "$1" = simctl ] && [ "$2" = io ]; then
  # xcrun simctl io <udid> screenshot <path>
  printf 'PNG' > "$5"
  exit 0
fi
if [ "$1" = simctl ] && [ "$2" = launch ]; then
  # xcrun simctl launch --console <udid> <bundle> <argument>
  mode=autotest
  if [ "$6" = -autoSmoke ]; then mode=smoke; fi
  directory="$FIXTURE_CONTAINER/tmp/$mode"
  case "$FIXTURE_CASE" in
    partial)
      printf 'PASS first\n' > "$directory/result.txt"
      exit 0 ;;
    timeout)
      exec /bin/sleep 60 ;;
    pass|smoke-pass)
      for name in 01-home 02-export 03-manifest 04-pc-guide; do
        : > "$directory/now-$name"
        for _ in $(seq 1 50); do
          [ -f "$directory/ack-$name" ] && break
          sleep 0.1
        done
      done ;;
    smoke-missing)
      : > "$directory/now-01-home"
      sleep 0.5
      : > "$directory/ack-01-home" ;;
  esac
  printf 'RESULT: ALL PASS\n' > "$directory/result.txt"
  printf PASS > "$directory/done.txt"
  if [ "$FIXTURE_CASE" = crash ]; then exit 7; fi
  if [ "$FIXTURE_CASE" = fail ]; then printf FAIL > "$directory/done.txt"; fi
  sleep 2  # 给 runner 的 1s 轮询留出读到 done.txt 的窗口，避免存活检查竞态
  exit 0
fi
echo "mock xcrun: unexpected args: $*" >&2
exit 64
MOCK
  chmod +x "$testdir/bin/xcrun"
  local output status
  output=$(PATH="$testdir/bin:$PATH" bash tests/run_simulator_tests.sh UDID-FIXTURE smoke 2>&1)
  status=$?
  if [ "$expected" = ok ] && [ "$status" -ne 0 ]; then
    echo "FAIL [$scenario] 应通过却失败（exit=$status）"; echo "$output" | tail -5
    fail_count=$((fail_count+1))
  elif [ "$expected" = fail ] && [ "$status" -eq 0 ]; then
    echo "FAIL [$scenario] Incorrectly accepted $scenario"
    fail_count=$((fail_count+1))
  else
    echo "ok   [$scenario] exit=$status"
  fi
  rm -rf "$testdir"
}

run_case pass ok
run_case crash fail
run_case fail fail
run_case timeout fail
run_case partial fail
run_case smoke-missing fail
run_case smoke-pass ok

if [ "$fail_count" -ne 0 ]; then
  echo "GATE FAIL: $fail_count scenarios wrong"
  exit 1
fi
echo "GATE PASS: runner rejects every broken handshake"
