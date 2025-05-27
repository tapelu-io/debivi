#!/bin/bash

# MIT License
#
# Copyright (c) 2024 tapelu-io <quangbq@gmail.com>
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
PACKAGE_NAME="wine-runner-suite"
VERSION="1.1.4" # Release Candidate Version
ARCH="amd64"
DEB_FILE_OUTPUT_NAME="${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"
PREFIX_DIR_NAME="wine-runner-staging" # Staging directory for package contents
BUILD_ROOT="$(cd "$(dirname "$0")" && pwd)/${PREFIX_DIR_NAME}" # Absolute path to build staging root

BINDIR="${BUILD_ROOT}/usr/bin"
SHAREDIR="${BUILD_ROOT}/usr/share/applications"
ETCDIR="${BUILD_ROOT}/etc/wine-runner" # Config file directory
DEBIANDIR="${BUILD_ROOT}/DEBIAN"      # Debian control files directory

# Prompt for maintainer if not set via environment variable
if [ -z "$MAINTAINER" ]; then
    if [ -t 0 ]; then # Check if running in a terminal
        read -r -p "Enter maintainer name and email (e.g., Your Name <your.email@example.com>): " MAINTAINER_INPUT
        if [ -z "$MAINTAINER_INPUT" ]; then echo "ERROR: Maintainer information is required." >&2; exit 1; fi
        MAINTAINER="$MAINTAINER_INPUT"
    else
        echo "ERROR: MAINTAINER environment variable is not set for non-interactive build." >&2
        echo "Please set MAINTAINER (e.g., export MAINTAINER='Your Name <your.email@example.com>') or run interactively." >&2
        exit 1
    fi
else
    echo "INFO: Using maintainer from environment: $MAINTAINER"
fi

APT_LOG_DIR="/tmp"
APT_LOG="${APT_LOG_DIR}/${PACKAGE_NAME}-build-$(date +%Y%m%d-%H%M%S).log"
WINEHQ_KEY_URL="https://dl.winehq.org/wine-builds/winehq.key"
WINEHQ_KEY_PATH="/usr/share/keyrings/winehq-archive.key" # Standard path for APT keys

# Dependencies needed by this build script itself
BUILD_SCRIPT_DEPS="dpkg-dev wget ca-certificates gnupg"

# Runtime dependencies for the final .deb package (resolved on the target system)
RUNTIME_DEPS_BASE="winehq-stable (>= 8.0) | winehq-devel (>= 8.0) | wine (>= 7.0), \
libvulkan1, mesa-vulkan-drivers | nvidia-driver-535 | nvidia-driver-545 | nvidia-driver-550 | nvidia-driver-555, \
steam-installer | steam, \
zram-tools | zram-config, \
cpupowerutils | linux-tools-common, \
winetricks, libnotify-bin, xdg-utils, \
zenity | kdialog" # For GUI prompts (desktop shortcut creation)
RUNTIME_RECOMMENDED="dxvk (>= 2.1), icoutils" # icoutils for wrestool (icon extraction)

# --- Helper Functions for Build Script ---
_log_msg() { echo "INFO: $1" | tee -a "$APT_LOG"; }
_log_warn() { echo "WARNING: $1" | tee -a "$APT_LOG"; }
_log_err() { echo "ERROR: $1" | tee -a "$APT_LOG" >&2; }

# --- Build Process Starts ---
_log_msg "Starting ${PACKAGE_NAME} DEB build process (v${VERSION})..."
mkdir -p "$APT_LOG_DIR" # Ensure log directory exists
_log_msg "Build logs will be saved to: $APT_LOG"

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    _log_err "This script requires sudo privileges to install build dependencies. Run with 'sudo bash $0'."
    exit 1
fi

# Update package lists on the build system
_log_msg "Updating package lists on build system..."
apt-get update -qq >> "$APT_LOG" 2>&1 || { _log_err "Failed to update package lists on build system. This is critical. Check network and /etc/apt/sources.list. Log: $APT_LOG"; exit 1; }

# Install dependencies required by this build script
_log_msg "Installing essential build script dependencies: $BUILD_SCRIPT_DEPS"
DEBIAN_FRONTEND=noninteractive apt-get install -y $BUILD_SCRIPT_DEPS >> "$APT_LOG" 2>&1 || { _log_err "Failed to install script dependencies. Log: $APT_LOG and ensure your system's package manager is working."; exit 1; }

# Prepare clean build directory
_log_msg "Cleaning up old build directory: $BUILD_ROOT"
rm -rf "$BUILD_ROOT"
_log_msg "Creating directory structure in $BUILD_ROOT..."
mkdir -p "$BINDIR" "$SHAREDIR" "$ETCDIR" "$DEBIANDIR" || { _log_err "Failed to create staging directories"; exit 1; }

_log_msg "Generating package files..."

# DEBIAN/control file
cat > "$DEBIANDIR/control" << EOF
Package: ${PACKAGE_NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Replaces: wine-runner-universal (<< ${VERSION})
Breaks: wine-runner-universal (<< ${VERSION})
Conflicts: wine-runner-universal
Maintainer: ${MAINTAINER}
Depends: ${RUNTIME_DEPS_BASE}
Recommends: ${RUNTIME_RECOMMENDED}
Installed-Size: 230 # Estimated size in KB, adjust after building
Section: utils
Priority: optional
Description: Advanced Wine Runner Suite for Windows applications on Debian/Ubuntu
 Provides a comprehensive environment for running 32/64-bit Windows applications.
 Features a unified 'wine-runner' command with an '--install' mode for setup and
 subsequent execution. Attempts to install common dependencies like WebView2.
 Offers to create desktop shortcuts for installed applications.
 .
 This package replaces the older 'wine-runner-universal' package.
EOF

# DEBIAN/conffiles - Marks the config file as a conffile
_log_msg "Generating DEBIAN/conffiles..."
echo "/etc/wine-runner/wine-runner.conf" > "$DEBIANDIR/conffiles"


# DEBIAN/preinst script (runs on target system before unpacking)
cat > "$DEBIANDIR/preinst" << 'EOF'
#!/bin/bash
set -e
echo "wine-runner-suite: Preparing system for Wine..."
OS_ID="unknown"; OS_CODENAME="unknown"
if [ -f /etc/os-release ]; then 
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="$ID"; OS_CODENAME="$VERSION_CODENAME"
elif type lsb_release >/dev/null 2>&1; then 
    OS_ID=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
    OS_CODENAME=$(lsb_release -sc)
fi
echo "wine-runner-suite: Detected OS: $OS_ID, Codename: $OS_CODENAME"

if ! dpkg --print-foreign-architectures | grep -q i386; then
    echo "wine-runner-suite: Enabling i386 architecture..."
    dpkg --add-architecture i386
    echo "wine-runner-suite: Updating package lists after i386 add..."
    apt-get update -qq || echo "wine-runner-suite: WARNING - apt-get update after i386 add failed. Continuing..."
else 
    echo "wine-runner-suite: i386 architecture already enabled."
fi

echo "wine-runner-suite: Attempting to configure WineHQ repository..."
NEEDS_WINEHQ_SETUP=true
KEYRING_DIR_PREINST="/usr/share/keyrings"
WINEHQ_KEYFILE_PREINST="${KEYRING_DIR_PREINST}/winehq-archive.key"

if [ -f "$WINEHQ_KEYFILE_PREINST" ]; then
    DEB_REPO_TYPE=""
    if [ "$OS_ID" = "ubuntu" ]; then DEB_REPO_TYPE="ubuntu"; elif [ "$OS_ID" = "debian" ]; then DEB_REPO_TYPE="debian"; fi
    if [ -n "$DEB_REPO_TYPE" ]; then
        POTENTIAL_SOURCES_FILE="/etc/apt/sources.list.d/winehq-${OS_CODENAME}.sources" # Check against the specific codename
        if [ -f "$POTENTIAL_SOURCES_FILE" ] && \
           grep -q "URIs: https://dl.winehq.org/wine-builds/${DEB_REPO_TYPE}/" "$POTENTIAL_SOURCES_FILE" && \
           grep -q "Suites: $OS_CODENAME" "$POTENTIAL_SOURCES_FILE" && \
           grep -q "Signed-By: $WINEHQ_KEYFILE_PREINST" "$POTENTIAL_SOURCES_FILE"; then
            echo "wine-runner-suite: WineHQ $DEB_REPO_TYPE .sources file for $OS_CODENAME seems correctly configured."
            NEEDS_WINEHQ_SETUP=false
        elif grep -q "dl.winehq.org/wine-builds/${DEB_REPO_TYPE}/.*$OS_CODENAME" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
             # Fallback check for older .list file format if .sources not found or not matching
            echo "wine-runner-suite: WineHQ $DEB_REPO_TYPE repository for $OS_CODENAME seems present in .list files."
            NEEDS_WINEHQ_SETUP=false
        fi
    fi
fi

if $NEEDS_WINEHQ_SETUP; then
    echo "wine-runner-suite: Setting up WineHQ repository for $OS_ID $OS_CODENAME..."
    apt-get install -y --no-install-recommends -qq wget ca-certificates gnupg >/dev/null 2>&1 || \
        echo "wine-runner-suite: WARNING - Failed to install prerequisite packages (wget, gnupg, ca-certificates) for WineHQ setup."
    
    mkdir -p "$KEYRING_DIR_PREINST"
    echo "wine-runner-suite: Downloading WineHQ GPG key to $WINEHQ_KEYFILE_PREINST..."
    if ! wget -qO- "https://dl.winehq.org/wine-builds/winehq.key" | gpg --dearmor -o "$WINEHQ_KEYFILE_PREINST"; then
        echo "wine-runner-suite: WARNING - Failed to download or dearmor WineHQ GPG key."
    else 
        chmod 0644 "$WINEHQ_KEYFILE_PREINST"
    fi

    SOURCES_LIST_FILE_PREINST=""; WINEHQ_SUITE_PREINST=""; REPO_URI_BASE=""
    case "$OS_ID" in
        ubuntu)
            REPO_URI_BASE="https://dl.winehq.org/wine-builds/ubuntu/"
            case "$OS_CODENAME" in 
                noble|jammy|focal) WINEHQ_SUITE_PREINST="$OS_CODENAME";; 
                *) echo "wine-runner-suite: WARNING - Unsupported Ubuntu codename '$OS_CODENAME' for automatic WineHQ setup.";; 
            esac
            ;;
        debian)
            REPO_URI_BASE="https://dl.winehq.org/wine-builds/debian/"
            case "$OS_CODENAME" in 
                bookworm|bullseye|buster) WINEHQ_SUITE_PREINST="$OS_CODENAME";; 
                *) echo "wine-runner-suite: WARNING - Unsupported Debian codename '$OS_CODENAME' for automatic WineHQ setup.";; 
            esac
            ;;
        *)
            echo "wine-runner-suite: OS '$OS_ID' not explicitly supported for automatic WineHQ setup."
            ;;
    esac

    if [ -n "$WINEHQ_SUITE_PREINST" ] && [ -n "$REPO_URI_BASE" ]; then
        # Prefer .sources format
        SOURCES_LIST_FILE_PREINST="/etc/apt/sources.list.d/winehq-${WINEHQ_SUITE_PREINST}.sources"
        echo -e "Types: deb\nURIs: $REPO_URI_BASE\nSuites: $WINEHQ_SUITE_PREINST\nComponents: main\nArchitectures: amd64 i386\nSigned-By: $WINEHQ_KEYFILE_PREINST" > "$SOURCES_LIST_FILE_PREINST"
        
        if [ -f "$SOURCES_LIST_FILE_PREINST" ]; then
            echo "wine-runner-suite: WineHQ sources file created/updated: $SOURCES_LIST_FILE_PREINST."
            echo "wine-runner-suite: Updating package lists after WineHQ setup..."
            apt-get update -qq || echo "wine-runner-suite: WARNING - apt-get update after WineHQ setup failed."
        else 
             echo "wine-runner-suite: WARNING - Failed to write WineHQ sources file $SOURCES_LIST_FILE_PREINST."
        fi
    elif $NEEDS_WINEHQ_SETUP; then 
        echo "wine-runner-suite: WARNING - Could not determine appropriate WineHQ configuration for $OS_ID $OS_CODENAME."
    fi
else
    echo "wine-runner-suite: Skipping dynamic WineHQ setup as it seems adequately configured or not applicable."
fi

echo "wine-runner-suite: Pre-installation steps complete."
exit 0
EOF

# DEBIAN/postinst script
POSTINST_CONTENT=$(cat << EOF
#!/bin/bash
set -e
echo "wine-runner-suite: Finalizing installation of $PACKAGE_NAME v$VERSION..."
if command -v update-desktop-database >/dev/null; then
    update-desktop-database -q || echo "wine-runner-suite: Warning - update-desktop-database failed."
fi
if command -v xdg-mime >/dev/null; then
    xdg-mime default wine-runner-generic.desktop application/x-ms-dos-executable application/x-ms-shortcut application/x-msdownload
    xdg-mime default wine-runner-installer.desktop application/x-msi
fi
if command -v notify-send >/dev/null; then
    if [ -n "\${XDG_CURRENT_DESKTOP:-}" ] || [ -n "\${DISPLAY:-}" ] || [ -n "\${WAYLAND_DISPLAY:-}" ] || \
       pgrep -u "\$(id -u)" -f "gnome-session|startkde|plasma_session|xfce4-session|lxsession|mate-session|cinnamon-session" >/dev/null 2>&1; then
        notify-send "Wine Runner Suite ($PACKAGE_NAME v$VERSION) Installed" \
        "Use 'wine-runner' command or double-click Windows files.
First run initializes user's Wine environment." \
        --icon=wine >/dev/null 2>&1 || echo "wine-runner-suite: Info - Desktop notification attempt failed (non-critical)."
    else echo "wine-runner-suite: Info - No graphical session detected, skipping desktop notification."; fi
else echo "wine-runner-suite: Info - notify-send not found, skipping desktop notification."; fi
echo "----------------------------------------------------------------------"
echo "Wine Runner Suite ($PACKAGE_NAME v$VERSION) successfully installed!"
echo " - Use 'wine-runner <file.exe>' or 'wine-runner --install <setup.exe|setup.msi>'"
echo " - Or double-click .exe/.msi files."
echo " - First run initializes user Wine environment (typically ~/.wine)."
echo " - Configure via /etc/wine-runner/wine-runner.conf (edit as root)."
echo "----------------------------------------------------------------------"
exit 0
EOF
)
echo "$POSTINST_CONTENT" > "$DEBIANDIR/postinst"

# DEBIAN/prerm script
cat > "$DEBIANDIR/prerm" << 'EOF'
#!/bin/bash
set -e
echo "wine-runner-suite: Preparing for removal..."
exit 0
EOF

# DEBIAN/postrm script
cat > "$DEBIANDIR/postrm" << 'EOF'
#!/bin/bash
set -e
echo "wine-runner-suite: Finalizing removal..."
if [ "$1" = "purge" ]; then
    echo "wine-runner-suite: Purging configuration files..."
    rm -f /etc/wine-runner/wine-runner.conf
fi
if command -v update-desktop-database >/dev/null; then
    update-desktop-database -q || echo "wine-runner-suite: Warning - update-desktop-database during removal failed."
fi
echo "wine-runner-suite removed. User Wine prefixes (~/.wine) are untouched."
exit 0
EOF

# /etc/wine-runner/wine-runner.conf
cat > "$ETCDIR/wine-runner.conf" << 'EOF'
# Wine Runner Suite Configuration
WR_WINEDEBUG="-all"
WR_WINEPREFIX="~/.wine"
WR_CPU_CORES="0-7"
# WR_CPU_CORES="" 
WR_EXTRA_WINETRICKS_VERBS=""
# Example: WR_EXTRA_WINETRICKS_VERBS="dxvk,d3dcompiler_47,dotnet48"
EOF

# User Init Function
USER_INIT_FUNCTION_TEMPLATE=$(cat << 'ENDOFSCRIPT_TEMPLATE'
_initialize_wine_runner_user_env() {
    local actual_wineprefix="$1"
    local wine_runner_version="${WINE_RUNNER_VERSION_PLACEHOLDER}" 
    local sentinel_file="${actual_wineprefix}/.wine_runner_suite_initialized_v${wine_runner_version}"
    if [ ! -f "$sentinel_file" ]; then
        echo "Wine Runner Suite: First run for v${wine_runner_version} or new prefix ('${actual_wineprefix}'). Initializing..."
        if command -v notify-send >/dev/null; then
            notify-send "Wine Runner Suite Initializing" \
            "Setting up Wine environment in '${actual_wineprefix}' (v${wine_runner_version})... This may take several minutes." \
            --icon=wine ; fi
        mkdir -p "${actual_wineprefix}"
        echo "Wine Runner Suite: Setting Windows version to 10 in '${actual_wineprefix}'..."
        if ! WINEPREFIX="${actual_wineprefix}" winecfg -v win10 >/dev/null 2>&1; then
            echo "Wine Runner Suite: Warning - winecfg command failed."; fi
        local winetricks_verbs_to_install="corefonts vcrun2022 webview2"
        # Use :- default to prevent error if WR_EXTRA_WINETRICKS_VERBS is unbound and set -u is active
        if [ -n "${WR_EXTRA_WINETRICKS_VERBS:-}" ]; then 
            local extra_verbs; extra_verbs=$(echo "${WR_EXTRA_WINETRICKS_VERBS}" | tr ',' ' ')
            winetricks_verbs_to_install="${winetricks_verbs_to_install} ${extra_verbs}"; fi
        echo "Wine Runner Suite: Installing Winetricks components (${winetricks_verbs_to_install}) in '${actual_wineprefix}'..."
        if command -v winetricks >/dev/null; then
            if ping -c 1 dl.winehq.org > /dev/null 2>&1 || ping -c 1 raw.githubusercontent.com > /dev/null 2>&1 || ping -c 1 google.com >/dev/null 2>&1; then
                echo "Wine Runner Suite: Winetricks command: WINEPREFIX=\"${actual_wineprefix}\" timeout 1200 winetricks -q ${winetricks_verbs_to_install}"
                # shellcheck disable=SC2086 # We want word splitting for $winetricks_verbs_to_install
                if ! WINEPREFIX="${actual_wineprefix}" timeout 1200 winetricks -q ${winetricks_verbs_to_install}; then
                     echo "Wine Runner Suite: Warning - Winetricks components failed. Check Winetricks logs or internet connection.";fi
            else echo "Wine Runner Suite: Warning - No internet detected; skipping Winetricks components installation.";fi
        else echo "Wine Runner Suite: Warning - winetricks command not found. Cannot install Winetricks components.";fi
        echo "Wine Runner Suite: Disabling DXVK HUD by default in '${actual_wineprefix}'..."
        if ! WINEPREFIX="${actual_wineprefix}" wine reg add "HKCU\\Software\\Wine\\DXVK" /v "HUD" /t REG_SZ /d "0" /f >/dev/null 2>&1; then
            WINEPREFIX="${actual_wineprefix}" wine reg add "HKCU\\Software\\Wine\\Direct3D" /v "dxvkHud" /t REG_SZ /d "0" /f >/dev/null 2>&1 || \
            echo "Wine Runner Suite: Warning - Failed to set DXVK HUD registry key.";fi
        echo "Wine Runner Suite: Initialization complete for '${actual_wineprefix}' (v${wine_runner_version})."
        touch "$sentinel_file"
        find "${actual_wineprefix}" -maxdepth 1 -name '.wine_runner_suite_initialized_v*' ! -name "$(basename "$sentinel_file")" -delete >/dev/null 2>&1 || true
        if command -v notify-send >/dev/null; then
            notify-send "Wine Runner Suite Initialized" \
            "Wine environment in '${actual_wineprefix}' (v${wine_runner_version}) is ready." --icon=wine;fi
    fi
}
ENDOFSCRIPT_TEMPLATE
)
USER_INIT_FUNCTION="${USER_INIT_FUNCTION_TEMPLATE//\$\{WINE_RUNNER_VERSION_PLACEHOLDER\}/${VERSION}}"

# Combined /usr/bin/wine-runner script
cat > "$BINDIR/wine-runner" << EOF
#!/bin/bash
set -e; set -u; set -o pipefail

# Default configuration values
WR_WINEDEBUG_DEFAULT="-all"
WR_WINEPREFIX_DEFAULT="~/.wine"
WR_CPU_CORES_DEFAULT="" 
WR_EXTRA_WINETRICKS_VERBS_DEFAULT="" 

# Initialize from defaults (will be overridden by sourced config if variables are set there)
WR_WINEDEBUG="\${WR_WINEDEBUG_DEFAULT}"
WR_WINEPREFIX="\${WR_WINEPREFIX_DEFAULT}"
WR_CPU_CORES="\${WR_CPU_CORES_DEFAULT}"
WR_EXTRA_WINETRICKS_VERBS="\${WR_EXTRA_WINETRICKS_VERBS_DEFAULT}"

if [ -f "/etc/wine-runner/wine-runner.conf" ]; then 
    # shellcheck source=/dev/null
    source "/etc/wine-runner/wine-runner.conf"; 
fi

# Expand tilde in WINEPREFIX
if [[ "\${WR_WINEPREFIX}" == "~/"* ]]; then ACTUAL_WINEPREFIX="\${HOME}/\${WR_WINEPREFIX#\~\/}"; \
elif [[ "\${WR_WINEPREFIX}" == "~" ]]; then ACTUAL_WINEPREFIX="\${HOME}"; \
else ACTUAL_WINEPREFIX="\${WR_WINEPREFIX}"; fi
export WINEPREFIX="\${ACTUAL_WINEPREFIX}"; export WINEDEBUG="\${WR_WINEDEBUG}"

${USER_INIT_FUNCTION} # Embed the User Init Function here

_initialize_wine_runner_user_env "\${ACTUAL_WINEPREFIX}"

CMD_PREFIX=""
# Use :- default for WR_CPU_CORES to avoid unbound variable error with set -u if not in config
if [ -n "\${WR_CPU_CORES:-}" ] && command -v taskset &> /dev/null; then 
    CMD_PREFIX="taskset -c \${WR_CPU_CORES}"; \
    echo "Wine Runner Suite: Using taskset with cores: \${WR_CPU_CORES}"; \
elif [ -n "\${WR_CPU_CORES:-}" ]; then 
    echo "Wine Runner Suite: Warning - WR_CPU_CORES ('\${WR_CPU_CORES}') is set but 'taskset' command not found."; 
fi

INSTALL_MODE=0; TARGET_FILE=""; APP_ARGS=() # Initialize APP_ARGS as an array
while [[ \$# -gt 0 ]]; do 
    key="\$1"
    case \$key in
        -i|--install) INSTALL_MODE=1; shift;;
        -h|--help)
            echo -e "Usage: wine-runner [-i|--install] <file.exe|file.msi> [arguments...]\n"
            echo -e "Options:\n  -i, --install  Run as installer, then find app & offer shortcut.\n  -h, --help     Show this help message."
            exit 0;;
        --) # End of options marker
            shift # Remove the --
            if [ \$# -gt 0 ]; then # If there's at least one arg after --
                TARGET_FILE="\$1"; shift # It's the target file
                APP_ARGS+=("\$@") # All the rest are app args
            fi
            break ;;
        -*) # Unknown option
            echo "Error: Unknown option: \$1" >&2
            echo "Run 'wine-runner --help' for usage." >&2
            exit 1;;
        *)  # Default case: argument
            if [ -z "\$TARGET_FILE" ]; then
                TARGET_FILE="\$1"
            else
                APP_ARGS+=("\$1") # Add to app arguments array
            fi
            shift;;
    esac
done

if [ -z "\$TARGET_FILE" ]; then
    echo "Usage: wine-runner [-i|--install] <file.exe|file.msi> [arguments...]" >&2
    echo "Run 'wine-runner --help' for more information." >&2
    if command -v notify-send >/dev/null; then notify-send -u critical "Wine Runner Suite Error" "No file specified for wine-runner." --icon=dialog-error; fi
    exit 2 
fi

TARGET_EXT="\${TARGET_FILE##*.}"; TARGET_EXT_LOWER="\$(echo "\$TARGET_EXT" | tr '[:upper:]' '[:lower:]')"

if [ \$INSTALL_MODE -eq 1 ]; then # INSTALL MODE (--install flag was used)
    INSTALLER_EXIT_CODE=0
    echo "Wine Runner Suite: Install mode activated for '\$TARGET_FILE'"
    if [[ "\$TARGET_EXT_LOWER" == "msi" ]]; then
        echo "Wine Runner Suite: Installing .msi: '\$TARGET_FILE' with args: \${APP_ARGS[*]}"
        # shellcheck disable=SC2086 # CMD_PREFIX is single token, APP_ARGS is array
        \$CMD_PREFIX wine64 msiexec /i "\$TARGET_FILE" "\${APP_ARGS[@]}" || INSTALLER_EXIT_CODE=\$?
    elif [[ "\$TARGET_EXT_LOWER" == "exe" ]]; then
        echo "Wine Runner Suite: Running .exe installer: '\$TARGET_FILE' with args: \${APP_ARGS[*]}"
        # shellcheck disable=SC2086
        \$CMD_PREFIX wine64 "\$TARGET_FILE" "\${APP_ARGS[@]}" || INSTALLER_EXIT_CODE=\$?
    else 
        echo "Error: Unsupported installer type for --install mode: '\$TARGET_FILE'" >&2; 
        if command -v notify-send >/dev/null; then notify-send -u critical "Wine Runner Suite Error" "Unsupported installer: \${TARGET_FILE##*/}" --icon=dialog-error; fi
        exit 3; 
    fi

    if [ \$INSTALLER_EXIT_CODE -ne 0 ]; then
        echo "Wine Runner Suite: Warning - Installer '\${TARGET_FILE##*/}' exited with code \${INSTALLER_EXIT_CODE}."
        if command -v notify-send >/dev/null; then notify-send "Wine Runner Suite Notice" "Installer for \${TARGET_FILE##*/} finished with exit code \${INSTALLER_EXIT_CODE}." --icon=dialog-warning; fi
    fi

    echo "Wine Runner Suite: Searching for newly installed executable in '\${ACTUAL_WINEPREFIX}'..."
    APP_EXE_FOUND=\$(find "\${ACTUAL_WINEPREFIX}/drive_c/Program Files" \
                       "\${ACTUAL_WINEPREFIX}/drive_c/Program Files (x86)" \
                       "\${ACTUAL_WINEPREFIX}/drive_c/users/\${USER}/AppData/Local/Programs" \
                       "\${ACTUAL_WINEPREFIX}/drive_c/users/\${USER}/Desktop" \
                       -path "\${ACTUAL_WINEPREFIX}/drive_c/windows" -prune -o \
                       -path "\${ACTUAL_WINEPREFIX}/drive_c/ProgramData" -prune -o \
                       -path "\${ACTUAL_WINEPREFIX}/drive_c/users/\${USER}/AppData/Roaming" -prune -o \
                       -path "\${ACTUAL_WINEPREFIX}/drive_c/users/\${USER}/AppData/Local/Temp" -prune -o \
                       -type f -iname "*.exe" \
                       ! -iname "unins*.exe" ! -iname "setup*.exe" ! -iname "install*.exe" ! -iname "repair*.exe" \
                       ! -iname "modify*.exe" ! -iname "report*.exe" ! -iname "feedback*.exe" ! -iname "*unin*" \
                       -mmin -30 -print0 2>/dev/null | xargs -0 -r stat -c '%Y %n' 2>/dev/null | sort -nr | head -n 1 | sed -e 's/^[^ ]* //')


    if [[ -n "\$APP_EXE_FOUND" ]] && [[ -f "\$APP_EXE_FOUND" ]]; then
        APP_BASENAME="\$(basename "\$APP_EXE_FOUND")"
        APP_NAME_GUESS="\$(echo "\$APP_BASENAME" | sed -e 's/\.exe$//i' -e 's/[_.-]/ /g' -e 's/\b\(.\)/\u\1/g')"

        echo "Wine Runner Suite: Found potential executable: '\$APP_EXE_FOUND' (Guessed App Name: '\$APP_NAME_GUESS')"
        
        # Construct a unique filename for the .desktop file based on the app name
        SANITIZED_APP_NAME_FOR_DESKTOP="\$(echo "\$APP_NAME_GUESS" | tr ' ' '-' | tr -dc '[:alnum:]-' | tr '[:upper:]' '[:lower:]')"
        DESKTOP_SHORTCUT_FILENAME="wine-\${SANITIZED_APP_NAME_FOR_DESKTOP}.desktop"
        DESKTOP_SHORTCUT_PATH="\${HOME}/.local/share/applications/\$DESKTOP_SHORTCUT_FILENAME"
        
        CREATE_SHORTCUT=0
        USER_APP_NAME="\$APP_NAME_GUESS"

        if command -v zenity >/dev/null; then
            RESPONSE=\$(zenity --forms --title="Create Desktop Shortcut?" \
                --text="An application was likely installed from \${TARGET_FILE##*/}. Details:" \
                --add-entry="Application Name (for shortcut):*\$APP_NAME_GUESS" \
                --add-label="Executable found: \$APP_EXE_FOUND" \
                --ok-label="Create Shortcut" --cancel-label="Skip Shortcut" 2>/dev/null)
            if [ \$? -eq 0 ] && [ -n "\$RESPONSE" ]; then USER_APP_NAME="\$(echo "\$RESPONSE" | cut -d'|' -f1)"; CREATE_SHORTCUT=1; fi
        elif command -v kdialog >/dev/null; then
            USER_APP_NAME_TEMP=\$(kdialog --inputbox "Enter application name for shortcut (found '\$APP_NAME_GUESS' from \${APP_BASENAME}):" "\$APP_NAME_GUESS" 2>/dev/null)
            if [ \$? -eq 0 ] && [ -n "\$USER_APP_NAME_TEMP" ]; then 
                USER_APP_NAME="\$USER_APP_NAME_TEMP"
                kdialog --yesno "Create desktop shortcut for '\$USER_APP_NAME' (\${APP_BASENAME})?" && CREATE_SHORTCUT=1
            fi
        else 
            read -r -p "Found '\$APP_BASENAME'. Enter name for shortcut (default: '\$APP_NAME_GUESS'): " benutzer_app_name_eingabe
            USER_APP_NAME="\${benutzer_app_name_eingabe:-\$APP_NAME_GUESS}"
            read -r -p "Create desktop shortcut for '\$USER_APP_NAME'? (y/N): " response
            if [[ "\$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then CREATE_SHORTCUT=1; fi
        fi

        if [ \$CREATE_SHORTCUT -eq 1 ] && [ -n "\$USER_APP_NAME" ]; then
            echo "Wine Runner Suite: Creating desktop shortcut for '\$USER_APP_NAME' at '\$DESKTOP_SHORTCUT_PATH'..."
            APP_ICON_PATH="wine" # Default icon
            ICON_DEST_DIR_BASE="\${HOME}/.local/share/icons" # Base for user icons

            if command -v wrestool >/dev/null && command -v icotool >/dev/null; then
                ICON_TMP_DIR="\$(mktemp -d -t wrs-icons-XXXXXX)"
                # Ensure ICON_TMP_DIR is cleaned up on exit, interrupt, or termination
                _cleanup_icon_tmp() { 
                    # echo "Cleaning up temp icon dir: \$ICON_TMP_DIR" # For debugging
                    rm -rf "\$ICON_TMP_DIR"; 
                }
                trap _cleanup_icon_tmp EXIT INT TERM
                
                echo "Wine Runner Suite: Attempting to extract icon from '\$APP_EXE_FOUND'..."
                # Extract all icons first
                if wrestool -x --raw -t group_icon "\$APP_EXE_FOUND" -o "\$ICON_TMP_DIR/" >/dev/null 2>&1; then
                    # Find the "best" .ico file (e.g., largest, or first high-res if detectable)
                    # For now, just take the first one found or largest by size
                    ICON_ICO_FILE="\$(find "\$ICON_TMP_DIR/" -name "*.ico" -print0 | xargs -0 -r ls -S | head -n 1)"
                    if [ -n "\$ICON_ICO_FILE" ] && [ -f "\$ICON_ICO_FILE" ]; then
                        # Sanitize app name for icon filename to avoid special chars
                        SANITIZED_APP_NAME_FOR_ICONFILE="\$(echo "\$USER_APP_NAME" | tr -dc '[:alnum:]_-' | tr ' ' '-' | tr '[:upper:]' '[:lower:]')"
                        # Include part of exe name for more uniqueness
                        SANITIZED_EXE_BASENAME="\$(basename "\$APP_EXE_FOUND" .exe | tr -dc '[:alnum:]_-')"
                        
                        # Store icons in a structured way like hicolor theme, e.g., 48x48
                        # icotool can extract specific sizes; for simplicity, extract highest res PNG
                        FINAL_ICON_DIR="\${ICON_DEST_DIR_BASE}/hicolor/48x48/apps"
                        mkdir -p "\$FINAL_ICON_DIR"
                        CONVERTED_ICON_PNG="\${FINAL_ICON_DIR}/wineapp-\${SANITIZED_APP_NAME_FOR_ICONFILE}-\${SANITIZED_EXE_BASENAME}.png"
                        
                        if icotool -x --width=48 --height=48 -o "\$CONVERTED_ICON_PNG" "\$ICON_ICO_FILE" >/dev/null 2>&1 && [ -s "\$CONVERTED_ICON_PNG" ]; then
                             APP_ICON_PATH="\$CONVERTED_ICON_PNG" # Use full path for user-specific icon
                             echo "Wine Runner Suite: Extracted and saved 48x48 icon to '\$APP_ICON_PATH'"
                        elif icotool -x -o "\$CONVERTED_ICON_PNG" "\$ICON_ICO_FILE" >/dev/null 2>&1 && [ -s "\$CONVERTED_ICON_PNG" ]; then # Fallback to any size
                             APP_ICON_PATH="\$CONVERTED_ICON_PNG"
                             echo "Wine Runner Suite: Extracted icon (any size) to '\$APP_ICON_PATH'"
                        else
                             echo "Wine Runner Suite: Warning - Failed to convert .ico to .png for shortcut. Using default icon."
                        fi
                    else
                        echo "Wine Runner Suite: Info - No .ico files extracted by wrestool or found in temp dir."
                    fi
                else
                    echo "Wine Runner Suite: Info - wrestool failed to extract 'group_icon' resource or none found."
                fi
                # Explicit cleanup and clear trap
                _cleanup_icon_tmp
                trap - EXIT INT TERM 
            else
                echo "Wine Runner Suite: Info - 'icoutils' (wrestool, icotool) not installed. Using generic Wine icon for shortcut."
            fi

            mkdir -p "\$(dirname "\$DESKTOP_SHORTCUT_PATH")"
            # The Exec line for the user's .desktop file should use /usr/bin/wine-runner to benefit from all its setup
            echo -e "[Desktop Entry]\nVersion=1.0\nName=\${USER_APP_NAME}\nExec=/usr/bin/wine-runner \"\${APP_EXE_FOUND}\"\nType=Application\nIcon=\${APP_ICON_PATH}\nComment=Run \${USER_APP_NAME} via Wine Runner Suite\nCategories=X-Wine;Application;Utility;\nStartupWMClass=\${APP_BASENAME}" > "\$DESKTOP_SHORTCUT_PATH"
            chmod +x "\$DESKTOP_SHORTCUT_PATH"
            # Update desktop database for the user's local applications directory
            if command -v update-desktop-database >/dev/null; then update-desktop-database -q "\$(dirname "\$(dirname "\$DESKTOP_SHORTCUT_PATH")")"; fi
            if command -v notify-send >/dev/null; then notify-send "Wine Runner Suite" "Desktop shortcut for '\$USER_APP_NAME' created." --icon="\${APP_ICON_PATH}"; fi
        fi
        
        if command -v notify-send >/dev/null; then notify-send "Wine Runner Suite" "Installation of \${TARGET_FILE##*/} likely complete. Running \${APP_BASENAME}." --icon=wine; fi
        # Execute the found application.
        # APP_ARGS from CLI were for the installer, not for the installed app.
        # If arguments need to be passed to the installed app, this would need further logic.
        # shellcheck disable=SC2086
        exec \$CMD_PREFIX wine64 "\$APP_EXE_FOUND"
    else
        echo "Wine Runner Suite: Notice - No recently modified main executable found after installation of \${TARGET_FILE##*/}."
        if command -v notify-send >/dev/null; then notify-send "Wine Runner Suite Notice" "Installation of \${TARGET_FILE##*/} complete. No main executable auto-detected. Please run manually if needed." --icon=dialog-information; fi
    fi
    exit 0 # Successful completion of --install mode, even if app not auto-launched.

else # DIRECT RUN MODE (no --install flag)
    if [[ "\$TARGET_EXT_LOWER" == "exe" ]]; then
        echo "Wine Runner Suite: Running .exe (direct mode): '\$TARGET_FILE' with args: \${APP_ARGS[*]}"
        # shellcheck disable=SC2086
        exec \$CMD_PREFIX wine64 "\$TARGET_FILE" "\${APP_ARGS[@]}"
    elif [[ "\$TARGET_EXT_LOWER" == "msi" ]]; then
        echo "Wine Runner Suite: Installing .msi (direct mode, no post-launch): '\$TARGET_FILE' with args: \${APP_ARGS[*]}"
        # shellcheck disable=SC2086
        exec \$CMD_PREFIX wine64 msiexec /i "\$TARGET_FILE" "\${APP_ARGS[@]}"
    else 
        echo "Error: Unsupported file type for direct run: '\$TARGET_FILE'" >&2
        if command -v notify-send >/dev/null; then notify-send -u critical "Wine Runner Suite Error" "Unsupported file: \${TARGET_FILE##*/}" --icon=dialog-error; fi
        exit 3 
    fi
fi
EOF

# Desktop file for general .exe execution (uses wine-runner without --install)
cat > "$SHAREDIR/wine-runner-generic.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Name=Run with Wine Runner Suite
Comment=Run Windows Executable with Wine Runner Suite
Exec=/usr/bin/wine-runner %F
Terminal=false
Type=Application
MimeType=application/x-ms-dos-executable;application/x-ms-shortcut;application/x-msdownload;
NoDisplay=false
StartupNotify=true
Icon=wine
Keywords=windows;exe;run;application;launch;
Categories=X-Wine;Utility;Emulator;System;
EOF

# Desktop file specifically for .msi (uses wine-runner WITH --install)
# This will be the default for .msi files.
# Also makes "Install with..." available for .exe files in "Open With"
cat > "$SHAREDIR/wine-runner-installer.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Name=Install with Wine Runner Suite
Comment=Install Windows Application (MSI or EXE) with Wine Runner Suite and attempt to run
Exec=/usr/bin/wine-runner --install %F
Terminal=false
Type=Application
MimeType=application/x-msi;application/x-ms-dos-executable; 
NoDisplay=false 
StartupNotify=true
Icon=package-x-generic 
Keywords=windows;msi;exe;installer;setup;install;package;
Categories=X-Wine;Utility;Emulator;System;
EOF

# --- Set Permissions ---
_log_msg "Setting permissions..."
chmod 755 "$BINDIR/wine-runner"
chmod 755 "$DEBIANDIR/preinst" "$DEBIANDIR/postinst" "$DEBIANDIR/prerm" "$DEBIANDIR/postrm" "$DEBIANDIR/conffiles"
chmod 0644 "$SHAREDIR"/*.desktop "$ETCDIR"/*.conf

# --- Build .deb package ---
_log_msg "Building .deb package: $DEB_FILE_OUTPUT_NAME"
dpkg-deb --build "$BUILD_ROOT" "$(dirname "$BUILD_ROOT")/${DEB_FILE_OUTPUT_NAME}" >> "$APT_LOG" 2>&1 || { _log_err "Failed to build .deb package. Check $APT_LOG"; exit 1; }

_log_msg "Successfully built $(cd "$(dirname "$BUILD_ROOT")" && pwd)/${DEB_FILE_OUTPUT_NAME}"
_log_msg "Build logs: $APT_LOG"
echo ""
echo "----------------------------------------------------------------------"
echo "Package built: $(cd "$(dirname "$BUILD_ROOT")" && pwd)/${DEB_FILE_OUTPUT_NAME}"
echo "----------------------------------------------------------------------"
echo "To install, navigate to the directory containing the .deb file:"
echo "  cd \"$(cd "$(dirname "$BUILD_ROOT")" && pwd)\""
echo "Then run:"
echo "  sudo apt install \"./${DEB_FILE_OUTPUT_NAME}\""
echo ""
echo "Or provide the full path:"
echo "  sudo apt install \"$(cd "$(dirname "$BUILD_ROOT")" && pwd)/${DEB_FILE_OUTPUT_NAME}\""
echo ""
echo "To uninstall: sudo apt remove $PACKAGE_NAME"
echo "To purge (remove config file too): sudo apt purge $PACKAGE_NAME"

exit 0
