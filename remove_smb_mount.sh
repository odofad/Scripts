#!/bin/bash

# Script to remove a user-selected SMB mount from Ubuntu

# Exit on errors
set -e

# Function to check if sudo is available
check_sudo() {
    if ! command -v sudo &>/dev/null; then
        echo "Error: sudo is required but not installed."
        exit 1
    fi
}

# Function to list SMB mounts from /etc/fstab
list_smb_mounts() {
    echo "Fetching SMB mounts from /etc/fstab..."
    MOUNTS=()
    MOUNT_LINES=()
    INDEX=1
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^# ]] || [[ -z "$line" ]] && continue
        # Check for cifs mounts
        if echo "$line" | grep -q "cifs"; then
            SHARE=$(echo "$line" | awk '{print $1}')
            MOUNT_POINT=$(echo "$line" | awk '{print $2}')
            echo "$INDEX. $SHARE on $MOUNT_POINT"
            MOUNTS+=("$MOUNT_POINT")
            MOUNT_LINES+=("$line")
            ((INDEX++))
        fi
    done < /etc/fstab
    if [ ${#MOUNTS[@]} -eq 0 ]; then
        echo "No SMB mounts found in /etc/fstab."
        exit 1
    fi
}

# Function to prompt user for mount selection
prompt_mount_selection() {
    read -p "Enter the number of the mount to remove (1-${#MOUNTS[@]}): " SELECTED
    if ! [[ "$SELECTED" =~ ^[0-9]+$ ]] || [ "$SELECTED" -lt 1 ] || [ "$SELECTED" -gt ${#MOUNTS[@]} ]; then
        echo "Error: Invalid selection. Please enter a number between 1 and ${#MOUNTS[@]}."
        exit 1
    fi
    SELECTED_MOUNT=${MOUNTS[$((SELECTED-1))]}
    SELECTED_LINE=${MOUNT_LINES[$((SELECTED-1))]}
    SELECTED_SHARE=$(echo "$SELECTED_LINE" | awk '{print $1}')
    echo "Selected: $SELECTED_SHARE on $SELECTED_MOUNT"
}

# Function to extract credentials file from fstab line
get_credentials_file() {
    CREDS_FILE=$(echo "$SELECTED_LINE" | grep -o "credentials=[^, ]*" | cut -d'=' -f2)
    if [ -z "$CREDS_FILE" ]; then
        echo "No credentials file specified in fstab entry."
    else
        echo "Credentials file: $CREDS_FILE"
    fi
}

# Function to check if credentials file is used by other mounts
is_creds_file_used() {
    if [ -z "$CREDS_FILE" ]; then
        return 1
    fi
    grep -v "^#" /etc/fstab | grep -v "$SELECTED_LINE" | grep -q "credentials=$CREDS_FILE"
}

# Function to back up /etc/fstab
backup_fstab() {
    echo "Backing up /etc/fstab to /etc/fstab.bak..."
    sudo cp /etc/fstab /etc/fstab.bak
}

# Function to remove fstab entry
remove_fstab_entry() {
    echo "Removing fstab entry for $SELECTED_SHARE on $SELECTED_MOUNT..."
    # Create temporary fstab without the selected line
    sudo grep -v "$SELECTED_LINE" /etc/fstab > /tmp/fstab.tmp
    sudo mv /tmp/fstab.tmp /etc/fstab
    echo "fstab entry removed."
}

# Function to unmount the share
unmount_share() {
    if mount | grep -q "$SELECTED_MOUNT"; then
        echo "Unmounting $SELECTED_MOUNT..."
        sudo umount "$SELECTED_MOUNT"
        if mount | grep -q "$SELECTED_MOUNT"; then
            echo "Warning: Failed to unmount $SELECTED_MOUNT. It may be in use."
        else
            echo "Unmount successful."
        fi
    else
        echo "$SELECTED_MOUNT is not currently mounted."
    fi
}

# Function to clean up credentials file
cleanup_credentials() {
    if [ -n "$CREDS_FILE" ] && [ -f "$CREDS_FILE" ]; then
        if is_creds_file_used; then
            echo "Credentials file $CREDS_FILE is used by other mounts. Keeping it."
        else
            read -p "Remove credentials file $CREDS_FILE? (y/N): " REMOVE_CREDS
            if [[ "$REMOVE_CREDS" =~ ^[Yy]$ ]]; then
                echo "Removing credentials file $CREDS_FILE..."
                sudo rm "$CREDS_FILE"
                echo "Credentials file removed."
            else
                echo "Keeping credentials file $CREDS_FILE."
            fi
        fi
    fi
}

# Main execution
echo "Starting SMB mount removal..."

check_sudo
list_smb_mounts
prompt_mount_selection
get_credentials_file
backup_fstab
unmount_share
remove_fstab_entry
cleanup_credentials

echo "Removal complete! The SMB mount $SELECTED_SHARE on $SELECTED_MOUNT has been removed."
echo "It will no longer mount automatically on boot."
