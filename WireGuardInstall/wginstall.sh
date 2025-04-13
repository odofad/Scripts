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
    echo "WireGuardInstall: Generating new key pair..."
    privkey=$(wg genkey)
    pubkey=$(echo "$privkey" | wg pubkey)
    mkdir -p $WG_KEY_DIR
    echo "$privkey" > $WG_PRIVATE_KEY
    echo "$pubkey" > $WG_PUBLIC_KEY
    chmod 600 $WG_PRIVATE_KEY $WG_PUBLIC_KEY
    echo "WireGuardInstall: Private key saved to $WG_PRIVATE_KEY"
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
            generate_keys
            return 1
        fi
        return 0
    else
        generate_keys
        return 1
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

    # Check for existing keys
    check_keys "client"
    CLIENT_PRIVKEY=$(cat $WG_PRIVATE_KEY)
    CLIENT_PUBKEY=$(cat $WG_PUBLIC_KEY)

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

    # Get VPS public key and IP
    read -p "Enter VPS public key: " VPS_PUBKEY
    read -p "Enter VPS public IP [default: $VPS_IP]: " INPUT_VPS_IP
    VPS_IP=${INPUT_VPS_IP:-$VPS_IP}

    # Create client config
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

    read -p "Enter client public key: " CLIENT_PUBKEY
    read -p "Enter client VPN IP (e.g., $VPN_SUBNET.2): " CLIENT_IP
    if [[ -z $CLIENT_PUBKEY || -z $CLIENT_IP ]]; then
        echo "WireGuardInstall: Client public key and IP are required."
        return
    fi

    # Check if client already exists
    if grep -q "$CLIENT_PUBKEY" $WG_CONFIG; then
        echo "WireGuardInstall: Client with public key $CLIENT_PUBKEY already exists."
        read -p "Overwrite this client? (y/n) [default: n]: " overwrite
        overwrite=${overwrite:-n}
        if [[ $overwrite =~ ^[Yy]$ ]]; then
            # Remove existing peer
            sed -i "/PublicKey = $CLIENT_PUBKEY/,/AllowedIPs/ { /PublicKey/!d; /AllowedIPs/!d; s/AllowedIPs.*/AllowedIPs = $CLIENT_IP\/32/ }" $WG_CONFIG
            echo "WireGuardInstall: Updated client with IP $CLIENT_IP."
        else
            echo "WireGuardInstall: Keeping existing client."
            return
        fi
    else
        # Add new peer
        echo -e "\n[Peer]\nPublicKey = $CLIENT_PUBKEY\nAllowedIPs = $CLIENT_IP/32" >> $WG_CONFIG
        echo "WireGuardInstall: Added client with IP $CLIENT_IP."
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
        grep -A3 "\[Peer\]" $WG_CONFIG | grep -E "PublicKey|AllowedIPs" | awk '{print $3}' | paste - - | column -t
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
    CLIENT_IP="$VPN_SUBNET.2"

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
