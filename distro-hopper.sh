#!/usr/bin/env bash

set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────
CONTAINER_NAME="arch-plasma-2"
CONTAINER_IMAGE="docker.io/library/archlinux:latest"
SESSION_HOME="$HOME/.local/share/ephemeral-sessions/arch-3-plasma"
#you can change the name to fedora or almalinux with this one
# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[ephemeral]${NC} $*"; }
success() { echo -e "${GREEN}[ephemeral]${NC} $*"; }
warn()    { echo -e "${YELLOW}[ephemeral]${NC} $*"; }
error()   { echo -e "${RED}[ephemeral]${NC} $*" >&2; exit 1; }

# ─── Dependency check ─────────────────────────────────────────────────────────
check_deps() {
    command -v distrobox &>/dev/null || error "distrobox not found. Install it globally first."
    command -v podman    &>/dev/null || error "podman not found. Install it globally first."
    command -v startplasma-wayland &>/dev/null || error "startplasma-wayland not found. Install plasma globally first."
    success "Dependencies OK"
}

# ─── Wayland socket ───────────────────────────────────────────────────────────
check_wayland() {
    if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
        warn "WAYLAND_DISPLAY not set, attempting to detect..."
        for sock in "$XDG_RUNTIME_DIR"/wayland-*; do
            if [[ -S "$sock" ]]; then
                export WAYLAND_DISPLAY="$(basename "$sock")"
                success "Found Wayland socket: $WAYLAND_DISPLAY"
                break
            fi
        done
    fi

    [[ -z "${WAYLAND_DISPLAY:-}" ]] && error "No Wayland socket found. Are you running inside Sway?"
    log "Using WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
}

# ─── Session home ─────────────────────────────────────────────────────────────
setup_home() {
    if [[ ! -d "$SESSION_HOME" ]]; then
        log "Creating isolated session home at $SESSION_HOME"
        mkdir -p "$SESSION_HOME"
    else
        log "Using existing session home at $SESSION_HOME"
    fi

    mkdir -p "$SESSION_HOME/.local/bin"
    printf '#!/bin/bash\nexec /usr/bin/sudo "$@"\n' > "$SESSION_HOME/.local/bin/sudo"
    chmod +x "$SESSION_HOME/.local/bin/sudo"
    mkdir -p "$SESSION_HOME/.cache"
}


setup_container() {
    if distrobox list 2>/dev/null | grep -q "$CONTAINER_NAME"; then
        log "Container '$CONTAINER_NAME' already exists, skipping creation"
        return
    fi

    log "Creating container '$CONTAINER_NAME'..."
    distrobox create \
    --name "$CONTAINER_NAME" \
    --image "$CONTAINER_IMAGE" \
    --home "$SESSION_HOME" \
    --no-entry \
    --yes \
    --volume /run/current-system:/run/current-system:ro \
    --volume /etc/fonts:/etc/fonts:ro \
    --volume /etc/dbus-1:/etc/dbus-1:ro \
    --volume /run/opengl-driver:/run/opengl-driver:ro \
    --additional-flags "--device /dev/dri"
}

# ─── Launch ───────────────────────────────────────────────────────────────────
launch_session() {
    log "Launching Fedora KDE Plasma session..."
    log "Home: $SESSION_HOME"
    log "Wayland: $WAYLAND_DISPLAY"
    echo ""

    # Build KDE service database first
    distrobox enter "$CONTAINER_NAME" -- \
        env \
        HOME="$SESSION_HOME" \
        XDG_DATA_DIRS="/usr/share:/usr/local/share:/run/current-system/sw/share:${XDG_DATA_DIRS:-}" \
        /run/current-system/sw/bin/kbuildsycoca6 2>/dev/null || true

    distrobox enter "$CONTAINER_NAME" -- \
        env \
        HOME="$SESSION_HOME" \
        WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        XDG_SESSION_TYPE=wayland \
        QT_QPA_PLATFORM=wayland \
        XDG_DATA_DIRS="/usr/share:/usr/local/share:/run/current-system/sw/share:${XDG_DATA_DIRS:-}" \
        PATH="$SESSION_HOME/.local/bin:/run/current-system/sw/bin:/usr/bin:/usr/sbin:/usr/local/bin:$PATH" \
        SHELL=/bin/bash \
        FONTCONFIG_PATH=/etc/fonts \
        FONTCONFIG_FILE=/etc/fonts/fonts.conf \
        BALOO_ENABLED=0 \
        KDE_BALOO_INDEXING_ENABLED=0 \
        FLATPAK_SESSION_HELPER="" \
        TZ="America/New_York" \
        TZDIR="/etc/zoneinfo" \
        dbus-run-session -- \
        /run/current-system/sw/bin/startplasma-wayland
}
# ─── Reset ────────────────────────────────────────────────────────────────────
reset_session() {
    warn "This will destroy the container and wipe the session home."
    read -rp "Are you sure? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }

    log "Removing container..."
    distrobox rm --force "$CONTAINER_NAME" 2>/dev/null || true

    log "Removing session home..."
    rm -rf "$SESSION_HOME"

    success "Reset complete. Run the script again to start fresh."
}

# ─── Entrypoint ───────────────────────────────────────────────────────────────
case "${1:-}" in
    --reset)  reset_session ;;
    --help|-h)
        echo "Usage: ephemeral-session [--reset | --help]"
        echo ""
        echo "  (no args)  Launch the Fedora KDE Plasma session"
        echo "  --reset    Destroy container and session home, start fresh"
        echo "  --help     Show this help"
        ;;
    *)
        check_deps
        check_wayland
        setup_home
        setup_container
        launch_session
        ;;
esac
