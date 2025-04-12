#!/bin/bash

# Automated script to permanently mount SMB shares on Ubuntu with user-specified ownership

# Exit on errors
set -e

# Function to check if sudo is available
check_sudo() {
    if ! command -v sudo &>/dev/null; then
        echo "Error: sudo is required but not installed."
        exit 1
    fi
}

# Function to install cifs-utils
install_cifs_utils() {
    echo "Checking for cifs-utils..."
    if ! dpkg -l | grep -q cifs-utils; then
        echo "Installing cifs-utils..."
        sudo apt-get update
        sudo apt-get install -y cifs-utils
    else
        echo "cifs-utils is already installed."
    fi
}

# Function to prompt for SMB details and mount user
prompt_smb_details() {
    read -e -p "Enter SMB server and share (e.g., //192.168.1.100/share): " SMB_SHARE
    read -e -p "Enter SMB username: " SMB_USER
    read -e -s -p "Enter SMB password: " SMB_PASS
    echo
    read -e -p "Enter local mount point (e.g., /mnt/smb_share): " MOUNT_POINT
    read -e -p "Enter the user to own the mount (e.g., osi): " MOUNT_USER
}

# Function to validate inputs
validate_inputs() {
    if [[ -z "$SMB_SHARE" || -z "$SMB_USER" || -z "$SMB_PASS" || -z "$MOUNT_POINT" || -z "$MOUNT_USER" ]]; then
        echo "Error: All inputs are required."
        exit 1
    fi
    if [[ ! "$SMB_SHARE" =~ ^//[0-9a-zA-Z.-]+/[0-9a-zA-Z._-]+$ ]]; then
        echo "Error: Invalid SMB share format. Use //server/share."
        exit 1
    fi
    # Validate mount user exists
    if ! id "$MOUNT_USER" &>/dev/null; then
        echo "Error: User '$MOUNT_USER' does not exist on this system."
        exit 1
    fi
}

# Function to get UID and GID for the specified user
get_user_ids() {
    MOUNT_UID=$(id -u "$MOUNT_USER")
    MOUNT_GID=$(id -g "$MOUNT_USER")
    echo "Using UID=$MOUNT_UID and GID=$MOUNT_GID for user '$MOUNT_USER'."
}

# Function to create credentials file
setup_credentials() {
    CREDS_FILE="/etc/smb_credentials"
    echo "Setting up credentials file at $CREDS_FILE..."
    if [[ ! -f "$CREDS_FILE" ]]; then
        sudo bash -c "cat > $CREDS_FILE" <<EOF
username=$SMB_USER
password=$SMB_PASS
EOF
        sudo chmod 600 "$CREDS_FILE"
        echo "Credentials file created."
    else
        echo "Credentials file already exists. Skipping."
    fi
}

# Function to create mount point
create_mount_point() {
    echo "Creating mount point at $MOUNT_POINT..."
    if [[ ! -d "$MOUNT_POINT" ]]; then
        sudo mkdir -p "$MOUNT_POINT"
        sudo chmod 755 "$MOUNT_POINT"
        echo "Mount point created."
    else
        echo "Mount point already exists."
    fi
}

# Function to update /etc/fstab
update_fstab() {
    FSTAB_ENTRY="$SMB_SHARE $MOUNT_POINT cifs credentials=/etc/smb_credentials,uid=$MOUNT_UID,gid=$MOUNT_GID,file_mode=0755,dir_mode=0755,vers=3.0,nofail 0 0"
    echo "Checking /etc/fstab for existing entry..."
    if ! grep -q "$SMB_SHARE $MOUNT_POINT" /etc/fstab; then
        echo "Adding entry to /etc/fstab..."
        echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
    else
        echo "fstab entry already exists. Skipping."
    fi
}

# Function to test mount
test_mount() {
    echo "Testing mount..."
    sudo mount -a
    if mount | grep -q "$MOUNT_POINT"; then
        echo "Mount successful! SMB share is mounted at $MOUNT_POINT."
    else
        echo "Error: Mount failed. Check SMB share details or network connectivity."
        exit 1
    fi
}

# Main execution
echo "Starting SMB mount setup..."

check_sudo
install_cifs_utils
prompt_smb_details
validate_inputs
get_user_ids
setup_credentials
create_mount_point
update_fstab
test_mount

echo "Setup complete! SMB share will mount automatically on boot for user '$MOUNT_USER'."
