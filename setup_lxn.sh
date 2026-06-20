#!/usr/bin/env bash
#
# Bootstrap mqqt_influx_esp on THIS host (run locally on lxn after git clone).
#   1. open local sshd for password access
#   2. install build deps + tmux via apt
#   3. install + start InfluxDB 3 Core locally, create admin token + database
#   4. ensure Rust toolchain
#   5. write .env with InfluxDB + MQTT endpoints
#   6. cargo build --release
#   7. start the binary in a named tmux session
#
set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SESSION_NAME="influx_lxn"
readonly TOKEN_FILE="/root/.influx_lxn_token"
readonly INFLUXDB3_VERSION="3.10.0"

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
prompt INFLUX_HOST "InfluxDB host"

INFLUX_PORT="${INFLUX_PORT:-8181}"
prompt INFLUX_PORT "InfluxDB port"

INFLUX_DATABASE="${INFLUX_DATABASE:-listen_lxn}"
prompt INFLUX_DATABASE "InfluxDB database"

MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
prompt MQTT_HOST "MQTT host"

MQTT_PORT="${MQTT_PORT:-1884}"
prompt MQTT_PORT "MQTT port"

MQTT_TOPIC="${MQTT_TOPIC:-mini_c3/sensor}"
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

# ── install + start InfluxDB 3 Core from official binary ─────────────────────
install_influx() {
    if command -v influxdb3 >/dev/null 2>&1; then
        log "influxdb3 already installed, skipping"
    else
        local artifact
        case "$(uname -m)" in
            x86_64|amd64)   artifact="linux_amd64" ;;
            aarch64|arm64)  artifact="linux_arm64" ;;
            *) die "unsupported architecture for influxdb3: $(uname -m)" ;;
        esac

        local url="https://dl.influxdata.com/influxdb/releases/influxdb3-core-${INFLUXDB3_VERSION}_${artifact}.tar.gz"
        local tmp="/tmp/influxdb3-core.tar.gz"
        log "downloading influxdb3 core ${INFLUXDB3_VERSION} (${artifact})"
        curl -fsSL "${url}"     -o "${tmp}"
        curl -fsSL "${url}.sha256" -o "${tmp}.sha256"

        # supply-chain pin: verify the tarball against the published sha256 sidecar
        local dl_sha ch_sha
        dl_sha="$(cut -d ' ' -f 1 "${tmp}.sha256" | grep -E '^[0-9a-f]{64}$')"
        [[ -n "${dl_sha}" ]] || die "no valid sha256 in ${url}.sha256"
        ch_sha="$(sha256sum "${tmp}" | cut -d ' ' -f 1)"
        [[ "${ch_sha}" = "${dl_sha}" ]] \
            || die "influxdb3 checksum mismatch: ${ch_sha} != ${dl_sha}"

        # tarball layout varies across releases; extract then move the binary
        local xdir="/tmp/influxdb3-extract"
        rm -rf "${xdir}"; mkdir -p "${xdir}"
        tar -xf "${tmp}" -C "${xdir}"
        install -m 0755 "$(find "${xdir}" -name influxdb3 -type f | head -n1)" /usr/local/bin/influxdb3
        rm -rf "${xdir}" "${tmp}" "${tmp}.sha256"
    fi

    log "writing influxdb3 systemd unit"
    mkdir -p /var/lib/influxdb3
    cat > /etc/systemd/system/influxdb3.service <<EOF
[Unit]
Description=InfluxDB 3 Core
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/influxdb3 serve --node-id=node0 --http-bind=0.0.0.0:${INFLUX_PORT} --object-store=file --data-dir=/var/lib/influxdb3
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable influxdb3 >/dev/null
    systemctl restart influxdb3

    log "waiting for influxdb3 health endpoint"
    local i
    for ((i = 0; i < 60; i++)); do
        if curl -sf "http://${INFLUX_HOST}:${INFLUX_PORT}/health" >/dev/null; then
            log "influxdb3 healthy"
            return
        fi
        sleep 1
    done
    die "influxdb3 did not become healthy"
}

# ── create / reuse admin token + database (idempotent) ───────────────────────
setup_influx() {
    if [[ -f "${TOKEN_FILE}" ]]; then
        INFLUX_TOKEN="$(cat "${TOKEN_FILE}")"
        log "reusing influxdb3 token from ${TOKEN_FILE}"
    else
        log "creating influxdb3 admin token"
        local resp code body
        resp="$(curl -s -w '\n%{http_code}' -X POST "http://${INFLUX_HOST}:${INFLUX_PORT}/api/v3/configure/token/admin")"
        code="$(printf '%s' "${resp}" | tail -n1)"
        body="$(printf '%s' "${resp}" | sed '$d')"
        if [[ "${code}" = "409" ]]; then
            die "admin token already exists but ${TOKEN_FILE} is missing — cannot recover token. Reset with 'rm -rf /var/lib/influxdb3' or provide INFLUX_TOKEN."
        fi
        INFLUX_TOKEN="$(printf '%s' "${body}" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)"
        [[ -n "${INFLUX_TOKEN}" ]] || die "could not parse admin token from response: ${body}"
        echo -n "${INFLUX_TOKEN}" > "${TOKEN_FILE}"
        chmod 600 "${TOKEN_FILE}"
        log "admin token saved to ${TOKEN_FILE}"
    fi

    # v3 auto-creates the database on first write; this is best-effort and non-fatal
    log "ensuring database '${INFLUX_DATABASE}'"
    influxdb3 create database "${INFLUX_DATABASE}" \
        --host "http://${INFLUX_HOST}:${INFLUX_PORT}" \
        --token "${INFLUX_TOKEN}" 2>/dev/null \
        || log "database create skipped (already exists or auto-creates on write)"
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
INFLUX_DATABASE=${INFLUX_DATABASE}
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
