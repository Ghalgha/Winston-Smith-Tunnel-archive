#!/usr/bin/env bash
set -uo pipefail

mkdir -p ci-diagnostics
adb logcat -b all -v threadtime > ci-diagnostics/logcat-live.txt 2>&1 &
LOGCAT_PID=$!

set +e
./gradlew --no-daemon :app:connectedDebugAndroidTest
TEST_STATUS=$?
set -e

kill "$LOGCAT_PID" 2>/dev/null || true
wait "$LOGCAT_PID" 2>/dev/null || true

if [ "$TEST_STATUS" -ne 0 ]; then
  echo "Instrumentation failed with exit code $TEST_STATUS; collecting emulator state"
  adb devices -l > ci-diagnostics/adb-devices.txt 2>&1 || true
  adb -s emulator-5554 shell getprop > ci-diagnostics/getprop.txt 2>&1 || true
  adb -s emulator-5554 shell cat /proc/meminfo > ci-diagnostics/meminfo.txt 2>&1 || true
  adb -s emulator-5554 shell cat /proc/pressure/memory > ci-diagnostics/memory-pressure.txt 2>&1 || true
  adb -s emulator-5554 shell ps -A -o USER,PID,PPID,VSZ,RSS,NAME > ci-diagnostics/processes.txt 2>&1 || true
  for service in activity package window input meminfo cpuinfo; do
    adb -s emulator-5554 shell dumpsys "$service" > "ci-diagnostics/dumpsys-$service.txt" 2>&1 || true
  done
  free -h > ci-diagnostics/runner-memory.txt 2>&1 || true
  df -h > ci-diagnostics/runner-disk.txt 2>&1 || true
fi

exit "$TEST_STATUS"
