#!/bin/bash

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export TERM="${TERM:-xterm}"

readonly SCRIPT_VERSION="2.5.0"
readonly LOG_FILE="/var/log/wstt-install.log"
readonly PEER_PORT="${WSTT_PEER_PORT:-46100}"
readonly SSH_PORT="${WSTT_SSH_PORT:-22}"
readonly WEB_PORT="${WSTT_WEB_PORT:-46102}"
readonly LE_HTTP_PORT="80"
readonly WSTT_LE_HTTP01_LOCK="/run/lock/acme-http01.lock"
readonly LE_RENEW_BEFORE_SECONDS="259200"
readonly DEPLOY_MODE="${WSTT_DEPLOY_MODE:-systemd}"
readonly WSTT_IFACE="wstt1"
readonly WSTT_CONFIG_DIR="/etc/wstt"
readonly WSTT_LE_CERTBOT="/opt/wstt-certbot/bin/certbot"
readonly WSTT_LE_VENV="/opt/wstt-certbot"
readonly WSTT_LE_CONFIG_DIR="${WSTT_CONFIG_DIR}/letsencrypt"
readonly WSTT_LE_WORK_DIR="/var/lib/wstt/letsencrypt"
readonly WSTT_LE_LOGS_DIR="/var/log/wstt/letsencrypt"
readonly WSTT_LE_STATE_FILE="${WSTT_CONFIG_DIR}/letsencrypt-ip.env"
readonly WSTT_LE_RENEW_HELPER="/usr/local/lib/wstt-letsencrypt-renew.sh"
readonly WSTT_LE_SERVICE="wstt-letsencrypt.service"
readonly WSTT_LE_TIMER="wstt-letsencrypt.timer"
readonly WSTT_DATABASE_FILE="wstt.db"
readonly WSTT_DATABASE_WAL_FILE="wstt.db-wal"
readonly WSTT_DATABASE_SHM_FILE="wstt.db-shm"
readonly WSTT_LEGACY_MIGRATION_JSON="passwords.json"
readonly WSTT_LEGACY_MIGRATION_IMPORTED_JSON="passwords.json.imported"
readonly WSTT_ENV_FILE="${WSTT_CONFIG_DIR}/wstt.env"
readonly WSTT_DEPLOY_OVERRIDES_FILE="${WSTT_CONFIG_DIR}/deploy-overrides.json"
readonly WSTT_RUNTIME_ARCHIVE_DIR="${WSTT_CONFIG_DIR}/runtime-archive"
readonly UPLOAD_BINARY="${WSTT_UPLOAD_BINARY:-/tmp/.wstt-upload-server}"
readonly UPLOAD_ENV_FILE="${WSTT_UPLOAD_ENV_FILE:-/tmp/.wstt-upload-web.env}"
readonly UPLOAD_OVERRIDES_FILE="${WSTT_UPLOAD_OVERRIDES_FILE:-/tmp/.wstt-upload-overrides.json}"
readonly WSTT_SYSCTL_FILE="/etc/sysctl.d/99-wstt.conf"
readonly WSTT_UDP_SYSCTL_FILE="/etc/sysctl.d/99-wstt-udp-buffers.conf"
readonly IPT_COMMENT="WSTT_MANAGED"
readonly WSTT_DOCKER_IMAGE="wstt:2.5.0"
readonly WSTT_DOCKER_CONTAINER="wstt"
readonly WSTT_DOCKER_PREREQ_SERVICE="wstt-docker-prereq.service"
readonly WSTT_DOCKER_PREREQ_HELPER="/usr/local/lib/wstt/docker-prereq.sh"
readonly WSTT_RUNTIME_DIR="/run/wstt"
readonly WSTT_DOCKER_NETWORK_READY="${WSTT_RUNTIME_DIR}/docker-network.ready"
readonly XT_WAIT="${WSTT_XT_WAIT:-2}"
readonly START_STABILITY_SECONDS="${WSTT_START_STABILITY_SECONDS:-4}"
readonly DOCKER_BUILD_TIMEOUT_SECONDS="${WSTT_DOCKER_BUILD_TIMEOUT_SECONDS:-180}"
readonly EXIT_INVALID_ARGUMENT=2
readonly EXIT_PREFLIGHT_FAILED=20
readonly EXIT_CUTOVER_FAILED=30

SYSTEMD_NEEDS_RELOAD=0
DEPLOY_PHASE="initial"
DOCKER_CONTEXT_DIR=""
WSTT_DOCKER_CANDIDATE_IMAGE=""

validate_port() {
    local name="$1" value="$2"
    case "$value" in
        ''|*[!0-9]*) die "$name должен быть числом от 1 до 65535, получено: $value" ;;
    esac
    if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        die "$name должен быть в диапазоне 1..65535, получено: $value"
    fi
}

validate_positive_seconds() {
    local name="$1" value="$2"
    case "$value" in
        ''|*[!0-9]*) die "$name должен быть положительным числом секунд, получено: $value" ;;
    esac
    if [ "$value" -lt 1 ] || [ "$value" -gt 900 ]; then
        die "$name должен быть в диапазоне 1..900, получено: $value"
    fi
}

validate_distinct_network_ports() {
    [ "$PEER_PORT" != "$SSH_PORT" ] || die "WSTT_PEER_PORT не может совпадать с SSH-портом"
    [ "$PEER_PORT" != "$WEB_PORT" ] || die "WSTT_PEER_PORT не может совпадать с WEB-портом"
    [ "$PEER_PORT" != "$LE_HTTP_PORT" ] || die "WSTT_PEER_PORT не может совпадать с HTTP-портом"
    [ "$WEB_PORT" != "$SSH_PORT" ] || die "WSTT_WEB_PORT не может совпадать с SSH-портом"
    [ "$WEB_PORT" != "$LE_HTTP_PORT" ] || die "WSTT_WEB_PORT не может совпадать с HTTP-01 портом Let’s Encrypt"
    [ "$SSH_PORT" != "$LE_HTTP_PORT" ] || die "WSTT_SSH_PORT не может совпадать с HTTP-01 портом Let’s Encrypt"
}

C_GREEN=''; C_YELLOW=''; C_RED=''
C_CYAN='';  C_BOLD='';      C_NC=''

log_info()  { echo -e "${C_GREEN}[✓]${C_NC} $*" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${C_YELLOW}[!]${C_NC} $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${C_RED}[✗]${C_NC} $*" | tee -a "$LOG_FILE"; }
log_step()  { echo -e "${C_CYAN}[►]${C_NC} ${C_BOLD}$*${C_NC}" | tee -a "$LOG_FILE"; }

default_exit_code() {
    case "$DEPLOY_PHASE" in
        validation) printf '%s' "$EXIT_INVALID_ARGUMENT" ;;
        preflight) printf '%s' "$EXIT_PREFLIGHT_FAILED" ;;
        cutover|activation) printf '%s' "$EXIT_CUTOVER_FAILED" ;;
        *) printf '%s' 1 ;;
    esac
}

die() {
    local message="$1" code="${2:-$(default_exit_code)}"
    log_error "$message"
    printf 'CSQTT_DEPLOY_ERROR|%s|%s\n' "$DEPLOY_PHASE" "$message"
    cleanup_deploy_uploads
    exit "$code"
}

wstt_systemd_unit_exists() {
    command -v systemctl >/dev/null 2>&1 || return 1
    local state
    state="$(systemctl show --value -p LoadState wstt 2>/dev/null || true)"
    [ -n "$state" ] && [ "$state" != "not-found" ]
}

wstt_systemd_unit_is_managed() {
    wstt_systemd_unit_exists || return 1
    local unit
    unit="$(systemctl cat wstt 2>/dev/null || true)"
    printf '%s\n' "$unit" | grep -Eq '(/usr/local/bin/wstt|/usr/local/lib/wstt/)'
}

wstt_docker_container_exists() {
    command -v docker >/dev/null 2>&1 && docker inspect "$WSTT_DOCKER_CONTAINER" >/dev/null 2>&1
}

docker_container_runs_wstt() {
    local container="$1" container_id proc pid cgroup executable command_line details
    docker inspect "$container" >/dev/null 2>&1 || return 1
    details="$(docker inspect --format '{{.Name}}|{{.Config.Image}}|{{json .Config.Entrypoint}}|{{json .Config.Cmd}}|{{range .Mounts}}{{.Source}}:{{.Destination}}|{{end}}' "$container" 2>/dev/null || true)"
    case "$details" in
        *'|wstt|'*|*'|wstt:'*|*'|wstt-docker-'*|*'/usr/local/bin/wstt'*|*":${WSTT_CONFIG_DIR}"*) return 0 ;;
    esac
    if docker top "$container" -eo pid,args 2>/dev/null | awk '
NR > 1 && $0 ~ /(^|[[:space:]])\/usr\/local\/bin\/wstt([[:space:]]|$)/ { found = 1 }
END { exit !found }
'; then
        return 0
    fi
    container_id="$(docker inspect --format '{{.Id}}' "$container" 2>/dev/null || true)"
    [ -n "$container_id" ] || return 1
    for proc in /proc/[0-9]*; do
        pid="${proc##*/}"
        cgroup="$(cat "$proc/cgroup" 2>/dev/null || true)"
        case "$cgroup" in
            *"docker-${container_id}.scope"*|*"/docker/${container_id}"*) ;;
            *) continue ;;
        esac
        executable="$(readlink "$proc/exe" 2>/dev/null || true)"
        case "$executable" in
            /usr/local/bin/wstt|'/usr/local/bin/wstt (deleted)') return 0 ;;
        esac
        command_line="$({ tr '\0' ' ' < "$proc/cmdline"; } 2>/dev/null || true)"
        case " $command_line " in
            *" /usr/local/bin/wstt "*|*" --config-dir ${WSTT_CONFIG_DIR} "*) return 0 ;;
        esac
    done
    return 1
}

wstt_persistent_state_exists() {
    [ -f "$WSTT_ENV_FILE" ] || [ -f "${WSTT_CONFIG_DIR}/${WSTT_DATABASE_FILE}" ] || \
        [ -f "${WSTT_CONFIG_DIR}/${WSTT_LEGACY_MIGRATION_JSON}" ] || \
        [ -f "${WSTT_CONFIG_DIR}/${WSTT_LEGACY_MIGRATION_IMPORTED_JSON}" ] || \
        [ -f "${WSTT_CONFIG_DIR}/web_cert.pem" ] || [ -f "${WSTT_CONFIG_DIR}/web_key.pem" ]
}

peer_port_listeners() {
    ss -H -lunp "sport = :${PEER_PORT}" 2>/dev/null || true
}

peer_port_listener_pids() {
    peer_port_listeners | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -un || true
}

web_port_listeners() {
    ss -H -ltnp "sport = :${WEB_PORT}" 2>/dev/null || true
}

assert_web_port_is_available() {
    local listeners
    listeners="$(web_port_listeners)"
    [ -z "$listeners" ] && return 0
    log_error "TCP/${WEB_PORT} уже занят посторонним процессом; его остановка запрещена"
    printf '%s\\n' "$listeners" | tee -a "$LOG_FILE" >&2
    die "Порт TCP/${WEB_PORT} занят. Выберите другой порт; чужие процессы не затрагиваются."
}

docker_container_for_pid() {
    local pid="$1" cgroup container_id
    command -v docker >/dev/null 2>&1 || return 1
    cgroup="$(cat "/proc/$pid/cgroup" 2>/dev/null || true)"
    container_id="$(printf '%s\n' "$cgroup" | sed -nE 's#.*docker-([0-9a-f]{12,64})\.scope.*#\1#p; s#.*/docker/([0-9a-f]{12,64}).*#\1#p' | head -n 1)"
    [ -n "$container_id" ] || return 1
    docker inspect "$container_id" >/dev/null 2>&1 || return 1
    printf '%s\n' "$container_id"
}

wstt_process_is_owned() {
    local pid="$1" executable command_line
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ -r "/proc/$pid/cmdline" ] || return 1
    executable="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
    case "$executable" in
        /usr/local/bin/wstt|'/usr/local/bin/wstt (deleted)'|/usr/local/lib/wstt/*|'/usr/local/lib/wstt/'*' (deleted)') return 0 ;;
    esac
    local container_id
    container_id="$(docker_container_for_pid "$pid" || true)"
    if [ -n "$container_id" ] && docker_container_runs_wstt "$container_id"; then
        return 0
    fi
    command_line="$({ tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null || true)"
    case " $command_line " in
        *" --config-dir ${WSTT_CONFIG_DIR} "*|*" /usr/local/bin/wstt "*|*" /usr/local/lib/wstt/"*) ;;
        *) return 1 ;;
    esac
    return 0
}

wstt_process_owns_peer_port() { wstt_process_is_owned "$1"; }

all_wstt_process_pids() {
    local proc pid
    for proc in /proc/[0-9]*; do
        pid="${proc##*/}"
        wstt_process_is_owned "$pid" && printf '%s\n' "$pid"
    done
    return 0
}

wstt_peer_port_is_owned() {
    local pid
    while IFS= read -r pid; do
        wstt_process_owns_peer_port "$pid" && return 0
    done < <(peer_port_listener_pids)
    return 1
}

force_stop_wstt_processes() {
    local pid attempt found
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
        found=0
        while IFS= read -r pid; do
            found=1
            log_warn "Принудительное завершение WSTT: PID $pid"
            if [ "$attempt" -le 2 ]; then
                kill -TERM "$pid" 2>/dev/null || true
            else
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done < <(all_wstt_process_pids)
        if [ "$found" -eq 0 ]; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

assert_peer_port_is_available() {
    local listeners
    listeners="$(peer_port_listeners)"
    [ -z "$listeners" ] && return 0
    log_error "UDP/${PEER_PORT} уже занят посторонним процессом; его остановка запрещена"
    printf '%s\\n' "$listeners" | tee -a "$LOG_FILE" >&2
    die "Порт UDP/${PEER_PORT} занят. Выберите другой порт; чужие процессы не затрагиваются."
}

web_port_listeners() {
    ss -H -ltnp "sport = :${WEB_PORT}" 2>/dev/null || true
}

listener_line_is_wstt_owned() {
    local line="$1" pids pid
    pids="$(printf '%s\n' "$line" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -un || true)"
    [ -n "$pids" ] || return 1
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        wstt_process_is_owned "$pid" || return 1
    done <<< "$pids"
    return 0
}

assert_no_foreign_listeners() {
    local label="$1" listeners="$2" line
    [ -n "$listeners" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if ! listener_line_is_wstt_owned "$line"; then
            log_error "$label занят посторонним процессом; его остановка запрещена"
            printf '%s\n' "$listeners" | tee -a "$LOG_FILE" >&2
            die "Порт $label занят. Выберите другой порт; чужие процессы не затрагиваются."
        fi
    done <<< "$listeners"
}

assert_wstt_ports_preflight() {
    assert_no_foreign_listeners "UDP/${PEER_PORT}" "$(peer_port_listeners)"
    assert_no_foreign_listeners "TCP/${WEB_PORT}" "$(web_port_listeners)"
}

archive_wstt_docker_state() {
    local container="$1" container_id archive_dir source base copied=0
    container_id="$(docker inspect --format '{{.Id}}' "$container" 2>/dev/null || true)"
    [ -n "$container_id" ] || return 0
    archive_dir="${WSTT_RUNTIME_ARCHIVE_DIR}/docker-${container_id:0:12}-$(date +%s)"
    umask 077
    mkdir -p "$archive_dir" || die "Не удалось подготовить архив состояния Docker WSTT"
    for source in /etc/wstt/wstt.db /etc/wstt/wstt.db-wal /etc/wstt/wstt.db-shm /etc/wstt/passwords.json /etc/wstt/passwords.json.imported; do
        base="${source##*/}"
        if docker cp "${container}:${source}" "${archive_dir}/${base}" >/dev/null 2>&1; then
            chmod 600 "${archive_dir}/${base}" 2>/dev/null || true
            copied=1
        fi
    done
    if [ "$copied" -eq 1 ]; then
        log_info "Состояние Docker WSTT сохранено: $archive_dir"
    else
        rmdir "$archive_dir" >/dev/null 2>&1 || true
    fi
}

stop_and_archive_wstt_docker_container() {
    local container="$1" name running
    docker inspect "$container" >/dev/null 2>&1 || return 0
    name="$(docker inspect --format '{{.Name}}' "$container" 2>/dev/null || printf '%s' "$container")"
    name="${name#/}"
    docker update --restart=no "$container" >/dev/null 2>&1 || true
    running="$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || printf false)"
    if [ "$running" = "true" ]; then
        timeout 10 docker stop --time 5 "$container" >/dev/null 2>&1 || true
        if [ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || printf false)" = "true" ]; then
            docker kill "$container" >/dev/null 2>&1 || true
        fi
    fi
    archive_wstt_docker_state "$container"
    timeout 10 docker rm -f "$container" >/dev/null 2>&1 || \
        die "Не удалось остановить старый Docker-контейнер WSTT"
}

remove_all_wstt_docker_containers() {
    command -v docker >/dev/null 2>&1 || return 0
    local container name
    while IFS= read -r container; do
        [ -n "$container" ] || continue
        docker_container_runs_wstt "$container" || continue
        name="$(docker inspect --format '{{.Name}}' "$container" 2>/dev/null || printf '%s' "$container")"
        name="${name#/}"
        log_info "Остановка Docker runtime WSTT: $name"
        stop_and_archive_wstt_docker_container "$container"
    done < <(docker ps -aq --no-trunc 2>/dev/null || true)
}

systemd_unit_runs_wstt() {
    local unit="$1" content
    content="$(systemctl cat "$unit" 2>/dev/null || true)"
    if printf '%s\n' "$content" | grep -Eq '(/usr/local/bin/wstt|/usr/local/lib/wstt/)'; then
        return 0
    fi
    return 1
}

list_wstt_systemd_units() {
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit
    while IFS= read -r unit; do
        case "$unit" in
            *.service) ;;
            *) continue ;;
        esac
        case "$unit" in
            "$WSTT_DOCKER_PREREQ_SERVICE"|"$WSTT_LE_SERVICE") continue ;;
        esac
        if systemd_unit_runs_wstt "$unit"; then
            printf '%s\n' "$unit"
        fi
    done < <({
        systemctl list-units --type=service --all --no-legend --plain 2>/dev/null || true
        systemctl list-unit-files --type=service --no-legend --plain 2>/dev/null || true
    } | awk '{print $1}' | sort -u)
    return 0
}

stop_wstt_docker_prereq() {
    command -v systemctl >/dev/null 2>&1 || return 0
    local requires_link="/etc/systemd/system/docker.service.requires/${WSTT_DOCKER_PREREQ_SERVICE}"
    local wants_link="/etc/systemd/system/docker.service.wants/${WSTT_DOCKER_PREREQ_SERVICE}"
    if [ -e "$requires_link" ] || [ -L "$requires_link" ]; then
        rm -f -- "$requires_link"
        SYSTEMD_NEEDS_RELOAD=1
    fi
    if [ -e "$wants_link" ] || [ -L "$wants_link" ]; then
        rm -f -- "$wants_link"
        SYSTEMD_NEEDS_RELOAD=1
    fi
    systemctl disable "$WSTT_DOCKER_PREREQ_SERVICE" >/dev/null 2>&1 || true
    if [ "$SYSTEMD_NEEDS_RELOAD" -eq 1 ]; then
        systemctl daemon-reload || die "systemctl daemon-reload завершился ошибкой при отключении Docker prerequisites"
        SYSTEMD_NEEDS_RELOAD=0
    fi
    if systemctl is-active --quiet "$WSTT_DOCKER_PREREQ_SERVICE"; then
        log_info "Остановка Docker prerequisite WSTT: $WSTT_DOCKER_PREREQ_SERVICE"
        timeout 10 systemctl stop "$WSTT_DOCKER_PREREQ_SERVICE" >/dev/null 2>&1 || true
        if systemctl is-active --quiet "$WSTT_DOCKER_PREREQ_SERVICE"; then
            timeout 2 systemctl kill --kill-who=all --signal=SIGKILL "$WSTT_DOCKER_PREREQ_SERVICE" >/dev/null 2>&1 || true
        fi
        if systemctl is-active --quiet "$WSTT_DOCKER_PREREQ_SERVICE"; then
            die "Не удалось остановить Docker prerequisite WSTT: $WSTT_DOCKER_PREREQ_SERVICE"
        fi
    fi
}

stop_all_running_wstt_systemd_units() {
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit
    while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        log_info "Остановка systemd runtime WSTT: $unit"
        if ! timeout 10 systemctl stop "$unit" >/dev/null 2>&1; then
            log_warn "systemctl stop завершился с ошибкой для $unit; проверяется фактическое состояние"
        fi
        if systemctl is-active --quiet "$unit"; then
            timeout 2 systemctl kill --kill-who=all --signal=SIGKILL "$unit" >/dev/null 2>&1 || true
        fi
        if systemctl is-active --quiet "$unit"; then
            die "Не удалось остановить systemd runtime WSTT: $unit"
        fi
        systemctl disable "$unit" >/dev/null 2>&1 || true
    done < <(list_wstt_systemd_units)
    return 0
}

remove_all_wstt_systemd_units() {
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit fragment
    while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        fragment="$(systemctl show --value -p FragmentPath "$unit" 2>/dev/null || true)"
        case "$fragment" in
            /etc/systemd/system/*)
                rm -f -- "$fragment"
                rm -rf -- "${fragment}.d"
                rm -f -- "/etc/systemd/system/multi-user.target.wants/${unit}"
                SYSTEMD_NEEDS_RELOAD=1
                ;;
        esac
    done < <(list_wstt_systemd_units)
    return 0
}

prog() { echo "CSQTT_PROGRESS|$1|$2"; }

run_timed() {
    local label="$1" started=$SECONDS
    shift
    "$@"
    log_info "Время этапа «$label»: $((SECONDS - started))с"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Скрипт должен быть запущен от root. Если sudo отсутствует, зайдите под root и запустите: bash $0 $*"
    fi
}

OS_ID="" ; PKG_MGR=""

detect_os() {
    log_step "Определение операционной системы..."
    if [ ! -f /etc/os-release ]; then
        die "Файл /etc/os-release не найден."
    fi
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    case "$OS_ID" in
        ubuntu|debian|linuxmint|pop)     PKG_MGR="apt" ;;
        centos|rhel|rocky|almalinux|oracle|ol) PKG_MGR="yum"
            command -v dnf &>/dev/null && PKG_MGR="dnf" ;;
        fedora)                          PKG_MGR="dnf" ;;
        arch|manjaro|endeavouros)        PKG_MGR="pacman" ;;
        *)
            case " ${ID_LIKE:-} " in
                *" debian "*) PKG_MGR="apt" ;;
                *" rhel "*|*" fedora "*)
                    PKG_MGR="yum"
                    command -v dnf &>/dev/null && PKG_MGR="dnf"
                    ;;
                *" arch "*) PKG_MGR="pacman" ;;
                *) die "Неподдерживаемый дистрибутив: $OS_ID" ;;
            esac
            ;;
    esac
    log_info "ОС: ${PRETTY_NAME:-$OS_ID} | PM: $PKG_MGR"
}

pkg_update_done=0

pkg_update() {
    [ "$pkg_update_done" = "1" ] && return 0
    log_step "Обновление индексов пакетов..."
    case "$PKG_MGR" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y >>"$LOG_FILE" 2>&1 || log_warn "apt update завершился с ошибкой, пробую продолжить"
            ;;
        dnf)    dnf makecache -y >>"$LOG_FILE" 2>&1 || true ;;
        yum)    yum makecache -y >>"$LOG_FILE" 2>&1 || true ;;
        pacman) : ;;
    esac
    pkg_update_done=1
}

pkg_install() {
    [ "$#" -eq 0 ] && return 0
    case "$PKG_MGR" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y -qq --no-install-recommends "$@" >>"$LOG_FILE" 2>&1
            ;;
        dnf)    dnf install -y "$@" >>"$LOG_FILE" 2>&1 ;;
        yum)    yum install -y "$@" >>"$LOG_FILE" 2>&1 ;;
        pacman) pacman -Syu --noconfirm --needed "$@" >>"$LOG_FILE" 2>&1 ;;
    esac
}

pkg_install_with_refresh() {
    pkg_install "$@" && return 0
    pkg_update
    pkg_install "$@"
}

install_prerequisites() {
    prog 0.10 "Пакеты..."
    log_step "Проверка базовых зависимостей..."

    local ip_package procps_package
    case "$PKG_MGR" in
        apt)     ip_package="iproute2"; procps_package="procps" ;;
        dnf|yum) ip_package="iproute";  procps_package="procps-ng" ;;
        pacman)  ip_package="iproute2"; procps_package="procps-ng" ;;
    esac

    local -a packages=()
    local need_iptables=0
    command -v ip >/dev/null 2>&1 || packages+=("$ip_package")
    command -v curl >/dev/null 2>&1 || packages+=("curl")
    command -v modprobe >/dev/null 2>&1 || packages+=("kmod")
    if ! command -v sysctl >/dev/null 2>&1; then
        packages+=("$procps_package")
    fi
    command -v iptables >/dev/null 2>&1 || need_iptables=1

    if [ "$PKG_MGR" = "pacman" ] && [ "$need_iptables" -eq 1 ]; then
        packages+=("iptables")
        need_iptables=0
    fi

    if [ "${#packages[@]}" -eq 0 ] && [ "$need_iptables" -eq 0 ]; then
        log_info "Все системные зависимости уже установлены — обновление пакетов не требуется"
        return 0
    fi

    pkg_update
    if [ "${#packages[@]}" -gt 0 ]; then
        pkg_install "${packages[@]}" || die "Не удалось установить обязательные пакеты: ${packages[*]}"
    fi

    if [ "$need_iptables" -eq 1 ]; then
        case "$PKG_MGR:$OS_ID" in
            dnf:fedora)
                pkg_install iptables-nft || pkg_install iptables || \
                    die "Не удалось установить iptables/iptables-nft"
                ;;
            dnf:*|yum:*)
                pkg_install iptables || pkg_install iptables-nft || \
                    die "Не удалось установить iptables/iptables-nft"
                ;;
            *)
                pkg_install iptables || die "Не удалось установить обязательный пакет iptables"
                ;;
        esac
    fi
}

require_runtime_tools() {
    command -v ip >/dev/null 2>&1 || die "Команда ip не найдена. Установите iproute2/iproute."
    command -v iptables >/dev/null 2>&1 || die "Команда iptables не найдена. Она обязательна для TUN и NAT."
    command -v sysctl >/dev/null 2>&1 || die "Команда sysctl не найдена. Установите procps/procps-ng."
    if [ "$DEPLOY_MODE" = "systemd" ]; then
        command -v systemctl >/dev/null 2>&1 || die "systemctl не найден. Для native-установки нужен VPS с systemd."
    fi
    case "$(uname -m)" in
        x86_64|amd64) log_info "Архитектура VPS: amd64" ;;
        aarch64|arm64) log_info "Архитектура VPS: ARM64" ;;
        armv7l|armv7|armhf) log_info "Архитектура VPS: ARM32" ;;
        *) die "Архитектура VPS $(uname -m) не поддерживается. Поддерживаются: x86_64, aarch64, armv7l." ;;
    esac
}

detect_wan_interface() {
    local iface fallback=""
    while IFS= read -r iface; do
        iface="${iface%%@*}"
        [ -n "$iface" ] || continue
        [ -n "$fallback" ] || fallback="$iface"
        if ! is_ignored_wan_interface "$iface" && ip link show "$iface" >/dev/null 2>&1; then
            echo "$iface"
            return 0
        fi
    done <<EOF
$(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); break}}')
EOF
    while IFS= read -r iface; do
        iface="${iface%%@*}"
        [ -n "$iface" ] || continue
        [ -n "$fallback" ] || fallback="$iface"
        if ! is_ignored_wan_interface "$iface" && ip link show "$iface" >/dev/null 2>&1; then
            echo "$iface"
            return 0
        fi
    done <<EOF
$(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/@.*/, "", $2); print $2}')
EOF
    while IFS= read -r iface; do
        iface="${iface%%@*}"
        [ -n "$iface" ] || continue
        [ "$iface" = "lo" ] && continue
        [ -n "$fallback" ] || fallback="$iface"
        if ! is_ignored_wan_interface "$iface" && ip link show "$iface" >/dev/null 2>&1; then
            echo "$iface"
            return 0
        fi
    done <<EOF
$(ls /sys/class/net/ 2>/dev/null || true)
EOF
    [ -n "$fallback" ] && echo "$fallback"
}

is_ignored_wan_interface() {
    local iface="${1%%@*}"
    case "$iface" in
        ""|lo|"$WSTT_IFACE"|wsttp*|tun*|tap*|wg*|warp*|Warp*|WARP*|CloudflareWARP*|tailscale*|zt*|docker*|br-*|veth*|cni*|flannel*|virbr*|podman*|kube*|dummy*|ifb*)
            return 0
            ;;
    esac
    return 1
}

detect_firewall() {
    command -v iptables >/dev/null 2>&1 || \
        die "iptables не найден: без него сервер не сможет создать рабочий TUN/NAT."
    local ver
    ver="$(iptables --version 2>/dev/null || echo unknown)"
    log_info "Firewall backend: iptables (${ver})"
}

ipt_add_or_ensure() {
    local table="$1" chain="$2"
    shift 2
    local -a targs=()
    [ "$table" = "filter" ] || targs=(-t "$table")
    iptables -w "$XT_WAIT" "${targs[@]}" -C "$chain" "$@" >/dev/null 2>&1 || \
        iptables -w "$XT_WAIT" "${targs[@]}" -I "$chain" 1 "$@" >>"$LOG_FILE" 2>&1
}

fw_add_input_udp() {
    local port="$1"
    ipt_add_or_ensure filter INPUT -p udp --dport "$port" -m comment --comment "$IPT_COMMENT" -j ACCEPT || \
        die "Не удалось открыть ${port}/udp в iptables"
}

fw_add_input_tcp() {
    local port="$1"
    ipt_add_or_ensure filter INPUT -p tcp --dport "$port" -m comment --comment "$IPT_COMMENT" -j ACCEPT || \
        die "Не удалось открыть ${port}/tcp в iptables"
}

fw_add_forward() {
    ipt_add_or_ensure filter INPUT -i "$WSTT_IFACE" -s "10.67.68.0/24" -m comment --comment "$IPT_COMMENT" -j ACCEPT || \
        die "Не удалось установить INPUT -i $WSTT_IFACE"
    if ! iptables -w "$XT_WAIT" -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1; then
        ipt_add_or_ensure filter FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$IPT_COMMENT" -j ACCEPT || \
            die "Не удалось установить FORWARD RELATED,ESTABLISHED"
    fi
    ipt_add_or_ensure filter FORWARD -i "$WSTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT || \
        die "Не удалось установить FORWARD -i $WSTT_IFACE"
    ipt_add_or_ensure filter FORWARD -o "$WSTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT || \
        die "Не удалось установить FORWARD -o $WSTT_IFACE"
}

fw_add_masquerade() {
    local iface="$1" subnet="$2"
    if [ -n "$iface" ]; then
        iptables -w "$XT_WAIT" -t nat -C POSTROUTING -s "$subnet" -o "$iface" -m comment --comment "$IPT_COMMENT" -j MASQUERADE >/dev/null 2>&1 || \
            iptables -w "$XT_WAIT" -t nat -A POSTROUTING -s "$subnet" -o "$iface" -m comment --comment "$IPT_COMMENT" -j MASQUERADE >>"$LOG_FILE" 2>&1 || true
        local wan_ip
        wan_ip="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1)"
        if [ -n "$wan_ip" ]; then
            iptables -w "$XT_WAIT" -t nat -C POSTROUTING -s "$subnet" -o "$iface" -m comment --comment "$IPT_COMMENT" -j SNAT --to-source "$wan_ip" >/dev/null 2>&1 || \
                iptables -w "$XT_WAIT" -t nat -I POSTROUTING 1 -s "$subnet" -o "$iface" -m comment --comment "$IPT_COMMENT" -j SNAT --to-source "$wan_ip" >>"$LOG_FILE" 2>&1 || true
        fi
    fi
    iptables -w "$XT_WAIT" -t nat -C POSTROUTING -s "$subnet" ! -o "$WSTT_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE >/dev/null 2>&1 || \
        iptables -w "$XT_WAIT" -t nat -A POSTROUTING -s "$subnet" ! -o "$WSTT_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE >>"$LOG_FILE" 2>&1 || \
        die "Не удалось установить NAT MASQUERADE"
}

fw_add_mss_clamping() {
    local subnet="$1"
    ipt_add_or_ensure mangle FORWARD -s "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu || \
        die "Не удалось установить исходящий TCP MSS clamping"
    ipt_add_or_ensure mangle FORWARD -d "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu || \
        die "Не удалось установить входящий TCP MSS clamping"
}

delete_marked_rules() {
    local table="$1" chain="$2" marker="$3" binary="${4:-iptables}" i numbers number
    local -a targs=()
    [ "$table" = "filter" ] || targs=(-t "$table")
    for i in 1 2 3 4 5 6 7 8; do
        numbers="$("$binary" -w "$XT_WAIT" "${targs[@]}" -S "$chain" 2>/dev/null | awk -v chain="$chain" -v marker="$marker" '
$1 == "-A" && $2 == chain {
    n++
    if (index($0, marker)) hit[++h] = n
}
END {
    for (i = h; i >= 1; i--) print hit[i]
}
')" || return 0
        [ -n "$numbers" ] || break
        while IFS= read -r number; do
            [ -n "$number" ] && "$binary" -w "$XT_WAIT" "${targs[@]}" -D "$chain" "$number" >/dev/null 2>&1 || true
        done <<EOF
$numbers
EOF
    done
}

cleanup_wstt_policy_routes() {
    command -v ip >/dev/null 2>&1 || return 0
    while ip -4 rule del from 10.67.68.0/24 priority 1067 table 1067 >/dev/null 2>&1; do :; done
    while ip -4 rule del fwmark 0x423 priority 1067 table 1067 >/dev/null 2>&1; do :; done
    while ip -4 rule del fwmark 0x7532/0x7532 priority 30002 table 30002 >/dev/null 2>&1; do :; done
    ip -4 route flush table 1067 >/dev/null 2>&1 || true
    ip -4 route flush table 30002 >/dev/null 2>&1 || true
}

cleanup_wstt_netfilter_rules() {
    local table chain marker
    for marker in "$IPT_COMMENT" WSTT_MIRRORED WSTT_TPROXY WSTT_LOCAL_SOCKS WSTT_LOCAL_SOCKS_MARK WSTT_SOCKS WSTT_CASCADE_NO_QUIC; do
        for table in filter nat mangle; do
            for chain in INPUT FORWARD PREROUTING POSTROUTING OUTPUT; do
                delete_marked_rules "$table" "$chain" "$marker"
                if command -v ip6tables >/dev/null 2>&1; then
                    delete_marked_rules "$table" "$chain" "$marker" ip6tables
                fi
            done
        done
    done
}

secure_persistent_state() {
    [ -d "$WSTT_CONFIG_DIR" ] || return 0
    chmod 700 "$WSTT_CONFIG_DIR" 2>/dev/null || true
    [ -d "$WSTT_RUNTIME_ARCHIVE_DIR" ] && chmod 700 "$WSTT_RUNTIME_ARCHIVE_DIR" 2>/dev/null || true
    [ -d "$WSTT_LE_CONFIG_DIR" ] && chmod 700 "$WSTT_LE_CONFIG_DIR" 2>/dev/null || true

    local file
    for file in \
        "$WSTT_DATABASE_FILE" \
        "$WSTT_DATABASE_WAL_FILE" \
        "$WSTT_DATABASE_SHM_FILE" \
        "$WSTT_LEGACY_MIGRATION_JSON" \
        "$WSTT_LEGACY_MIGRATION_IMPORTED_JSON"; do
        [ -f "$WSTT_CONFIG_DIR/$file" ] && chmod 600 "$WSTT_CONFIG_DIR/$file" 2>/dev/null || true
    done
    [ -f "$WSTT_ENV_FILE" ] && chmod 600 "$WSTT_ENV_FILE" 2>/dev/null || true
    [ -f "$WSTT_DEPLOY_OVERRIDES_FILE" ] && chmod 600 "$WSTT_DEPLOY_OVERRIDES_FILE" 2>/dev/null || true
    [ -f "$WSTT_CONFIG_DIR/web_cert.pem" ] && chmod 644 "$WSTT_CONFIG_DIR/web_cert.pem" 2>/dev/null || true
    [ -f "$WSTT_CONFIG_DIR/web_key.pem" ] && chmod 600 "$WSTT_CONFIG_DIR/web_key.pem" 2>/dev/null || true
    [ -f "$WSTT_LE_STATE_FILE" ] && chmod 600 "$WSTT_LE_STATE_FILE" 2>/dev/null || true
}

ensure_wstt_directory() {
    local path="$1" mode="$2"
    if [ -L "$path" ] || [ ! -d "$path" ]; then
        rm -rf -- "$path" || die "Не удалось очистить путь WSTT: $path"
    fi
    mkdir -p -- "$path" || die "Не удалось подготовить каталог WSTT: $path"
    chmod "$mode" "$path" || die "Не удалось установить права на каталог WSTT: $path"
}

clear_runtime_config_preserving_database() {
    local entry base
    ensure_wstt_directory "$WSTT_CONFIG_DIR" 700
    shopt -s nullglob dotglob
    for entry in "$WSTT_CONFIG_DIR"/*; do
        base="${entry##*/}"
        case "$base" in
            "$WSTT_DATABASE_FILE"|"$WSTT_DATABASE_WAL_FILE"|"$WSTT_DATABASE_SHM_FILE"|"$WSTT_LEGACY_MIGRATION_JSON"|"$WSTT_LEGACY_MIGRATION_IMPORTED_JSON"|web_cert.pem|web_key.pem|letsencrypt-ip.env|letsencrypt|runtime-archive) continue ;;
        esac
        rm -rf -- "$entry"
    done
    shopt -u nullglob dotglob
    secure_persistent_state
}

remove_managed_work_dir() {
    local path="$1"
    case "$path" in
        /tmp/wstt-docker.*)
            rm -rf -- "$path"
            ;;
        "")
            ;;
        *)
            log_warn "Отказ от удаления неожиданного временного пути: $path"
            return 1
            ;;
    esac
}

cleanup_deploy_uploads() {
    local docker_context="$DOCKER_CONTEXT_DIR"
    DOCKER_CONTEXT_DIR=""
    remove_managed_work_dir "$docker_context" || true
    if command -v docker >/dev/null 2>&1 && [ -n "$WSTT_DOCKER_CANDIDATE_IMAGE" ]; then
        docker image rm "$WSTT_DOCKER_CANDIDATE_IMAGE" >/dev/null 2>&1 || true
        WSTT_DOCKER_CANDIDATE_IMAGE=""
    fi
    rm -f -- "$UPLOAD_BINARY" "$UPLOAD_ENV_FILE" "$UPLOAD_OVERRIDES_FILE"
}

validate_candidate_environment() {
    local candidate_env="$1" candidate_overrides="$2"
    grep -Eq '^[[:space:]]*(export[[:space:]]+)?WSTT_WEB_USER=.+$' "$candidate_env" || \
        die "В переданной WEB-конфигурации отсутствует WSTT_WEB_USER" "$EXIT_PREFLIGHT_FAILED"
    grep -Eq '^[[:space:]]*(export[[:space:]]+)?WSTT_WEB_PASS=.+$' "$candidate_env" || \
        die "В переданной WEB-конфигурации отсутствует WSTT_WEB_PASS" "$EXIT_PREFLIGHT_FAILED"
    grep -q '"main_password"' "$candidate_overrides" || \
        die "В deploy-конфигурации отсутствует main_password" "$EXIT_PREFLIGHT_FAILED"
}

prepare_uploaded_release() {
    DEPLOY_PHASE="preflight"
    [ -f "$UPLOAD_BINARY" ] && [ -s "$UPLOAD_BINARY" ] || \
        die "Новый бинарник не загружен или пуст" "$EXIT_PREFLIGHT_FAILED"
    [ -f "$UPLOAD_ENV_FILE" ] && [ -s "$UPLOAD_ENV_FILE" ] || \
        die "Одноразовая WEB-конфигурация не загружена" "$EXIT_PREFLIGHT_FAILED"
    [ -f "$UPLOAD_OVERRIDES_FILE" ] && [ -s "$UPLOAD_OVERRIDES_FILE" ] || \
        die "Одноразовая deploy-конфигурация не загружена" "$EXIT_PREFLIGHT_FAILED"

    chmod 0755 "$UPLOAD_BINARY" || die "Не удалось подготовить загруженный бинарник wstt" "$EXIT_PREFLIGHT_FAILED"
    chmod 0600 "$UPLOAD_ENV_FILE" "$UPLOAD_OVERRIDES_FILE" || \
        die "Не удалось защитить загруженную конфигурацию" "$EXIT_PREFLIGHT_FAILED"
    validate_candidate_environment "$UPLOAD_ENV_FILE" "$UPLOAD_OVERRIDES_FILE"
    [ -x "$UPLOAD_BINARY" ] || die "Загруженный бинарник WSTT не исполняемый" "$EXIT_PREFLIGHT_FAILED"
    log_info "Загруженный бинарник wstt проверен"
    log_info "Загруженный бинарник и конфигурация проверены до остановки текущего сервиса"
}

finish_deployment() {
    if command -v docker >/dev/null 2>&1 && [ -n "$WSTT_DOCKER_CANDIDATE_IMAGE" ]; then
        docker image rm "$WSTT_DOCKER_CANDIDATE_IMAGE" >/dev/null 2>&1 || \
            log_warn "Не удалось снять временный Docker tag $WSTT_DOCKER_CANDIDATE_IMAGE"
    fi
    cleanup_deploy_uploads
}

cleanup_legacy_proxy_interfaces() {
    local iface
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep '^wsttp' || true); do
        timeout 2 ip link del "$iface" 2>/dev/null || true
    done
}

remove_wstt_tun_interface() {
    local attempt waited=0
    if ! ip link show "$WSTT_IFACE" >/dev/null 2>&1; then
        return 0
    fi

    log_warn "Обнаружен остаточный TUN-интерфейс $WSTT_IFACE; выполняется восстановление runtime"
    for attempt in 1 2 3 4; do
        if timeout 2 ip link del "$WSTT_IFACE" >>"$LOG_FILE" 2>&1; then
            waited=0
            while [ "$waited" -lt 20 ]; do
                if ! ip link show "$WSTT_IFACE" >/dev/null 2>&1; then
                    log_info "Остаточный TUN-интерфейс $WSTT_IFACE удалён"
                    return 0
                fi
                sleep 0.1
                waited=$((waited + 1))
            done
        fi
        sleep 0.2
    done

    ip -d link show "$WSTT_IFACE" 2>&1 | tee -a "$LOG_FILE" >&2 || true
    return 1
}

wstt_cleanup() {
    prog 0.15 "Очистка..."
    echo "🧹 Переключение со старой установки WSTT..."

    # Remove only WSTT-owned state even after an interrupted/partial prior install.

    remove_all_wstt_docker_containers

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$WSTT_LE_TIMER" >/dev/null 2>&1 || true
        timeout 30 systemctl stop "$WSTT_LE_SERVICE" >/dev/null 2>&1 || true
        if systemctl is-active --quiet "$WSTT_LE_SERVICE"; then
            timeout 2 systemctl kill --kill-who=all --signal=SIGKILL "$WSTT_LE_SERVICE" >/dev/null 2>&1 || true
        fi
        if systemctl is-active --quiet "$WSTT_LE_SERVICE"; then
            die "Не удалось остановить службу обновления сертификата WSTT"
        fi
        stop_wstt_docker_prereq
        stop_all_running_wstt_systemd_units
    fi

    force_stop_wstt_processes || die "Не удалось завершить процессы WSTT"
    cleanup_wstt_policy_routes
    remove_all_wstt_systemd_units
    [ -e "/etc/systemd/system/${WSTT_DOCKER_PREREQ_SERVICE}" ] && SYSTEMD_NEEDS_RELOAD=1
    rm -f "/etc/systemd/system/${WSTT_DOCKER_PREREQ_SERVICE}"
    rm -f "/etc/systemd/system/docker.service.requires/${WSTT_DOCKER_PREREQ_SERVICE}"
    rm -f "/etc/systemd/system/docker.service.wants/${WSTT_DOCKER_PREREQ_SERVICE}"
    if [ "$SYSTEMD_NEEDS_RELOAD" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || die "systemctl daemon-reload завершился ошибкой после удаления старого runtime"
        SYSTEMD_NEEDS_RELOAD=0
    fi
    rm -f /usr/local/bin/wstt
    rm -rf /usr/local/lib/wstt
    clear_runtime_config_preserving_database

    assert_peer_port_is_available
    assert_web_port_is_available

    cleanup_legacy_proxy_interfaces
    remove_wstt_tun_interface || die "Не удалось освободить TUN-интерфейс $WSTT_IFACE; переключение отменено"
    cleanup_wstt_netfilter_rules || true

    echo "✓ Старый runtime удалён; SQLite/legacy JSON state сохранён"
}

setup_sysctl() {
    prog 0.25 "Sysctl..."
    echo "⚙️  Настройка сетевых параметров..."

    # IP forwarding is a host-wide kernel switch shared by every VPN instance.
    # Keep only the forwarding switches required by WSTT; do not rewrite global
    # TCP, qdisc, rp_filter, or router-advertisement policy for other services.
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true

    mkdir -p /etc/sysctl.d
    cat > "$WSTT_SYSCTL_FILE" << 'SYSEOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSEOF

    cat > "$WSTT_UDP_SYSCTL_FILE" << 'SYSEOF'
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
SYSEOF

    sysctl -p "$WSTT_SYSCTL_FILE" >>"$LOG_FILE" 2>&1 || log_warn "Не удалось применить параметры маршрутизации"
    sysctl -p "$WSTT_UDP_SYSCTL_FILE" >>"$LOG_FILE" 2>&1 || log_warn "Ядро ограничило лимиты сетевых буферов; сервер продолжит работу с доступными значениями"

    [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" = "1" ] || \
        die "IPv4 forwarding невозможно включить на этом VPS"

    echo "✓ Sysctl настроен (IPv4/IPv6 forwarding + UDP buffers)"
}

setup_nat_and_firewall() {
    prog 0.40 "NAT + Firewall..."
    echo "🛡  Настройка NAT и фаервола..."

    local iface
    iface=$(detect_wan_interface)

    if [ -z "$iface" ]; then
        die "Не удалось определить WAN-интерфейс для NAT подсети 10.67.68.0/24"
    fi
    ip link show "$iface" >/dev/null 2>&1 || die "Определённый WAN-интерфейс $iface не существует"

    log_info "WAN-интерфейс: $iface"
    # Preserve router advertisements while global IPv6 forwarding is enabled.
    sysctl -w "net.ipv6.conf.${iface}.accept_ra=2" >>"$LOG_FILE" 2>&1 || true

    local gw_ip
    gw_ip="$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); break}}')"
    if [ -n "$gw_ip" ]; then
        ip route replace "$gw_ip" dev "$iface" scope link >>"$LOG_FILE" 2>&1 || true
    fi

    fw_add_input_udp "$PEER_PORT"
    fw_add_input_tcp "$WEB_PORT"
    fw_add_input_tcp "$LE_HTTP_PORT"

    fw_add_forward

    fw_add_masquerade "$iface" "10.67.68.0/24"
    
    fw_add_mss_clamping "10.67.68.0/24"

    echo "✓ NAT: MASQUERADE на $iface для 10.67.68.0/24"
    echo "✓ Порты WSTT: ${PEER_PORT}/udp(PEER), ${WEB_PORT}/tcp(WEB), ${LE_HTTP_PORT}/tcp(LE)"
    echo "✓ TCP MSS Clamping включен"
}

write_network_helper() {
    local target="$1"
    cat > "$target" << NETEOF
#!/bin/sh
set -eu
    PEER_PORT="$PEER_PORT"
WEB_PORT="$WEB_PORT"
LE_HTTP_PORT="$LE_HTTP_PORT"
WSTT_IFACE="$WSTT_IFACE"
IPT_COMMENT="$IPT_COMMENT"
SUBNET="10.67.68.0/24"
SUBNET6="fd67:68::/64"
XT_WAIT="$XT_WAIT"
WSTT_RUNTIME_DIR="$WSTT_RUNTIME_DIR"
NETWORK_READY_FILE="$WSTT_DOCKER_NETWORK_READY"

command -v ip >/dev/null 2>&1 || exit 20
command -v iptables >/dev/null 2>&1 || exit 21
[ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
[ -w /proc/sys/net/ipv6/conf/all/forwarding ] && echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true

is_ignored_wan_interface() {
    ignored_iface="\${1%%@*}"
    case "\$ignored_iface" in
        ""|lo|"\$WSTT_IFACE"|wsttp*|tun*|tap*|wg*|warp*|Warp*|WARP*|CloudflareWARP*|tailscale*|zt*|docker*|br-*|veth*|cni*|flannel*|virbr*|podman*|kube*|dummy*|ifb*)
            return 0
            ;;
    esac
    return 1
}

detect_wan_interface() {
    fallback=""
    for iface in \$(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") {print \$(i+1); break}}'); do
        iface="\${iface%%@*}"
        [ -n "\$iface" ] || continue
        [ -n "\$fallback" ] || fallback="\$iface"
        if ! is_ignored_wan_interface "\$iface" && ip link show "\$iface" >/dev/null 2>&1; then
            echo "\$iface"
            return 0
        fi
    done
    for iface in \$(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/@.*/, "", \$2); print \$2}'); do
        iface="\${iface%%@*}"
        [ -n "\$iface" ] || continue
        [ -n "\$fallback" ] || fallback="\$iface"
        if ! is_ignored_wan_interface "\$iface" && ip link show "\$iface" >/dev/null 2>&1; then
            echo "\$iface"
            return 0
        fi
    done
    for iface in \$(ls /sys/class/net/ 2>/dev/null || true); do
        iface="\${iface%%@*}"
        [ -n "\$iface" ] || continue
        [ "\$iface" = "lo" ] && continue
        [ -n "\$fallback" ] || fallback="\$iface"
        if ! is_ignored_wan_interface "\$iface" && ip link show "\$iface" >/dev/null 2>&1; then
            echo "\$iface"
            return 0
        fi
    done
    [ -n "\$fallback" ] && echo "\$fallback"
}

WAN_IFACE=""
network_waited=0
while [ "\$network_waited" -lt 90 ]; do
    candidate_iface=\$(detect_wan_interface || true)
    if [ -n "\$candidate_iface" ] && ip link show "\$candidate_iface" >/dev/null 2>&1 && \
       ip -o -4 route show default 2>/dev/null | grep -q .; then
        WAN_IFACE="\$candidate_iface"
        break
    fi
    network_waited=\$((network_waited + 1))
    sleep 1
done
[ -n "\$WAN_IFACE" ] || exit 22
# Preserve IPv6 router advertisements while forwarding is enabled.
[ -w "/proc/sys/net/ipv6/conf/\$WAN_IFACE/accept_ra" ] && echo 2 > "/proc/sys/net/ipv6/conf/\$WAN_IFACE/accept_ra" 2>/dev/null || true
[ -w "/proc/sys/net/ipv4/conf/\$WSTT_IFACE/rp_filter" ] && echo 2 > "/proc/sys/net/ipv4/conf/\$WSTT_IFACE/rp_filter" 2>/dev/null || true
[ -w "/proc/sys/net/ipv6/conf/\$WSTT_IFACE/disable_ipv6" ] && echo 0 > "/proc/sys/net/ipv6/conf/\$WSTT_IFACE/disable_ipv6" 2>/dev/null || true
[ -w "/proc/sys/net/ipv6/conf/\$WSTT_IFACE/forwarding" ] && echo 1 > "/proc/sys/net/ipv6/conf/\$WSTT_IFACE/forwarding" 2>/dev/null || true

# Для /32 сетей с onlink-шлюзом обеспечиваем явный host route к шлюзу
gw=\$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if(\$i=="via") {print \$(i+1); break}}')
if [ -n "\$gw" ]; then
    ip route replace "\$gw" dev "\$WAN_IFACE" scope link 2>/dev/null || true
fi

if ip link show "\$WSTT_IFACE" >/dev/null 2>&1; then
    ip link set dev "\$WSTT_IFACE" txqueuelen 1000 2>/dev/null || true
fi

ipt() { iptables -w "\$XT_WAIT" "\$@"; }
ipt -C INPUT -p udp --dport "\$PEER_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I INPUT -p udp --dport "\$PEER_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
ipt -C INPUT -p tcp --dport "\$WEB_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I INPUT -p tcp --dport "\$WEB_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
ipt -C INPUT -p tcp --dport "\$LE_HTTP_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I INPUT -p tcp --dport "\$LE_HTTP_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
ipt -C INPUT -i "\$WSTT_IFACE" -s "\$SUBNET" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I INPUT -i "\$WSTT_IFACE" -s "\$SUBNET" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
if ! ipt -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    ipt -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || \
        ipt -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$IPT_COMMENT" -j ACCEPT
fi
ipt -C FORWARD -i "\$WSTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I FORWARD -i "\$WSTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
ipt -C FORWARD -o "\$WSTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I FORWARD -o "\$WSTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
ipt -t nat -C POSTROUTING -s "\$SUBNET" -o "\$WAN_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE 2>/dev/null || ipt -t nat -A POSTROUTING -s "\$SUBNET" -o "\$WAN_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE || true
ipt -t nat -C POSTROUTING -s "\$SUBNET" ! -o "\$WSTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE 2>/dev/null || ipt -t nat -A POSTROUTING -s "\$SUBNET" ! -o "\$WSTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE
WAN_IP="\$(ip -4 -o addr show dev "\$WAN_IFACE" scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n 1)"
if [ -n "\$WAN_IP" ]; then
    ipt -t nat -C POSTROUTING -s "\$SUBNET" -o "\$WAN_IFACE" -m comment --comment "\$IPT_COMMENT" -j SNAT --to-source "\$WAN_IP" 2>/dev/null || \
    ipt -t nat -I POSTROUTING 1 -s "\$SUBNET" -o "\$WAN_IFACE" -m comment --comment "\$IPT_COMMENT" -j SNAT --to-source "\$WAN_IP" 2>/dev/null || true
fi
ipt -t mangle -C FORWARD -s "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ipt -t mangle -I FORWARD -s "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu
ipt -t mangle -C FORWARD -d "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ipt -t mangle -I FORWARD -d "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu

if command -v ip6tables >/dev/null 2>&1 && ip -6 route show default 2>/dev/null | grep -q .; then
    ip6t() { ip6tables -w "\$XT_WAIT" "\$@"; }
    if ! ip6t -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        ip6t -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || \
            ip6t -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$IPT_COMMENT" -j ACCEPT
    fi
    ip6t -C FORWARD -i "\$WSTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ip6t -I FORWARD -i "\$WSTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
    ip6t -C FORWARD -o "\$WSTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ip6t -I FORWARD -o "\$WSTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
    ip6t -t nat -C POSTROUTING -s "\$SUBNET6" ! -o "\$WSTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE 2>/dev/null || ip6t -t nat -A POSTROUTING -s "\$SUBNET6" ! -o "\$WSTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE || true
    ip6t -t mangle -C FORWARD -s "\$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ip6t -t mangle -I FORWARD -s "\$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    ip6t -t mangle -C FORWARD -d "\$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ip6t -t mangle -I FORWARD -d "\$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
fi
umask 077
mkdir -p "\$WSTT_RUNTIME_DIR"
: > "\$NETWORK_READY_FILE"
NETEOF
    chmod 0755 "$target"
}

write_tun_recovery_helper() {
    local target="$1"
    cat > "$target" << RECOVEREOF
#!/bin/sh
set -eu
WSTT_IFACE="$WSTT_IFACE"
PEER_PORT="$PEER_PORT"
WSTT_CONFIG_DIR="$WSTT_CONFIG_DIR"

peer_port_is_busy() {
    ss -H -lun "sport = :\$PEER_PORT" 2>/dev/null | grep -q .
}

peer_port_pids() {
    ss -H -lunp "sport = :\$PEER_PORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -un || true
}

wstt_process_is_owned() {
    pid="\$1"
    [ -r "/proc/\$pid/cmdline" ] || return 1
    executable="\$(readlink "/proc/\$pid/exe" 2>/dev/null || true)"
    case "\$executable" in
        /usr/local/bin/wstt|'/usr/local/bin/wstt (deleted)'|/usr/local/lib/wstt/*|'/usr/local/lib/wstt/'*' (deleted)') return 0 ;;
    esac
    command_line="\$({ tr '\\0' ' ' < "/proc/\$pid/cmdline"; } 2>/dev/null || true)"
    case " \$command_line " in
        *" --config-dir \$WSTT_CONFIG_DIR "*|*" /usr/local/bin/wstt "*|*" /usr/local/lib/wstt/"*) return 0 ;;
        *) return 1 ;;
    esac
}

release_owned_peer_port() {
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        peer_port_is_busy || return 0
        pids="\$(peer_port_pids)"
        if [ -z "\$pids" ]; then
            echo "[WSTT] UDP/\$PEER_PORT is occupied by a runtime without visible PID" >&2
            ss -H -lunp "sport = :\$PEER_PORT" >&2 || true
            return 24
        fi
        for pid in \$pids; do
            if [ "\$attempt" -le 2 ]; then
                echo "[WSTT] UDP/\$PEER_PORT runtime PID \$pid; terminating" >&2
                kill -TERM "\$pid" 2>/dev/null || true
            else
                echo "[WSTT] UDP/\$PEER_PORT runtime PID \$pid; killing" >&2
                kill -KILL "\$pid" 2>/dev/null || true
            fi
        done
        sleep 0.2
    done
    echo "[WSTT] UDP/\$PEER_PORT did not release" >&2
    ss -H -lunp "sport = :\$PEER_PORT" >&2 || true
    return 24
}

release_owned_peer_port || exit \$?

if ! ip link show "\$WSTT_IFACE" >/dev/null 2>&1; then
    exit 0
fi

echo "[WSTT] stale TUN interface \$WSTT_IFACE detected; recovering runtime" >&2
for attempt in 1 2 3 4; do
    timeout 2 ip link del "\$WSTT_IFACE" >/dev/null 2>&1 || true
    if ! ip link show "\$WSTT_IFACE" >/dev/null 2>&1; then
        echo "[WSTT] stale TUN interface \$WSTT_IFACE removed" >&2
        exit 0
    fi
    sleep 0.2
done

ip -d link show "\$WSTT_IFACE" >&2 || true
echo "[WSTT] unable to release TUN interface \$WSTT_IFACE" >&2
exit 23
RECOVEREOF
    chmod 0755 "$target"
}

install_network_helper() {
    ensure_wstt_directory /usr/local/lib/wstt 755
    write_network_helper /usr/local/lib/wstt/network-up.sh
    write_tun_recovery_helper /usr/local/lib/wstt/tun-recover.sh
}

verify_configured_network() {
    local iface="${1:-$(detect_wan_interface)}"
    [ -n "$iface" ] || die "WAN-интерфейс не определён при проверке сети"
    [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" = "1" ] || die "IPv4 forwarding не включён"
    ip link show "$iface" >/dev/null 2>&1 || die "WAN-интерфейс $iface исчез"
}

setup_wstt_binary() {
    prog 0.60 "Бинарник..."
    echo "Установка wstt..."

    install -m 0755 "$UPLOAD_BINARY" /usr/local/bin/wstt || \
        die "Не удалось установить новый бинарник wstt"
    echo "✓ wstt установлен"

    echo "✓ SOCKS5-форвардер встроен в wstt (TPROXY, поднимается при первом использовании)"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop wstt-cascade.service --no-block >/dev/null 2>&1 || true
        timeout 1 systemctl kill --kill-who=all --signal=SIGKILL wstt-cascade.service >/dev/null 2>&1 || true
    fi
    if [ -e /etc/systemd/system/wstt-cascade.service ] || [ -L /etc/systemd/system/wstt-cascade.service ]; then
        SYSTEMD_NEEDS_RELOAD=1
    fi
    rm -f /etc/systemd/system/wstt-cascade.service
    rm -f /etc/systemd/system/multi-user.target.wants/wstt-cascade.service
    rm -f /usr/local/bin/wstt-cascade
    rm -f /usr/local/share/wstt/cascade.sh

    mkdir -p "$WSTT_CONFIG_DIR"
}

setup_wstt_environment() {
    ensure_wstt_directory "$WSTT_CONFIG_DIR" 700
    install -m 0600 "$UPLOAD_ENV_FILE" "$WSTT_ENV_FILE" || \
        die "Не удалось активировать загруженную WEB-конфигурацию"
    if ! grep -Eq '^[[:space:]]*(export[[:space:]]+)?WSTT_PUBLIC_IP=.+$' "$WSTT_ENV_FILE"; then
        local detected_ip="${WSTT_PUBLIC_IP:-}"
        [ -n "$detected_ip" ] || detected_ip="$(detect_public_ipv4 2>/dev/null || true)"
        if [ -n "$detected_ip" ]; then
            printf 'WSTT_PUBLIC_IP=%s\n' "$detected_ip" >> "$WSTT_ENV_FILE"
            log_info "Определен публичный IP сервера: $detected_ip"
        fi
    fi
    install -m 0600 "$UPLOAD_OVERRIDES_FILE" "$WSTT_DEPLOY_OVERRIDES_FILE" || \
        die "Не удалось активировать загруженную deploy-конфигурацию"
    echo "✓ Конфигурация запуска установлена безопасным EnvironmentFile"
}

LE_CERTBOT_COMMAND=""

is_public_ipv4() {
    local ip="$1" first second third fourth value
    case "$ip" in
        *[!0-9.]*|*..*|.*|*.) return 1 ;;
    esac
    IFS=. read -r first second third fourth <<< "$ip"
    for value in "$first" "$second" "$third" "$fourth"; do
        case "$value" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "$value" -le 255 ] || return 1
    done
    [ "$first" -gt 0 ] || return 1
    [ "$first" -lt 224 ] || return 1
    [ "$first" -ne 10 ] || return 1
    [ "$first" -ne 127 ] || return 1
    [ "$first" -ne 0 ] || return 1
    [ "$first" -ne 169 ] || [ "$second" -ne 254 ] || return 1
    [ "$first" -ne 192 ] || [ "$second" -ne 168 ] || return 1
    [ "$first" -ne 172 ] || [ "$second" -lt 16 ] || [ "$second" -gt 31 ] || return 1
    [ "$first" -ne 100 ] || [ "$second" -lt 64 ] || [ "$second" -gt 127 ] || return 1
    [ "$first" -ne 198 ] || [ "$second" -ne 18 ] || return 1
    [ "$first" -ne 198 ] || [ "$second" -ne 19 ] || return 1
    return 0
}

detect_public_ipv4() {
    local route_ip
    route_ip="$(ip -4 route get 77.88.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1)"
    if [ -n "$route_ip" ] && is_public_ipv4 "$route_ip"; then
        printf '%s\n' "$route_ip"
        return 0
    fi
    local endpoint value
    for endpoint in https://api.ipify.org https://ipv4.icanhazip.com; do
        value="$(curl -4 -fsS --connect-timeout 3 --max-time 7 "$endpoint" 2>/dev/null || true)"
        value="$(printf '%s' "$value" | tr -d '[:space:]')"
        if is_public_ipv4 "$value"; then
            printf '%s\n' "$value"
            return 0
        fi
    done
    return 1
}

certbot_supports_ip_certificates() {
    "$1" certonly --help all 2>&1 | grep -Fq -- "--ip-address"
}

ensure_letsencrypt_client() {
    local system_certbot=""
    local -a python_packages=()
    if command -v certbot >/dev/null 2>&1; then
        system_certbot="$(command -v certbot)"
        if certbot_supports_ip_certificates "$system_certbot"; then
            LE_CERTBOT_COMMAND="$system_certbot"
            return 0
        fi
    fi
    if [ -x "$WSTT_LE_CERTBOT" ] && certbot_supports_ip_certificates "$WSTT_LE_CERTBOT"; then
        LE_CERTBOT_COMMAND="$WSTT_LE_CERTBOT"
        return 0
    fi

    log_step "Подготовка Let’s Encrypt клиента..."
    if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import ensurepip' >/dev/null 2>&1; then
        case "$PKG_MGR" in
            apt) python_packages=(python3 python3-venv) ;;
            dnf|yum) python_packages=(python3 python3-pip) ;;
            pacman) python_packages=(python) ;;
        esac
        if ! pkg_install_with_refresh "${python_packages[@]}"; then
            log_warn "Python/venv недоступны; WEB-панель временно останется на self-signed TLS"
            return 1
        fi
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        if ! pkg_install_with_refresh openssl; then
            log_warn "OpenSSL недоступен; проверка и обновление Let’s Encrypt сертификата отложены"
            return 1
        fi
    fi
    if [ ! -x "$WSTT_LE_CERTBOT" ] || ! "$WSTT_LE_CERTBOT" --version >/dev/null 2>&1; then
        rm -rf "$WSTT_LE_VENV"
        if ! python3 -m venv "$WSTT_LE_VENV" >>"$LOG_FILE" 2>&1; then
            log_warn "Не удалось создать изолированный Let’s Encrypt client; WEB-панель временно останется на self-signed TLS"
            return 1
        fi
    fi
    if ! timeout 180 "$WSTT_LE_VENV/bin/pip" install --disable-pip-version-check --no-cache-dir --upgrade 'certbot>=5.4,<6' >>"$LOG_FILE" 2>&1; then
        log_warn "Не удалось установить актуальный Certbot с поддержкой IP-сертификатов; WEB-панель временно останется на self-signed TLS"
        return 1
    fi
    if ! certbot_supports_ip_certificates "$WSTT_LE_CERTBOT"; then
        log_warn "Установленный Certbot не поддерживает Let’s Encrypt IP-сертификаты"
        return 1
    fi
    LE_CERTBOT_COMMAND="$WSTT_LE_CERTBOT"
    return 0
}

letsencrypt_cert_name() {
    printf 'wstt-ip-%s\n' "${1//./-}"
}

state_value() {
    local key="$1"
    [ -f "$WSTT_LE_STATE_FILE" ] || return 1
    sed -n "s/^${key}=//p" "$WSTT_LE_STATE_FILE" | head -n 1
}

certificate_is_wstt_rcgen() {
    local issuer subject
    [ -s "$WSTT_CONFIG_DIR/web_cert.pem" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    issuer="$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$WSTT_CONFIG_DIR/web_cert.pem" 2>/dev/null || true)"
    subject="$(openssl x509 -noout -subject -nameopt RFC2253 -in "$WSTT_CONFIG_DIR/web_cert.pem" 2>/dev/null || true)"
    issuer="${issuer#issuer=}"
    subject="${subject#subject=}"
    [ "$subject" = "CN=rcgen self signed cert" ] && [ "$issuer" = "$subject" ]
}

certificate_is_wstt_letsencrypt() {
    local saved_ip cert_name issuer subject_alt_names
    [ -s "$WSTT_CONFIG_DIR/web_cert.pem" ] || return 1
    [ -s "$WSTT_CONFIG_DIR/web_key.pem" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    saved_ip="$(state_value IP 2>/dev/null || true)"
    cert_name="$(state_value CERT_NAME 2>/dev/null || true)"
    is_public_ipv4 "$saved_ip" || return 1
    [ "$cert_name" = "$(letsencrypt_cert_name "$saved_ip")" ] || return 1
    issuer="$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$WSTT_CONFIG_DIR/web_cert.pem" 2>/dev/null || true)"
    issuer="${issuer#issuer=}"
    case "$issuer" in
        *"O=Let's Encrypt"*|*ISRG*) ;;
        *) return 1 ;;
    esac
    subject_alt_names="$(openssl x509 -noout -ext subjectAltName -in "$WSTT_CONFIG_DIR/web_cert.pem" 2>/dev/null || true)"
    printf '%s\n' "$subject_alt_names" | grep -Fq "IP Address:${saved_ip}" || printf '%s\n' "$subject_alt_names" | grep -Fq "IP:${saved_ip}"
}

web_certificate_is_wstt_managed() {
    certificate_is_wstt_rcgen || certificate_is_wstt_letsencrypt
}

web_certificate_is_user_managed() {
    [ -s "$WSTT_CONFIG_DIR/web_cert.pem" ] || return 1
    ! web_certificate_is_wstt_managed
}

letsencrypt_certificate_is_current() {
    local public_ip="$1" saved_ip
    certificate_is_wstt_letsencrypt || return 1
    saved_ip="$(state_value IP 2>/dev/null || true)"
    [ "$saved_ip" = "$public_ip" ] || return 1
    [ -s "$WSTT_CONFIG_DIR/web_cert.pem" ] || return 1
    openssl x509 -noout -checkend "$LE_RENEW_BEFORE_SECONDS" -in "$WSTT_CONFIG_DIR/web_cert.pem" >/dev/null 2>&1
}

disable_letsencrypt_renewal_timer() {
    rm -f -- /etc/cron.d/wstt-letsencrypt
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl disable --now "$WSTT_LE_TIMER" >/dev/null 2>&1 || true
}

install_letsencrypt_certificate() {
    local public_ip="$1" cert_name="$2" source_dir="${3:-}" cert_tmp key_tmp state_tmp
    [ -n "$source_dir" ] || source_dir="${WSTT_LE_CONFIG_DIR}/live/${cert_name}"
    [ -s "$source_dir/fullchain.pem" ] && [ -s "$source_dir/privkey.pem" ] || return 1
    cert_tmp="$(mktemp "${WSTT_CONFIG_DIR}/.web_cert.XXXXXX")" || return 1
    key_tmp="$(mktemp "${WSTT_CONFIG_DIR}/.web_key.XXXXXX")" || {
        rm -f -- "$cert_tmp"
        return 1
    }
    state_tmp="$(mktemp "${WSTT_CONFIG_DIR}/.letsencrypt-ip.XXXXXX")" || {
        rm -f -- "$cert_tmp" "$key_tmp"
        return 1
    }
    if ! install -m 0644 "$source_dir/fullchain.pem" "$cert_tmp" || \
       ! install -m 0600 "$source_dir/privkey.pem" "$key_tmp"; then
        rm -f -- "$cert_tmp" "$key_tmp" "$state_tmp"
        return 1
    fi
    printf 'IP=%s\nCERT_NAME=%s\n' "$public_ip" "$cert_name" > "$state_tmp"
    chmod 0600 "$state_tmp"
    mv -f -- "$cert_tmp" "$WSTT_CONFIG_DIR/web_cert.pem"
    mv -f -- "$key_tmp" "$WSTT_CONFIG_DIR/web_key.pem"
    mv -f -- "$state_tmp" "$WSTT_LE_STATE_FILE"
    secure_persistent_state
}

letsencrypt_certificate_ip() {
    local subject_alt_names
    [ -s "$WSTT_CONFIG_DIR/web_cert.pem" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    subject_alt_names="$(openssl x509 -noout -ext subjectAltName -in "$WSTT_CONFIG_DIR/web_cert.pem" 2>/dev/null || true)"
    printf '%s\n' "$subject_alt_names" | sed -n -E 's/.*(IP Address:|IP:)([0-9.]+).*/\2/p' | head -n 1
}

adopt_letsencrypt_certificate() {
    local public_ip cert_name source_dir issuer
    [ -s "$WSTT_CONFIG_DIR/web_cert.pem" ] || return 1
    [ -s "$WSTT_CONFIG_DIR/web_key.pem" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    issuer="$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$WSTT_CONFIG_DIR/web_cert.pem" 2>/dev/null || true)"
    issuer="${issuer#issuer=}"
    case "$issuer" in
        *"O=Let's Encrypt"*|*ISRG*) ;;
        *) return 1 ;;
    esac
    public_ip="$(letsencrypt_certificate_ip 2>/dev/null || true)"
    is_public_ipv4 "$public_ip" || return 1
    cert_name="$(letsencrypt_cert_name "$public_ip")"
    source_dir="/etc/letsencrypt/live/${cert_name}"
    [ -s "$source_dir/fullchain.pem" ] || return 1
    [ -s "$source_dir/privkey.pem" ] || return 1
    install_letsencrypt_certificate "$public_ip" "$cert_name" "$source_dir"
}

issue_letsencrypt_ip_certificate() {
    local certbot="$1" public_ip="$2" cert_name="$3"
    (
        if ! command -v flock >/dev/null 2>&1; then
            log_warn "flock недоступен; выдача Let’s Encrypt отложена"
            exit 1
        fi
        mkdir -p /run/lock || exit 1
        if ! { exec 9>"$WSTT_LE_HTTP01_LOCK"; } 2>/dev/null; then
            log_warn "Файл блокировки Let’s Encrypt недоступен; выдача сертификата отложена"
            exit 1
        fi
        if ! flock -w 120 9; then
            log_warn "Другой ACME-клиент удерживает HTTP-01 блокировку; выдача сертификата отложена"
            exit 1
        fi
        install -d -m 0700 "$WSTT_LE_CONFIG_DIR" "$WSTT_LE_WORK_DIR" "$WSTT_LE_LOGS_DIR" || {
            log_warn "Не удалось подготовить изолированные каталоги Certbot WSTT"
            exit 1
        }
        if ss -ltnH "sport = :${LE_HTTP_PORT}" 2>/dev/null | grep -q .; then
            log_warn "TCP/${LE_HTTP_PORT} уже занят другим сервисом; Let’s Encrypt IP-сертификат отложен, сохранён self-signed fallback"
            exit 1
        fi
        if ! timeout 90 "$certbot" --config-dir "$WSTT_LE_CONFIG_DIR" --work-dir "$WSTT_LE_WORK_DIR" --logs-dir "$WSTT_LE_LOGS_DIR" certonly --standalone --http-01-port "$LE_HTTP_PORT" \
            --non-interactive --agree-tos --register-unsafely-without-email \
            --preferred-profile shortlived --ip-address "$public_ip" \
            --cert-name "$cert_name" --keep-until-expiring >>"$LOG_FILE" 2>&1; then
            if ! timeout 90 "$certbot" --config-dir "$WSTT_LE_CONFIG_DIR" --work-dir "$WSTT_LE_WORK_DIR" --logs-dir "$WSTT_LE_LOGS_DIR" certonly --standalone --http-01-port "$LE_HTTP_PORT" \
                --non-interactive --agree-tos --register-unsafely-without-email \
                --ip-address "$public_ip" \
                --cert-name "$cert_name" --keep-until-expiring >>"$LOG_FILE" 2>&1; then
                log_warn "Let’s Encrypt не подтвердил IP ${public_ip}; сохранён self-signed fallback, следующая проверка выполнится автоматически"
                exit 1
            fi
        fi
        if ! install_letsencrypt_certificate "$public_ip" "$cert_name"; then
            log_warn "Let’s Encrypt выдал сертификат, но WSTT не смог безопасно активировать его"
            exit 1
        fi
        log_info "Let’s Encrypt IP-сертификат активирован для ${public_ip}"
    )
}

generate_rcgen_fallback_certificate() {
    local cert_tmp key_tmp current_ip="${1:-}" san_ext
    command -v openssl >/dev/null 2>&1 || return 1
    cert_tmp="$(mktemp "${WSTT_CONFIG_DIR}/.web_cert.XXXXXX")" || return 1
    key_tmp="$(mktemp "${WSTT_CONFIG_DIR}/.web_key.XXXXXX")" || { rm -f -- "$cert_tmp"; return 1; }
    san_ext="subjectAltName = DNS:localhost,IP:127.0.0.1"
    if [ -n "$current_ip" ] && is_public_ipv4 "$current_ip"; then
        san_ext="${san_ext},IP:${current_ip}"
    fi
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -subj "/CN=rcgen self signed cert" \
        -addext "$san_ext" \
        -keyout "$key_tmp" -out "$cert_tmp" >/dev/null 2>&1; then
        if ! openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
            -subj "/CN=rcgen self signed cert" \
            -keyout "$key_tmp" -out "$cert_tmp" >/dev/null 2>&1; then
            rm -f -- "$cert_tmp" "$key_tmp"
            return 1
        fi
    fi
    mv -f -- "$cert_tmp" "$WSTT_CONFIG_DIR/web_cert.pem"
    mv -f -- "$key_tmp" "$WSTT_CONFIG_DIR/web_key.pem"
    chmod 644 "$WSTT_CONFIG_DIR/web_cert.pem"
    chmod 600 "$WSTT_CONFIG_DIR/web_key.pem"
    rm -f -- "$WSTT_LE_STATE_FILE"
}

write_letsencrypt_renewal_helper() {
    install -d -m 0755 /usr/local/lib
    cat > "$WSTT_LE_RENEW_HELPER" << 'LEHELPER'
#!/bin/bash
set -Eeuo pipefail

CERTBOT="${WSTT_LE_CERTBOT:-}"
if [ -z "$CERTBOT" ] || ! "$CERTBOT" --version >/dev/null 2>&1; then
    if [ -x /opt/wstt-certbot/bin/certbot ] && /opt/wstt-certbot/bin/certbot --version >/dev/null 2>&1; then
        CERTBOT="/opt/wstt-certbot/bin/certbot"
    elif command -v certbot >/dev/null 2>&1 && certbot --version >/dev/null 2>&1; then
        CERTBOT="$(command -v certbot)"
    fi
fi
CONFIG_DIR="${WSTT_CONFIG_DIR:-/etc/wstt}"
STATE_FILE="${CONFIG_DIR}/letsencrypt-ip.env"
LE_CONFIG_DIR="${CONFIG_DIR}/letsencrypt"
LE_WORK_DIR="/var/lib/wstt/letsencrypt"
LE_LOGS_DIR="/var/log/wstt/letsencrypt"
mkdir -p "$LE_CONFIG_DIR" "$LE_WORK_DIR" "$LE_LOGS_DIR" || exit 1
chmod 0700 "$LE_CONFIG_DIR" "$LE_WORK_DIR" "$LE_LOGS_DIR" || exit 1
CERT_PATH="${CONFIG_DIR}/web_cert.pem"
KEY_PATH="${CONFIG_DIR}/web_key.pem"
RENEW_BEFORE_SECONDS="${WSTT_LE_RENEW_BEFORE_SECONDS:-259200}"
HTTP_PORT="${WSTT_LE_HTTP_PORT:-80}"
HTTP01_LOCK_FILE="/run/lock/acme-http01.lock"
SERVICE_MANAGER="${WSTT_DEPLOY_MODE:-systemd}"

log() {
    logger -t wstt-letsencrypt -- "$*" 2>/dev/null || true
    printf '%s\n' "$*"
}

is_public_ipv4() {
    local ip="$1" first second third fourth value
    case "$ip" in
        *[!0-9.]*|*..*|.*|*.) return 1 ;;
    esac
    IFS=. read -r first second third fourth <<< "$ip"
    for value in "$first" "$second" "$third" "$fourth"; do
        case "$value" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "$value" -le 255 ] || return 1
    done
    [ "$first" -gt 0 ] && [ "$first" -lt 224 ] && [ "$first" -ne 10 ] && [ "$first" -ne 127 ] || return 1
    [ "$first" -ne 169 ] || [ "$second" -ne 254 ] || return 1
    [ "$first" -ne 192 ] || [ "$second" -ne 168 ] || return 1
    [ "$first" -ne 172 ] || [ "$second" -lt 16 ] || [ "$second" -gt 31 ] || return 1
    [ "$first" -ne 100 ] || [ "$second" -lt 64 ] || [ "$second" -gt 127 ] || return 1
    [ "$first" -ne 198 ] || [ "$second" -ne 18 ] || return 1
    [ "$first" -ne 198 ] || [ "$second" -ne 19 ] || return 1
}

public_ipv4() {
    local route_ip
    route_ip="$(ip -4 route get 77.88.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1)"
    if [ -n "$route_ip" ] && is_public_ipv4 "$route_ip"; then
        printf '%s\n' "$route_ip"
        return 0
    fi
    local endpoint value
    for endpoint in https://api.ipify.org https://ipv4.icanhazip.com; do
        value="$(curl -4 -fsS --connect-timeout 3 --max-time 7 "$endpoint" 2>/dev/null || true)"
        value="$(printf '%s' "$value" | tr -d '[:space:]')"
        if is_public_ipv4 "$value"; then
            printf '%s\n' "$value"
            return 0
        fi
    done
    value="$(state_value IP 2>/dev/null || true)"
    if is_public_ipv4 "$value"; then
        printf '%s\n' "$value"
        return 0
    fi
    return 1
}

state_value() {
    local key="$1"
    [ -f "$STATE_FILE" ] || return 1
    sed -n "s/^${key}=//p" "$STATE_FILE" | head -n 1
}

certificate_is_wstt_rcgen() {
    local issuer subject
    [ -s "$CERT_PATH" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    issuer="$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$CERT_PATH" 2>/dev/null || true)"
    subject="$(openssl x509 -noout -subject -nameopt RFC2253 -in "$CERT_PATH" 2>/dev/null || true)"
    issuer="${issuer#issuer=}"
    subject="${subject#subject=}"
    [ "$subject" = "CN=rcgen self signed cert" ] && [ "$issuer" = "$subject" ]
}

certificate_is_wstt_letsencrypt() {
    local saved_ip cert_name issuer subject_alt_names
    [ -s "$CERT_PATH" ] || return 1
    [ -s "$KEY_PATH" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    saved_ip="$(state_value IP 2>/dev/null || true)"
    cert_name="$(state_value CERT_NAME 2>/dev/null || true)"
    if [ -z "$saved_ip" ] || [ -z "$cert_name" ]; then
        saved_ip="$(openssl x509 -noout -ext subjectAltName -in "$CERT_PATH" 2>/dev/null | sed -n -E 's/.*(IP Address:|IP:)([0-9.]+).*/\2/p' | head -n 1)"
        cert_name="wstt-ip-${saved_ip//./-}"
    fi
    is_public_ipv4 "$saved_ip" || return 1
    [ "$cert_name" = "wstt-ip-${saved_ip//./-}" ] || return 1
    issuer="$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$CERT_PATH" 2>/dev/null || true)"
    issuer="${issuer#issuer=}"
    case "$issuer" in
        *"O=Let's Encrypt"*|*ISRG*) ;;
        *) return 1 ;;
    esac
    subject_alt_names="$(openssl x509 -noout -ext subjectAltName -in "$CERT_PATH" 2>/dev/null || true)"
    printf '%s\n' "$subject_alt_names" | grep -Fq "IP Address:${saved_ip}" || printf '%s\n' "$subject_alt_names" | grep -Fq "IP:${saved_ip}"
}

certificate_is_wstt_managed() {
    certificate_is_wstt_rcgen || certificate_is_wstt_letsencrypt
}

needs_renewal() {
    local current_ip="$1" saved_ip
    if certificate_is_wstt_rcgen; then
        return 0
    fi
    saved_ip="$(state_value IP 2>/dev/null || true)"
    [ "$saved_ip" = "$current_ip" ] || return 0
    [ -s "$CERT_PATH" ] || return 0
    openssl x509 -noout -checkend "$RENEW_BEFORE_SECONDS" -in "$CERT_PATH" >/dev/null 2>&1 || return 0
    return 1
}

certificate_is_expired() {
    [ -s "$CERT_PATH" ] || return 0
    command -v openssl >/dev/null 2>&1 || return 1
    ! openssl x509 -noout -checkend 0 -in "$CERT_PATH" >/dev/null 2>&1
}

generate_rcgen_fallback() {
    local current_ip="${1:-}" cert_tmp key_tmp san_ext
    command -v openssl >/dev/null 2>&1 || return 1
    cert_tmp="$(mktemp "${CONFIG_DIR}/.web_cert.XXXXXX")" || return 1
    key_tmp="$(mktemp "${CONFIG_DIR}/.web_key.XXXXXX")" || { rm -f -- "$cert_tmp"; return 1; }
    san_ext="subjectAltName = DNS:localhost,IP:127.0.0.1"
    if [ -n "$current_ip" ] && is_public_ipv4 "$current_ip"; then
        san_ext="${san_ext},IP:${current_ip}"
    fi
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -subj "/CN=rcgen self signed cert" \
        -addext "$san_ext" \
        -keyout "$key_tmp" -out "$cert_tmp" >/dev/null 2>&1; then
        if ! openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
            -subj "/CN=rcgen self signed cert" \
            -keyout "$key_tmp" -out "$cert_tmp" >/dev/null 2>&1; then
            rm -f -- "$cert_tmp" "$key_tmp"
            return 1
        fi
    fi
    mv -f -- "$cert_tmp" "$CERT_PATH"
    mv -f -- "$key_tmp" "$KEY_PATH"
    chmod 644 "$CERT_PATH"
    chmod 600 "$KEY_PATH"
    rm -f -- "$STATE_FILE"
}

fallback_if_expired() {
    local current_ip="${1:-}"
    if certificate_is_expired; then
        log "Let’s Encrypt: текущий сертификат истёк; активируется fallback rcgen сертификат"
        if generate_rcgen_fallback "$current_ip"; then
            reload_wstt_tls
            log "Let’s Encrypt: fallback rcgen сертификат успешно активирован"
        fi
    fi
}

install_certificate() {
    local current_ip="$1" cert_name="$2" source_dir cert_tmp key_tmp state_tmp
    source_dir="${LE_CONFIG_DIR}/live/${cert_name}"
    [ -s "$source_dir/fullchain.pem" ] && [ -s "$source_dir/privkey.pem" ] || return 1
    cert_tmp="$(mktemp "${CONFIG_DIR}/.web_cert.XXXXXX")" || return 1
    key_tmp="$(mktemp "${CONFIG_DIR}/.web_key.XXXXXX")" || { rm -f -- "$cert_tmp"; return 1; }
    state_tmp="$(mktemp "${CONFIG_DIR}/.letsencrypt-ip.XXXXXX")" || { rm -f -- "$cert_tmp" "$key_tmp"; return 1; }
    if ! install -m 0644 "$source_dir/fullchain.pem" "$cert_tmp" || ! install -m 0600 "$source_dir/privkey.pem" "$key_tmp"; then
        rm -f -- "$cert_tmp" "$key_tmp" "$state_tmp"
        return 1
    fi
    printf 'IP=%s\nCERT_NAME=%s\n' "$current_ip" "$cert_name" > "$state_tmp"
    chmod 0600 "$state_tmp"
    mv -f -- "$cert_tmp" "$CERT_PATH"
    mv -f -- "$key_tmp" "$KEY_PATH"
    mv -f -- "$state_tmp" "$STATE_FILE"
    chmod 644 "$CERT_PATH"
    chmod 600 "$KEY_PATH" "$STATE_FILE"
}

reload_wstt_tls() {
    if [ "$SERVICE_MANAGER" = "docker" ]; then
        docker kill --signal USR1 wstt >/dev/null 2>&1 || return 0
    else
        systemctl kill --kill-who=main --signal USR1 wstt >/dev/null 2>&1 || return 0
    fi
}

main() {
    local current_ip cert_name
    if [ -s "$CERT_PATH" ] && ! certificate_is_wstt_managed; then
        log "Let’s Encrypt: обнаружен пользовательский TLS-сертификат; WSTT не изменяет его и отключает собственное продление"
        return 0
    fi
    current_ip="$(public_ipv4 2>/dev/null || true)"
    if [ -z "$CERTBOT" ] || [ ! -x "$CERTBOT" ]; then
        log "Let’s Encrypt: Certbot не найден, обновление отложено"
        fallback_if_expired "$current_ip"
        return 0
    fi
    if [ -z "$current_ip" ]; then
        log "Let’s Encrypt: публичный IPv4 не определён, обновление отложено"
        fallback_if_expired ""
        return 0
    fi
    if ! needs_renewal "$current_ip"; then
        return 0
    fi
    if ! command -v flock >/dev/null 2>&1; then
        log "Let’s Encrypt: flock недоступен, обновление отложено"
        fallback_if_expired "$current_ip"
        return 0
    fi
    if ! mkdir -p /run/lock; then
        log "Let’s Encrypt: каталог блокировок недоступен, обновление отложено"
        fallback_if_expired "$current_ip"
        return 0
    fi
    if ! { exec 9>"$HTTP01_LOCK_FILE"; } 2>/dev/null; then
        log "Let’s Encrypt: файл блокировки недоступен, обновление отложено"
        fallback_if_expired "$current_ip"
        return 0
    fi
    if ! flock -w 120 9; then
        log "Let’s Encrypt: другой ACME-клиент удерживает HTTP-01 блокировку, обновление отложено"
        fallback_if_expired "$current_ip"
        return 0
    fi
    if ss -ltnH "sport = :${HTTP_PORT}" 2>/dev/null | grep -q .; then
        log "Let’s Encrypt: TCP/${HTTP_PORT} занят, обновление отложено"
        fallback_if_expired "$current_ip"
        return 0
    fi
    cert_name="wstt-ip-${current_ip//./-}"
    if ! timeout 90 "$CERTBOT" --config-dir "$LE_CONFIG_DIR" --work-dir "$LE_WORK_DIR" --logs-dir "$LE_LOGS_DIR" certonly --standalone --http-01-port "$HTTP_PORT" --non-interactive --agree-tos --register-unsafely-without-email --preferred-profile shortlived --ip-address "$current_ip" --cert-name "$cert_name" --force-renewal; then
        if ! timeout 90 "$CERTBOT" --config-dir "$LE_CONFIG_DIR" --work-dir "$LE_WORK_DIR" --logs-dir "$LE_LOGS_DIR" certonly --standalone --http-01-port "$HTTP_PORT" --non-interactive --agree-tos --register-unsafely-without-email --ip-address "$current_ip" --cert-name "$cert_name" --force-renewal; then
            log "Let’s Encrypt: перевыпуск IP-сертификата не удался, текущий сертификат сохранён"
            fallback_if_expired "$current_ip"
            return 0
        fi
    fi
    if ! install_certificate "$current_ip" "$cert_name"; then
        log "Let’s Encrypt: не удалось безопасно активировать новый сертификат"
        fallback_if_expired "$current_ip"
        return 0
    fi
    reload_wstt_tls
    log "Let’s Encrypt: IP-сертификат обновлён и TLS-конфигурация WSTT перезагружена"
}

main "$@"
LEHELPER
    chmod 0755 "$WSTT_LE_RENEW_HELPER"
}

install_letsencrypt_renewal_timer() {
    rm -f -- /etc/cron.d/wstt-letsencrypt
    command -v systemctl >/dev/null 2>&1 || {
        log_warn "systemd не найден: автоматическое продление Let’s Encrypt требует systemd"
        return 0
    }
    cat > "/etc/systemd/system/${WSTT_LE_SERVICE}" << LEUNIT
[Unit]
Description=Renew WSTT Let’s Encrypt IP certificate
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=WSTT_DEPLOY_MODE=${DEPLOY_MODE}
Environment=WSTT_LE_CERTBOT=${LE_CERTBOT_COMMAND}
Environment=WSTT_LE_RENEW_BEFORE_SECONDS=${LE_RENEW_BEFORE_SECONDS}
ExecStart=${WSTT_LE_RENEW_HELPER}
LEUNIT
    cat > "/etc/systemd/system/${WSTT_LE_TIMER}" << LETIMER
[Unit]
Description=Check WSTT Let’s Encrypt IP certificate lifetime

[Timer]
OnBootSec=5min
OnUnitInactiveSec=24h
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
LETIMER
    systemctl daemon-reload || {
        log_warn "Не удалось обновить systemd unit для Let’s Encrypt"
        return 0
    }
    systemctl enable --now "$WSTT_LE_TIMER" >/dev/null 2>&1 || \
        log_warn "Не удалось включить автоматическое продление Let’s Encrypt"
}

setup_letsencrypt_ip_tls() {
    local public_ip cert_name
    if ! certificate_is_wstt_letsencrypt && adopt_letsencrypt_certificate; then
        log_info "Let’s Encrypt IP-сертификат WSTT принят под автоматическое продление"
    fi
    if web_certificate_is_user_managed; then
        rm -f -- "$WSTT_LE_STATE_FILE"
        disable_letsencrypt_renewal_timer
        log_info "Используется заранее установленный TLS-сертификат пользователя; WSTT сохраняет его и не заменяет Let’s Encrypt"
        return 0
    fi
    public_ip="$(detect_public_ipv4 2>/dev/null || true)"
    if [ -z "$public_ip" ]; then
        public_ip="$(state_value IP 2>/dev/null || true)"
    fi
    if ! ensure_letsencrypt_client; then
        if [ ! -s "$WSTT_CONFIG_DIR/web_cert.pem" ] || ! openssl x509 -noout -checkend 0 -in "$WSTT_CONFIG_DIR/web_cert.pem" >/dev/null 2>&1; then
            generate_rcgen_fallback_certificate "$public_ip" || true
        fi
        return 0
    fi
    write_letsencrypt_renewal_helper
    if [ -z "$public_ip" ]; then
        log_warn "Публичный IPv4 не определён; WEB-панель временно останется на self-signed TLS"
        if [ ! -s "$WSTT_CONFIG_DIR/web_cert.pem" ] || ! openssl x509 -noout -checkend 0 -in "$WSTT_CONFIG_DIR/web_cert.pem" >/dev/null 2>&1; then
            generate_rcgen_fallback_certificate "" || true
        fi
        install_letsencrypt_renewal_timer
        return 0
    fi
    if letsencrypt_certificate_is_current "$public_ip"; then
        log_info "Let’s Encrypt IP-сертификат действителен; перевыпуск не требуется"
    else
        cert_name="$(letsencrypt_cert_name "$public_ip")"
        if ! issue_letsencrypt_ip_certificate "$LE_CERTBOT_COMMAND" "$public_ip" "$cert_name"; then
            if [ ! -s "$WSTT_CONFIG_DIR/web_cert.pem" ] || ! openssl x509 -noout -checkend 0 -in "$WSTT_CONFIG_DIR/web_cert.pem" >/dev/null 2>&1; then
                generate_rcgen_fallback_certificate "$public_ip" || true
            fi
        fi
    fi
    install_letsencrypt_renewal_timer
}

verify_web_panel() {
    local attempt scheme code
    local probe_file="/tmp/wstt-web-probe.$$"
    local secret_path="${WSTT_WEB_SECRET_PATH:-}"
    if [ -z "$secret_path" ] && [ -f "$WSTT_ENV_FILE" ]; then
        secret_path="$(grep -E '^[[:space:]]*(export[[:space:]]+)?WSTT_WEB_SECRET_PATH=' "$WSTT_ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\"' | tr -d "'\"'" | tr -d '[:space:]' || true)"
    fi
    local probe_path=""
    if [ -n "$secret_path" ]; then
        probe_path="${secret_path#/}"
    fi

    for attempt in $(seq 1 24); do
        for scheme in https http; do
            code="$(curl -k -sS -o "$probe_file" -w "%{http_code}" \
                --connect-timeout 1 --max-time 2 \
                "${scheme}://127.0.0.1:${WEB_PORT}/${probe_path}" 2>>"$LOG_FILE" || true)"
            case "$code" in
                200|301|302|401)
                    rm -f -- "$probe_file"
                    log_info "WEB-панель ответила локальной health-проверке (${scheme}, HTTP ${code})"
                    return 0
                    ;;
            esac
        done
        sleep 0.25
    done
    rm -f -- "$probe_file"
    die "WEB-панель не ответила на локальную health-проверку порта ${WEB_PORT}"
}

ensure_docker() {
    log_step "Проверка Docker Engine..."

    if ! command -v docker >/dev/null 2>&1; then
        pkg_update
        if [ "$PKG_MGR" = "pacman" ]; then
            pkg_install docker || die "Не удалось установить Docker Engine"
        else
            pkg_install ca-certificates curl || die "Не удалось установить curl и ca-certificates для Docker"
            local installer
            installer="$(mktemp)"
            curl -fsSL https://get.docker.com -o "$installer" || die "Не удалось загрузить официальный установщик Docker"
            sh "$installer" >>"$LOG_FILE" 2>&1 || {
                rm -f "$installer"
                die "Не удалось установить Docker Engine"
            }
            rm -f "$installer"
        fi
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker >>"$LOG_FILE" 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        service docker start >>"$LOG_FILE" 2>&1 || true
    fi

    docker --version | tee -a "$LOG_FILE"
    docker info >>"$LOG_FILE" 2>&1 || die "Docker установлен, но демон недоступен; проверьте docker info"
    log_info "Docker Engine готов"
}

ensure_tun_device() {
    if [ -c /dev/net/tun ]; then
        return 0
    fi
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tun >>"$LOG_FILE" 2>&1 || true
    fi
    mkdir -p /dev/net
    [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 >>"$LOG_FILE" 2>&1 || true
    [ -c /dev/net/tun ] || die "Устройство /dev/net/tun недоступно на этом VPS"
}

check_kernel_compatibility() {
    [ "$(uname -s)" = "Linux" ] || die "WSTT Server поддерживает только Linux"
    local release base major minor
    release="$(uname -r)"
    base="${release%%-*}"
    major="${base%%.*}"
    base="${base#*.}"
    minor="${base%%.*}"
    case "$major:$minor" in
        *[!0-9:]*|:*) log_warn "Не удалось разобрать версию ядра $release; решающей будет рабочая проверка TUN" ;;
        *)
            if [ "$major" -lt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -lt 5 ]; }; then
                log_warn "Ядро $release старше проверенного диапазона 5.5–7.x; установка продолжится только при успешных рабочих пробах"
            else
                log_info "Ядро Linux $release входит в поддерживаемый диапазон"
            fi
            ;;
    esac
}

load_kernel_network_modules() {
    command -v modprobe >/dev/null 2>&1 || return 0
    local module
    for module in tun nf_tables ip_tables iptable_filter iptable_nat iptable_mangle nf_nat nf_conntrack xt_comment xt_MASQUERADE xt_TCPMSS; do
        modprobe "$module" >>"$LOG_FILE" 2>&1 || true
    done
}

probe_tun_support() {
    ensure_tun_device
    local probe_iface="wttprobe$(( $$ % 100000 ))"
    ip link del "$probe_iface" >>"$LOG_FILE" 2>&1 || true
    if ! ip tuntap add dev "$probe_iface" mode tun >>"$LOG_FILE" 2>&1; then
        load_kernel_network_modules
        ip link del "$probe_iface" >>"$LOG_FILE" 2>&1 || true
        if ! ip tuntap add dev "$probe_iface" mode tun >>"$LOG_FILE" 2>&1; then
            die "TUN существует, но ядро или политика VPS запрещает TUNSETIFF/CAP_NET_ADMIN"
        fi
    fi
    if ! ip link del "$probe_iface" >>"$LOG_FILE" 2>&1; then
        die "Рабочий TUN создан, но тестовый интерфейс $probe_iface не удалось удалить"
    fi
    log_info "TUN проверен реальным созданием и удалением интерфейса"
}

run_platform_preflight() {
    prog 0.35 "Совместимость ядра..."
    log_step "Проверка совместимости ядра и VPS..."
    check_kernel_compatibility
    probe_tun_support
}

install_docker_boot_prerequisite() {
    command -v systemctl >/dev/null 2>&1 || \
        die "Docker-режим требует systemd для подготовки TUN до автозапуска контейнера"

    ensure_wstt_directory /usr/local/lib/wstt 755
    cat > "$WSTT_DOCKER_PREREQ_HELPER" << 'PREREQ'
#!/bin/sh
set -eu

if [ ! -c /dev/net/tun ]; then
    command -v modprobe >/dev/null 2>&1 && modprobe tun || true
    mkdir -p /dev/net
    [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200
fi

[ -c /dev/net/tun ] || exit 20
mkdir -p /run/wstt
chmod 0755 /run/wstt 2>/dev/null || true
rm -f /run/wstt/docker-network.ready
touch /run/xtables.lock
chmod 600 /run/xtables.lock 2>/dev/null || true
PREREQ
    chmod 0755 "$WSTT_DOCKER_PREREQ_HELPER"

    local unit_tmp
    unit_tmp="$(mktemp)"
    cat > "$unit_tmp" << PREREQUNIT
[Unit]
Description=Prepare WSTT Docker TUN and xtables lock
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${WSTT_DOCKER_PREREQ_HELPER}

[Install]
RequiredBy=docker.service
PREREQUNIT
    install -m 0644 "$unit_tmp" "/etc/systemd/system/${WSTT_DOCKER_PREREQ_SERVICE}"
    rm -f "$unit_tmp"
    systemctl daemon-reload || die "Не удалось обновить systemd для Docker prerequisites"
    systemctl enable "$WSTT_DOCKER_PREREQ_SERVICE" >/dev/null 2>&1 || \
        die "Не удалось включить Docker prerequisites"
    "$WSTT_DOCKER_PREREQ_HELPER" || \
        die "Не удалось обновить Docker runtime prerequisites"
    systemctl start "$WSTT_DOCKER_PREREQ_SERVICE" || \
        die "Не удалось подготовить TUN/xtables lock для Docker"
}

write_wstt_dockerfile() {
    local target="$1"
    cat > "$target" << 'DOCKERFILE'
FROM alpine:3.21
ARG WSTT_BUILD_DNS_PRIMARY
ARG WSTT_BUILD_DNS_SECONDARY
RUN set -eu; if [ -n "${WSTT_BUILD_DNS_PRIMARY:-}" ]; then printf 'nameserver %s\n' "$WSTT_BUILD_DNS_PRIMARY" > /etc/resolv.conf; fi; if [ -n "${WSTT_BUILD_DNS_SECONDARY:-}" ]; then printf 'nameserver %s\n' "$WSTT_BUILD_DNS_SECONDARY" >> /etc/resolv.conf; fi; timeout -k 5s 120s apk add --no-cache --no-progress ca-certificates iproute2 iptables; rm -rf /var/cache/apk/*
COPY wstt /usr/local/bin/wstt
COPY network-up.sh /usr/local/lib/wstt/network-up.sh
COPY tun-recover.sh /usr/local/lib/wstt/tun-recover.sh
RUN chmod 0755 /usr/local/bin/wstt /usr/local/lib/wstt/network-up.sh /usr/local/lib/wstt/tun-recover.sh
ENTRYPOINT ["/bin/sh", "-ec", "/usr/local/lib/wstt/network-up.sh; /usr/local/lib/wstt/tun-recover.sh; exec /usr/local/bin/wstt \"$@\"", "--"]
DOCKERFILE
}

docker_build_candidate_image() {
    local image="$1" context_dir="$2" primary_log fallback_log
    primary_log="$(mktemp)" || return 1
    if timeout -k 15s "${DOCKER_BUILD_TIMEOUT_SECONDS}s" docker build --network host -t "$image" "$context_dir" >"$primary_log" 2>&1; then
        cat "$primary_log" >>"$LOG_FILE"
        rm -f -- "$primary_log"
        return 0
    fi
    cat "$primary_log" >>"$LOG_FILE"
    if ! grep -Eqi 'Temporary failure resolving|Could not resolve|Name or service not known|Connection timed out|Could not connect|Network is unreachable|Failed to fetch|apk|returned a non-zero code: 124' "$primary_log"; then
        rm -f -- "$primary_log"
        return 1
    fi
    rm -f -- "$primary_log"
    log_warn "Docker build не получил DNS через сеть VPS; повтор с резервными DNS Яндекса"
    fallback_log="$(mktemp)" || return 1
    if timeout -k 15s "${DOCKER_BUILD_TIMEOUT_SECONDS}s" docker build --network default \
        --build-arg WSTT_BUILD_DNS_PRIMARY=77.88.8.8 \
        --build-arg WSTT_BUILD_DNS_SECONDARY=77.88.8.1 \
        -t "$image" "$context_dir" >"$fallback_log" 2>&1; then
        cat "$fallback_log" >>"$LOG_FILE"
        rm -f -- "$fallback_log"
        log_info "Docker-образ собран через резервные DNS Яндекса"
        return 0
    fi
    cat "$fallback_log" >>"$LOG_FILE"
    rm -f -- "$fallback_log"
    return 1
}

prepare_docker_candidate() {
    local source_binary="$1" context_dir
    [ -x "$source_binary" ] || \
        die "Docker-образ нельзя собрать без установленного бинарника wstt" "$EXIT_PREFLIGHT_FAILED"
    ensure_tun_device
    DOCKER_CONTEXT_DIR="$(mktemp -d /tmp/wstt-docker.XXXXXX)" || \
        die "Не удалось создать Docker staging context" "$EXIT_PREFLIGHT_FAILED"
    context_dir="$DOCKER_CONTEXT_DIR"
    install -m 0755 "$source_binary" "$context_dir/wstt" || \
        die "Не удалось подготовить Docker-бинарник" "$EXIT_PREFLIGHT_FAILED"
    write_network_helper "$context_dir/network-up.sh" || \
        die "Не удалось подготовить Docker network helper" "$EXIT_PREFLIGHT_FAILED"
    write_tun_recovery_helper "$context_dir/tun-recover.sh" || \
        die "Не удалось подготовить Docker TUN recovery helper" "$EXIT_PREFLIGHT_FAILED"
    write_wstt_dockerfile "$context_dir/Dockerfile"

    WSTT_DOCKER_CANDIDATE_IMAGE="${WSTT_DOCKER_IMAGE}-candidate-$$"
    if ! docker_build_candidate_image "$WSTT_DOCKER_CANDIDATE_IMAGE" "$context_dir"; then
        tail -n 80 "$LOG_FILE" | sed 's/^/   >> /' >&2 || true
        die "Сборка Docker-образа WSTT завершилась ошибкой" "$EXIT_PREFLIGHT_FAILED"
    fi
    probe_docker_runtime "$WSTT_DOCKER_CANDIDATE_IMAGE"
    remove_managed_work_dir "$DOCKER_CONTEXT_DIR" || true
    DOCKER_CONTEXT_DIR=""
    log_info "Docker-образ прошёл проверку: $WSTT_DOCKER_CANDIDATE_IMAGE"
}

setup_wstt_docker() {
    prog 0.75 "Docker-образ..."
    [ -n "$WSTT_DOCKER_CANDIDATE_IMAGE" ] || \
        die "Не найден проверенный Docker-кандидат" "$EXIT_PREFLIGHT_FAILED"
    docker tag "$WSTT_DOCKER_CANDIDATE_IMAGE" "$WSTT_DOCKER_IMAGE" || \
        die "Не удалось активировать проверенный Docker-образ"
    install_docker_boot_prerequisite
    log_info "Проверенный Docker-образ активирован: $WSTT_DOCKER_IMAGE"
}

probe_docker_runtime() {
    local image="${1:-$WSTT_DOCKER_IMAGE}"
    local probe_iface="wttd$(( $$ % 100000 ))" probe_chain="WSTT_D$(( $$ % 1000000 ))" output
    if ! output="$(docker run --rm \
        --network host \
        --cap-drop ALL \
        --cap-add NET_ADMIN \
        --cap-add NET_RAW \
        --device /dev/net/tun:/dev/net/tun \
        --env "PROBE_IFACE=$probe_iface" \
        --env "PROBE_CHAIN=$probe_chain" \
        --entrypoint /bin/sh \
        "$image" -ec '
ip tuntap add dev "$PROBE_IFACE" mode tun
ip link del "$PROBE_IFACE"
for table in filter nat mangle; do
    iptables -w 2 -t "$table" -N "$PROBE_CHAIN"
    iptables -w 2 -t "$table" -X "$PROBE_CHAIN"
done
' 2>&1)"; then
        printf '%s\n' "$output" >>"$LOG_FILE"
        die "Docker не прошёл рабочую проверку TUN или netfilter"
    fi
    printf '%s\n' "$output" >>"$LOG_FILE"
    log_info "Docker runtime проверен: TUN/netfilter"
}

start_wstt_docker() {
    prog 0.90 "Запуск Docker..."
    ensure_tun_device
    remove_all_wstt_docker_containers
    assert_peer_port_is_available
    remove_wstt_tun_interface || die "Не удалось освободить TUN-интерфейс $WSTT_IFACE перед запуском Docker"

    docker run -d \
        --name "$WSTT_DOCKER_CONTAINER" \
        --label com.wstt.managed=true \
        --label com.wstt.component=server \
        --restart unless-stopped \
        --network host \
        --cap-drop ALL \
        --cap-add NET_ADMIN \
        --cap-add NET_RAW \
        --device /dev/net/tun:/dev/net/tun \
        --stop-timeout 5 \
        --ulimit nofile=65535:65535 \
        --env-file "$WSTT_ENV_FILE" \
        --env WSTT_SERVICE_MANAGER=docker \
        --volume "$WSTT_CONFIG_DIR:$WSTT_CONFIG_DIR" \
        --mount "type=bind,src=${WSTT_RUNTIME_DIR},dst=${WSTT_RUNTIME_DIR}" \
        --mount "type=bind,src=/run/xtables.lock,dst=/run/xtables.lock" \
        "$WSTT_DOCKER_IMAGE" \
        --listen "0.0.0.0:${PEER_PORT}" \
        --web-port "$WEB_PORT" \
        --config-dir "$WSTT_CONFIG_DIR" >>"$LOG_FILE" 2>&1 || \
        die "Не удалось создать Docker-контейнер WSTT"

    local state running main_pid restarts candidate_pid=0 candidate_restarts=0 found=0
    local attempts=0
    while [ "$attempts" -lt 48 ]; do
        attempts=$((attempts + 1))
        state="$(docker inspect --format '{{.State.Running}}|{{.State.Pid}}|{{.RestartCount}}' "$WSTT_DOCKER_CONTAINER" 2>/dev/null || echo 'false|0|-1')"
        IFS='|' read -r running main_pid restarts <<< "$state"
        case "$main_pid" in ''|*[!0-9]*) main_pid=0 ;; esac
        case "$restarts" in ''|*[!0-9]*) restarts=-1 ;; esac
        if [ "$running" = "true" ] && [ "$main_pid" -gt 1 ] && ip link show "$WSTT_IFACE" >/dev/null 2>&1; then
            candidate_pid="$main_pid"
            candidate_restarts="$restarts"
            found=1
            break
        fi
        sleep 0.25
    done

    if [ "$found" -ne 1 ]; then
        docker logs --tail 50 "$WSTT_DOCKER_CONTAINER" 2>&1 | sed 's/^/   >> /' || true
        die "Docker WSTT не запустился или TUN $WSTT_IFACE не создан"
    fi

    sleep "$START_STABILITY_SECONDS"
    state="$(docker inspect --format '{{.State.Running}}|{{.State.Pid}}|{{.RestartCount}}' "$WSTT_DOCKER_CONTAINER" 2>/dev/null || echo 'false|0|-1')"
    IFS='|' read -r running main_pid restarts <<< "$state"
    if [ "$running" != "true" ] || [ "$main_pid" != "$candidate_pid" ] || [ "$restarts" != "$candidate_restarts" ] || \
       ! ip link show "$WSTT_IFACE" >/dev/null 2>&1; then
        docker logs --tail 50 "$WSTT_DOCKER_CONTAINER" 2>&1 | sed 's/^/   >> /' || true
        die "Docker WSTT вошёл в crash-loop во время стабильной проверки"
    fi

    verify_configured_network
    verify_web_panel
    finish_deployment
    prog 1.0 "Готово!"
    echo ""
    echo "✓ Деплой успешно завершён"
    echo "CSQTT_DEPLOY_OK"
    echo "   Режим:      Docker"
    echo "   Бинарник:   /usr/local/bin/wstt"
    echo "   Конфиг:     ${WSTT_CONFIG_DIR}"
    echo "   Контейнер:  ${WSTT_DOCKER_CONTAINER}"
    echo "   Образ:      ${WSTT_DOCKER_IMAGE}"
    echo "   PEER:       порт ${PEER_PORT}"
    echo "   SSH:        порт ${SSH_PORT}"
    echo "   WEB:        порт ${WEB_PORT}"
    echo "   PID:        ${candidate_pid}"
    echo "   Логи:       docker logs -f ${WSTT_DOCKER_CONTAINER}"
    echo "   Статус:     docker ps --filter name=${WSTT_DOCKER_CONTAINER}"
    echo ""
}

setup_wstt_service() {
    prog 0.75 "Сервис..."
    echo "🔧 Создание systemd-сервиса WSTT..."

    local unit_tmp
    unit_tmp="$(mktemp)"
    cat > "$unit_tmp" << WSTTSVC
[Unit]
Description=WSTT VPN Server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
EnvironmentFile=-${WSTT_ENV_FILE}
Environment=WSTT_SERVICE_MANAGER=systemd
ExecStartPre=/usr/local/lib/wstt/network-up.sh
ExecStartPre=/usr/local/lib/wstt/tun-recover.sh
ExecStart=/usr/local/bin/wstt --listen 0.0.0.0:${PEER_PORT} --web-port ${WEB_PORT} --config-dir ${WSTT_CONFIG_DIR}
Restart=on-failure
RestartSec=3
KillMode=control-group
TimeoutStartSec=30
TimeoutStopSec=5
Nice=-20

[Install]
WantedBy=multi-user.target
WSTTSVC

    if [ ! -f /etc/systemd/system/wstt.service ] || ! cmp -s "$unit_tmp" /etc/systemd/system/wstt.service; then
        install -m 0644 "$unit_tmp" /etc/systemd/system/wstt.service
        SYSTEMD_NEEDS_RELOAD=1
    fi
    rm -f "$unit_tmp"

    if [ "$SYSTEMD_NEEDS_RELOAD" -eq 1 ]; then
        systemctl daemon-reload || die "systemctl daemon-reload завершился ошибкой"
        SYSTEMD_NEEDS_RELOAD=0
    fi

    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sfn /etc/systemd/system/wstt.service /etc/systemd/system/multi-user.target.wants/wstt.service
    echo "✓ Сервис wstt.service создан и включён"
}

diagnose_systemd_failure() {
    local props result="unknown" exec_code="unknown" exec_status="unknown" restarts="unknown" active="unknown" sub="unknown" pid="0"
    props="$(systemctl show wstt -p Result -p ExecMainCode -p ExecMainStatus -p NRestarts -p ActiveState -p SubState -p MainPID 2>/dev/null || true)"
    while IFS='=' read -r key value; do
        case "$key" in
            Result) result="$value" ;; ExecMainCode) exec_code="$value" ;; ExecMainStatus) exec_status="$value" ;;
            NRestarts) restarts="$value" ;; ActiveState) active="$value" ;; SubState) sub="$value" ;; MainPID) pid="$value" ;;
        esac
    done <<< "$props"
    log_error "systemd: active=$active/$sub result=$result code=$exec_code status=$exec_status restarts=$restarts pid=$pid"
    journalctl -u wstt -b -n 50 --no-pager 2>/dev/null | sed 's/^/   >> /' | tee -a "$LOG_FILE" || true
}

start_wstt() {
    if [ "$DEPLOY_MODE" = "docker" ]; then
        start_wstt_docker
        return
    fi
    prog 0.90 "Запуск..."
    echo "🚀 Запуск WSTT VPN Server..."

    [ -x /usr/local/bin/wstt ] || die "Исполняемый файл /usr/local/bin/wstt не установлен"

    if ! systemctl start wstt; then
        systemctl reset-failed wstt >/dev/null 2>&1 || true
        if ! systemctl start wstt; then
            diagnose_systemd_failure
            die "systemctl start wstt завершился ошибкой"
        fi
    fi

    local props key value active sub main_pid restarts
    local candidate_pid=0 candidate_restarts=0 attempts=0 found=0
    while [ "$attempts" -lt 48 ]; do
        attempts=$((attempts + 1))
        active=""; sub=""; main_pid=0; restarts=0
        props="$(systemctl show wstt -p ActiveState -p SubState -p MainPID -p NRestarts 2>/dev/null || true)"
        while IFS='=' read -r key value; do
            case "$key" in
                ActiveState) active="$value" ;; SubState) sub="$value" ;; MainPID) main_pid="$value" ;; NRestarts) restarts="$value" ;;
            esac
        done <<< "$props"
        case "$main_pid" in ''|*[!0-9]*) main_pid=0 ;; esac
        case "$restarts" in ''|*[!0-9]*) restarts=0 ;; esac

        if [ "$active" = "active" ] && [ "$sub" = "running" ] && [ "$main_pid" -gt 1 ] && \
           kill -0 "$main_pid" 2>/dev/null && ip link show "$WSTT_IFACE" >/dev/null 2>&1; then
            candidate_pid="$main_pid"
            candidate_restarts="$restarts"
            found=1
            break
        fi
        sleep 0.25
    done

    if [ "$found" -ne 1 ]; then
        diagnose_systemd_failure
        die "WSTT не запустился: сервис не running или TUN $WSTT_IFACE не создан"
    fi

    sleep "$START_STABILITY_SECONDS"
    active=""; sub=""; main_pid=0; restarts=0
    props="$(systemctl show wstt -p ActiveState -p SubState -p MainPID -p NRestarts 2>/dev/null || true)"
    while IFS='=' read -r key value; do
        case "$key" in
            ActiveState) active="$value" ;; SubState) sub="$value" ;; MainPID) main_pid="$value" ;; NRestarts) restarts="$value" ;;
        esac
    done <<< "$props"
    case "$main_pid" in ''|*[!0-9]*) main_pid=0 ;; esac
    case "$restarts" in ''|*[!0-9]*) restarts=0 ;; esac

    if [ "$active" != "active" ] || [ "$sub" != "running" ] || [ "$main_pid" != "$candidate_pid" ] || \
       [ "$restarts" != "$candidate_restarts" ] || ! kill -0 "$candidate_pid" 2>/dev/null || \
       ! ip link show "$WSTT_IFACE" >/dev/null 2>&1; then
        diagnose_systemd_failure
        die "WSTT вошёл в crash-loop или потерял TUN во время стабильной проверки"
    fi

    verify_configured_network
    verify_web_panel
    [ "$restarts" -eq 0 ] || log_warn "Во время старта wstt перезапустился $restarts раз(а), затем стабилизировался"
    log_info "WSTT сервер подтверждён: PID $candidate_pid, интерфейс $WSTT_IFACE активен"
    finish_deployment

    prog 1.0 "Готово!"
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "✓ Деплой успешно завершён"
    echo "CSQTT_DEPLOY_OK"
    echo "   Режим: systemd"
    echo "   Бинарник: /usr/local/bin/wstt"
    echo "   Unit: /etc/systemd/system/wstt.service"
    echo "   Конфиг: ${WSTT_CONFIG_DIR}"
    echo "   NAT:  MASQUERADE (восстанавливается после reboot)"
    echo "   PEER: порт ${PEER_PORT}"
    echo "   SSH:  порт ${SSH_PORT}"
    echo "   WEB:  порт ${WEB_PORT}"
    echo "   PID:  ${candidate_pid}"
    echo "   Логи:   journalctl -u wstt -f"
    echo "   Статус: systemctl status wstt"
    echo "══════════════════════════════════════════════════════════════"
    echo ""
}

do_uninstall() {
    log_step "Удаление WSTT..."

    remove_all_wstt_docker_containers
    if command -v docker >/dev/null 2>&1; then
        timeout 5 docker image rm "$WSTT_DOCKER_IMAGE" >/dev/null 2>&1 || true
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$WSTT_LE_TIMER" >/dev/null 2>&1 || true
        timeout 30 systemctl stop "$WSTT_LE_SERVICE" >/dev/null 2>&1 || true
        if systemctl is-active --quiet "$WSTT_LE_SERVICE"; then
            timeout 2 systemctl kill --kill-who=all --signal=SIGKILL "$WSTT_LE_SERVICE" >/dev/null 2>&1 || true
        fi
        if systemctl is-active --quiet "$WSTT_LE_SERVICE"; then
            die "Не удалось остановить службу обновления сертификата WSTT"
        fi
        stop_wstt_docker_prereq
        stop_all_running_wstt_systemd_units
    fi
    force_stop_wstt_processes || die "Не удалось завершить процессы WSTT; удаление отменено"
    cleanup_wstt_policy_routes
    remove_all_wstt_systemd_units
    rm -f "/etc/systemd/system/${WSTT_DOCKER_PREREQ_SERVICE}"
    rm -f "/etc/systemd/system/docker.service.requires/${WSTT_DOCKER_PREREQ_SERVICE}"
    rm -f "/etc/systemd/system/docker.service.wants/${WSTT_DOCKER_PREREQ_SERVICE}"
    rm -f "/etc/systemd/system/${WSTT_LE_SERVICE}" "/etc/systemd/system/${WSTT_LE_TIMER}" /etc/cron.d/wstt-letsencrypt
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true

    cleanup_legacy_proxy_interfaces
    remove_wstt_tun_interface || log_warn "Не удалось удалить TUN-интерфейс $WSTT_IFACE во время uninstall"
    cleanup_wstt_netfilter_rules || true

    rm -f /usr/local/bin/wstt /usr/local/bin/wstt-cascade "$WSTT_LE_RENEW_HELPER"
    rm -rf /run/wstt /usr/local/lib/wstt /var/lib/wstt /opt/wstt-certbot /var/log/wstt/letsencrypt
    secure_persistent_state
    rm -f "$WSTT_SYSCTL_FILE" "$WSTT_UDP_SYSCTL_FILE"
    # Do not reload the entire host sysctl configuration or turn forwarding off:
    # the original CSQTT instance may still depend on the shared forwarding state.

    log_info "WSTT удалён. SQLite state и конфигурация сохранены в ${WSTT_CONFIG_DIR}"
}

do_status() {
    echo "Статус WSTT:"
    echo ""
    if command -v docker >/dev/null 2>&1 && docker inspect "$WSTT_DOCKER_CONTAINER" >/dev/null 2>&1; then
        if [ "$(docker inspect --format '{{.State.Running}}' "$WSTT_DOCKER_CONTAINER" 2>/dev/null)" = "true" ]; then
            log_info "Docker-контейнер: АКТИВЕН"
        else
            log_warn "Docker-контейнер: НЕ АКТИВЕН"
        fi
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active wstt &>/dev/null; then
        log_info "Сервис: АКТИВЕН"
    else
        log_warn "Сервис: НЕ АКТИВЕН"
    fi
    if [ -f /usr/local/bin/wstt ]; then
        log_info "Бинарник: установлен"
    else
        log_warn "Бинарник: НЕ найден"
    fi
    if ip link show "$WSTT_IFACE" &>/dev/null; then
        log_info "WSTT интерфейс ($WSTT_IFACE): активен"
    else
        log_warn "WSTT интерфейс ($WSTT_IFACE): не активен"
    fi
}

handle_unexpected_error() {
    local line="$1" status="$2"
    trap - ERR
    log_error "Неперехваченная ошибка deploy.sh (строка $line, exit=$status)"
    printf 'CSQTT_DEPLOY_ERROR|%s|Неперехваченная ошибка deploy.sh (строка %s, exit=%s)\n' "$DEPLOY_PHASE" "$line" "$status"
    cleanup_deploy_uploads
    case "$DEPLOY_PHASE" in
        validation) exit "$EXIT_INVALID_ARGUMENT" ;;
        preflight) exit "$EXIT_PREFLIGHT_FAILED" ;;
        *) exit "$status" ;;
    esac
}

trap 'handle_unexpected_error "$LINENO" "$?"' ERR

main() {
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║       WSTT VPN Server — Installer v${SCRIPT_VERSION}                    ║"
    echo "║       PEER: ${PEER_PORT}  |  SSH: ${SSH_PORT}  | WEB: ${WEB_PORT}       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"

    local action="${1:-install}"
    check_root
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== WSTT Installer v${SCRIPT_VERSION} — $(date) ===" >> "$LOG_FILE"

    case "$action" in
        status|--status|-s)       do_status ;;
        uninstall|--uninstall|-u)
            DEPLOY_PHASE="validation"
            validate_port "WSTT_PEER_PORT" "$PEER_PORT"
            do_uninstall
            ;;
        install|--install|-i)
            DEPLOY_PHASE="validation"
            case "$DEPLOY_MODE" in
                systemd|docker) ;;
                *) die "WSTT_DEPLOY_MODE должен быть systemd или docker" ;;
            esac
            validate_port "WSTT_PEER_PORT" "$PEER_PORT"
            validate_port "WSTT_SSH_PORT" "$SSH_PORT"
            validate_port "WSTT_WEB_PORT" "$WEB_PORT"
            validate_positive_seconds "WSTT_DOCKER_BUILD_TIMEOUT_SECONDS" "$DOCKER_BUILD_TIMEOUT_SECONDS"
            validate_distinct_network_ports

            local total_started=$SECONDS
            detect_os
            run_timed "зависимости" install_prerequisites
            require_runtime_tools
            if [ "$DEPLOY_MODE" = "docker" ]; then
                prog 0.12 "Docker..."
                run_timed "Docker" ensure_docker
            fi
            run_timed "проверка upload" prepare_uploaded_release
            if [ "$DEPLOY_MODE" = "docker" ]; then
                run_timed "Docker preflight" prepare_docker_candidate "$UPLOAD_BINARY"
            fi
            run_timed "preflight" run_platform_preflight
            assert_wstt_ports_preflight
            DEPLOY_PHASE="cutover"
            run_timed "переключение runtime" wstt_cleanup
            run_timed "sysctl" setup_sysctl
            detect_firewall
            run_timed "NAT/firewall" setup_nat_and_firewall
            install_network_helper
            setup_wstt_environment
            run_timed "Let’s Encrypt" setup_letsencrypt_ip_tls
            DEPLOY_PHASE="activation"
            run_timed "бинарник" setup_wstt_binary
            run_timed "принудительная остановка" force_stop_wstt_processes
            if [ "$DEPLOY_MODE" = "docker" ]; then
                run_timed "Docker activation" setup_wstt_docker
            else
                run_timed "systemd unit" setup_wstt_service
            fi
            run_timed "запуск" start_wstt
            log_info "Общее время deploy.sh: $((SECONDS - total_started))с"
            ;;
        *) die "Неизвестная команда установщика: $action" ;;
    esac
}

main "$@"
