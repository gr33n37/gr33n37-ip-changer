#!/bin/bash

[[ "$UID" -ne 0 && "$(uname)" != "Darwin" ]] && {
    echo "Script must be run as root (except on macOS)."
    exit 1
}

install_packages_linux() {
    local distro
    distro=$(awk -F= '/^NAME/{print $2}' /etc/os-release)
    distro=${distro//\"/}
    
    case "$distro" in
        *"Ubuntu"* | *"Debian"*)
            apt-get update
            apt-get install -y curl tor
            ;;
        *"Fedora"* | *"CentOS"* | *"Red Hat"* | *"Amazon Linux"*)
            yum update
            yum install -y curl tor
            ;;
        *"Arch"*)
            pacman -S --noconfirm curl tor
            ;;
        *)
            echo "Unsupported distribution: $distro. Please install curl and tor manually."
            exit 1
            ;;
    esac
}

install_packages_macos() {
    if ! command -v brew &> /dev/null; then
        echo "Homebrew is not installed. Please install Homebrew from https://brew.sh/ and re-run this script."
        exit 1
    fi
    if ! brew list tor &> /dev/null; then
        echo "Installing tor via Homebrew..."
        brew install tor
    fi
    if ! brew list curl &> /dev/null; then
        echo "Installing curl via Homebrew..."
        brew install curl
    fi
}

start_tor_linux() {
    if ! systemctl --quiet is-active tor.service; then
        echo "Starting tor service"
        systemctl start tor.service
    fi
}

start_tor_macos() {
    if ! pgrep -x "tor" > /dev/null; then
        echo "Starting tor service with Homebrew..."
        brew services start tor
        sleep 3
    fi
}

change_ip_linux() {
    echo "Reloading tor service"
    systemctl reload tor.service
    echo -e "\033[34mNew IP address: $(get_ip)\033[0m"
}

change_ip_macos() {
    echo "Restarting tor service with Homebrew..."
    brew services restart tor
    sleep 3
    echo -e "\033[34mNew IP address: $(get_ip)\033[0m"
}

get_ip() {
    local url get_ip ip
    url="https://checkip.amazonaws.com"
    get_ip=$(curl -s -x socks5h://127.0.0.1:9050 "$url")
    # Use portable grep/awk for IP extraction
    ip=$(echo "$get_ip" | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}')
    echo "$ip"
}

# Delete Tor log files every 5s under typical Homebrew / Linux paths (not Tor data/state). Stops when the script exits.
_ipc_tor_log_purge_once() {
    local d
    if [ "$(uname)" = "Darwin" ]; then
        for d in /opt/homebrew/var/log/tor /usr/local/var/log/tor "${HOME}/Library/Logs/Tor"; do
            if [ -d "$d" ]; then
                find "$d" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -exec rm -f {} + 2>/dev/null || true
            fi
        done
    else
        for d in /var/log/tor; do
            if [ -d "$d" ] && [ -w "$d" ]; then
                find "$d" -mindepth 1 -maxdepth 1 -type f -exec rm -f {} + 2>/dev/null || true
            fi
        done
    fi
}

_ipc_start_tor_log_purge_loop() {
    (
        while true; do
            sleep 5
            _ipc_tor_log_purge_once
        done
    ) &
    _IPC_LOG_PURGE_PID=$!
}

_ipc_stop_tor_log_purge_loop() {
    if [ -n "${_IPC_LOG_PURGE_PID:-}" ]; then
        kill "$_IPC_LOG_PURGE_PID" 2>/dev/null || true
        _IPC_LOG_PURGE_PID=
    fi
}

trap '_ipc_stop_tor_log_purge_loop' EXIT INT TERM

OS_TYPE=$(uname)
if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS
    if ! command -v curl &> /dev/null || ! brew list tor &> /dev/null; then
        echo "Checking/installing curl and tor for macOS..."
        install_packages_macos
    fi
    start_tor_macos
    _ipc_start_tor_log_purge_loop
else
    # Linux
    if ! command -v curl &> /dev/null || ! command -v tor &> /dev/null; then
        echo "Installing curl and tor"
        install_packages_linux
    fi
    start_tor_linux
    _ipc_start_tor_log_purge_loop
fi

clear
cat << EOF
   ____ ____  __________ _   _ __________   ___ ____        ____ _   _    _    _   _  ____ _____ ____  
  / ___|  _ \|___ /___ /| \ | |___ /___  | |_ _|  _ \      / ___| | | |  / \  | \ | |/ ___| ____|  _ \ 
 | |  _| |_) | |_ \ |_ \|  \| | |_ \  / /   | || |_) |____| |   | |_| | / _ \ |  \| | |  _|  _| | |_) |
 | |_| |  _ < ___) |__) | |\  |___) |/ /    | ||  __/_____| |___|  _  |/ ___ \| |\  | |_| | |___|  _ < 
  \____|_| \_\____/____/|_| \_|____//_/    |___|_|         \____|_| |_/_/   \_\_| \_|\____|_____|_| \_\
                                                                                                       
EOF

while true; do
    read -rp $'\033[34mEnter time interval in seconds (type 0 for infinite IP changes): \033[0m' interval
    read -rp $'\033[34mEnter number of times to change IP address (type 0 for infinite IP changes): \033[0m' times

    if [ "$interval" -eq "0" ] || [ "$times" -eq "0" ]; then
        echo "Starting infinite IP changes"
        while true; do
            if [ "$OS_TYPE" = "Darwin" ]; then
                change_ip_macos
                # Use bash RANDOM for macOS
                interval=$(( ( RANDOM % 11 ) + 10 ))
            else
                change_ip_linux
                interval=$(shuf -i 10-20 -n 1)
            fi
            sleep "$interval"
        done
    else
        for ((i=0; i< times; i++)); do
            if [ "$OS_TYPE" = "Darwin" ]; then
                change_ip_macos
            else
                change_ip_linux
            fi
            sleep "$interval"
        done
    fi
done
