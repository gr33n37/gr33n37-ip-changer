#!/bin/bash

# Ensure script is run as root
if [[ "$UID" -ne 0 ]]; then
    echo "Error: This script must be run as root."
    exit 1
fi

install_packages() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian)
                apt-get update && apt-get install -y curl tor
                ;;
            fedora|centos|rhel|amzn)
                yum update -y && yum install -y curl tor
                ;;
            arch)
                pacman -S --noconfirm curl tor
                ;;
            *)
                echo "Unsupported distribution: $NAME. Please install curl and tor manually."
                exit 1
                ;;
        esac
    else
        echo "Cannot determine OS distribution. Please install curl and tor manually."
        exit 1
    fi
}

# Verify dependencies
if ! command -v curl &> /dev/null || ! command -v tor &> /dev/null; then
    echo "Dependencies missing. Installing curl and tor..."
    install_packages
fi

# Ensure Tor service is running
if ! systemctl --quiet is-active tor.service; then
    echo "Starting Tor service..."
    systemctl start tor.service
    sleep 2 # Give Tor a moment to bootstrap
fi

get_ip() {
    # Added a 10-second max timeout to prevent hanging on bad exit nodes
    local ip
    ip=$(curl -s --max-time 10 -x socks5h://127.0.0.1:9050 "https://checkip.amazonaws.com" | tr -d '\r\n')
    
    if [[ -z "$ip" ]]; then
        echo "Refreshed (Circuit building...)"
    else
        echo "$ip"
    fi
}

change_ip() {
    echo "Refreshing Tor circuits..."
    systemctl reload tor.service
    echo -e "\033[34mCurrent External IP: $(get_ip)\033[0m"
}

clear
cat << EOF
   ____ ____  __________ _   _ __________   ___ ____        ____ _   _    _    _   _  ____ _____ ____  
  / ___|  _ \|___ /___ /| \ | |___ /___  | |_ _|  _ \      / ___| | | |  / \  | \ | |/ ___| ____|  _ \ 
 | |  _| |_) | |_ \ |_ \|  \| | |_ \  / /   | || |_) |____| |   | |_| | / _ \ |  \| | |  _|  _| | |_) |
 | |_| |  _ < ___) |__) | |\  |___) |/ /    | ||  __/_____| |___|  _  |/ ___ \| |\  | |_| | |___|  _ < 
  \____|_| \_\____/____/|_| \_|____//_/    |___|_|         \____|_| |_/_/   \_\_| \_|\____|_____|_| \_\
                                                                                                       
EOF

# Input validation loop for Interval
while true; do
    read -rp $'\033[34mEnter time interval in seconds (0 for randomized 10-20s): \033[0m' interval
    if [[ "$interval" =~ ^[0-9]+$ ]]; then break; fi
    echo "Invalid input. Please enter a valid number."
done

# Input validation loop for Iterations
while true; do
    read -rp $'\033[34mEnter number of times to change IP (0 for infinite): \033[0m' times
    if [[ "$times" =~ ^[0-9]+$ ]]; then break; fi
    echo "Invalid input. Please enter a valid number."
done

# Execution Block
if [ "$interval" -eq 0 ] || [ "$times" -eq 0 ]; then
    echo "Starting infinite IP rotation loop. Press [CTRL+C] to stop."
    while true; do
        change_ip
        # Standardize loop delay or keep randomized behavior
        local_delay=$(( interval == 0 ? $(shuf -i 10-20 -n 1) : interval ))
        sleep "$local_delay"
    done
else
    echo "Starting scheduled rotation for $times cycles..."
    for ((i=1; i<=times; i++)); do
        echo "--- Cycle $i of $times ---"
        change_ip
        if [ "$i" -lt "$times" ]; then
            sleep "$interval"
        fi
    done
fi
