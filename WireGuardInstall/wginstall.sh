#!/bin/bash

# WireGuardInstall (wginstall.sh)
# Automates WireGuard VPN setup for hosting a gaming server behind NAT
# Allows players to connect to VPS public IP without VPN software

# Configuration variables
WG_CONFIG="/etc/wireguard/wg0.conf"
WG_KEY_DIR="/etc/wireguard"
WG_PRIVATE_KEY="$WG_KEY_DIR/privatekey"
WG_PUBLIC_KEY="$WG_KEY_DIR/publickey"
WG_INTERFACE="wg0"
WG_PORT="51820"
VPN_SUBNET="10.8.0" # Matches your config
VPS_IP=$(curl -s ifconfig.me) # Auto-detect public IP
NET_IFACE=$(ip -o -f inet addr show | awk '/scope global/ {print $2}' | head -1) # Auto-detect network interface
LOG_FILE="/var/log/wginstall.log"

# Get script's directory for default config path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Determine the original user's home directory
if [[ -n $SUDO_USER ]]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    USER_NAME=$SUDO_USER
else
    USER_HOME=$HOME
    USER_NAME=$(whoami)
fi
WG_CLIENTS_DIR="$USER_HOME/wgclients"

# Ensure script runs as root
if [[ $EUID -ne 0 ]]; then
    echo "WireGuardInstall: This script must be run as root (use sudo)." | tee -a "$LOG_FILE"
    exit 1
fi

# Function to log and display messages
log() {
    echo "WireGuardInstall: $1" | tee -a "$LOG_FILE"
}

# Function to install WireGuard
install_wireguard() {
    log "Installing WireGuard..."
    apt update && apt install -y wireguard iptables-persistent
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
    # Set ownership to user, not root
    chown "$USER_NAME:$USER_NAME" "$privkey_file" "$pubkey_file"
    log "Private key saved to $privkey_file"
    log "Public key: $pubkey"
}

# Function to check and manage keys
check_keys() {
    local role=$1 # "client" or "server"
    if [[ -f $WG_PRIVATE_KEY && -f $WG_PUBLIC_KEY ]]; then
        log "Existing keys found for $role."
        log "Public key: $(cat $WG_PUBLIC_KEY)"
        read -p "Reuse existing keys? (y/n) [default: y]: " reuse
        reuse=${reuse:-y}
        if [[ $reuse =~ ^[Nn]$ ]]; then
            generate_keys "$WG_PRIVATE_KEY" "$WG_PUBLIC_KEY"
            return 1
        fi
        return 0
    else
        generate_keys "$WG_PRIVATE_KEY" "$WG_PUBLIC_KEY"
        return 1
    fi
}

# Function to find next available IP
get_next_ip() {
    local subnet=$1
    local used_ips=()
    if [[ -f $WG_CONFIG ]]; then
        # Extract IPs from AllowedIPs (e.g., 10.8.0.2/32)
        while IFS= read -r ip; do
            ip=$(echo "$ip" | grep -o "$subnet\.[0-9]\+")
            [[ -n $ip ]] && used_ips+=("$ip")
        done < <(grep "AllowedIPs" $WG_CONFIG)
    fi
    # Start from 10.8.0.2 (reserve .1 for server)
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

# Function to parse client config file
parse_client_config() {
    local config_file=$1
    if [[ ! -f $config_file ]]; then
        log "Config file $config_file not found."
        exit 1
    fi

    # Extract values using grep and awk
    CLIENT_PRIVKEY=$(grep "PrivateKey" "$config_file" | awk -F '= ' '{print $2}' | tr -d '[:space:]')
    CLIENT_IP=$(grep "Address" "$config_file" | awk -F '= ' '{print $2}' | awk -F '/' '{print $1}' | tr -d '[:space:]')
    VPS_PUBKEY=$(grep "PublicKey" "$config_file" | awk -F '= ' '{print $2}' | tr -d '[:space:]')
    ENDPOINT=$(grep "Endpoint" "$config_file" | awk -F '= ' '{print $2}' | tr -d '[:space:]')

    # Validate extracted values
    if [[ -z $CLIENT_PRIVKEY || -z $CLIENT_IP || -z $VPS_PUBKEY || -z $ENDPOINT ]]; then
        log "Invalid or incomplete config file. Missing required fields."
        exit 1
    fi

    # Extract VPS_IP and port from endpoint
    VPS_IP=$(echo "$ENDPOINT" | awk -F ':' '{print $1}')
    PORT=$(echo "$ENDPOINT" | awk -F ':' '{print $2}')
    if [[ "$PORT" != "$WG_PORT" ]]; then
        log "Warning: Endpoint port ($PORT) differs from default ($WG_PORT). Using $PORT."
    fi
}

# Function to validate wg0.conf syntax
validate_wg_config() {
    local config_file=$1
    if ! wg-quick strip "$config_file" >/dev/null 2>&1; then
        log "Error: Invalid configuration in $config_file."
        log "Please check $config_file for syntax errors."
        return 1
    fi
    return 0
}

# Menu Option 1: Setup Client (Gaming Server)
setup_client() {
    log "Setting up WireGuard client (gaming server)..."
    if ! command -v wg >/dev/null; then
        install_wireguard
        log "WireGuard installed."
    else
        log "WireGuard already installed."
    fi

    # Check for existing config
    if [[ -f $WG_CONFIG ]]; then
        log "Existing config found at $WG_CONFIG."
        read -p "Overwrite config? (y/n) [default: n]: " overwrite
        overwrite=${overwrite:-n}
        if [[ $overwrite =~ ^[Nn]$ ]]; then
            log "Keeping existing config. Please manually edit $WG_CONFIG if needed."
            return
        else
            rm -f "$WG_CONFIG"
        fi
    fi

    # Prompt to import client config or manual setup
    read -p "Import client config file? (y/n) [default: n]: " import_choice
    import_choice=${import_choice:-n}

    if [[ $import_choice =~ ^[Yy]$ ]]; then
        read -p "Enter client config filename (default: client_gamingserver1.conf in $WG_CLIENTS_DIR): " CONFIG_FILENAME
        CONFIG_FILENAME=${CONFIG_FILENAME:-client_gamingserver1.conf}
        # If no absolute path, assume wgclients directory
        if [[ ! $CONFIG_FILENAME =~ ^/ ]]; then
            CONFIG_FILE="$WG_CLIENTS_DIR/$CONFIG_FILENAME"
        else
            CONFIG_FILE="$CONFIG_FILENAME"
        fi
        parse_client_config "$CONFIG_FILE"

        # Generate public key from private key for verification
        mkdir -p $WG_KEY_DIR
        echo "$CLIENT_PRIVKEY" > $WG_PRIVATE_KEY
        chmod 600 $WG_PRIVATE_KEY
        chown "$USER_NAME:$USER_NAME" $WG_PRIVATE_KEY
        CLIENT_PUBKEY=$(cat $WG_PRIVATE_KEY | wg pubkey)
        echo "$CLIENT_PUBKEY" > $WG_PUBLIC_KEY
        chmod 600 $WG_PUBLIC_KEY
        chown "$USER_NAME:$USER_NAME" $WG_PUBLIC_KEY

        # Create client config
        cat > "$WG_CONFIG" << EOL
[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_IP/24

[Peer]
PublicKey = $VPS_PUBKEY
Endpoint = $ENDPOINT
AllowedIPs = $VPN_SUBNET.0/24
PersistentKeepalive = 25
EOL
        chmod 600 "$WG_CONFIG"
        log "Imported client config from $CONFIG_FILE to $WG_CONFIG"
    else
        # Manual setup
        check_keys "client"
        CLIENT_PRIVKEY=$(cat $WG_PRIVATE_KEY)
        CLIENT_PUBKEY=$(cat $WG_PUBLIC_KEY)

        read -p "Enter VPS public key: " VPS_PUBKEY
        read -p "Enter VPS public IP [default: $VPS_IP]: " INPUT_VPS_IP
        VPS_IP=${INPUT_VPS_IP:-$VPS_IP}
        CLIENT_IP="$VPN_SUBNET.2"

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
        chmod 600 "$WG_CONFIG"
        log "Manual client config created at $WG_CONFIG"
    fi

    # Start WireGuard
    systemctl enable wg-quick@$WG_INTERFACE
    systemctl restart wg-quick@$WG_INTERFACE
    if [[ $? -eq 0 ]]; then
        log "Client setup complete. Client IP: $CLIENT_IP"
        log "Config saved to $WG_CONFIG"
        log "Public key: $CLIENT_PUBKEY"
    else
        log "Error: Failed to restart WireGuard."
        log "Status:"
        systemctl status wg-quick@$WG_INTERFACE --no-pager | tee -a "$LOG_FILE"
        log "Recent logs:"
        journalctl -xeu wg-quick@$WG_INTERFACE --no-pager | tail -n 20 | tee -a "$LOG_FILE"
    fi
}

# Menu Option 2: Setup Server (VPS)
setup_server() {
    log "Installing WireGuard server (VPS)..."
    if ! command -v wg >/dev/null; then
        install_wireguard
        log "WireGuard installed."
    else
        log "WireGuard already installed."
    fi

    # Enable IP forwarding
    if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
        log "Enabling IP forwarding..."
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
        sysctl -p
    else
        log "IP forwarding already enabled."
    fi

    # Check for existing keys
    check_keys "server"
    SERVER_PRIVKEY=$(cat $WG_PRIVATE_KEY)
    SERVER_PUBKEY=$(cat $WG_PUBLIC_KEY)

    # Check for existing config
    if [[ -f $WG_CONFIG ]]; then
        log "Existing config found at $WG_CONFIG."
        read -p "Overwrite config? (y/n) [default: n]: " overwrite
        overwrite=${overwrite:-n}
        if [[ $overwrite =~ ^[Yy]$ ]]; then
            rm -f $WG_CONFIG
        else
            log "Keeping existing config. Please manually edit $WG_CONFIG if needed."
            return
        fi
    fi

    # Create server config
    SERVER_IP="$VPN_SUBNET.1"
    cat > $WG_CONFIG << EOL
[Interface]
PrivateKey = $SERVER_PRIVKEY
Address = $SERVER_IP/24
ListenPort = $WG_PORT
PostUp = iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -A POSTROUTING -o $NET_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -D POSTROUTING -o $NET_IFACE -j MASQUERADE
EOL

    # Validate config before applying
    if ! validate_wg_config $WG_CONFIG; then
        log "Aborting server setup due to invalid configuration."
        return
    fi

    # Start WireGuard
    systemctl enable wg-quick@$WG_INTERFACE
    systemctl restart wg-quick@$WG_INTERFACE
    if [[ $? -eq 0 ]]; then
        log "Server setup complete. Server IP: $SERVER_IP"
        log "Public key: $SERVER_PUBKEY"
        log "Config saved to $WG_CONFIG"
    else
        log "Error: Failed to start WireGuard."
        log "Status:"
        systemctl status wg-quick@$WG_INTERFACE --no-pager | tee -a "$LOG_FILE"
        log "Recent logs:"
        journalctl -xeu wg-quick@$WG_INTERFACE --no-pager | tail -n 20 | tee -a "$LOG_FILE"
    fi
}

# Menu Option 3: Client Management
client_management() {
    while true; do
        echo -e "\n=== WireGuardInstall Client Management Submenu ==="
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
            *) log "Invalid option. Please try again." ;;
        esac
    done
}

# Suboption 3.1: Add Client
add_client() {
    log "Setting up client keys and connections..."
    if [[ ! -f $WG_CONFIG ]]; then
        log "No server config found at $WG_CONFIG. Please run 'Setup Server' first."
        return
    fi

    # Prompt for client name
    read -p "Enter client name (e.g., GamingServer1): " CLIENT_NAME
    if [[ -z $CLIENT_NAME ]]; then
        log "Client name is required."
        return
    fi

    # Sanitize client name for filename
    CLIENT_NAME_SAFE=$(echo "$CLIENT_NAME" | tr -dc '[:alnum:]_-' | tr '[:upper:]' '[:lower:]')
    # Use wgclients directory in user's home
    mkdir -p "$WG_CLIENTS_DIR"
    CLIENT_CONF="$WG_CLIENTS_DIR/client_$CLIENT_NAME_SAFE.conf"

    # Get next available IP
    CLIENT_IP=$(get_next_ip $VPN_SUBNET)
    if [[ -z $CLIENT_IP ]]; then
        log "Failed to assign client IP."
        return
    fi

    # Prompt for client public key
    read -p "Enter client public key (or press Enter to generate new keys): " CLIENT_PUBKEY
    if [[ -z $CLIENT_PUBKEY ]]; then
        # Generate new keys for client
        CLIENT_PRIVKEY_FILE="$WG_CLIENTS_DIR/client_$CLIENT_NAME_SAFE_privatekey"
        CLIENT_PUBKEY_FILE="$WG_CLIENTS_DIR/client_$CLIENT_NAME_SAFE_publickey"
        generate_keys "$CLIENT_PRIVKEY_FILE" "$CLIENT_PUBKEY_FILE"
        CLIENT_PRIVKEY=$(cat "$CLIENT_PRIVKEY_FILE")
        CLIENT_PUBKEY=$(cat "$CLIENT_PUBKEY_FILE")
    else
        # Use provided public key, no private key needed here
        CLIENT_PRIVKEY="YOUR_PRIVATE_KEY_HERE"
    fi

    # Check if client already exists by public key or IP
    if grep -q "PublicKey = $CLIENT_PUBKEY" $WG_CONFIG; then
        log "Client with public key $CLIENT_PUBKEY already exists."
        read -p "Overwrite this client? (y/n) [default: n]: " overwrite
        overwrite=${overwrite:-n}
        if [[ $overwrite =~ ^[Yy]$ ]]; then
            # Remove existing peer
            sed -i "/# Client: .*\|PublicKey = $CLIENT_PUBKEY/,+2d" $WG_CONFIG
            log "Removed existing client with public key $CLIENT_PUBKEY."
        else
            log "Keeping existing client."
            return
        fi
    fi
    if grep -q "AllowedIPs = $CLIENT_IP/32" $WG_CONFIG; then
        log "IP $CLIENT_IP already assigned to another client."
        read -p "Assign a different IP? (y/n) [default: y]: " reassign
        reassign=${reassign:-y}
        if [[ $reassign =~ ^[Yy]$ ]]; then
            CLIENT_IP=$(get_next_ip $VPN_SUBNET)
            log "Assigned new IP: $CLIENT_IP"
        else
            log "Cannot proceed with duplicate IP."
            return
        fi
    fi

    # Create temporary file for new config
    TEMP_CONFIG=$(mktemp)
    cat $WG_CONFIG > $TEMP_CONFIG
    echo -e "\n# Client: $CLIENT_NAME\n[Peer]\nPublicKey = $CLIENT_PUBKEY\nAllowedIPs = $CLIENT_IP/32" >> $TEMP_CONFIG

    # Validate temporary config
    if ! validate_wg_config $TEMP_CONFIG; then
        log "Aborting client addition due to invalid configuration."
        rm -f $TEMP_CONFIG
        return
    fi

    # Apply new config
    mv $TEMP_CONFIG $WG_CONFIG
    chmod 600 $WG_CONFIG
    log "Successfully added client '$CLIENT_NAME' with IP $CLIENT_IP."

    # Generate client config file
    if [[ "$CLIENT_PRIVKEY" != "YOUR_PRIVATE_KEY_HERE" ]]; then
        SERVER_PUBKEY=$(cat $WG_PUBLIC_KEY)
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
        chown "$USER_NAME:$USER_NAME" "$CLIENT_CONF"
        log "Generated client config at $CLIENT_CONF"
        log "Transfer this file to the client and import in Option 1."
    else
        log "Using provided public key. No client config generated (private key unknown)."
        log "Create client config manually with IP $CLIENT_IP and server details."
    fi

    # Restart WireGuard
    systemctl restart wg-quick@$WG_INTERFACE
    if [[ $? -eq 0 ]]; then
        log "WireGuard restarted successfully."
    else
        log "Error: Failed to restart WireGuard."
        log "Status:"
        systemctl status wg-quick@$WG_INTERFACE --no-pager | tee -a "$LOG_FILE"
        log "Recent logs:"
        journalctl -xeu wg-quick@$WG_INTERFACE --no-pager | tail -n 20 | tee -a "$LOG_FILE"
    fi
}

# Suboption 3.2: View Clients
view_clients() {
    log "Viewing clients..."
    if [[ -f $WG_CONFIG ]]; then
        log "Configuration at $WG_CONFIG:"
        cat $WG_CONFIG | tee -a "$LOG_FILE"
        log "Existing clients:"
        grep -B1 -A2 "^# Client:" $WG_CONFIG | grep -E "^# Client:|PublicKey|AllowedIPs" | awk '{print $0}' | paste - - - | column -t | tee -a "$LOG_FILE"
        if command -v wg >/dev/null; then
            log "Current WireGuard status:"
            wg show | tee -a "$LOG_FILE"
        fi
    else
        log "No configuration found at $WG_CONFIG."
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
    grep -B1 -A2 "^# Client:" $WG_CONFIG | grep -E "^# Client:|PublicKey|AllowedIPs" | awk '{print $0}' | paste - - - | column -t | tee -a "$LOG_FILE"
    read -p "Enter client name or public key to delete: " DELETE_IDENTIFIER
    if [[ -z $DELETE_IDENTIFIER ]]; then
        log "Client name or public key required."
        return
    fi
    # Check if identifier matches a client name or public key
    if grep -B1 "# Client:.*$DELETE_IDENTIFIER" $WG_CONFIG >/dev/null || grep "PublicKey = $DELETE_IDENTIFIER" $WG_CONFIG >/dev/null; then
        # Create temporary file for new config
        TEMP_CONFIG=$(mktemp)
        sed "/# Client:.*$DELETE_IDENTIFIER\|PublicKey = $DELETE_IDENTIFIER/,+2d" $WG_CONFIG > $TEMP_CONFIG

        # Validate temporary config
        if ! validate_wg_config $TEMP_CONFIG; then
            log "Aborting client deletion due to invalid resulting configuration."
            rm -f $TEMP_CONFIG
            return
        fi

        # Apply new config
        mv $TEMP_CONFIG $WG_CONFIG
        chmod 600 $WG_CONFIG

        # Extract client name for config file deletion
        CLIENT_NAME=$(grep -B1 "PublicKey = $DELETE_IDENTIFIER" $WG_CONFIG | grep "^# Client:" | awk -F ': ' '{print $2}' || echo "")
        if [[ -z $CLIENT_NAME ]]; then
            CLIENT_NAME=$(grep "# Client:.*$DELETE_IDENTIFIER" $WG_CONFIG | awk -F ': ' '{print $2}' || echo "")
        fi
        if ! grep "PublicKey = $DELETE_IDENTIFIER" $WG_CONFIG >/dev/null; then
            log "Successfully deleted client."
            # Delete client config file if it exists
            if [[ -n $CLIENT_NAME ]]; then
                CLIENT_NAME_SAFE=$(echo "$CLIENT_NAME" | tr -dc '[:alnum:]_-' | tr '[:upper:]' '[:lower:]')
                CLIENT_CONF="$WG_CLIENTS_DIR/client_$CLIENT_NAME_SAFE.conf"
                if [[ -f $CLIENT_CONF ]]; then
                    read -p "Also delete client config file $CLIENT_CONF? (y/n) [default: y]: " delete_file
                    delete_file=${delete_file:-y}
                    if [[ $delete_file =~ ^[Yy]$ ]]; then
                        rm -f "$CLIENT_CONF"
                        log "Deleted $CLIENT_CONF."
                    fi
                fi
            fi
            # Restart WireGuard
            systemctl restart wg-quick@$WG_INTERFACE
            if [[ $? -eq 0 ]]; then
                log "WireGuard restarted successfully."
            else
                log "Error: Failed to restart WireGuard."
                log "Status:"
                systemctl status wg-quick@$WG_INTERFACE --no-pager | tee -a "$LOG_FILE"
                log "Recent logs:"
                journalctl -xeu wg-quick@$WG_INTERFACE --no-pager | tail -n 20 | tee -a "$LOG_FILE"
            fi
        else
            log "Error: Failed to delete client from $WG_CONFIG."
        fi
    else
        log "No client found with name or public key '$DELETE_IDENTIFIER'."
    fi
}

# Menu Option 4: Port Forwards and Firewall
port_forwards_firewall() {
    log "Configuring port forwards and firewall..."
    read -p "Enter game port (e.g., 25565): " GAME_PORT
    read -p "Enter protocol (tcp/udp) [default: tcp]: " PROTOCOL
    PROTOCOL=${PROTOCOL:-tcp}

    # List available client IPs
    if [[ -f $WG_CONFIG ]]; then
        log "Available client IPs:"
        grep "AllowedIPs" $WG_CONFIG | awk '{print $3}' | sort | tee -a "$LOG_FILE"
    fi
    read -p "Enter client IP for forwarding (e.g., $VPN_SUBNET.2): " CLIENT_IP
    CLIENT_IP=${CLIENT_IP:-$VPN_SUBNET.2}

    # Set up iptables for port forwarding
    log "Setting up iptables rules..."
    iptables -A FORWARD -i $NET_IFACE -o $WG_INTERFACE -p $PROTOCOL --dport $GAME_PORT -d $CLIENT_IP -j ACCEPT
    iptables -t nat -A PREROUTING -i $NET_IFACE -p $PROTOCOL --dport $GAME_PORT -j DNAT --to-destination $CLIENT_IP:$GAME_PORT
    netfilter-persistent save

    # Configure firewall
    log "Configuring UFW..."
    ufw allow $WG_PORT/udp
    ufw allow $GAME_PORT/$PROTOCOL
    ufw reload
    log "Port forwarding set up for $GAME_PORT/$PROTOCOL to $CLIENT_IP"
    log "Firewall rules updated. Players connect to $VPS_IP:$GAME_PORT"
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
        *) log "Invalid option. Please try again." ;;
    esac
done
