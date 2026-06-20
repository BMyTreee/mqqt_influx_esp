#!/usr/bin/env bash
#
# Bootstrap mqqt_influx_esp on THIS host (run locally on lxn after git clone).
#   1. open local sshd for password access
#   2. install build deps + tmux via apt
#   3. install + start InfluxDB v2 locally, run initial setup (org/bucket/token)
#   4. ensure Rust toolchain
#   5. write .env with InfluxDB + MQTT endpoints
#   6. cargo build --release
#   7. start the binary in a named tmux session
#
set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SESSION_NAME="influx_lxn"
readonly TOKEN_FILE="/root/.influx_lxn_token"

# ── helpers ──────────────────────────────────────────────────────────────────
log() { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[setup:err]\033[0m %s\n' "$*" >&2; exit 1; }

# prompt VAR "label" [silent] — set VAR from user input or keep default
prompt() {
    local var="$1" label="$2" silent="${3:-}"
    local input
    if [[ "$silent" == "silent" ]]; then
        read -rsp "$label [${!var}]: " input || true
        echo
    else
        read -rp "$label [${!var}]: " input || true
    fi
    if [[ -n "$input" ]]; then
        printf -v "$var" '%s' "$input"
    fi
}

# ── runtime prompts (hardcoded default, customize at runtime) ────────────────
INFLUX_HOST="${INFLUX_HOST:-127.0.0.1}"
INFLUX_PORT="${INFLUX_PORT:-8086}"

INFLUX_USER="${INFLUX_USER:-admin}"
prompt INFLUX_USER "InfluxDB admin user"

INFLUX_PASSWORD="${INFLUX_PASSWORD:-lxn_influx_pw}"
prompt INFLUX_PASSWORD "InfluxDB admin password" silent

INFLUX_ORG="${INFLUX_ORG:-lxn}"
prompt INFLUX_ORG "InfluxDB org"

INFLUX_BUCKET="${INFLUX_BUCKET:-listen_lxn}"
prompt INFLUX_BUCKET "InfluxDB bucket"

INFLUX_TOKEN="${INFLUX_TOKEN:-lxn-$(date +%s)-local-token}"
prompt INFLUX_TOKEN "InfluxDB admin token" silent

MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
prompt MQTT_HOST "MQTT host"

MQTT_PORT="${MQTT_PORT:-1883}"
prompt MQTT_PORT "MQTT port"

MQTT_TOPIC="${MQTT_TOPIC:-sensors/+/reading}"
prompt MQTT_TOPIC "MQTT topic"

# ── preflight ────────────────────────────────────────────────────────────────
preflight() {
    [[ -f "${HERE}/Cargo.toml" ]] || die "must run from the mqqt_influx_esp repo root"
    [[ "$(id -u)" -eq 0 ]] || die "must run as root (needs apt + systemctl + sshd)"
    log "dir=${HERE}"
}

# ── open local sshd for password auth (so external clients can access) ───────
open_local_ssh() {
    log "enabling password authentication on local sshd"
    sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
    systemctl restart sshd || systemctl restart ssh
}

# ── install C toolchain + tmux + curl via apt ────────────────────────────────
install_deps() {
    log "installing build-essential, curl, pkg-config, tmux via apt"
    apt-get update
    apt-get install -y build-essential curl pkg-config tmux gnupg wget
}

# ── install + start InfluxDB v2 from official repo ──────────────────────────
install_influx() {
    if command -v influxd >/dev/null 2>&1; then
        log "influxd already installed, skipping"
    else
        log "adding InfluxData apt repo"
        local keyring="/etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg"
        local keyurl="https://repos.influxdata.com/influxdata-archive_compat.key"
        local keysha="393e8779c89ac8d958f81f948f9ad2fb460cb31dc24941548858a7da1b1dbce1"
        wget -qO /tmp/influxdata-archive_compat.key "${keyurl}"
        echo "${keysha}  /tmp/influxdata-archive_compat.key" | sha256sum -c -
        cat /tmp/influxdata-archive_compat.key | gpg --dearmor | tee "${keyring}" >/dev/null
        echo "deb [signed-by=${keyring}] https://repos.influxdata.com/debian stable main" \
            > /etc/apt/sources.list.d/influxdata.list
        apt-get update
        apt-get install -y influxdb2 influxdb2-cli
    fi
    log "enabling + starting influxdb"
    systemctl enable influxdb >/dev/null
    systemctl restart influxdb

    log "waiting for influxdb health endpoint"
    local i
    for ((i = 0; i < 60; i++)); do
        if curl -sf "http://${INFLUX_HOST}:${INFLUX_PORT}/health" >/dev/null; then
            log "influxdb healthy"
            return
        fi
        sleep 1
    done
    die "influxdb did not become healthy"
}

# ── run initial InfluxDB setup once; persist token so re-runs are stable ─────
setup_influx() {
    local allowed
    allowed="$(curl -sf "http://${INFLUX_HOST}:${INFLUX_PORT}/api/v2/setup" | grep -o '"allowed":[a-z]*' | cut -d: -f2)"
    if [[ "${allowed}" == "true" ]]; then
        log "running initial influxdb setup"
        influx setup \
            --host "http://${INFLUX_HOST}:${INFLUX_PORT}" \
            --username "${INFLUX_USER}" \
            --password "${INFLUX_PASSWORD}" \
            --org "${INFLUX_ORG}" \
            --bucket "${INFLUX_BUCKET}" \
            --token "${INFLUX_TOKEN}" \
            --force
        echo -n "${INFLUX_TOKEN}" > "${TOKEN_FILE}"
        chmod 600 "${TOKEN_FILE}"
        log "token saved to ${TOKEN_FILE}"
    else
        log "influxdb already set up"
        if [[ -f "${TOKEN_FILE}" ]]; then
            INFLUX_TOKEN="$(cat "${TOKEN_FILE}")"
            log "reusing token from ${TOKEN_FILE}"
        else
            log "no saved token file — using prompted INFLUX_TOKEN"
        fi
    fi
}

# ── ensure rust ──────────────────────────────────────────────────────────────
ensure_rust() {
    log "ensuring rust toolchain"
    if ! command -v cargo >/dev/null 2>&1; then
        echo "installing rustup + stable toolchain"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    fi
    # persist cargo PATH for tmux + future shells
    grep -q '.cargo/env' "${HOME}/.bashrc" \
        || echo 'source "${HOME}/.cargo/env"' >> "${HOME}/.bashrc"
    # shellcheck disable=SC1090
    source "${HOME}/.cargo/env"
    cargo --version
    rustc --version
}

# ── write local .env ─────────────────────────────────────────────────────────
write_env() {
    log "writing ${HERE}/.env"
    cat > "${HERE}/.env" <<EOF
INFLUX_URL=http://${INFLUX_HOST}:${INFLUX_PORT}
INFLUX_ORG=${INFLUX_ORG}
INFLUX_BUCKET=${INFLUX_BUCKET}
INFLUX_TOKEN=${INFLUX_TOKEN}

MQTT_HOST=${MQTT_HOST}
MQTT_PORT=${MQTT_PORT}
MQTT_TOPIC=${MQTT_TOPIC}
EOF
}

# ── build ────────────────────────────────────────────────────────────────────
build() {
    log "cargo build --release"
    (cd "${HERE}" && cargo build --release)
}

# ── tmux ─────────────────────────────────────────────────────────────────────
start_tmux() {
    log "starting tmux session '${SESSION_NAME}'"
    tmux kill-session -t "${SESSION_NAME}" 2>/dev/null || true
    # interactive shell stays alive even after the binary crashes
    tmux new-session -d -s "${SESSION_NAME}" -c "${HERE}"
    tmux send-keys -t "${SESSION_NAME}" \
        "source \"\${HOME}/.cargo/env\" && set -a && . ./.env && set +a && ./target/release/mqqt_influx_esp" Enter
    tmux list-sessions
}

# ── jump into the running session ────────────────────────────────────────────
jump_to_session() {
    if [[ -n "${TMUX:-}" ]]; then
        exec tmux switch-client -t "${SESSION_NAME}"
    else
        exec tmux attach -t "${SESSION_NAME}"
    fi
}

attach_usage() {
    cat <<EOF

┌─ tmux cheat-sheet (session: ${SESSION_NAME}) ──────────────────────────────┐
│ attach / switch into the session:                                            │
│   tmux attach -t ${SESSION_NAME}            # from a normal shell           │
│   tmux switch-client -t ${SESSION_NAME}     # from inside another tmux      │
│                                                                              │
│ once inside the session, all commands start with the prefix Ctrl+b:          │
│   Ctrl+b  d            detach (leave it running in the background)           │
│   Ctrl+b  s            list/switch between sessions                          │
│   Ctrl+b  ( / )        previous / next session                               │
│   Ctrl+b  c            create a new window inside the session                │
│   Ctrl+b  n / p        next / previous window                                │
│   Ctrl+b  0..9         jump to window N                                      │
│   Ctrl+b  %            split left/right    Ctrl+b " split top/bottom         │
│   Ctrl+b  o            cycle panes         Ctrl+b arrows move between panes  │
│   Ctrl+b  [            enter copy-mode (scroll back, q to exit)              │
│                                                                              │
│ from outside the session:                                                    │
│   tmux ls                                   # list sessions                  │
│   tmux capture-pane -p -t ${SESSION_NAME} -S -50  # tail last 50 lines       │
│   tmux kill-session -t ${SESSION_NAME}      # stop the listener             │
└──────────────────────────────────────────────────────────────────────────────┘
EOF
}

main() {
    preflight
    open_local_ssh
    install_deps
    install_influx
    setup_influx
    ensure_rust
    write_env
    build
    start_tmux
    attach_usage
    log "done."
    jump_to_session
}

main "$@"
