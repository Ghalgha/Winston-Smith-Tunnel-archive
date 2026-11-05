#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
PROJECT_ROOT="$(printenv WSTT_PROJECT_ROOT || true)"
[ -n "$PROJECT_ROOT" ] || PROJECT_ROOT="$SCRIPT_DIR"
RUNTIME_ONLY=0
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 1 ] && [ "$1" = "--runtime-only" ] || { echo "Usage: $0 [--runtime-only]" >&2; exit 2; }
  RUNTIME_ONLY=1
fi
fail() { echo "[FAIL] $*" >&2; exit 1; }
skip() { echo "[SKIP] $*"; }
pass() { echo "[PASS] $*"; }

[ -d "$PROJECT_ROOT/rust-server" ] || fail "Missing rust-server under $PROJECT_ROOT"
if [ "$RUNTIME_ONLY" -eq 0 ]; then
  command -v cargo >/dev/null || fail "cargo is not on PATH"
  command -v rustup >/dev/null || fail "rustup is not on PATH"
  if ! rustup toolchain list | grep -Eq '^1\\.97\\.1(-|$)'; then
    rustup toolchain install 1.97.1 --profile minimal
  fi
  if ! rustup target list --installed --toolchain 1.97.1 | grep -Fxq x86_64-unknown-linux-gnu; then
    rustup target add x86_64-unknown-linux-gnu --toolchain 1.97.1
  fi
  cargo +1.97.1 test --locked --target x86_64-unknown-linux-gnu --manifest-path "$PROJECT_ROOT/rust-server/Cargo.toml" --all-targets
  pass "Rust server tests"
  cargo +1.97.1 build --locked --target x86_64-unknown-linux-gnu --manifest-path "$PROJECT_ROOT/rust-server/Cargo.toml"
  SERVER_BIN="$PROJECT_ROOT/rust-server/target/x86_64-unknown-linux-gnu/debug/wstt"
else
  SERVER_BIN="$(printenv WSTT_SERVER_BIN || true)"
  [ -n "$SERVER_BIN" ] || SERVER_BIN="$PROJECT_ROOT/rust-server/target/x86_64-unknown-linux-gnu/debug/wstt"
fi
[ -x "$SERVER_BIN" ] || fail "Missing executable server binary: $SERVER_BIN"

if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null; then
    sudo -E env WSTT_PROJECT_ROOT="$PROJECT_ROOT" WSTT_SERVER_BIN="$SERVER_BIN" bash "$SCRIPT_PATH" --runtime-only
    exit $?
  fi
  if [ "$RUNTIME_ONLY" -eq 1 ]; then skip "Runtime-only mode requires root; runtime checks not run"
  else skip "Runtime checks need root; Rust tests/build completed"; fi
  echo "STATUS: PASS_WITH_RUNTIME_SKIPPED"
  exit 0
fi

for tool in ip python3 curl ss; do command -v "$tool" >/dev/null || fail "Missing required tool: $tool"; done
if [ ! -c /dev/net/tun ]; then
  skip "/dev/net/tun unavailable; runtime checks skipped"
  echo "STATUS: PASS_WITH_RUNTIME_SKIPPED"
  exit 0
fi

RUN_DIR="$(mktemp -d /tmp/wstt-wsl-check.XXXXXX)"
chmod 700 "$RUN_DIR"
NS="wstt-check-$$-$RANDOM"
PID=""
UNIT=""
NS_CREATED=0
cleanup() {
  local p
  if [ -n "$UNIT" ] && command -v systemctl >/dev/null; then
    if command -v timeout >/dev/null; then timeout 10 systemctl stop "$UNIT" >/dev/null 2>&1 || true
    else systemctl stop "$UNIT" >/dev/null 2>&1 || true; fi
    systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
  fi
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  if [ "$NS_CREATED" -eq 1 ]; then
    while read -r p; do [ -n "$p" ] && kill -TERM "$p" 2>/dev/null || true; done < <(ip netns pids "$NS" 2>/dev/null || true)
    sleep 1
    while read -r p; do [ -n "$p" ] && kill -KILL "$p" 2>/dev/null || true; done < <(ip netns pids "$NS" 2>/dev/null || true)
    ip netns del "$NS" 2>/dev/null || echo "[WARN] Could not remove namespace $NS" >&2
  fi
  rm -rf -- "$RUN_DIR"
}
trap cleanup EXIT INT TERM

if ! ip netns add "$NS" 2>"$RUN_DIR/netns.err"; then
  skip "Network namespaces unavailable: $(tr '\n' ' ' < "$RUN_DIR/netns.err")"
  echo "STATUS: PASS_WITH_RUNTIME_SKIPPED"
  exit 0
fi
NS_CREATED=1
ip netns exec "$NS" ip link set lo up

ports() {
  ip netns exec "$NS" python3 - <<'PY'
import socket
for kind in (socket.SOCK_DGRAM, socket.SOCK_STREAM):
    s = socket.socket(socket.AF_INET, kind)
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1], end=" ")
    s.close()
print()
PY
}
ready() {
  local port="$1" code=000
  for n in $(seq 1 20); do
    code="$(ip netns exec "$NS" curl -kfsS --connect-timeout 0.5 --max-time 1 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$port/" 2>/dev/null || true)"
    [ "$code" = 200 ] && return 0
    sleep .25
  done
  return 1
}
ready_once() {
  local port="$1" code=000
  code="$(ip netns exec "$NS" curl -kfsS --connect-timeout 0.5 --max-time 1 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$port/" 2>/dev/null || true)"
  [ "$code" = 200 ]
}
stop_server() {
  kill -TERM "$1" 2>/dev/null || true
  for n in $(seq 1 40); do
    if ! kill -0 "$1" 2>/dev/null; then wait "$1" 2>/dev/null || true; PID=""; return 0; fi
    sleep .25
  done
  return 1
}

echo "[3/3] Isolated WSTT runtime"
read -r UDP WEB < <(ports)
[[ "$UDP" =~ ^[0-9]+$ && "$WEB" =~ ^[0-9]+$ ]] || fail "Could not allocate test ports"
mkdir "$RUN_DIR/config"
ip netns exec "$NS" "$SERVER_BIN" --config-dir "$RUN_DIR/config" --web-port "$WEB" --listen "127.0.0.1:$UDP" >"$RUN_DIR/server.log" 2>&1 &
PID=$!
ready "$WEB" || { cat "$RUN_DIR/server.log" >&2; fail "Standalone HTTPS endpoint did not become ready"; }
TUN="$(ip netns exec "$NS" ip -o link show dev wstt1 2>/dev/null || true)"
[[ "$TUN" =~ qlen[[:space:]]48([[:space:]]|$) ]] || fail "Expected wstt1 txqueuelen 48; got: $TUN"
ip netns exec "$NS" ss -H -lun "sport = :$UDP" | grep -q . || fail "UDP listener missing on $UDP"
pass "Isolated TUN wstt1 (qlen 48), UDP and HTTPS"
stop_server "$PID" || fail "Server did not stop after SIGTERM"
if ip netns exec "$NS" ip link show wstt1 >/dev/null 2>&1; then fail "TUN remained after server exit"; fi

if command -v systemd-run >/dev/null && command -v systemctl >/dev/null && systemctl show --property=Version --value >/dev/null 2>&1; then
  read -r UDP WEB < <(ports)
  UNIT_NAME="wstt-check-$BASHPID-$RANDOM.service"
  if systemctl show "$UNIT_NAME" >/dev/null 2>&1; then fail "Generated systemd unit name already exists: $UNIT_NAME"; fi
  UNIT="$UNIT_NAME"
  mkdir "$RUN_DIR/systemd"
  systemd-run --quiet --collect --unit="$UNIT" --property=Type=exec --property=Restart=no \
    "$(command -v ip)" netns exec "$NS" "$SERVER_BIN" --config-dir "$RUN_DIR/systemd" --web-port "$WEB" --listen "127.0.0.1:$UDP" \
    || fail "systemd-run failed"
  OK=0
  for n in $(seq 1 40); do
    if systemctl is-active --quiet "$UNIT" && ready_once "$WEB"; then OK=1; break; fi
    sleep .25
  done
  [ "$OK" -eq 1 ] || { systemctl status "$UNIT" --no-pager >&2 || true; fail "Transient systemd unit failed"; }
  systemctl stop "$UNIT" || fail "Could not stop transient unit"
  systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
  UNIT=""
  if ip netns exec "$NS" ip link show wstt1 >/dev/null 2>&1; then fail "TUN remained after systemd stop"; fi
  pass "Transient systemd lifecycle; no persistent unit file"
else
  skip "systemd unavailable; transient-unit check skipped"
fi

if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  IMAGE="$(printenv WSTT_WSL_DOCKER_IMAGE || true)"
  [ -n "$IMAGE" ] || IMAGE="debian:bookworm-slim"
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    skip "Docker image $IMAGE is not local; image was not pulled"
  else
    NAME="wstt-check-$$-$RANDOM"
    read -r DUDP DWEB < <(ports)
    docker run -d --name "$NAME" --label "wstt.wsl-test=$NAME" --cap-add NET_ADMIN --device /dev/net/tun \
      -p "127.0.0.1::$DUDP/udp" -p "127.0.0.1::$DWEB/tcp" \
      --tmpfs /tmp/wstt-check:rw,nosuid,nodev,size=16m -v "$SERVER_BIN:/usr/local/bin/wstt:ro" \
      --entrypoint /usr/local/bin/wstt "$IMAGE" --config-dir /tmp/wstt-check --web-port "$DWEB" --listen "0.0.0.0:$DUDP" \
      >"$RUN_DIR/docker.id" || { OWNER="$(docker inspect --format '{{ index .Config.Labels "wstt.wsl-test" }}' "$NAME" 2>/dev/null || true)"; [ "$OWNER" = "$NAME" ] && docker rm -f "$NAME" >/dev/null 2>&1 || true; fail "docker run failed"; }
    DOCKER_CLEAN=1
    clean_docker() { if [ "$DOCKER_CLEAN" -eq 1 ]; then OWNER="$(docker inspect --format '{{ index .Config.Labels "wstt.wsl-test" }}' "$NAME" 2>/dev/null || true)"; [ "$OWNER" = "$NAME" ] || return 1; docker rm -f "$NAME" >/dev/null 2>&1 || return 1; DOCKER_CLEAN=0; fi; }
    trap 'clean_docker; cleanup' EXIT INT TERM
    HP="$(docker port "$NAME" "$DWEB/tcp" | awk -F: 'NR==1 {print $NF}')"
    [[ "$HP" =~ ^[0-9]+$ ]] || fail "Docker host port not assigned"
    OK=0
    for n in $(seq 1 40); do
      CODE="$(curl -kfsS --connect-timeout 0.5 --max-time 1 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$HP/" 2>/dev/null || true)"
      if [ "$CODE" = 200 ]; then OK=1; break; fi
      sleep .25
    done
    [ "$OK" -eq 1 ] || { docker logs "$NAME" >&2 || true; fail "Docker HTTPS endpoint failed"; }
    docker exec "$NAME" sh -c 'test -r /sys/class/net/wstt1/ifindex && test "$(cat /sys/class/net/wstt1/ifindex)" -gt 0' || fail "Docker TUN missing"
    [ "$(docker exec "$NAME" cat /sys/class/net/wstt1/tx_queue_len)" = 48 ] || fail "Docker TUN qlen mismatch"
    pass "Docker isolated TUN and HTTPS"
    clean_docker || fail "Could not remove Docker test container"
    trap cleanup EXIT INT TERM
  fi
else
  skip "Docker daemon unavailable; it was not started"
fi
echo "STATUS: PASS (available checks passed; optional checks may be skipped)"
