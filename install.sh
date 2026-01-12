#!/bin/bash
set -e

# ============================================================================
# hifi-wifi v3.0 Installer - Refactored for clarity and maintainability
# ============================================================================

# Colors
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

echo -e "${BLUE}=== hifi-wifi v3.0 Installer ===${NC}\n"

# ============================================================================
# Helper Functions
# ============================================================================

# Detect the real user when running under sudo
detect_user() {
    if [ -n "$SUDO_USER" ]; then
        REAL_USER="$SUDO_USER"
        REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        REAL_USER=$(whoami)
        REAL_HOME="$HOME"
    fi
}

# Run command as non-root user with preserved environment
as_user() {
    if [ "$USER" != "$REAL_USER" ]; then
        sudo -u "$REAL_USER" HOME="$REAL_HOME" PATH="$REAL_HOME/.cargo/bin:$PATH" "$@"
    else
        "$@"
    fi
}

# Check for pre-compiled binary
find_precompiled_binary() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    if [[ -f "$script_dir/bin/hifi-wifi-x86_64" ]]; then
        echo "$script_dir/bin/hifi-wifi-x86_64"
    elif [[ -f "$script_dir/hifi-wifi-x86_64" ]]; then
        echo "$script_dir/hifi-wifi-x86_64"
    else
        echo ""
    fi
}

# Setup Homebrew (works on SteamOS, persists across updates!)
# Installs to /home/linuxbrew/.linuxbrew - doesn't touch rootfs
setup_homebrew() {
    local HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
    
    # Check if already installed
    if [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
        echo -e "${GREEN}Homebrew already installed${NC}"
        eval "$($HOMEBREW_PREFIX/bin/brew shellenv)"
        return 0
    fi
    
    echo -e "${BLUE}Installing Homebrew (one-time setup, persists across SteamOS updates)...${NC}"
    echo -e "${YELLOW}This may take 5-10 minutes on first run.${NC}"
    
    # Homebrew needs to run as non-root user
    if [[ $EUID -eq 0 ]] && [[ -n "$SUDO_USER" ]]; then
        # Create linuxbrew directory with correct permissions
        mkdir -p /home/linuxbrew
        chown "$SUDO_USER:$SUDO_USER" /home/linuxbrew
        
        # Install as the real user (non-interactive)
        sudo -u "$SUDO_USER" bash -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' || {
            echo -e "${RED}Homebrew installation failed${NC}"
            return 1
        }
    else
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
            echo -e "${RED}Homebrew installation failed${NC}"
            return 1
        }
    fi
    
    # Set up environment
    eval "$($HOMEBREW_PREFIX/bin/brew shellenv)"
    echo -e "${GREEN}Homebrew installed successfully${NC}"
}

# Find Homebrew's GCC binary (installed as gcc-VERSION, e.g., gcc-15)
find_homebrew_gcc() {
    local HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
    local gcc_cellar="$HOMEBREW_PREFIX/Cellar/gcc"
    
    if [[ ! -d "$gcc_cellar" ]]; then
        return 1
    fi
    
    # Get the installed version directory (e.g., 15.2.0)
    local version_dir
    version_dir=$(ls -1 "$gcc_cellar" 2>/dev/null | head -1)
    if [[ -z "$version_dir" ]]; then
        return 1
    fi
    
    # Extract major version (15.2.0 -> 15)
    local major_version="${version_dir%%.*}"
    
    # The actual binaries are gcc-MAJOR and g++-MAJOR
    local gcc_bin="$HOMEBREW_PREFIX/bin/gcc-$major_version"
    local gxx_bin="$HOMEBREW_PREFIX/bin/g++-$major_version"
    
    if [[ -x "$gcc_bin" ]] && [[ -x "$gxx_bin" ]]; then
        echo "$gcc_bin:$gxx_bin"
        return 0
    fi
    
    return 1
}

# Install build dependencies via Homebrew
setup_homebrew_build_deps() {
    echo -e "${BLUE}Installing build dependencies via Homebrew...${NC}"
    
    local HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
    eval "$($HOMEBREW_PREFIX/bin/brew shellenv)"
    
    # Install gcc (includes everything needed for Rust compilation)
    # Note: brew install may return non-zero for post-install warnings
    if [[ $EUID -eq 0 ]] && [[ -n "$SUDO_USER" ]]; then
        sudo -u "$SUDO_USER" "$HOMEBREW_PREFIX/bin/brew" install gcc || true
    else
        brew install gcc || true
    fi
    
    # Verify GCC actually works by finding the versioned binary
    local gcc_paths
    if gcc_paths=$(find_homebrew_gcc); then
        local gcc_bin="${gcc_paths%%:*}"
        if "$gcc_bin" --version &>/dev/null; then
            echo -e "${GREEN}Build dependencies ready! ($(basename "$gcc_bin"))${NC}"
            return 0
        fi
    fi
    
    echo -e "${RED}Failed to install gcc via Homebrew${NC}"
    return 1
}

# Setup SteamOS build environment using Homebrew (persists across updates!)
setup_steamos_build_env() {
    echo -e "${BLUE}[SteamOS] Preparing build environment via Homebrew...${NC}"
    echo -e "${YELLOW}Homebrew installs to home directory - survives SteamOS updates!${NC}\n"
    
    # Homebrew approach - no root needed, persists across updates
    setup_homebrew || {
        echo -e "${RED}Failed to set up Homebrew${NC}"
        echo -e "${YELLOW}Consider using the pre-compiled release instead:${NC}"
        echo -e "${BLUE}https://github.com/doughty247/hifi-wifi/releases${NC}"
        exit 1
    }
    
    setup_homebrew_build_deps || {
        echo -e "${RED}Failed to install build dependencies${NC}"
        exit 1
    }
    
    # Find and export the versioned GCC binaries
    local gcc_paths
    gcc_paths=$(find_homebrew_gcc)
    local gcc_bin="${gcc_paths%%:*}"
    local gxx_bin="${gcc_paths##*:}"
    
    export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
    export CC="$gcc_bin"
    export CXX="$gxx_bin"
    
    echo -e "${GREEN}Build environment ready! (CC=$CC)${NC}\n"
}

# Check for Rust toolchain, install if missing
setup_rust() {
    echo -e "${BLUE}Checking Rust toolchain...${NC}"
    
    local cargo_bin="$REAL_HOME/.cargo/bin/cargo"
    local rustup_bin="$REAL_HOME/.cargo/bin/rustup"
    
    if [[ ! -x "$cargo_bin" ]]; then
        echo -e "${BLUE}Rust not found. Installing for user $REAL_USER...${NC}"
        
        if ! command -v curl &>/dev/null; then
            echo -e "${RED}Error: curl is required to install Rust${NC}"
            exit 1
        fi
        
        as_user curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | as_user sh -s -- -y
        
        if [[ ! -x "$cargo_bin" ]]; then
            echo -e "${RED}Rust installation failed${NC}"
            exit 1
        fi
    fi
    
    # Verify cargo works
    if ! as_user "$cargo_bin" --version &>/dev/null; then
        echo -e "${YELLOW}Cargo appears broken, attempting repair...${NC}"
        as_user "$rustup_bin" self update 2>/dev/null || true
        as_user "$rustup_bin" default stable 2>/dev/null || true
        
        if ! as_user "$cargo_bin" --version &>/dev/null; then
            echo -e "${RED}Cargo is not working. Please reinstall Rust manually.${NC}"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}Rust toolchain ready${NC}\n"
}

# Build binary from source
build_from_source() {
    echo -e "${BLUE}Building release binary...${NC}"
    echo "Building as user: $REAL_USER"
    
    local cargo_bin="$REAL_HOME/.cargo/bin/cargo"
    as_user "$cargo_bin" build --release
    
    if [[ ! -f "target/release/hifi-wifi" ]]; then
        echo -e "${RED}Build failed! Binary not found in target/release/${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Build complete${NC}\n"
}

# Install the hifi-wifi service
install_service() {
    echo -e "${BLUE}Installing hifi-wifi service...${NC}"
    
    local run_as_root=""
    [[ $EUID -ne 0 ]] && run_as_root="sudo"
    
    # Stop existing service to prevent "text file busy" errors
    if systemctl is-active --quiet hifi-wifi 2>/dev/null; then
        echo -e "${BLUE}Stopping existing service...${NC}"
        $run_as_root systemctl stop hifi-wifi
    fi
    
    # Run the binary's install command
    $run_as_root ./target/release/hifi-wifi install
    
    # SELinux: Fix context on Fedora-based systems (Bazzite)
    if command -v chcon &>/dev/null && [[ -f /var/lib/hifi-wifi/hifi-wifi ]]; then
        echo -e "${BLUE}Setting SELinux context...${NC}"
        $run_as_root chcon -t bin_t /var/lib/hifi-wifi/hifi-wifi 2>/dev/null || true
    fi
    
    echo -e "${GREEN}Service installed${NC}\n"
}

# Create CLI symlink (handles SteamOS read-only filesystem)
create_cli_symlink() {
    local distro_id="${1:-}"
    local run_as_root=""
    [[ $EUID -ne 0 ]] && run_as_root="sudo"
    
    if [[ -L /usr/local/bin/hifi-wifi ]]; then
        return 0  # Already exists
    fi
    
    echo -e "${BLUE}Creating CLI symlink...${NC}"
    
    if [[ "$distro_id" == "steamos" ]]; then
        # SteamOS: Need to disable read-only temporarily
        systemd-sysext unmerge 2>/dev/null || true
        steamos-readonly disable 2>&1 | grep -v "Warning:" || true
        sleep 1
        $run_as_root ln -sf /var/lib/hifi-wifi/hifi-wifi /usr/local/bin/hifi-wifi 2>/dev/null || true
        steamos-readonly enable 2>&1 | grep -v "Warning:" || true
    else
        $run_as_root ln -sf /var/lib/hifi-wifi/hifi-wifi /usr/local/bin/hifi-wifi 2>/dev/null || true
    fi
}

# Apply initial optimizations
apply_optimizations() {
    local run_as_root=""
    [[ $EUID -ne 0 ]] && run_as_root="sudo"
    
    local hifi_cmd
    if [[ -L /usr/local/bin/hifi-wifi ]]; then
        hifi_cmd="hifi-wifi"
    else
        echo -e "${YELLOW}CLI symlink not in PATH yet. Using absolute path.${NC}"
        hifi_cmd="/var/lib/hifi-wifi/hifi-wifi"
    fi
    
    echo -e "${BLUE}Applying initial optimizations...${NC}"
    $run_as_root $hifi_cmd apply
    echo ""
}

# Offer reboot
offer_reboot() {
    echo -e "${GREEN}Success! hifi-wifi v3.0 is installed and active.${NC}\n"
    echo -e "  Check status:    ${BLUE}hifi-wifi status${NC}"
    echo -e "  Live monitoring: ${BLUE}sudo hifi-wifi monitor${NC}"
    echo -e "  Service logs:    ${BLUE}journalctl -u hifi-wifi -f${NC}\n"
    echo -e "${BLUE}Note:${NC} Driver-level tweaks require a reboot for full effect.\n"
    
    read -p "Reboot now? [Y/n] " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        echo -e "${BLUE}Rebooting...${NC}"
        
        local run_as_root=""
        [[ $EUID -ne 0 ]] && run_as_root="sudo"
        
        # Try systemctl first
        if ! $run_as_root systemctl reboot 2>/dev/null; then
            # Fallback for desktop environments with session inhibitors
            if command -v gnome-session-quit &>/dev/null; then
                local user_id=$(id -u "$REAL_USER")
                sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$user_id/bus" \
                    gnome-session-quit --reboot --no-prompt 2>/dev/null || {
                    echo -e "${YELLOW}Please reboot manually from your desktop${NC}"
                }
            elif command -v qdbus &>/dev/null; then
                sudo -u "$REAL_USER" qdbus org.kde.Shutdown /Shutdown org.kde.Shutdown.logoutAndReboot 2>/dev/null || {
                    echo -e "${YELLOW}Please reboot manually from your desktop${NC}"
                }
            else
                echo -e "${YELLOW}Please reboot manually${NC}"
            fi
        fi
    fi
}

# ============================================================================
# Main Installation Flow
# ============================================================================

main() {
    # Detect user and platform
    detect_user
    
    local distro_id=""
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        distro_id="$ID"
    fi
    
    # Step 1: Check for pre-compiled binary
    echo -e "${BLUE}[1/5] Checking for pre-compiled binary...${NC}"
    local precompiled_bin=$(find_precompiled_binary)
    
    if [[ -n "$precompiled_bin" ]]; then
        echo -e "${GREEN}Found: $precompiled_bin${NC}"
        
        # Verify architecture
        if ! file "$precompiled_bin" | grep -q "x86-64"; then
            echo -e "${RED}Error: Binary is not x86_64 architecture${NC}"
            exit 1
        fi
        
        # Copy to target/release
        mkdir -p target/release
        cp "$precompiled_bin" target/release/hifi-wifi
        chmod +x target/release/hifi-wifi
        echo -e "${GREEN}Using pre-compiled binary (skipping build)${NC}\n"
    else
        echo -e "${YELLOW}No pre-compiled binary found. Will build from source.${NC}\n"
        
        # SteamOS info - Homebrew makes this much easier now
        if [[ "$distro_id" == "steamos" ]]; then
            echo -e "${YELLOW}NOTE: Building from source on SteamOS uses Homebrew.${NC}"
            echo -e "${YELLOW}First-time setup takes ~10 minutes but persists across SteamOS updates.${NC}"
            echo -e "${YELLOW}Alternatively, download the pre-compiled release:${NC}"
            echo -e "${BLUE}https://github.com/doughty247/hifi-wifi/releases${NC}\n"
            read -p "Continue with Homebrew build? [y/N] " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
        fi
        
        # Step 2: Setup build environment (SteamOS uses Homebrew, others use system packages)
        if [[ "$distro_id" == "steamos" ]]; then
            echo -e "${BLUE}[2/5] Setting up Homebrew build environment...${NC}"
            setup_steamos_build_env
        elif [[ "$distro_id" == *"arch"* ]]; then
            if ! command -v cc &>/dev/null; then
                echo -e "${BLUE}[2/5] Setting up build environment...${NC}"
                # Arch but not SteamOS - use pacman directly
                sudo pacman -Sy --noconfirm --needed base-devel
            else
                echo -e "${BLUE}[2/5] Build tools already installed${NC}\n"
            fi
        else
            echo -e "${BLUE}[2/5] Build environment check...${NC}"
            if ! command -v cc &>/dev/null && [[ "$distro_id" == "bazzite" ]]; then
                echo -e "${YELLOW}gcc not found. On Bazzite, run: ${BLUE}ujust install-rust${NC}\n"
            else
                echo -e "${GREEN}Build tools available${NC}\n"
            fi
        fi
        
        # Step 3: Setup Rust
        echo -e "${BLUE}[3/5] Setting up Rust toolchain...${NC}"
        setup_rust
        
        # Step 4: Build
        echo -e "${BLUE}[4/5] Building from source...${NC}"
        build_from_source
    fi
    
    # Step 5: Install
    echo -e "${BLUE}[5/5] Installing service...${NC}"
    install_service
    create_cli_symlink "$distro_id"
    apply_optimizations
    
    # Offer reboot
    offer_reboot
}

# Run main
main
