#!/bin/bash

# MIT License
#
# Copyright (c) [2025] [tapelu-io] <quangbq@gmail.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.


set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
PACKAGE_NAME="wine-runner-universal"
VERSION="1.0.1"
ARCH="amd64"
DEB_FILE_OUTPUT_NAME="${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"
PREFIX_DIR_NAME="wine-runner-staging"
BUILD_ROOT="$(cd "$(dirname "$0")" && pwd)/${PREFIX_DIR_NAME}"

BINDIR="${BUILD_ROOT}/usr/bin"
SHAREDIR="${BUILD_ROOT}/usr/share/applications"
ICONDIR="${BUILD_ROOT}/usr/share/icons/hicolor/48x48/apps"
ETCDIR="${BUILD_ROOT}/etc/wine-runner"
DEBIANDIR="${BUILD_ROOT}/DEBIAN"

# Prompt for maintainer
if [ -z "$MAINTAINER" ]; then
    if [ -t 0 ]; then
        read -r -p "Enter maintainer name and email (e.g., Your Name <your.email@example.com>): " MAINTAINER_INPUT
        if [ -z "$MAINTAINER_INPUT" ]; then echo "ERROR: Maintainer is required." >&2; exit 1; fi
        MAINTAINER="$MAINTAINER_INPUT"
    else
        echo "ERROR: MAINTAINER env var not set for non-interactive build." >&2; exit 1;
    fi
else
    echo "INFO: Using maintainer from environment: $MAINTAINER"
fi

APT_LOG_DIR="/tmp"
APT_LOG="${APT_LOG_DIR}/wine-runner-build-$(date +%Y%m%d-%H%M%S).log"
WINEHQ_KEY_URL="https://dl.winehq.org/wine-builds/winehq.key"
DEBIAN_WINEHQ_KEY_PATH="/usr/share/keyrings/winehq-archive.key"
UBUNTU_WINEHQ_KEY_PATH="/usr/share/keyrings/winehq-archive.key"

BUILD_SCRIPT_DEPS="dpkg-dev wget ca-certificates gnupg software-properties-common"
RUNTIME_DEPS_BASE="winehq-stable (>= 8.0) | winehq-devel (>= 8.0) | wine (>= 7.0), \
libvulkan1, mesa-vulkan-drivers | nvidia-driver-XXX, \
steam-installer | steam, \
zram-tools | zram-config, \
cpupowerutils | linux-tools-common, \
winetricks, libnotify-bin, xdg-utils"
RUNTIME_RECOMMENDED="dxvk (>= 2.0)"

_log_msg() { echo "INFO: $1" | tee -a "$APT_LOG"; }
_log_warn() { echo "WARNING: $1" | tee -a "$APT_LOG"; }
_log_err() { echo "ERROR: $1" | tee -a "$APT_LOG" >&2; }

_log_msg "Starting Wine Runner DEB build process (v${VERSION})..."
mkdir -p "$APT_LOG_DIR"
_log_msg "Build logs: $APT_LOG"

if [ "$(id -u)" -ne 0 ]; then
    _log_err "This script requires sudo privileges for initial dependency installation. Run with 'sudo bash $0'."
    exit 1
fi

_log_msg "Updating package lists on build system..."
# MODIFIED: Made apt-get update failure fatal
apt-get update -qq >> "$APT_LOG" 2>&1 || { _log_err "Failed to update package lists on build system. This is critical. Check network and /etc/apt/sources.list. Check $APT_LOG"; exit 1; }

_log_msg "Installing essential build script dependencies: $BUILD_SCRIPT_DEPS"
DEBIAN_FRONTEND=noninteractive apt-get install -y $BUILD_SCRIPT_DEPS >> "$APT_LOG" 2>&1 || { _log_err "Failed to install script dependencies. Check $APT_LOG"; exit 1; }

_log_msg "Cleaning up old build directory: $BUILD_ROOT"
rm -rf "$BUILD_ROOT"
_log_msg "Creating directory structure in $BUILD_ROOT..."
mkdir -p "$BINDIR" "$SHAREDIR" "$ICONDIR" "$ETCDIR" "$DEBIANDIR" || { _log_err "Failed to create staging directories"; exit 1; }

_log_msg "Generating package files..."

cat > "$DEBIANDIR/control" << EOF
Package: ${PACKAGE_NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Depends: ${RUNTIME_DEPS_BASE}
Recommends: ${RUNTIME_RECOMMENDED}
Installed-Size: 150
Section: utils
Priority: optional
Description: Universal Wine Runner for Windows applications on Debian/Ubuntu
 Installs and configures Wine (via WineHQ if possible) for running 32-bit and
 64-bit Windows applications (.exe, .msi) with helper scripts and common tweaks.
 .
 Aims for broad compatibility across recent Debian and Ubuntu releases.
 The pre-installation script attempts to set up WineHQ repositories.
 User-specific Wine environment initialized on first application run.
EOF

cat > "$DEBIANDIR/preinst" << 'EOF'
#!/bin/bash
set -e
echo "wine-runner: Preparing system for Wine..."
OS_ID="unknown"; OS_CODENAME="unknown"
if [ -f /etc/os-release ]; then . /etc/os-release; OS_ID="$ID"; OS_CODENAME="$VERSION_CODENAME"; \
elif type lsb_release >/dev/null 2>&1; then OS_ID=$(lsb_release -si | tr '[:upper:]' '[:lower:]'); OS_CODENAME=$(lsb_release -sc); fi
echo "wine-runner: Detected OS: $OS_ID, Codename: $OS_CODENAME"
if ! dpkg --print-foreign-architectures | grep -q i386; then
    echo "wine-runner: Enabling i386 architecture..."; dpkg --add-architecture i386
    echo "wine-runner: Updating package lists after i386..."; apt-get update -qq || echo "wine-runner: WARNING - apt-get update after i386 add failed."
else echo "wine-runner: i386 architecture already enabled."; fi
echo "wine-runner: Attempting to configure WineHQ repository..."
NEEDS_WINEHQ_SETUP=true
if grep -q "dl.winehq.org" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
    echo "wine-runner: WineHQ repository seems already configured."; NEEDS_WINEHQ_SETUP=false; fi
if $NEEDS_WINEHQ_SETUP; then
    echo "wine-runner: Setting up WineHQ repository..."
    apt-get install -y --no-install-recommends wget ca-certificates gnupg software-properties-common >/dev/null 2>&1 || {
        echo "wine-runner: WARNING - Failed to install packages for WineHQ setup. Wine might not install from WineHQ."
    }
    KEYRING_DIR="/usr/share/keyrings"; WINEHQ_KEYFILE="${KEYRING_DIR}/winehq-archive.key"; mkdir -p "$KEYRING_DIR"
    wget -qO- "https://dl.winehq.org/wine-builds/winehq.key" | gpg --dearmor -o "$WINEHQ_KEYFILE" >/dev/null 2>&1 || {
        echo "wine-runner: WARNING - Failed to download/dearmor WineHQ key."
    }
    SOURCES_LIST_FILE=""; WINEHQ_SUITE=""
    case "$OS_ID" in
        ubuntu) case "$OS_CODENAME" in noble|24.04) WINEHQ_SUITE="noble";; jammy|22.04) WINEHQ_SUITE="jammy";; focal|20.04) WINEHQ_SUITE="focal";; *) echo "wine-runner: WARNING - Unsupported Ubuntu codename '$OS_CODENAME'.";; esac
            if [ -n "$WINEHQ_SUITE" ]; then SOURCES_LIST_FILE="/etc/apt/sources.list.d/winehq-${WINEHQ_SUITE}.sources"
                 echo "Types: deb\nURIs: https://dl.winehq.org/wine-builds/ubuntu/\nSuites: $WINEHQ_SUITE\nComponents: main\nArchitectures: amd64 i386\nSigned-By: $WINEHQ_KEYFILE" > "$SOURCES_LIST_FILE"; fi;;
        debian) case "$OS_CODENAME" in bookworm|12) WINEHQ_SUITE="bookworm";; bullseye|11) WINEHQ_SUITE="bullseye";; buster|10) WINEHQ_SUITE="buster";; *) echo "wine-runner: WARNING - Unsupported Debian codename '$OS_CODENAME'.";; esac
            if [ -n "$WINEHQ_SUITE" ]; then SOURCES_LIST_FILE="/etc/apt/sources.list.d/winehq-${WINEHQ_SUITE}.sources"
                echo "Types: deb\nURIs: https://dl.winehq.org/wine-builds/debian/\nSuites: $WINEHQ_SUITE\nComponents: main\nArchitectures: amd64 i386\nSigned-By: $WINEHQ_KEYFILE" > "$SOURCES_LIST_FILE"; fi;;
        *) echo "wine-runner: OS '$OS_ID' not explicitly supported for auto WineHQ setup.";;
    esac
    if [ -n "$SOURCES_LIST_FILE" ] && [ -f "$SOURCES_LIST_FILE" ]; then
        echo "wine-runner: WineHQ sources file created: $SOURCES_LIST_FILE."
        echo "wine-runner: Updating package lists after WineHQ setup..."; apt-get update -qq || echo "wine-runner: WARNING - apt-get update after WineHQ setup failed."
    elif $NEEDS_WINEHQ_SETUP; then echo "wine-runner: WARNING - Could not determine WineHQ config for $OS_ID $OS_CODENAME."; fi
else echo "wine-runner: Skipping WineHQ setup."; fi
echo "wine-runner: Pre-installation steps complete."
exit 0
EOF

POSTINST_CONTENT=$(cat << EOF
#!/bin/bash
set -e
echo "wine-runner: Finalizing installation of $PACKAGE_NAME v$VERSION..."
if command -v update-desktop-database >/dev/null; then
    update-desktop-database -q || echo "wine-runner: Warning - update-desktop-database failed."
fi
if command -v xdg-mime >/dev/null; then
    xdg-mime default wine-run.desktop application/x-ms-dos-executable application/x-ms-shortcut application/x-msdownload
    xdg-mime default wine-install-run.desktop application/x-msi
fi
if command -v notify-send >/dev/null; then
    if [ -n "\$DISPLAY" ] || [ -n "\$WAYLAND_DISPLAY" ] || pgrep -u "\$(id -u)" gnome-session >/dev/null 2>&1 || pgrep -u "\$(id -u)" plasma_session >/dev/null 2>&1 || pgrep -u "\$(id -u)" xfce4-session >/dev/null 2>&1; then
        notify-send "Wine Runner ($PACKAGE_NAME v$VERSION) Installed" \
        "Double-click .exe/.msi files to run/install Windows apps.
First run initializes user's Wine environment." \
        --icon=wine >/dev/null 2>&1 || echo "wine-runner: Info - Desktop notification attempt made but may have failed (non-critical)."
    else
        echo "wine-runner: Info - No obvious graphical session detected, skipping desktop notification during install."
    fi
else
    echo "wine-runner: Info - notify-send command not found, skipping desktop notification."
fi
echo "----------------------------------------------------------------------"
echo "Wine Runner ($PACKAGE_NAME v$VERSION) successfully installed!"
echo " - Double-click .exe or .msi files."
echo " - First run initializes user Wine environment (typically ~/.wine)."
echo " - Configure via /etc/wine-runner/wine-runner.conf (edit as root)."
echo "Optional tweaks:"
echo "  sudo cpupower frequency-set -g performance"
echo "  sudo systemctl enable --now zram-config (or zramswap.service)"
echo "----------------------------------------------------------------------"
exit 0
EOF
)
echo "$POSTINST_CONTENT" > "$DEBIANDIR/postinst"


cat > "$DEBIANDIR/prerm" << 'EOF'
#!/bin/bash
set -e
echo "wine-runner: Preparing for removal..."
exit 0
EOF

cat > "$DEBIANDIR/postrm" << 'EOF'
#!/bin/bash
set -e
echo "wine-runner: Finalizing removal..."
if [ "$1" = "purge" ]; then
    echo "wine-runner: Purging configuration files..."
    rm -f /etc/wine-runner/wine-runner.conf
fi
if command -v update-desktop-database >/dev/null; then
    update-desktop-database -q || echo "wine-runner: Warning - update-desktop-database during removal failed."
fi
echo "wine-runner removed. User Wine prefixes (~/.wine) are untouched."
exit 0
EOF

cat > "$ETCDIR/wine-runner.conf" << 'EOF'
# Wine Runner Configuration
WR_WINEDEBUG="-all"
WR_WINEPREFIX="~/.wine"
WR_CPU_CORES="0-7"
# WR_CPU_CORES=""
EOF

USER_INIT_FUNCTION_TEMPLATE=$(cat << 'ENDOFSCRIPT_TEMPLATE'
_initialize_wine_runner_user_env() {
    local actual_wineprefix="$1"
    local wine_runner_version="${WINE_RUNNER_VERSION_PLACEHOLDER}"
    local sentinel_file="${actual_wineprefix}/.wine_runner_initialized_v${wine_runner_version}"
    if [ ! -f "$sentinel_file" ]; then
        echo "Wine Runner: First run for v${wine_runner_version} or new prefix (${actual_wineprefix}). Initializing..."
        if command -v notify-send >/dev/null; then
            notify-send "Wine Runner Initializing" "Setting up Wine environment in ${actual_wineprefix} (v${wine_runner_version})... This may take minutes." --icon=wine
        fi
        mkdir -p "${actual_wineprefix}"
        echo "Wine Runner: Setting Windows version to 10..."
        if ! WINEPREFIX="${actual_wineprefix}" winecfg -v win10 >/dev/null 2>&1; then
            echo "Wine Runner: Warning - winecfg failed."
        fi
        echo "Wine Runner: Installing Winetricks (corefonts, vcrun2022)..."
        if command -v winetricks >/dev/null; then
            if ping -c 1 dl.winehq.org > /dev/null 2>&1 || ping -c 1 raw.githubusercontent.com > /dev/null 2>&1 ; then
                if ! WINEPREFIX="${actual_wineprefix}" timeout 600 winetricks -q corefonts vcrun2022; then
                     echo "Wine Runner: Warning - Winetricks components failed. Check logs/internet."
                fi
            else
                echo "Wine Runner: Warning - No internet for Winetricks."
            fi
        else
            echo "Wine Runner: Warning - winetricks not found."
        fi
        echo "Wine Runner: Disabling DXVK HUD..."
        if ! WINEPREFIX="${actual_wineprefix}" wine reg add "HKCU\\Software\\Wine\\DXVK" /v "HUD" /t REG_SZ /d "0" /f >/dev/null 2>&1; then
            WINEPREFIX="${actual_wineprefix}" wine reg add "HKCU\\Software\\Wine\\Direct3D" /v "dxvkHud" /t REG_SZ /d "0" /f >/dev/null 2>&1 || echo "Wine Runner: Warning - Failed to set DXVK HUD registry key."
        fi
        echo "Wine Runner: Initialization complete for ${actual_wineprefix} (v${wine_runner_version})."
        touch "$sentinel_file"
        find "${actual_wineprefix}" -name '.wine_runner_initialized_v*' ! -name ".wine_runner_initialized_v${wine_runner_version}" -delete >/dev/null 2>&1 || true
        if command -v notify-send >/dev/null; then
            notify-send "Wine Runner Initialized" "Wine environment in ${actual_wineprefix} (v${wine_runner_version}) is ready." --icon=wine
        fi
    fi
}
ENDOFSCRIPT_TEMPLATE
)
USER_INIT_FUNCTION="${USER_INIT_FUNCTION_TEMPLATE//\$\{WINE_RUNNER_VERSION_PLACEHOLDER\}/${VERSION}}"

cat > "$BINDIR/wine-run" << EOF
#!/bin/bash
set -e
WR_WINEDEBUG_DEFAULT="-all"; WR_WINEPREFIX_DEFAULT="~/.wine"; WR_CPU_CORES_DEFAULT=""
WR_WINEDEBUG="\${WR_WINEDEBUG_DEFAULT}"; WR_WINEPREFIX="\${WR_WINEPREFIX_DEFAULT}"; WR_CPU_CORES="\${WR_CPU_CORES_DEFAULT}"
if [ -f "/etc/wine-runner/wine-runner.conf" ]; then # shellcheck source=/dev/null
    source "/etc/wine-runner/wine-runner.conf"; fi
if [[ "\${WR_WINEPREFIX}" == "~/"* ]]; then ACTUAL_WINEPREFIX="\${HOME}/\${WR_WINEPREFIX#\~\/}"; \
elif [[ "\${WR_WINEPREFIX}" == "~" ]]; then ACTUAL_WINEPREFIX="\${HOME}"; \
else ACTUAL_WINEPREFIX="\${WR_WINEPREFIX}"; fi
export WINEPREFIX="\${ACTUAL_WINEPREFIX}"; export WINEDEBUG="\${WR_WINEDEBUG}"
${USER_INIT_FUNCTION}
_initialize_wine_runner_user_env "\${ACTUAL_WINEPREFIX}"
CMD_PREFIX=""
if [ -n "\${WR_CPU_CORES}" ] && command -v taskset &> /dev/null; then CMD_PREFIX="taskset -c \${WR_CPU_CORES}"; \
    echo "Wine Runner: Using taskset: \${WR_CPU_CORES}"; \
elif [ -n "\${WR_CPU_CORES}" ]; then echo "Wine Runner: Warning - taskset not found for WR_CPU_CORES."; fi
if [ \$# -eq 0 ]; then echo "Usage: wine-run <file.exe|file.msi> [args...]"; \
    if command -v notify-send >/dev/null; then notify-send -u critical "Wine Runner Error" "No file specified." --icon=dialog-error; fi; exit 1; fi
TARGET_FILE="\$1"; shift; TARGET_EXT="\${TARGET_FILE##*.}"; TARGET_EXT_LOWER="\$(echo "\$TARGET_EXT" | tr '[:upper:]' '[:lower:]')"
if [[ "\$TARGET_EXT_LOWER" == "exe" ]]; then echo "Wine Runner: Running .exe: \$TARGET_FILE"; exec \$CMD_PREFIX wine64 "\$TARGET_FILE" "\$@"; \
elif [[ "\$TARGET_EXT_LOWER" == "msi" ]]; then echo "Wine Runner: Running .msi: \$TARGET_FILE"; exec \$CMD_PREFIX wine64 msiexec /i "\$TARGET_FILE" "\$@"; \
else echo "Wine Runner: Error - Unsupported file: \$TARGET_FILE"; \
    if command -v notify-send >/dev/null; then notify-send -u critical "Wine Runner Error" "Unsupported file: \${TARGET_FILE##*/}" --icon=dialog-error; fi; exit 1; fi
EOF

cat > "$BINDIR/wine-install-run" << EOF
#!/bin/bash
set -e
WR_WINEDEBUG_DEFAULT="-all"; WR_WINEPREFIX_DEFAULT="~/.wine"; WR_CPU_CORES_DEFAULT=""
WR_WINEDEBUG="\${WR_WINEDEBUG_DEFAULT}"; WR_WINEPREFIX="\${WR_WINEPREFIX_DEFAULT}"; WR_CPU_CORES="\${WR_CPU_CORES_DEFAULT}"
if [ -f "/etc/wine-runner/wine-runner.conf" ]; then # shellcheck source=/dev/null
    source "/etc/wine-runner/wine-runner.conf"; fi
if [[ "\${WR_WINEPREFIX}" == "~/"* ]]; then ACTUAL_WINEPREFIX="\${HOME}/\${WR_WINEPREFIX#\~\/}"; \
elif [[ "\${WR_WINEPREFIX}" == "~" ]]; then ACTUAL_WINEPREFIX="\${HOME}"; \
else ACTUAL_WINEPREFIX="\${WR_WINEPREFIX}"; fi
export WINEPREFIX="\${ACTUAL_WINEPREFIX}"; export WINEDEBUG="\${WR_WINEDEBUG}"
${USER_INIT_FUNCTION}
_initialize_wine_runner_user_env "\${ACTUAL_WINEPREFIX}"
CMD_PREFIX=""
if [ -n "\${WR_CPU_CORES}" ] && command -v taskset &> /dev/null; then CMD_PREFIX="taskset -c \${WR_CPU_CORES}"; \
    echo "Wine Runner: Using taskset for installer: \${WR_CPU_CORES}"; \
elif [ -n "\${WR_CPU_CORES}" ]; then echo "Wine Runner: Warning - taskset not found for WR_CPU_CORES."; fi
if [ \$# -eq 0 ]; then echo "Usage: wine-install-run <installer.exe|installer.msi> [args...]"; \
    if command -v notify-send >/dev/null; then notify-send -u critical "Wine Runner Error" "No installer specified." --icon=dialog-error; fi; exit 1; fi
SETUP_FILE="\$1"; shift; INSTALLER_ARGS=("\$@"); INSTALLER_EXIT_CODE=0
SETUP_EXT="\${SETUP_FILE##*.}"; SETUP_EXT_LOWER="\$(echo "\$SETUP_EXT" | tr '[:upper:]' '[:lower:]')"
if [[ "\$SETUP_EXT_LOWER" == "msi" ]]; then echo "Wine Runner: Installing .msi: \$SETUP_FILE"; \
    \$CMD_PREFIX wine64 msiexec /i "\$SETUP_FILE" "\${INSTALLER_ARGS[@]}" || INSTALLER_EXIT_CODE=\$?; \
elif [[ "\$SETUP_EXT_LOWER" == "exe" ]]; then echo "Wine Runner: Installing .exe: \$SETUP_FILE"; \
    \$CMD_PREFIX wine64 "\$SETUP_FILE" "\${INSTALLER_ARGS[@]}" || INSTALLER_EXIT_CODE=\$?; \
else echo "Wine Runner: Error - Unsupported installer: \$SETUP_FILE"; \
    if command -v notify-send >/dev/null; then notify-send -u critical "Wine Runner Error" "Unsupported installer: \${SETUP_FILE##*/}" --icon=dialog-error; fi; exit 1; fi
if [ \$INSTALLER_EXIT_CODE -ne 0 ]; then echo "Wine Runner: Warning - Installer '\${SETUP_FILE##*/}' exit code \${INSTALLER_EXIT_CODE}."; \
    if command -v notify-send >/dev/null; then notify-send "Wine Runner Notice" "Installer for \${SETUP_FILE##*/} exit code \${INSTALLER_EXIT_CODE}." --icon=dialog-warning; fi; fi
echo "Wine Runner: Searching for new executable..."; APP_EXE=\$(find "\${ACTUAL_WINEPREFIX}/drive_c/Program Files" \
    "\${ACTUAL_WINEPREFIX}/drive_c/Program Files (x86)" -path "\${ACTUAL_WINEPREFIX}/drive_c/windows" -prune -o \
    -type f -iname "*.exe" ! -iname "unins*.exe" ! -iname "setup*.exe" -mmin -20 -print0 2>/dev/null | \
    xargs -0 -r stat -c '%Y %n' 2>/dev/null | sort -nr | head -n 1 | sed -e 's/^[^ ]* //')
if [[ -n "\$APP_EXE" ]] && [[ -f "\$APP_EXE" ]]; then echo "Wine Runner: Found: \$APP_EXE"; \
    if command -v notify-send >/dev/null; then notify-send "Wine Runner" "Install of \${SETUP_FILE##*/} complete. Running \${APP_EXE##*/}." --icon=wine; fi; \
    exec \$CMD_PREFIX wine64 "\$APP_EXE"; \
else echo "Wine Runner: Notice - No new main executable auto-detected."; \
    if command -v notify-send >/dev/null; then notify-send "Wine Runner Notice" "Install of \${SETUP_FILE##*/} complete. No main exe auto-detected." --icon=dialog-information; fi; fi
exit 0
EOF

cat > "$SHAREDIR/wine-run.desktop" << 'EOF'
[Desktop Entry]
Name=Run with Wine Runner
Comment=Run Windows Executable or MSI using Wine Runner
Exec=/usr/bin/wine-run %F
Terminal=false;Type=Application;MimeType=application/x-ms-dos-executable;application/x-ms-shortcut;application/x-msdownload;application/x-msi;
NoDisplay=false;StartupNotify=true;Icon=wine;Keywords=windows;exe;msi;run;
Categories=Utility;Emulator;System;
EOF
cat > "$SHAREDIR/wine-install-run.desktop" << 'EOF'
[Desktop Entry]
Name=Install with Wine Runner (and Run)
Comment=Install Windows Application using MSI with Wine Runner, then attempt to run it
Exec=/usr/bin/wine-install-run %F
Terminal=false;Type=Application;MimeType=application/x-msi;
NoDisplay=true;StartupNotify=true;Icon=wine-installer;Keywords=windows;msi;install;
Categories=Utility;Emulator;System;
EOF

_log_msg "Setting permissions..."
chmod 755 "$BINDIR/wine-run" "$BINDIR/wine-install-run"
chmod 755 "$DEBIANDIR/preinst" "$DEBIANDIR/postinst" "$DEBIANDIR/prerm" "$DEBIANDIR/postrm"
chmod 644 "$SHAREDIR"/*.desktop "$ETCDIR"/*.conf

_log_msg "Building .deb package: $DEB_FILE_OUTPUT_NAME"
dpkg-deb --build "$BUILD_ROOT" "$(dirname "$BUILD_ROOT")/${DEB_FILE_OUTPUT_NAME}" >> "$APT_LOG" 2>&1 || { _log_err "Failed to build .deb package. Check $APT_LOG"; exit 1; }

_log_msg "Successfully built $(cd "$(dirname "$BUILD_ROOT")" && pwd)/${DEB_FILE_OUTPUT_NAME}"
_log_msg "Build logs: $APT_LOG"
echo ""; echo "Package built: $(cd "$(dirname "$BUILD_ROOT")" && pwd)/${DEB_FILE_OUTPUT_NAME}"; echo ""
echo "To install: sudo apt install ./$(basename "$BUILD_ROOT")/${DEB_FILE_OUTPUT_NAME}"
echo " (Ensure you are in the directory: $(cd "$(dirname "$BUILD_ROOT")" && pwd) )"
echo "To uninstall: sudo apt remove $PACKAGE_NAME"

exit 0
