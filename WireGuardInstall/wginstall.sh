#!/bin/bash

# WireGuardInstall (wginstall.sh)
# Automates WireGuard VPN setup for hosting a gaming server behind NAT
# Allows players to connect to VPS public IP without VPN software

# Configuration variables
WG_CONFIG="/etc/wireguard/wg0.conf"
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
    privkey=$(wg genkey)
    pubkey=$(echo "$privkey" | wg pubkey)
    echo "$privkey" > privatekey
    echo "$pubkey" > publickey
    echo "Private key: $privkey"
    echo "Public key: $pubkey"
}

# Menu Option 1: Setup Client (Gaming Server)
setup_client() {
    echo "WireGuardInstall: Setting up WireGuard client (gaming server)..."
    if ! command -v wg >/dev/null; then
        install_wireguard
    fi

    # Generate keys
    echo "WireGuardInstall: Generating client keys..."
    generate_keys
    CLIENT_PRIVKEY=$(cat privatekey)
    CLIENT_PUBKEY=$(cat publickey)
    rm privatekey publickey

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
    systemctl start wg-quick@$WG_INTERFACE
    echo "WireGuardInstall: Client setup complete. Client IP: $CLIENT_IP"
    echo "WireGuardInstall: Config saved to $WG_CONFIG"
}

# Menu Option 2: Setup Server (VPS)
setup_server() {
    echo "WireGuardInstall: Setting up WireGuard server (VPS)..."
    if ! command -v wg >/dev/null; then
        install_wireguard
    fi

    # Enable IP forwarding
    echo "WireGuardInstall: Enabling IP forwarding..."
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p

    # Generate server keys
    echo "WireGuardInstall: Generating server keys..."
    mkdir -p /etc/wireguard
    generate_keys
    SERVER_PRIVKEY=$(cat privatekey)
    SERVER_PUBKEY=$(cat publickey)
    mv privatekey /etc/wireguard/
    mv publickey /etc/wireguard/

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
    systemctl start wg-quick@$WG_INTERFACE
    echo "WireGuardInstall: Server setup complete. Server IP: $SERVER_IP"
    echo "WireGuardInstall: Public key: $SERVER_PUBKEY"
    echo "WireGuardInstall: Config saved to $WG_CONFIG"
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
        2) setup_server ;;
        3) list_clients ;;
        4) port_forwards_firewall ;;
        5) echo "WireGuardInstall: Exiting..."; exit 0 ;;
        *) echo "WireGuardInstall: Invalid option. Please try again." ;;
    esac
done
