#!/bin/bash

# Script to configure static IP on Ubuntu Server 24.04 using Netplan

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (use sudo)."
  exit 1
fi

# Prompt for network interface
echo "Enter the network interface name (e.g., eno1, eth0):"
read interface
if [ -z "$interface" ]; then
  echo "Interface name cannot be empty."
  exit 1
fi

# Prompt for static IP address (with CIDR, e.g., 192.168.103.24/24)
echo "Enter the static IP address (e.g., 192.168.103.24/24):"
read ip_address
if [ -z "$ip_address" ]; then
  echo "IP address cannot be empty."
  exit 1
fi

# Prompt for gateway
echo "Enter the gateway IP (e.g., 192.168.103.1):"
read gateway
if [ -z "$gateway" ]; then
  echo "Gateway cannot be empty."
  exit 1
fi

# Prompt for DNS servers (comma-separated, e.g., 1.1.1.1,192.168.103.1)
echo "Enter DNS server IPs (comma-separated, e.g., 1.1.1.1,192.168.103.1):"
read dns_servers
if [ -z "$dns_servers" ]; then
  echo "DNS servers cannot be empty."
  exit 1
fi

# Convert comma-separated DNS servers to YAML array format
dns_array=$(echo "$dns_servers" | sed 's/,/ - /g' | sed 's/^/ - /')

# Define Netplan configuration file
netplan_file="/etc/netplan/01-netcfg.yaml"

# Backup existing Netplan file if it exists
if [ -f "$netplan_file" ]; then
  cp "$netplan_file" "$netplan_file.bak"
  echo "Backed up existing $netplan_file to $netplan_file.bak"
fi

# Write new Netplan configuration
cat > "$netplan_file" <<EOL
network:
  version: 2
  ethernets:
    $interface:
      addresses:
        - $ip_address
      nameservers:
        addresses:
$dns_array
      dhcp4: no
      routes:
        - to: default
          via: $gateway
EOL

# Set correct permissions
chmod 600 "$netplan_file"
echo "Set permissions for $netplan_file to 600"

# Flush existing IPs to avoid conflicts
ip addr flush dev "$interface"
echo "Flushed existing IPs on $interface"

# Apply Netplan configuration
netplan apply
if [ $? -eq 0 ]; then
  echo "Netplan configuration applied successfully."
else
  echo "Failed to apply Netplan configuration. Check $netplan_file for errors."
  exit 1
fi

# Verify IP configuration
echo "Verifying IP configuration..."
ip a show "$interface"

# Verify gateway
echo "Verifying gateway..."
ip route | grep default

# Verify DNS
echo "Verifying DNS..."
cat /etc/resolv.conf

echo "Configuration complete. Test connectivity with 'ping 8.8.8.8' or 'ping google.com'."