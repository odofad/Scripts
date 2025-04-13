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
VPN_SUBNET="10.0.0"
VPS_IP=$(curl -s ifconfig.me) # Auto-detect public IP
NET_IFACE=$(ip -o -f inet addr show | awk '/scope global/ {print $2}' | head -1) # Auto-detect network interface

# Ensure script runs as root
if [[ $EUID -ne 0 ]]; then
    echo "WireGuardInstall must be run as root (use sudo)."
    exit 1
fi

# Function to install WireGuard
install_wireguard() {
    echo "WireGuardInstall: Installing WireGuard..."
    apt update && apt install -y wireguard iptables-persistent
}

# Function to generate key pairs
generate_keys() {
    local privkey_file=$1
    local pubkey_file=$2
    echo "WireGuardInstall: Generating new key pair..."
    privkey=$(wg genkey)
    pubkey=$(echo "$privkey" | wg pubkey)
    mkdir -p $(dirname "$privkey_file")
    echo "$privkey" > "$privkey_file"
    echo "$pubkey" > "$pubkey_file"
    chmod 600 "$privkey_file" "$pubkey_file"
    echo "WireGuardInstall: Private key saved to $privkey_file"
    echo "WireGuardInstall: Public key: $pubkey"
}

# Function to check and manage keys
check_keys() {
    local role=$1 # "client" or "server"
    if [[ -f $WG_PRIVATE_KEY && -f $WG_PUBLIC_KEY ]]; then
        echo "WireGuardInstall: Existing keys found for $role."
        echo "Public key: $(cat $WG_PUBLIC_KEY)"
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
        # Extract IPs from AllowedIPs (e.g., 10.0.0.2/32)
        while IFS= read -r ip; do
            ip=$(echo "$ip" | grep -o "$subnet\.[0-9]\+")
            used_ips+=("$ip")
        done < <(grep "AllowedIPs" $WG_CONFIG)
    fi
    # Start from 10.0.0.2 (reserve .1 for server)
    for ((i=2; i<=254; i++)); do
        local candidate="$subnet.$i"
        if [[ ! " ${used_ips[*]} " =~ " $candidate " ]]; then
            echo "$candidate"
            return
        fi
    done
    echo "WireGuardInstall: No available IPs in $subnet.0/24." >&2
    exit 1
}

# Function to parse client config file
parse_client_config() {
    local config_file=$1
    if [[ ! -f $config_file ]]; then
        echo "WireGuardInstall: Config file $config_file not found."
        exit 1
    fi

    # Extract values using grep and awk
    CLIENT_PRIVKEY=$(grep "PrivateKey" "$config_file" | awk -F '= ' '{print $2}' | tr -d '[:space:]')
    CLIENT_IP=$(grep "Address" "$config_file" | awk -F '= ' '{print $2}' | awk -F '/' '{print $1}' | tr -d '[:space:]')
    VPS_PUBKEY=$(grep "PublicKey" "$config_file" | awk -F '= ' '{print $2}' | tr -d '[:space:]')
    ENDPOINT=$(grep "Endpoint" "$config_file" | awk -F '= ' '{print $2}' | tr -d '[:space:]')

    # Validate extracted values
    if [[ -z $CLIENT_PRIVKEY || -z $CLIENT_IP || -z $VPS_PUBKEY || -z $ENDPOINT ]]; then
        echo "WireGuardInstall: Invalid or incomplete config file. Missing required fields."
        exit 1
    fi

    # Extract VPS_IP and port from endpoint
    VPS_IP=$(echo "$ENDPOINT" | awk -F ':' '{print $1}')
    PORT=$(echo "$ENDPOINT" | awk -F ':' '{print $2}')
    if [[ "$PORT" != "$WG_PORT" ]]; then
        echo "WireGuardInstall: Warning: Endpoint port ($PORT) differs from default ($WG_PORT). Using $PORT."
    fi
}

# Menu Option 1: Setup Client (Gaming Server)
setup_client() {
    echo "WireGuardInstall: Setting up WireGuard client (gaming server)..."
    if ! command -v wg >/dev/null; then
        install_wireguard
    else
        echo "WireGuardInstall: WireGuard already installed."
    fi

    # Check for existing config
    if [[ -f $WG_CONFIG ]]; then
        echo "WireGuardInstall: Existing config found at $WG_CONFIG."
        read -p "Overwrite config? (y/n) [default: n]: " overwrite
        overwrite=${overwrite:-n}
        if [[ $overwrite =~ ^[Yy]$ ]]; then
            rm -f $WG_CONFIG
        else
            echo "WireGuardInstall: Keeping existing config. Please manually edit $WG_CONFIG if needed."
            return
        fi
    fi

    # Prompt for import or manual setup
    read -p "Import client config file? (y/n) [default: n]: " import_choice
    import_choice=${import_choice:-n}

    if [[ $import_choice =~ ^[Yy]$ ]]; then
        read -p "Enter path to client config file (e.g., client_gamingserver1.conf): " CONFIG_FILE
        parse_client_config "$CONFIG_FILE"

        # Generate public key from private key for verification
        mkdir -p $WG_KEY_DIR
        echo "$CLIENT_PRIVKEY" > $WG_PRIVATE_KEY
        chmod 600 $WG_PRIVATE_KEY
        CLIENT_PUBKEY=$(cat $WG_PRIVATE_KEY | wg pubkey)
        echo "$CLIENT_PUBKEY" > $WG_PUBLIC_KEY
        chmod 600 $WG_PUBLIC_KEY

        # Create client config
        cat > $WG_CONFIG << EOL
[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_IP/24

[Peer]
PublicKey = $VPS_PUBKEY
Endpoint = $ENDPOINT
AllowedIPs = $VPN_SUBNET.0/24
PersistentKeepalive = 25
EOL
    else
        # Manual setup
        check_keys "client"
        CLIENT_PRIVKEY=$(cat $WG_PRIVATE_KEY)
        CLIENT_PUBKEY=$(cat $WG_PUBLIC_KEY)

        read -p "Enter VPS public key: " VPS_PUBKEY
        read -p "Enter VPS public IP [default: $VPS_IP]: " INPUT_VPS_IP
        VPS_IP=${INPUT_VPS_IP:-$VPS_IP}
        CLIENT_IP="$VPN_SUBNET.2"

        cat > $WG_CONFIG << EOL
[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_IP/24

[Peer]
PublicKey = $VPS_PUBKEY
Endpoint = $VPS_IP:$WG_PORT
AllowedIPs = $VPN_SUBNET.0/24
PersistentKeepalive = 25
EOL
    fi

    # Start WireGuard
    systemctl enable wg-quick@$WG_INTERFACE
    systemctl restart wg-quick@$WG_INTERFACE
    echo "WireGuardInstall: Client setup complete. Client IP: $CLIENT_IP"
    echo "WireGuardInstall: Config saved to $WG_CONFIG"
    echo "WireGuardInstall: Public key: $CLIENT_PUBKEY"
}

# Submenu Option 2.1: Detect and View Configuration and Keys
detect_view_config() {
    echo "WireGuardInstall: Detecting and viewing configuration and keys..."
    if [[ -f $WG_PRIVATE_KEY && -f $WG_PUBLIC_KEY ]]; then
        echo "WireGuardInstall: Keys found."
        echo "Public key: $(cat $WG_PUBLIC_KEY)"
        echo "Private key location: $WG_PRIVATE_KEY (contents not displayed for security)"
    else
        echo "WireGuardInstall: No keys found in $WG_KEY_DIR."
    fi

    if [[ -f $WG_CONFIG ]]; then
        echo "WireGuardInstall: Configuration found at $WG_CONFIG:"
        cat $WG_CONFIG
    else
        echo "WireGuardInstall: No configuration found at $WG_CONFIG."
    fi

    if command -v wg >/dev/null; then
        echo "WireGuardInstall: WireGuard is installed."
        echo "WireGuardInstall: Current status:"
        wg show
    else
        echo "WireGuardInstall: WireGuard is not installed."
    fi
}

# Submenu Option 2.2: Setup Client Keys and Connections
setup_client_connections() {
    echo "WireGuardInstall: Setting up client keys and connections..."
    if [[ ! -f $WG_CONFIG ]]; then
        echo "WireGuardInstall: No server config found at $WG_CONFIG. Please run 'Install Server' first."
        return
    fi

    # Prompt for client name
    read -p "Enter client name (e.g., GamingServer1): " CLIENT_NAME
    if [[ -z $CLIENT_NAME ]]; then
        echo "WireGuardInstall: Client name is required."
        return
    fi

    # Sanitize client name for filename
    CLIENT_NAME_SAFE=$(echo "$CLIENT_NAME" | tr -dc '[:alnum:]_-' | tr '[:upper:]' '[:lower:]')
    CLIENT_CONF="/etc/wireguard/client_$CLIENT_NAME_SAFE.conf"

    # Get next available IP
    CLIENT_IP=$(get_next_ip $VPN_SUBNET)
    if [[ -z $CLIENT_IP ]]; then
        echo "WireGuardInstall: Failed to assign client IP."
        return
    fi

    # Prompt for client public key
    read -p "Enter client public key (or press Enter to generate new keys): " CLIENT_PUBKEY
    if [[ -z $CLIENT_PUBKEY ]]; then
        # Generate new keys for client
        CLIENT_PRIVKEY_FILE="/etc/wireguard/client_$CLIENT_NAME_SAFE_privatekey"
        CLIENT_PUBKEY_FILE="/etc/wireguard/client_$CLIENT_NAME_SAFE_publickey"
        generate_keys "$CLIENT_PRIVKEY_FILE" "$CLIENT_PUBKEY_FILE"
        CLIENT_PRIVKEY=$(cat "$CLIENT_PRIVKEY_FILE")
        CLIENT_PUBKEY=$(cat "$CLIENT_PUBKEY_FILE")
    else
        # Use provided public key, no private key needed here
        CLIENT_PRIVKEY="YOUR_PRIVATE_KEY_HERE"
    fi

    # Check if client already exists
    if [[ -n $(grep "$CLIENT_PUBKEY" $WG_CONFIG) ]]; then
        echo "WireGuardInstall: Client with public key $CLIENT_PUBKEY already exists."
        read -p "Overwrite this client? (y/n) [default: n]: " overwrite
        overwrite=${overwrite:-n}
        if [[ $overwrite =~ ^[Yy]$ ]]; then
            # Remove existing peer
            sed -i "/# Client: .*\|PublicKey = $CLIENT_PUBKEY/,/AllowedIPs/ { /PublicKey/!d; /AllowedIPs/!d; s/AllowedIPs.*/AllowedIPs = $CLIENT_IP\/32/ }" $WG_CONFIG
            echo "# Client: $CLIENT_NAME" >> $WG_CONFIG
            echo "WireGuardInstall: Updated client '$CLIENT_NAME' with IP $CLIENT_IP."
        else
            echo "WireGuardInstall: Keeping existing client."
            return
        fi
    else
        # Add new peer
        echo -e "\n# Client: $CLIENT_NAME\n[Peer]\nPublicKey = $CLIENT_PUBKEY\nAllowedIPs = $CLIENT_IP/32" >> $WG_CONFIG
        echo "WireGuardInstall: Added client '$CLIENT_NAME' with IP $CLIENT_IP."
    fi

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
        echo "WireGuardInstall: Generated client config at $CLIENT_CONF"
        echo "WireGuardInstall: Transfer this file to the client and use with 'wg-quick up <file>' or import in Option 1."
    else
        echo "WireGuardInstall: Using provided public key. No client config generated (private key unknown)."
        echo "WireGuardInstall: Create client config manually with IP $CLIENT_IP and server details."
    fi

    # Restart WireGuard
    systemctl restart wg-quick@$WG_INTERFACE
    echo "WireGuardInstall: WireGuard restarted. Client connection updated."
}

# Submenu Option 2.3: Install Server
install_server() {
    echo "WireGuardInstall: Installing WireGuard server (VPS)..."
    if ! command -v wg >/dev/null; then
        install_wireguard
    else
        echo "WireGuardInstall: WireGuard already installed."
    fi

    # Enable IP forwarding
    if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
        echo "WireGuardInstall: Enabling IP forwarding..."
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
        sysctl -p
    else
        echo "WireGuardInstall: IP forwarding already enabled."
    fi

    # Check for existing keys
    check_keys "server"
    SERVER_PRIVKEY=$(cat $WG_PRIVATE_KEY)
    SERVER_PUBKEY=$(cat $WG_PUBLIC_KEY)

    # Check for existing config
    if [[ -f $WG_CONFIG ]]; then
        echo "WireGuardInstall: Existing config found at $WG_CONFIG."
        read -p "Overwrite config? (y/n) [default: n]: " overwrite
        overwrite=${overwrite:-n}
        if [[ $overwrite =~ ^[Yy]$ ]]; then
            rm -f $WG_CONFIG
        else
            echo "WireGuardInstall: Keeping existing config. Please manually edit $WG_CONFIG if needed."
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

    # Start WireGuard
    systemctl enable wg-quick@$WG_INTERFACE
    systemctl restart wg-quick@$WG_INTERFACE
    echo "WireGuardInstall: Server setup complete. Server IP: $SERVER_IP"
    echo "WireGuardInstall: Public key: $SERVER_PUBKEY"
    echo "WireGuardInstall: Config saved to $WG_CONFIG"
}

# Menu Option 2: Server Submenu
server_menu() {
    while true; do
        echo -e "\n=== WireGuardInstall Server Setup Submenu ==="
        echo "1. Detect and View Configuration and Keys"
        echo "2. Setup Client Keys and Connections"
        echo "3. Install Server"
        echo "4. Back to Main Menu"
        read -p "Select an option [1-4]: " sub_choice

        case $sub_choice in
            1) detect_view_config ;;
            2) setup_client_connections ;;
            3) install_server ;;
            4) break ;;
            *) echo "WireGuardInstall: Invalid option. Please try again." ;;
        esac
    done
}

# Menu Option 3: List Clients
list_clients() {
    echo "WireGuardInstall: Listing configured clients..."
    if [[ -f $WG_CONFIG ]]; then
        echo "Clients in $WG_CONFIG:"
        grep -B1 -A2 "^# Client:\|^[Peer\]" $WG_CONFIG | grep -E "^# Client:|PublicKey|AllowedIPs" | awk '{print $0}' | paste - - - | column -t
    else
        echo "WireGuardInstall: No WireGuard config found at $WG_CONFIG."
    fi
}

# Menu Option 4: Port Forwards and Firewall
port_forwards_firewall() {
    echo "WireGuardInstall: Configuring port forwards and firewall..."
    read -p "Enter game port (e.g., 25565 for Minecraft): " GAME_PORT
    read -p "Enter protocol (tcp/udp) [default: tcp]: " PROTOCOL
    PROTOCOL=${PROTOCOL:-tcp}

    # List available client IPs
    if [[ -f $WG_CONFIG ]]; then
        echo "Available client IPs:"
        grep "AllowedIPs" $WG_CONFIG | awk '{print $3}' | sort
    fi
    read -p "Enter client IP for forwarding (e.g., $VPN_SUBNET.2): " CLIENT_IP
    CLIENT_IP=${CLIENT_IP:-$VPN_SUBNET.2}

    # Set up iptables for port forwarding
    echo "WireGuardInstall: Setting up iptables rules..."
    iptables -A FORWARD -i $NET_IFACE -o $WG_INTERFACE -p $PROTOCOL --dport $GAME_PORT -d $CLIENT_IP -j ACCEPT
    iptables -t nat -A PREROUTING -i $NET_IFACE -p $PROTOCOL --dport $GAME_PORT -j DNAT --to-destination $CLIENT_IP:$GAME_PORT
    netfilter-persistent save

    # Configure firewall
    echo "WireGuardInstall: Configuring UFW..."
    ufw allow $WG_PORT/udp
    ufw allow $GAME_PORT/$PROTOCOL
    ufw reload
    echo "WireGuardInstall: Port forwarding set up for $GAME_PORT/$PROTOCOL to $CLIENT_IP"
    echo "WireGuardInstall: Firewall rules updated. Players connect to $VPS_IP:$GAME_PORT"
}

# Main Menu
while true; do
    echo -e "\n=== WireGuardInstall Setup Menu ==="
    echo "1. Setup Client (Gaming Server)"
    echo "2. Setup Server (VPS)"
    echo "3. List Clients"
    echo "4. Port Forwards and Firewall"
    echo "5. Exit"
    read -p "Select an option [1-5]: " choice

    case $choice in
        1) setup_client ;;
        2) server_menu ;;
        3) list_clients ;;
        4) port_forwards_firewall ;;
        5) echo "WireGuardInstall: Exiting..."; exit 0 ;;
        *) echo "WireGuardInstall: Invalid option. Please try again." ;;
    esac
done
