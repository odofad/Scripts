#!/bin/bash

# Configuration variables
WG_CONFIG="/etc/wireguard/wg0.conf"
WG_KEY_DIR="/etc/wireguard"
WG_PRIVATE_KEY="$WG_KEY_DIR/privatekey"
WG_PUBLIC_KEY="$WG_KEY_DIR/publickey"
WG_INTERFACE="wg0"
WG_PORT="51820"
VPN_SUBNET="10.8.0" # Default subnet
VPS_IP=$(curl -s ifconfig.me) # Auto-detect public IP
NET_IFACE=$(ip -o -f inet addr show | awk '/scope global/ {print $2}' | head -1) # Auto-detect network interface
LOG_FILE="/var/log/wginstall.log"
WG_CLIENTS_DIR="$HOME/wgclients" # Folder for client configs

# Ensure script runs as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)."
    exit 1
fi

# Function to log and display messages
log() {
    echo "$1" | tee -a "$LOG_FILE"
}

# Function to generate key pairs
generate_keys() {
    local privkey_file=$1
    local pubkey_file=$2
    log "Generating new key pair..."
    privkey=$(wg genkey)
    pubkey=$(echo "$privkey" | wg pubkey)
    mkdir -p "$(dirname "$privkey_file")"
    echo "$privkey" > "$privkey_file"
    echo "$pubkey" > "$pubkey_file"
    chmod 600 "$privkey_file" "$pubkey_file"
    log "Private key saved to $privkey_file"
    log "Public key: $pubkey"
}

# Function to find next available IP
get_next_ip() {
    local subnet=$1
    local used_ips=()
    if [[ -f $WG_CONFIG ]]; then
        while IFS= read -r ip; do
            ip=$(echo "$ip" | grep -o "$subnet\.[0-9]\+")
            [[ -n $ip ]] && used_ips+=("$ip")
        done < <(grep "AllowedIPs" "$WG_CONFIG")
    fi
    for ((i=2; i<=254; i++)); do
        local candidate="$subnet.$i"
        if [[ ! " ${used_ips[*]} " =~ " $candidate " ]]; then
            echo "$candidate"
            return
        fi
    done
    log "No available IPs in $subnet.0/24."
    exit 1
}

# Menu Option 1: Setup Client (Gaming Server)
setup_client() {
    log "Setting up WireGuard client (gaming server)..."
    if ! command -v wg >/dev/null; then
        apt update && apt install -y wireguard
        log "WireGuard installed."
    else
        log "WireGuard already installed."
    fi

    if [[ -f $WG_CONFIG ]]; then
        log "Existing config found at $WG_CONFIG."
        read -p "Overwrite config? (y/n) [default: n]: " overwrite
        overwrite=${overwrite:-n}
        if [[ $overwrite =~ ^[Nn]$ ]]; then
            log "Keeping existing config. Exiting setup."
            return
        else
            rm -f "$WG_CONFIG"
        fi
    fi

    # Prompt to import client config or manual setup
    read -p "Import client config file? (y/n) [default: n]: " import_choice
    import_choice=${import_choice:-n}

    if [[ $import_choice =~ ^[Yy]$ ]]; then
        # Prompt for config filename with default in wgclients folder
        read -p "Enter client config filename (default: client_gamingserver1.conf in $WG_CLIENTS_DIR): " CONFIG_FILENAME
        CONFIG_FILENAME=${CONFIG_FILENAME:-client_gamingserver1.conf}
        # Determine full path
        if [[ ! $CONFIG_FILENAME =~ ^/ ]]; then
            CONFIG_FILE="$WG_CLIENTS_DIR/$CONFIG_FILENAME"
        else
            CONFIG_FILE="$CONFIG_FILENAME"
        fi
        # Verify file exists and import
        if [[ ! -f $CONFIG_FILE ]]; then
            log "Error: Config file $CONFIG_FILE not found."
            return
        fi
        cp "$CONFIG_FILE" "$WG_CONFIG"
        chmod 600 "$WG_CONFIG"
        log "Imported client config from $CONFIG_FILE to $WG_CONFIG"
    else
        # Manual setup
        generate_keys "$WG_PRIVATE_KEY" "$WG_PUBLIC_KEY"
        CLIENT_PRIVKEY=$(cat "$WG_PRIVATE_KEY")
        CLIENT_PUBKEY=$(cat "$WG_PUBLIC_KEY")
        CLIENT_IP="$VPN_SUBNET.2"

        read -p "Enter VPS public key: " VPS_PUBKEY
        read -p "Enter VPS public IP [default: $VPS_IP]: " INPUT_VPS_IP
        VPS_IP=${INPUT_VPS_IP:-$VPS_IP}

        cat > "$WG_CONFIG" << EOL
[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_IP/24

[Peer]
PublicKey = $VPS_PUBKEY
Endpoint = $VPS_IP:$WG_PORT
AllowedIPs = $VPN_SUBNET.0/24
PersistentKeepalive = 25
EOL
        log "Manual client config created at $WG_CONFIG"
    fi

    # Start WireGuard
    systemctl enable wg-quick@$WG_INTERFACE
    systemctl restart wg-quick@$WG_INTERFACE
    log "Client setup complete."
}

# Menu Option 2: Setup Server (VPS)
setup_server() {
    log "Setting up WireGuard server (VPS)..."
    if ! command -v wg >/dev/null; then
        apt update && apt install -y wireguard iptables-persistent
        log "WireGuard installed."
    else
        log "WireGuard already installed."
    fi

    if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
        log "Enabling IP forwarding..."
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
        sysctl -p
    fi

    generate_keys "$WG_PRIVATE_KEY" "$WG_PUBLIC_KEY"
    SERVER_PRIVKEY=$(cat "$WG_PRIVATE_KEY")
    SERVER_PUBKEY=$(cat "$WG_PUBLIC_KEY")
    SERVER_IP="$VPN_SUBNET.1"

    if [[ -f $WG_CONFIG ]]; then
        log "Existing config found at $WG_CONFIG."
        read -p "Overwrite config? (y/n) [default: n]: " overwrite
        overwrite=${overwrite:-n}
        [[ $overwrite =~ ^[Yy]$ ]] && rm -f "$WG_CONFIG"
    fi

    cat > "$WG_CONFIG" << EOL
[Interface]
PrivateKey = $SERVER_PRIVKEY
Address = $SERVER_IP/24
ListenPort = $WG_PORT
PostUp = iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -A POSTROUTING -o $NET_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -D POSTROUTING -o $NET_IFACE -j MASQUERADE
EOL

    systemctl enable wg-quick@$WG_INTERFACE
    systemctl restart wg-quick@$WG_INTERFACE
    log "Server setup complete. Public key: $SERVER_PUBKEY"
}

# Suboption 3.1: Add Client
add_client() {
    log "Adding new client..."
    if [[ ! -f $WG_CONFIG ]]; then
        log "No server config found at $WG_CONFIG. Run 'Setup Server' first."
        return
    fi

    read -p "Enter client name: " CLIENT_NAME
    CLIENT_NAME_SAFE=$(echo "$CLIENT_NAME" | tr -dc '[:alnum:]_-' | tr '[:upper:]' '[:lower:]')
    mkdir -p "$WG_CLIENTS_DIR"
    CLIENT_CONF="$WG_CLIENTS_DIR/client_$CLIENT_NAME_SAFE.conf"

    CLIENT_IP=$(get_next_ip "$VPN_SUBNET")
    CLIENT_PRIVKEY_FILE="$WG_CLIENTS_DIR/client_$CLIENT_NAME_SAFE_privatekey"
    CLIENT_PUBKEY_FILE="$WG_CLIENTS_DIR/client_$CLIENT_NAME_SAFE_publickey"
    generate_keys "$CLIENT_PRIVKEY_FILE" "$CLIENT_PUBKEY_FILE"
    CLIENT_PRIVKEY=$(cat "$CLIENT_PRIVKEY_FILE")
    CLIENT_PUBKEY=$(cat "$CLIENT_PUBKEY_FILE")

    echo -e "\n# Client: $CLIENT_NAME\n[Peer]\nPublicKey = $CLIENT_PUBKEY\nAllowedIPs = $CLIENT_IP/32" >> "$WG_CONFIG"
    SERVER_PUBKEY=$(cat "$WG_PUBLIC_KEY")

    cat > "$CLIENT_CONF" << EOL
[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_IP/24

[Peer]
PublicKey = $SERVER_PUBKEY
Endpoint = $VPS_IP:$WG_PORT
AllowedIPs = $VPN_SUBNET.0/24
PersistentKeepalive = 25
EOL

    chmod 600 "$CLIENT_CONF"
    systemctl restart wg-quick@$WG_INTERFACE
    log "Client '$CLIENT_NAME' added with IP $CLIENT_IP."
    log "Config saved to $CLIENT_CONF"
}

# Suboption 3.2: View Clients
view_clients() {
    log "Viewing clients..."
    if [[ -f $WG_CONFIG ]]; then
        log "Configuration at $WG_CONFIG:"
        cat "$WG_CONFIG" | tee -a "$LOG_FILE"
        log "Existing clients:"
        grep -B1 -A2 "^# Client:" "$WG_CONFIG" | tee -a "$LOG_FILE"
    else
        log "No configuration found."
    fi
}

# Suboption 3.3: Delete Client
delete_client() {
    log "Deleting client..."
    if [[ ! -f $WG_CONFIG ]]; then
        log "No server config found."
        return
    fi

    log "Existing clients:"
    grep -B1 -A2 "^# Client:" "$WG_CONFIG" | tee -a "$LOG_FILE"
    read -p "Enter client name to delete: " CLIENT_NAME
    if grep -q "# Client: $CLIENT_NAME" "$WG_CONFIG"; then
        sed -i "/# Client: $CLIENT_NAME/,+2d" "$WG_CONFIG"
        CLIENT_NAME_SAFE=$(echo "$CLIENT_NAME" | tr -dc '[:alnum:]_-' | tr '[:upper:]' '[:lower:]')
        CLIENT_CONF="$WG_CLIENTS_DIR/client_$CLIENT_NAME_SAFE.conf"
        [[ -f $CLIENT_CONF ]] && rm -f "$CLIENT_CONF" && log "Deleted $CLIENT_CONF"
        systemctl restart wg-quick@$WG_INTERFACE
        log "Client '$CLIENT_NAME' deleted."
    else
        log "Client not found."
    fi
}

# Menu Option 4: Port Forwards and Firewall
port_forwards_firewall() {
    log "Configuring port forwards and firewall..."
    read -p "Enter game port (e.g., 25565): " GAME_PORT
    read -p "Enter protocol (tcp/udp) [default: tcp]: " PROTOCOL
    PROTOCOL=${PROTOCOL:-tcp}
    read -p "Enter client IP (e.g., $VPN_SUBNET.2): " CLIENT_IP

    iptables -A FORWARD -i $NET_IFACE -o $WG_INTERFACE -p "$PROTOCOL" --dport "$GAME_PORT" -d "$CLIENT_IP" -j ACCEPT
    iptables -t nat -A PREROUTING -i $NET_IFACE -p "$PROTOCOL" --dport "$GAME_PORT" -j DNAT --to-destination "$CLIENT_IP:$GAME_PORT"
    netfilter-persistent save
    ufw allow "$WG_PORT/udp"
    ufw allow "$GAME_PORT/$PROTOCOL"
    ufw reload
    log "Port forwarding set for $GAME_PORT/$PROTOCOL to $CLIENT_IP"
}

# Client Management Submenu
client_management() {
    while true; do
        echo -e "\n=== Client Management Submenu ==="
        echo "1. Add Client"
        echo "2. View Clients"
        echo "3. Delete Client"
        echo "4. Back to Main Menu"
        read -p "Select an option [1-4]: " sub_choice

        case $sub_choice in
            1) add_client ;;
            2) view_clients ;;
            3) delete_client ;;
            4) break ;;
            *) log "Invalid option." ;;
        esac
    done
}

# Main Menu
while true; do
    echo -e "\n=== WireGuardInstall Setup Menu ==="
    echo "1. Setup Client (Gaming Server)"
    echo "2. Setup Server (VPS)"
    echo "3. Client Management"
    echo "4. Port Forwards and Firewall"
    echo "5. Exit"
    read -p "Select an option [1-5]: " choice

    case $choice in
        1) setup_client ;;
        2) setup_server ;;
        3) client_management ;;
        4) port_forwards_firewall ;;
        5) log "Exiting..."; exit 0 ;;
        *) log "Invalid option." ;;
    esac
done
