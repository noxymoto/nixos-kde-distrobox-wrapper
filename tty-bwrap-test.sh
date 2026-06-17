#!/usr/bin/env bash
# Launches an isolated KDE Plasma session via pure bubblewrap

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Anti Fork-Bomb Lock ──────────────────────────────────────────────────────
if [[ "${IN_EPHEMERAL_SANDBOX:-0}" == "1" ]]; then
    echo -e "${RED}[ephemeral] Recursion detected! Aborting to prevent infinite KDE loop.${NC}" >&2
    exit 1
fi
export IN_EPHEMERAL_SANDBOX=1

# ─── Config ───────────────────────────────────────────────────────────────────
PERSISTENT_HOME="$HOME/.local/share/ephemeral-sessions/plasma"
EPHEMERAL_HOME="/run/user/$(id -u)/ephemeral-sessions/plasma"
SESSION_HOME="$PERSISTENT_HOME"
EPHEMERAL=false
PLASMA_BIN="/run/current-system/sw/bin/startplasma-wayland"
USERNAME="$(id -un)"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

log()     { echo -e "${BLUE}[ephemeral]${NC} $*"; }
success() { echo -e "${GREEN}[ephemeral]${NC} $*"; }
warn()    { echo -e "${YELLOW}[ephemeral]${NC} $*"; }
error()   { echo -e "${RED}[ephemeral]${NC} $*" >&2; exit 1; }

# ─── Dependency check ─────────────────────────────────────────────────────────
check_deps() {
    command -v bwrap &>/dev/null || error "bwrap (bubblewrap) not found."
    [[ -f "$PLASMA_BIN" ]] || error "startplasma-wayland not found at $PLASMA_BIN."
    success "Dependencies OK"
}

# ─── Environment Detection ────────────────────────────────────────────────────
detect_environment() {
    local current_tty=""
    if [[ -n "${TTY:-}" ]]; then
        current_tty="$TTY"
    elif tty &>/dev/null; then
        current_tty="$(tty)"
    fi
    
    if [[ -z "${DISPLAY:-}" ]] && [[ -n "$current_tty" ]] && [[ "$current_tty" == /dev/tty* ]]; then
        warn "Running in TTY ($current_tty) - Standalone Compositor Mode"
        IN_TTY=true
        CURRENT_TTY="$current_tty"
        unset WAYLAND_DISPLAY
    elif [[ -n "${WAYLAND_DISPLAY:-}" ]] && [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
        IN_TTY=false
        success "Found Wayland socket: $WAYLAND_DISPLAY (Nested Window Mode)"
    else
        warn "No Wayland socket or TTY detected. Assuming Standalone Compositor Mode"
        IN_TTY=true
        CURRENT_TTY=""
        unset WAYLAND_DISPLAY
    fi
}

# ─── Session home ─────────────────────────────────────────────────────────────
setup_home() {
    if [[ "$EPHEMERAL" == true ]]; then
        log "Creating ephemeral RAM home at $SESSION_HOME"
        rm -rf "$SESSION_HOME"
        mkdir -p "$SESSION_HOME"
        trap 'log "Wiping ephemeral home..."; rm -rf "$SESSION_HOME"; success "Ephemeral session ended."' EXIT
    elif [[ ! -d "$SESSION_HOME" ]]; then
        log "Creating persistent session home at $SESSION_HOME"
        mkdir -p "$SESSION_HOME"
    else
        log "Using existing session home at $SESSION_HOME"
    fi

    mkdir -p "$SESSION_HOME/.local/bin"
    printf '#!/bin/bash\nexec /usr/bin/sudo "$@"\n' > "$SESSION_HOME/.local/bin/sudo"
    chmod +x "$SESSION_HOME/.local/bin/sudo"
    mkdir -p "$SESSION_HOME/.cache"

    # FORCE DISABLE KDE SESSION RESTORE
    mkdir -p "$SESSION_HOME/.config"
    cat > "$SESSION_HOME/.config/ksmserverrc" <<EOF
[General]
loginMode=emptySession
EOF
}

# ─── Launch ───────────────────────────────────────────────────────────────────
launch_session() {
    log "Launching KDE Plasma session via pure bwrap..."
    [[ "$EPHEMERAL" == true ]] && warn "Ephemeral mode — nothing will persist"
    echo ""

    local bwrap_args=(
        # Core mappings
        --ro-bind /nix /nix
        --ro-bind /sys /sys
        --dev-bind /dev /dev
        --bind /dev/shm /dev/shm
        --proc /proc
        --tmpfs /tmp
        
        # Keep /run accessible for systemd/dbus
        --bind /run /run
        
        # Read-only access to host configs
        --ro-bind /etc /etc
        
        # Try to bind standard FHS paths for NixOS compatibility
        --ro-bind-try /usr /usr
        --ro-bind-try /bin /bin

        # Home mapping
        --bind "$SESSION_HOME" "/home/$USERNAME"
        
        # Environment
        # bug here-xdg runtime shows up as a folder in RAM session
        --setenv HOME "/home/$USERNAME"
        --setenv XDG_RUNTIME_DIR "$XDG_RUNTIME_DIR"
        --setenv XDG_SESSION_TYPE wayland
        --setenv QT_QPA_PLATFORM wayland
        --setenv QT_WAYLAND_SHELL_INTEGRATION xdg-shell
        --setenv XDG_DATA_DIRS "/run/current-system/sw/share:/usr/share:/usr/local/share"
        --setenv PATH "$SESSION_HOME/.local/bin:/run/current-system/sw/bin:/usr/bin:/usr/sbin:/usr/local/bin:/bin"
        --setenv LD_LIBRARY_PATH "/run/opengl-driver/lib"
        --setenv LIBGL_DRIVERS_PATH "/run/opengl-driver/lib/dri"
        
        # Fixes for sandboxed KDE
        --setenv BALOO_ENABLED 0
        --setenv KDE_BALOO_INDEXING_ENABLED 0
        --setenv FLATPAK_SESSION_HELPER ""
        --setenv KDE_FULL_SESSION true
        --setenv DESKTOP_SESSION plasma
    )

    if [[ "$IN_TTY" == false ]]; then
        # NESTED MODE: Use existing Wayland socket
        log "Setting up nested mode on Wayland socket: $WAYLAND_DISPLAY"
        bwrap_args+=(
            --setenv WAYLAND_DISPLAY "$WAYLAND_DISPLAY"
        )
    else
        # TTY MODE: KWin needs to be the display server
        log "Setting up standalone mode on TTY"
        
        local isolated_runtime="$SESSION_HOME/xdg-runtime"
        mkdir -p "$isolated_runtime"
        chmod 700 "$isolated_runtime"
        
        # Detect available GPU
        local dri_card="/dev/dri/card0"
        if [[ -e /dev/dri/card1 ]]; then
            dri_card="/dev/dri/card1"
        fi
        log "Using GPU: $dri_card"
        
        bwrap_args+=(
            # Give KWin direct access to DRM and input devices
            --dev-bind /dev/dri /dev/dri
            --dev-bind /dev/input /dev/input
            
            # Create isolated runtime dir for Wayland socket
            --dir "$XDG_RUNTIME_DIR"
            --bind "$isolated_runtime" "$XDG_RUNTIME_DIR"
            
            # TTY-specific: KWin will create its own Wayland socket
            --setenv KWIN_DRM_DEVICE "$dri_card"
            --setenv EGL_PLATFORM drm
            --setenv KWIN_OPENGL_INTERFACE egl
            
            # Unset WAYLAND_DISPLAY so KWin creates its own
            --unsetenv WAYLAND_DISPLAY
            
            # Unset any X11 environment
            --unsetenv DISPLAY
	    --unsetenv XAUTHORITY
	    --setenv KWIN_WAYLAND_NO_XWAYLAND 1
	    --setenv KWIN_DRM_USE_LIBSEAT 1
            --setenv LIBSEAT_BACKEND seatd   
	    --bind /run/seatd.sock /run/seatd.sock
	    --setenv PLASMA_USE_SYSTEMD_SCOPE 0
	    --unsetenv DBUS_SESSION_BUS_ADDRESS
        )
    fi

    # Execute with dbus-run-session
    exec bwrap "${bwrap_args[@]}" -- "$(which dbus-run-session)" -- "$PLASMA_BIN" 2>&1 | tee /tmp/eph.log
}

# ─── Reset ────────────────────────────────────────────────────────────────────
reset_session() {
    warn "This will wipe the session home entirely."
    read -rp "Are you sure? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
    log "Removing session home..."
    rm -rf "$PERSISTENT_HOME" "$EPHEMERAL_HOME" 2>/dev/null || true
    success "Reset complete."
}

# ─── Entrypoint ───────────────────────────────────────────────────────────────
case "${1:-}" in
    --reset) reset_session ;;
    --ephemeral) EPHEMERAL=true; SESSION_HOME="$EPHEMERAL_HOME"; check_deps; detect_environment; setup_home; launch_session ;;
    --help|-h)
        echo "Usage: ephemeral-session [--reset | --ephemeral | --help]"
        echo "  (no args)    Launch with persistent home"
        echo "  --ephemeral  Launch with RAM-only home, nothing persists"
        echo "  --reset      Wipe the persistent session home"
        echo ""
        echo "Run from terminal emulator for nested mode, or from a TTY for standalone mode"
        ;;
    *) check_deps; detect_environment; setup_home; launch_session ;;
esac
