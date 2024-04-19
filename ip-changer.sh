#!/bin/bash

# Check if curl and tor are installed
if ! command -v curl &> /dev/null || ! command -v tor &> /dev/null; then
    echo "Installing curl and tor"
    sudo apt-get update
    sudo apt-get install -y curl tor
fi


# Check if tor is running
if ! systemctl --quiet is-active tor.service; then
    echo "Starting tor service"
    sudo systemctl start tor.service
fi

# Function to get IP address
get_ip() {
    url="https://www.myexternalip.com/raw"
    get_ip=$(curl -x socks5://127.0.0.1:9050 "$url")
    ip=$(echo "$get_ip" | grep -oP '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}')
    echo "$ip"
    
}

# Function to change IP address
change_ip() {
    echo "Reloading tor service"
    sudo systemctl reload tor.service
    echo -e "\033[34mNew IP address: $(get_ip)\033[0m"
}

# banner
clear
cat << EOF
   ____ ____  __________ _   _ __________   ___ ____        ____ _   _    _    _   _  ____ _____ ____  
  / ___|  _ \|___ /___ /| \ | |___ /___  | |_ _|  _ \      / ___| | | |  / \  | \ | |/ ___| ____|  _ \ 
 | |  _| |_) | |_ \ |_ \|  \| | |_ \  / /   | || |_) |____| |   | |_| | / _ \ |  \| | |  _|  _| | |_) |
 | |_| |  _ < ___) |__) | |\  |___) |/ /    | ||  __/_____| |___|  _  |/ ___ \| |\  | |_| | |___|  _ < 
  \____|_| \_\____/____/|_| \_|____//_/    |___|_|         \____|_| |_/_/   \_\_| \_|\____|_____|_| \_\
                                                                                                       
EOF

# Change IP address
while true; do
    echo -en "\033[34mEnter time interval in seconds (type 0 for infinite IP changes): \033[0m"
    read interval
    echo -en "\033[34mEnter number of times to change IP address (type 0 for infinite IP changes): \033[0m"
    read times
    
#    read -p "\033[33mEnter time interval in seconds (type 0 for infinite IP changes): \033[0m" interval
#    read -p "\033[33mEnter number of times to change IP address (type 0 for infinite IP changes): \033[0m" times

    if [ "$interval" -eq "0" ] || [ "$times" -eq "0" ]; then
        echo "Starting infinite IP changes"
        while true; do
            change_ip
            sleep $interval
        done
    else
        for ((i=0; i<$times; i++)); do
            change_ip
            sleep $interval
        done
    fi
done
