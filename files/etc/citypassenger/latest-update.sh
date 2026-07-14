key=$(uci get citypassenger.@device[0].key)
secret=$(uci get citypassenger.@device[0].secret)
api_domain=$(uci get citypassenger.@device[0].api_domain)
api="$api_domain/api/devices/$key/$secret/settings"
response=$(curl -s "$api")
echo $api
echo $response

# Remove exit 0 to enable production mode

# Function to ensure bridge interfaces are properly configured
ensure_bridge_configuration() {
    echo "Ensuring bridge interfaces are properly configured..."

    # Wait a moment for network restart to complete
    sleep 3
    # Check and configure br-lan
    lan_ip=$(uci get network.lan.ipaddr 2>/dev/null || echo "")
    lan_netmask=$(uci get network.lan.netmask 2>/dev/null || echo "")

    if [ -n "$lan_ip" ] && [ -n "$lan_netmask" ]; then
        # Check if br-lan interface exists and is up
        if ip link show br-lan >/dev/null 2>&1; then
            # Get current state
            br_lan_state=$(ip link show br-lan | grep "state" | awk '{print $9}')
            current_ip=$(ip addr show br-lan | grep "inet " | awk '{print $2}' | cut -d'/' -f1)

            echo "br-lan current state: $br_lan_state, current IP: $current_ip, expected IP: $lan_ip"

            # Bring interface up if it's down
            if [ "$br_lan_state" = "DOWN" ]; then
                echo "Bringing br-lan interface up..."
                ip link set br-lan up
                sleep 1
            fi

            # Assign IP if not present or different
            if [ "$current_ip" != "$lan_ip" ]; then
                echo "Configuring br-lan IP address: $lan_ip/$lan_netmask"
                # Remove any existing IP first
                ip addr flush dev br-lan 2>/dev/null || true
                # Calculate CIDR notation from netmask
                cidr_suffix=""
                case "$lan_netmask" in
                    "255.255.255.0") cidr_suffix="24" ;;
                    "255.255.0.0") cidr_suffix="16" ;;
                    "255.0.0.0") cidr_suffix="8" ;;
                    "255.255.255.128") cidr_suffix="25" ;;
                    "255.255.255.192") cidr_suffix="26" ;;
                    "255.255.255.224") cidr_suffix="27" ;;
                    "255.255.255.240") cidr_suffix="28" ;;
                    "255.255.255.248") cidr_suffix="29" ;;
                    "255.255.255.252") cidr_suffix="30" ;;
                    *) cidr_suffix="24" ;;  # Default fallback
                esac
                ip addr add ${lan_ip}/${cidr_suffix} dev br-lan
                echo "br-lan IP configured: ${lan_ip}/${cidr_suffix}"
            fi
        else
            echo "Warning: br-lan interface not found"
        fi
    fi

    echo "Bridge configuration check completed"
}

# Function to get available physical ports (excluding WAN ports)
get_device_ports() {
    local ports=""

    # Check for various port naming schemes used in different OpenWrt devices
    # Priority order: lan ports, eth ports, then fallback to any available

    # First try lan1-4 naming (common in many switches)
    for port in lan1 lan2 lan3 lan4; do
        if [ -e "/sys/class/net/$port" ]; then
            if ! echo "$port" | grep -q "wan"; then
                if [ -n "$ports" ]; then
                    ports="$ports $port"
                else
                    ports="$port"
                fi
            fi
        fi
    done

    # If no lan ports found, try eth1-4 naming
    if [ -z "$ports" ]; then
        for port in eth1 eth2 eth3 eth4; do
            if [ -e "/sys/class/net/$port" ]; then
                if ! echo "$port" | grep -q "wan"; then
                    if [ -n "$ports" ]; then
                        ports="$ports $port"
                    else
                        ports="$port"
                    fi
                fi
            fi
        done
    fi

    # If still no ports found, check for single 'lan' port (some devices)
    if [ -z "$ports" ]; then
        if [ -e "/sys/class/net/lan" ]; then
            ports="lan"
        fi
    fi

    # If still no ports found, scan for any available ethernet interfaces
    # Skip eth0 (usually CPU port), wan ports, and wireless interfaces
    if [ -z "$ports" ]; then
        for iface in /sys/class/net/*; do
            local port=$(basename "$iface")
            if [ "$port" != "eth0" ] && ! echo "$port" | grep -E "^(wan|wlan|wifi)" >/dev/null; then
                if [ -e "/sys/class/net/$port/operstate" ]; then
                    if [ -n "$ports" ]; then
                        ports="$ports $port"
                    else
                        ports="$port"
                    fi
                fi
            fi
        done
    fi

    echo "$ports"
}

# Function to ensure br-lan device exists with VLAN filtering capability
ensure_br_lan_device() {
    echo "Ensuring br-lan device exists..."

    # Check if br-lan device exists
    local brlan_exists
    brlan_exists=$(uci show network 2>/dev/null | grep "device.*name='br-lan'" | head -1)

    if [ -z "$brlan_exists" ]; then
        echo "Creating br-lan device configuration"
        uci add network device
        uci set "network.@device[-1].name=br-lan"
        uci set "network.@device[-1].type=bridge"

        # Add available ports to br-lan
        local available_ports
        available_ports=$(get_device_ports)

        if [ -n "$available_ports" ]; then
            for port in $available_ports; do
                echo "Adding port $port to br-lan device"
                uci add_list "network.@device[-1].ports=$port"
            done
        fi

        echo "br-lan device created successfully"
    else
        echo "br-lan device already exists"
    fi
}

# Function to remove existing VLAN configurations
cleanup_existing_vlans() {
    echo "Cleaning up existing VLAN configurations..."

    # Simple and reliable approach: remove all bridge-vlan sections
    # Use a while loop to keep removing until none exist
    local removed_count=0
    while true; do
        # Try to delete the first bridge-vlan section found
        if uci delete network.@bridge-vlan[0] 2>/dev/null; then
            removed_count=$((removed_count + 1))
            echo "Removed bridge-vlan section [0] (total removed: $removed_count)"
        else
            # No more sections to remove
            break
        fi
    done

    echo "VLAN cleanup completed - removed $removed_count bridge-vlan sections (not committed yet)"
}

# Function to validate VLAN ID
validate_vlan_id() {
    local vlan_id="$1"

    # Check if it's a number and within valid range (1-4094)
    if [ -n "$vlan_id" ] && [ "$vlan_id" != "null" ]; then
        if echo "$vlan_id" | grep -E '^[0-9]+$' >/dev/null; then
            if [ "$vlan_id" -ge 1 ] && [ "$vlan_id" -le 4094 ]; then
                return 0
            fi
        fi
    fi
    return 1
}

# Function to normalize tagging values to standard format
normalize_tagging_value() {
    local value="$1"
    case "$value" in
        "disabled"|"untagged")
            echo "disabled"
            ;;
        "enabled"|"tagged")
            echo "enabled"
            ;;
        *)
            echo "enabled"  # Default to enabled/tagged for unknown values
            ;;
    esac
}

# Function to determine which network should be untagged based on tagging settings
determine_untagged_preference() {
    local captive_portal_vlan_tagging="$1"
    local password_wifi_vlan_tagging="$2"

    # Normalize the tagging values to handle both "disabled/enabled" and "untagged/tagged"
    local norm_captive_tagging
    local norm_password_tagging
    norm_captive_tagging=$(normalize_tagging_value "$captive_portal_vlan_tagging")
    norm_password_tagging=$(normalize_tagging_value "$password_wifi_vlan_tagging")

    echo "Determining untagged preference:" >&2
    echo "  captive_portal_vlan_tagging: $captive_portal_vlan_tagging (normalized: $norm_captive_tagging)" >&2
    echo "  password_wifi_vlan_tagging: $password_wifi_vlan_tagging (normalized: $norm_password_tagging)" >&2

    # Return values: "lan" = LAN interface gets untagged, "captive" = captive portal gets untagged, "both_tagged" = both tagged

    if [ "$norm_captive_tagging" = "disabled" ] && [ "$norm_password_tagging" = "disabled" ]; then
        # Both disabled - prefer LAN interface for untagged
        echo "  -> Both tagging disabled, preferring LAN interface for untagged" >&2
        echo "lan"
    elif [ "$norm_captive_tagging" = "disabled" ] && [ "$norm_password_tagging" = "enabled" ]; then
        # Only captive portal tagging disabled - captive portal gets untagged
        echo "  -> Only captive portal tagging disabled, captive portal gets untagged" >&2
        echo "captive"
    elif [ "$norm_captive_tagging" = "enabled" ] && [ "$norm_password_tagging" = "disabled" ]; then
        # Only LAN tagging disabled - LAN gets untagged
        echo "  -> Only LAN tagging disabled, LAN gets untagged" >&2
        echo "lan"
    else
        # Both enabled - both tagged
        echo "  -> Both tagging enabled, both networks tagged" >&2
        echo "both_tagged"
    fi
}

# Function to configure bridge VLAN
configure_bridge_vlan() {
    local vlan_id="$1"
    local untagged="$2"  # "true" for untagged (u*), "false" for tagged
    local vlan_name="$3" # Description for logging

    # Validate VLAN ID
    if ! validate_vlan_id "$vlan_id"; then
        echo "ERROR: Invalid VLAN ID '$vlan_id' for $vlan_name"
        return 1
    fi

    echo "Configuring bridge VLAN $vlan_id for $vlan_name (untagged: $untagged)"

    # Add bridge-vlan configuration
    uci add network bridge-vlan
    uci set "network.@bridge-vlan[-1].device=br-lan"
    uci set "network.@bridge-vlan[-1].vlan=$vlan_id"

    # Configure ports
    local available_ports
    available_ports=$(get_device_ports)

    if [ -n "$available_ports" ]; then
        for port in $available_ports; do
            if [ "$untagged" = "true" ]; then
                echo "Adding port $port to VLAN $vlan_id as untagged (u*)"
                uci add_list "network.@bridge-vlan[-1].ports=$port:u*"
            else
                echo "Adding port $port to VLAN $vlan_id as tagged (t)"
                uci add_list "network.@bridge-vlan[-1].ports=$port:t"
            fi
        done
    else
        echo "No physical ports found for VLAN configuration"
    fi
}

# Function to cleanup old br-network1 configurations
cleanup_old_bridge_configs() {
    echo "Cleaning up old br-network1 configurations..."

    # Remove old br-network1 device if it exists
    local old_brnet1_section
    old_brnet1_section=$(uci show network 2>/dev/null | grep "device.*name='br-network1'" | cut -d'=' -f1 | cut -d'.' -f2 | head -1)

    if [ -n "$old_brnet1_section" ]; then
        echo "Removing old br-network1 device section: $old_brnet1_section"
        uci delete "network.$old_brnet1_section" 2>/dev/null
    fi

    # Clean up any old bridge configurations from network1 interface
    uci delete "network.network1.type" 2>/dev/null || true
    uci delete "network.network1.ifname" 2>/dev/null || true
    uci delete "network.network1.ports" 2>/dev/null || true

    echo "Old bridge configuration cleanup completed"
}

# Function to configure network interfaces with VLAN support
#
# VLAN Configuration Overview:
# ============================
# This function handles multiple scenarios:
#
# 1. VLAN Filtering ENABLED (vlan_enabled=true):
#    - Creates proper VLAN separation with vlan_filtering=1
#    - Configures bridge-vlan sections with :t (tagged) and :u* (untagged) ports
#    - Uses API-provided VLAN IDs or defaults (LAN=10, Captive=1)
#    - Applies tagging preferences based on API settings
#
# 2. VLAN Filtering DISABLED (vlan_enabled=false):
#    - Sets vlan_filtering=0 (bridge acts as regular bridge)
#    - Still creates VLAN interfaces for organizational purposes
#    - All traffic flows between all ports regardless of VLAN tags
#    - Useful for testing or when hardware doesn't support VLAN filtering
#
# 3. Port Naming Compatibility:
#    - Handles various port naming schemes: lan1-4, eth1-4, single 'lan', mixed
#    - Automatically detects available ports on the device
#    - Skips WAN ports and wireless interfaces
#
# 4. Tagging Preferences:
#    - Both disabled: LAN gets untagged (u*), captive gets tagged (t)
#    - Only captive disabled: Captive gets untagged (u*), LAN gets tagged (t)
#    - Only LAN disabled: LAN gets untagged (u*), captive gets tagged (t)
#    - Both enabled: Both networks get tagged (t)
#
# 5. Error Handling:
#    - Invalid VLAN configurations fall back to basic bridge mode
#    - Validates VLAN IDs (1-4094 range)
#    - Handles null/empty API values with sensible defaults
#
configure_vlan_interfaces() {
    local vlan_enabled="$1"
    local captive_portal_vlan="$2"
    local password_wifi_vlan="$3"
    local password_wifi_ip="$4"
    local password_wifi_netmask="$5"
    local captive_portal_ip="$6"
    local captive_portal_netmask="$7"
    local captive_portal_vlan_tagging="$8"
    local password_wifi_vlan_tagging="$9"

    echo "Configuring VLAN interfaces..."
    echo "vlan_enabled: $vlan_enabled"
    echo "captive_portal_vlan: $captive_portal_vlan"
    echo "password_wifi_vlan: $password_wifi_vlan"
    echo "captive_portal_vlan_tagging: $captive_portal_vlan_tagging"
    echo "password_wifi_vlan_tagging: $password_wifi_vlan_tagging"

    # Clean up old configurations first
    cleanup_old_bridge_configs

    # Clean up existing VLAN configurations
    cleanup_existing_vlans

    if [ "$vlan_enabled" = "true" ]; then
        # VLAN mode enabled
        echo "VLAN mode enabled - configuring VLANs based on API values and tagging preferences"

        # Configure VLAN filtering
        configure_vlan_filtering "true"

        # Determine untagged preference based on tagging settings
        local untagged_preference
        untagged_preference=$(determine_untagged_preference "$captive_portal_vlan_tagging" "$password_wifi_vlan_tagging")

        # Set default VLAN IDs if not specified
        local effective_password_wifi_vlan="$password_wifi_vlan"
        local effective_captive_portal_vlan="$captive_portal_vlan"

        if [ "$effective_password_wifi_vlan" = "null" ] || [ -z "$effective_password_wifi_vlan" ]; then
            effective_password_wifi_vlan="10"
        fi

        if [ "$effective_captive_portal_vlan" = "null" ] || [ -z "$effective_captive_portal_vlan" ]; then
            effective_captive_portal_vlan="1"
        fi

        echo "Effective VLAN IDs: Password WiFi VLAN $effective_password_wifi_vlan, Captive Portal VLAN $effective_captive_portal_vlan"
        echo "Untagged preference: $untagged_preference"

        # Configure VLANs based on tagging preference
        if [ "$untagged_preference" = "lan" ]; then
            # LAN interface gets untagged, captive portal gets tagged
            echo "Configuring LAN interface as untagged (u*), captive portal as tagged"

            if validate_vlan_id "$effective_password_wifi_vlan" && validate_vlan_id "$effective_captive_portal_vlan"; then
                if configure_bridge_vlan "$effective_password_wifi_vlan" "true" "Password WiFi (untagged)" && \
                   configure_bridge_vlan "$effective_captive_portal_vlan" "false" "Captive Portal (tagged)"; then
                    uci set "network.lan.device=br-lan.$effective_password_wifi_vlan"
                    uci set "network.network1.device=br-lan.$effective_captive_portal_vlan"
                else
                    echo "ERROR: Failed to configure VLANs, falling back to defaults"
                    configure_bridge_vlan "10" "true" "Password WiFi (fallback)"
                    configure_bridge_vlan "1" "false" "Captive Portal (fallback)"
                    uci set "network.lan.device=br-lan.10"
                    uci set "network.network1.device=br-lan.1"
                fi
            else
                echo "ERROR: Invalid VLAN IDs, using defaults"
                configure_bridge_vlan "10" "true" "Password WiFi (fallback)"
                configure_bridge_vlan "1" "false" "Captive Portal (fallback)"
                uci set "network.lan.device=br-lan.10"
                uci set "network.network1.device=br-lan.1"
            fi

        elif [ "$untagged_preference" = "captive" ]; then
            # Captive portal gets untagged, LAN interface gets tagged
            echo "Configuring captive portal as untagged (u*), LAN interface as tagged"

            if validate_vlan_id "$effective_password_wifi_vlan" && validate_vlan_id "$effective_captive_portal_vlan"; then
                if configure_bridge_vlan "$effective_password_wifi_vlan" "false" "Password WiFi (tagged)" && \
                   configure_bridge_vlan "$effective_captive_portal_vlan" "true" "Captive Portal (untagged)"; then
                    uci set "network.lan.device=br-lan.$effective_password_wifi_vlan"
                    uci set "network.network1.device=br-lan.$effective_captive_portal_vlan"
                else
                    echo "ERROR: Failed to configure VLANs, falling back to defaults"
                    configure_bridge_vlan "10" "false" "Password WiFi (fallback)"
                    configure_bridge_vlan "1" "true" "Captive Portal (fallback)"
                    uci set "network.lan.device=br-lan.10"
                    uci set "network.network1.device=br-lan.1"
                fi
            else
                echo "ERROR: Invalid VLAN IDs, using defaults"
                configure_bridge_vlan "10" "false" "Password WiFi (fallback)"
                configure_bridge_vlan "1" "true" "Captive Portal (fallback)"
                uci set "network.lan.device=br-lan.10"
                uci set "network.network1.device=br-lan.1"
            fi

        else
            # Both tagged
            echo "Configuring both networks as tagged"

            if validate_vlan_id "$effective_password_wifi_vlan" && validate_vlan_id "$effective_captive_portal_vlan"; then
                if configure_bridge_vlan "$effective_password_wifi_vlan" "false" "Password WiFi (tagged)" && \
                   configure_bridge_vlan "$effective_captive_portal_vlan" "false" "Captive Portal (tagged)"; then
                    uci set "network.lan.device=br-lan.$effective_password_wifi_vlan"
                    uci set "network.network1.device=br-lan.$effective_captive_portal_vlan"
                else
                    echo "ERROR: Failed to configure VLANs, falling back to defaults"
                    configure_bridge_vlan "10" "false" "Password WiFi (fallback)"
                    configure_bridge_vlan "1" "false" "Captive Portal (fallback)"
                    uci set "network.lan.device=br-lan.10"
                    uci set "network.network1.device=br-lan.1"
                fi
            else
                echo "ERROR: Invalid VLAN IDs, using defaults"
                configure_bridge_vlan "10" "false" "Password WiFi (fallback)"
                configure_bridge_vlan "1" "false" "Captive Portal (fallback)"
                uci set "network.lan.device=br-lan.10"
                uci set "network.network1.device=br-lan.1"
            fi
        fi
    else
        # VLAN mode disabled - use default configuration with VLAN filtering enabled
        echo "VLAN mode disabled - using default VLAN configuration with filtering enabled"

        # Keep VLAN filtering enabled even when VLAN mode is disabled
        # This provides network separation with default VLAN settings
        configure_vlan_filtering "true"

        # Determine untagged preference even in non-VLAN mode
        local untagged_preference
        untagged_preference=$(determine_untagged_preference "$captive_portal_vlan_tagging" "$password_wifi_vlan_tagging")

        # Configure default VLANs based on tagging preference
        # Use standard default VLANs: 10 for LAN, 1 for captive portal
        if [ "$untagged_preference" = "captive" ]; then
            # Captive portal gets untagged, LAN gets tagged
            echo "Default VLAN mode: Captive portal untagged (u*), LAN tagged"
            configure_bridge_vlan "10" "false" "Password WiFi (default, tagged)"
            configure_bridge_vlan "1" "true" "Captive Portal (default, untagged)"
        else
            # Default: LAN gets untagged, captive portal gets tagged (covers "lan" and "both_tagged" cases)
            echo "Default VLAN mode: LAN untagged (u*), captive portal tagged"
            configure_bridge_vlan "10" "true" "Password WiFi (default, untagged)"
            configure_bridge_vlan "1" "false" "Captive Portal (default, tagged)"
        fi

        # Configure interfaces with default VLAN assignments
        uci set "network.lan.device=br-lan.10"
        uci set "network.network1.device=br-lan.1"
    fi

    # Ensure basic interface configuration
    uci set "network.lan.proto=static"
    uci set "network.lan.ipaddr=$password_wifi_ip"
    uci set "network.lan.netmask=$password_wifi_netmask"

    uci set "network.network1.proto=static"
    uci set "network.network1.ipaddr=$captive_portal_ip"
    uci set "network.network1.netmask=$captive_portal_netmask"

    # Remove any old br-network1 configurations
    uci delete "network.network1.ifname" 2>/dev/null || true
    uci delete "network.network1.type" 2>/dev/null || true

    # Commit network changes
    uci commit network

    echo "VLAN interface configuration completed"
}

# Function to configure VLAN filtering on br-lan
configure_vlan_filtering() {
    local vlan_enabled="$1"

    echo "Configuring VLAN filtering: vlan_enabled=$vlan_enabled"

    # Ensure br-lan device exists
    ensure_br_lan_device

    # Find the br-lan device section
    local brlan_section
    brlan_section=$(uci show network 2>/dev/null | grep "device.*name='br-lan'" | cut -d'=' -f1 | cut -d'.' -f2 | head -1)

    if [ -n "$brlan_section" ]; then
        if [ "$vlan_enabled" = "true" ]; then
            echo "Enabling VLAN filtering on br-lan device"
            uci set "network.$brlan_section.vlan_filtering=1"
        else
            echo "Disabling VLAN filtering on br-lan device"
            uci set "network.$brlan_section.vlan_filtering=0"
        fi
        # DON'T commit here - let the calling function handle it
        echo "VLAN filtering configured (not committed yet)"
    else
        echo "ERROR: Could not find br-lan device section"
        return 1
    fi
}

# PRODUCTION MODE - UCI changes and service restarts enabled
echo "=================================="
echo "PRODUCTION MODE: Making actual changes"
echo "=================================="
status=$(echo "$response" | jq -r '.status')

if [ "$status" = "success" ]; then
    wifi_name=$(echo "$response" | jq -r '.settings.wifi_name')
    wifi_password=$(echo "$response" | jq -r '.settings.wifi_password')
    captive_portal_ssid=$(echo "$response" | jq -r '.settings.captive_portal_ssid')
    wifi_visible=$(echo "$response" | jq -r '.settings.wifi_visible')
    captive_portal_visible=$(echo "$response" | jq -r '.settings.captive_portal_visible')
    #captive_portal_whitelist_servers=$(echo "$response" | jq -r '.guest_settings.whitelist_servers')
    #captive_portal_whitelist_domains=$(echo "$response" | jq -r '.guest_settings.whitelist_domains')
    captive_portal_ip=$(echo "$response" | jq -r '.settings.captive_portal_ip')
    captive_portal_ip_base=$(echo "$captive_portal_ip" | cut -d. -f1-3)
    chilli_ip="$captive_portal_ip_base.0/24"
    echo "DEBUG: Calculated chilli_ip from captive_portal_ip '$captive_portal_ip' -> base: '$captive_portal_ip_base' -> chilli_ip: '$chilli_ip'"
    captive_portal_netmask=$(echo "$response" | jq -r '.settings.captive_portal_netmask')
    captive_portal_dns1=$(echo "$response" | jq -r '.settings.captive_portal_dns1')
    captive_portal_dns2=$(echo "$response" | jq -r '.settings.captive_portal_dns2')
    captive_portal_dhcp_start=$(echo "$response" | jq -r '.settings.captive_portal_dhcp_start')
    captive_dhcp_start_octet=$(echo "$captive_portal_dhcp_start" | awk -F'.' '{print $4}')
    captive_portal_dhcp_end=$(echo "$response" | jq -r '.settings.captive_portal_dhcp_end')
    captive_dhcp_end_octet=$(echo "$captive_portal_dhcp_end" | awk -F'.' '{print $4}')
    password_wifi_ip=$(echo "$response" | jq -r '.settings.password_wifi_ip')
    password_wifi_netmask=$(echo "$response" | jq -r '.settings.password_wifi_netmask')

    # Extract VLAN-related settings
    vlan_enabled=$(echo "$response" | jq -r '.settings.vlan_enabled // false')
    captive_portal_vlan=$(echo "$response" | jq -r '.settings.captive_portal_vlan // null')
    password_wifi_vlan=$(echo "$response" | jq -r '.settings.password_wifi_vlan // null')
    captive_portal_vlan_tagging=$(echo "$response" | jq -r '.settings.captive_portal_vlan_tagging // "enabled"')
    password_wifi_vlan_tagging=$(echo "$response" | jq -r '.settings.password_wifi_vlan_tagging // "enabled"')

    echo "VLAN Configuration from API:"
    echo "  vlan_enabled: $vlan_enabled"
    echo "  captive_portal_vlan: $captive_portal_vlan"
    echo "  password_wifi_vlan: $password_wifi_vlan"
    echo "  captive_portal_vlan_tagging: $captive_portal_vlan_tagging"
    echo "  password_wifi_vlan_tagging: $password_wifi_vlan_tagging"
    password_wifi_ip_mode=$(echo "$response" | jq -r '.settings.password_wifi_ip_mode')
    password_wifi_dns1=$(echo "$response" | jq -r '.settings.password_wifi_dns1')
    password_wifi_dns2=$(echo "$response" | jq -r '.settings.password_wifi_dns2')
    password_wifi_dhcp_start=$(echo "$response" | jq -r '.settings.password_wifi_dhcp_start')
    echo "Raw DHCP start: $password_wifi_dhcp_start"
    password_wifi_dhcp_start_octet=$(echo "$password_wifi_dhcp_start" | awk -F'.' '{print $4}')
    echo "Start octet: $password_wifi_dhcp_start_octet"

    password_wifi_dhcp_end=$(echo "$response" | jq -r '.settings.password_wifi_dhcp_end')
    echo "Raw DHCP end: $password_wifi_dhcp_end"
    password_wifi_dhcp_end_octet=$(echo "$password_wifi_dhcp_end" | awk -F'.' '{print $4}')
    echo "End octet: $password_wifi_dhcp_end_octet"

    # Calculate the limit safely
    if [[ "$password_wifi_dhcp_start_octet" =~ ^[0-9]+$ ]] && [[ "$password_wifi_dhcp_end_octet" =~ ^[0-9]+$ ]]; then
        password_wifi_dhcp_limit=$((password_wifi_dhcp_end_octet - password_wifi_dhcp_start_octet + 1))
        echo "Calculated limit: $password_wifi_dhcp_limit"
    else
        echo "Error: Invalid DHCP octets, cannot calculate limit"
        password_wifi_dhcp_limit=0
    fi

    # Extract radio configuration from API response
    country_code=$(echo "$response" | jq -r '.settings.country_code')
    transmit_power_2g=$(echo "$response" | jq -r '.settings.transmit_power_2g')
    transmit_power_5g=$(echo "$response" | jq -r '.settings.transmit_power_5g')
    channel_2g=$(echo "$response" | jq -r '.settings.channel_2g')
    channel_5g=$(echo "$response" | jq -r '.settings.channel_5g')
    channel_width_2g=$(echo "$response" | jq -r '.settings.channel_width_2g')
    channel_width_5g=$(echo "$response" | jq -r '.settings.channel_width_5g')

    echo "API Radio Settings:"
    echo "Country: $country_code"
    echo "2.4GHz - Channel: $channel_2g, Width: ${channel_width_2g}MHz, Power: ${transmit_power_2g}dBm"
    echo "5GHz - Channel: $channel_5g, Width: ${channel_width_5g}MHz, Power: ${transmit_power_5g}dBm"

    # Get current SSIDs and passwords
    current_ssid_radio1=$(uci get wireless.default_radio1.ssid)
    current_ssid_radio0=$(uci get wireless.default_radio0.ssid)
    current_captive_ssid_radio0=$(uci get wireless.captive_radio0.ssid)
    current_captive_ssid_radio1=$(uci get wireless.captive_radio1.ssid)
    current_password_radio1=$(uci get wireless.default_radio1.key)
    current_password_radio0=$(uci get wireless.default_radio0.key)
    current_captive_portal_ip=$(uci get network.network1.ipaddr)
    current_chilli_ip=$(uci get chilli.@chilli[0].net)
    current_captive_portal_netmask=$(uci get network.network1.netmask)
    current_captive_portal_dns1=$(uci get network.network1.dns | awk '{print$1}')
    current_captive_portal_dns2=$(uci get network.network1.dns | awk '{print$2}')
    current_password_wifi_ip=$(uci get network.lan.ipaddr)
    current_password_wifi_netmask=$(uci get network.lan.netmask)
    current_password_wifi_dns1=$(uci get network.lan.dns | awk '{print$1}')
    current_password_wifi_dns2=$(uci get network.lan.dns | awk '{print$2}')
    current_captive_portal_dhcp_start=$(uci get chilli.@chilli[0].dhcpstart)
    current_captive_portal_dhcp_end=$(uci get chilli.@chilli[0].dhcpend)
    current_password_wifi_dhcp_start=$(uci get dhcp.lan.start)
    current_password_wifi_dhcp_end=$(uci get dhcp.lan.limit)

    # Get current visibility settings
    current_wifi_hidden_radio0=$(uci get wireless.default_radio0.hidden)
    current_wifi_hidden_radio1=$(uci get wireless.default_radio1.hidden)
    current_captive_hidden_radio0=$(uci get wireless.captive_radio0.hidden)
    current_captive_hidden_radio1=$(uci get wireless.captive_radio1.hidden)

    # Get current radio configuration
    current_country_radio0=$(uci get wireless.radio0.country)
    current_country_radio1=$(uci get wireless.radio1.country)
    current_channel_radio0=$(uci get wireless.radio0.channel)
    current_channel_radio1=$(uci get wireless.radio1.channel)
    current_htmode_radio0=$(uci get wireless.radio0.htmode)
    current_htmode_radio1=$(uci get wireless.radio1.htmode)
    current_txpower_radio0=$(uci get wireless.radio0.txpower 2>/dev/null || echo "")
    current_txpower_radio1=$(uci get wireless.radio1.txpower 2>/dev/null || echo "")

    echo "Current Radio Settings:"
    echo "Country - Radio0: $current_country_radio0, Radio1: $current_country_radio1"
    echo "2.4GHz - Channel: $current_channel_radio0, HTMode: $current_htmode_radio0, Power: $current_txpower_radio0"
    echo "5GHz - Channel: $current_channel_radio1, HTMode: $current_htmode_radio1, Power: $current_txpower_radio1"
    # Initialize change flags
    ssid_changed=false
    captive_ssid_changed=false
    password_changed=false
    chilli_changed=false
    visibility_changed=false
    radio_changed=false
    captive_portal_ip_changed=false
    captive_portal_netmask_changed=false
    captive_portal_dns1_changed=false
    captive_portal_dns2_changed=false
    captive_portal_dhcp_start_changed=false
    captive_portal_dhcp_end_changed=false
    password_wifi_ip_changed=false
    password_wifi_netmask_changed=false
    password_wifi_dns1_changed=false
    password_wifi_dns2_changed=false
    password_wifi_dhcp_start_changed=false
    password_wifi_dhcp_end_changed=false
    dhcp_changed=false
    network_changed=false
    mac_filter_changed=false
    # Check and update regular WiFi visibility if it has changed
    if [ "$wifi_visible" = "1" ]; then
        # Enable regular WiFi networks
        if [ "$current_wifi_hidden_radio0" != "0" ]; then
            uci set wireless.default_radio0.hidden=0
            visibility_changed=true
        fi
        if [ "$current_wifi_hidden_radio1" != "0" ]; then
            uci set wireless.default_radio1.hidden=0
            visibility_changed=true
        fi
    elif [ "$wifi_visible" = "0" ]; then
        # Disable regular WiFi networks
        if [ "$current_wifi_hidden_radio0" != "1" ]; then
            uci set wireless.default_radio0.hidden=1
            visibility_changed=true
        fi
        if [ "$current_wifi_hidden_radio1" != "1" ]; then
            uci set wireless.default_radio1.hidden=1
            visibility_changed=true
        fi
    fi

    # Check and update captive portal visibility if it has changed
    if [ "$captive_portal_visible" = "1" ]; then
        # Enable captive portal networks
        if [ "$current_captive_hidden_radio0" != "0" ]; then
            uci set wireless.captive_radio0.hidden=0
            visibility_changed=true
        fi
        if [ "$current_captive_hidden_radio1" != "0" ]; then
            uci set wireless.captive_radio1.hidden=0
            visibility_changed=true
        fi
    elif [ "$captive_portal_visible" = "0" ]; then
        # Disable captive portal networks
        if [ "$current_captive_hidden_radio0" != "1" ]; then
            uci set wireless.captive_radio0.hidden=1
            visibility_changed=true
        fi
        if [ "$current_captive_hidden_radio1" != "1" ]; then
            uci set wireless.captive_radio1.hidden=1
            visibility_changed=true
        fi
    fi

    # Check and update SSIDs if they have changed
    if [ "$wifi_name" != "" ] && [ "$wifi_name" != "null" ]; then
        if [ "$current_ssid_radio1" != "$wifi_name" ]; then
            uci set wireless.default_radio1.ssid="$wifi_name"
            ssid_changed=true
        fi

        if [ "$current_ssid_radio0" != "$wifi_name" ]; then
            uci set wireless.default_radio0.ssid="$wifi_name"
            ssid_changed=true
        fi
    else
        echo "Error: WiFi SSID is null or empty, not updating"
    fi

    if [ "$captive_portal_ssid" != "" ] && [ "$captive_portal_ssid" != "null" ]; then
        if [ "$current_captive_ssid_radio0" != "$captive_portal_ssid" ]; then
            echo "Updating captive portal SSID from $current_captive_ssid_radio0 to $captive_portal_ssid"
            uci set wireless.captive_radio0.ssid="$captive_portal_ssid"
            ssid_changed=true
            captive_ssid_changed=true
        fi

        if [ "$current_captive_ssid_radio1" != "$captive_portal_ssid" ]; then
            echo "Updating captive portal SSID from $current_captive_ssid_radio1 to $captive_portal_ssid"
            uci set wireless.captive_radio1.ssid="$captive_portal_ssid"
            ssid_changed=true
            captive_ssid_changed=true
        fi
    else
        echo "Error: Captive portal SSID is null or empty, not updating"
    fi

    # Check and update WiFi passwords if they have changed
    if [ "$wifi_password" != "" ] && [ "$wifi_password" != "null" ] && [ ${#wifi_password} -ge 8 ]; then
        if [ "$current_password_radio1" != "$wifi_password" ]; then
            echo "Updating WiFi password from $current_password_radio1 to $wifi_password"
            uci set wireless.default_radio1.key="$wifi_password"
            password_changed=true
        fi

        if [ "$current_password_radio0" != "$wifi_password" ]; then
            echo "Updating WiFi password from $current_password_radio0 to $wifi_password"
            uci set wireless.default_radio0.key="$wifi_password"
            password_changed=true
        fi
    else
        echo "Error: WiFi password is null, empty, or less than 8 characters, not updating"
    fi

    # Function to convert channel width to htmode
    get_htmode() {
        local band=$1
        local width=$2

        if [ "$width" = "20" ]; then
            echo "HE20"
        elif [ "$width" = "40" ]; then
            echo "HE40"
        elif [ "$width" = "80" ] && [ "$band" = "5g" ]; then
            echo "HE80"
        elif [ "$width" = "160" ] && [ "$band" = "5g" ]; then
            echo "HE160"
        else
            # Default fallback
            if [ "$band" = "2g" ]; then
                echo "HE40"
            else
                echo "HE80"
            fi
        fi
    }

    # Check and update country code for both radios
    if [ "$country_code" != "" ] && [ "$country_code" != "null" ]; then
        if [ "$current_country_radio0" != "$country_code" ]; then
            echo "Updating radio0 country from $current_country_radio0 to $country_code"
            uci set wireless.radio0.country="$country_code"
            radio_changed=true
        fi

        if [ "$current_country_radio1" != "$country_code" ]; then
            echo "Updating radio1 country from $current_country_radio1 to $country_code"
            uci set wireless.radio1.country="$country_code"
            radio_changed=true
        fi
    fi

    # Check and update 2.4GHz radio settings
    if [ "$channel_2g" != "" ] && [ "$channel_2g" != "null" ]; then
        if [ "$current_channel_radio0" != "$channel_2g" ]; then
            echo "Updating 2.4GHz channel from $current_channel_radio0 to $channel_2g"
            uci set wireless.radio0.channel="$channel_2g"
            radio_changed=true
            network_changed=true
        fi
    fi

    if [ "$channel_width_2g" != "" ] && [ "$channel_width_2g" != "null" ]; then
        new_htmode_2g=$(get_htmode "2g" "$channel_width_2g")
        if [ "$current_htmode_radio0" != "$new_htmode_2g" ]; then
            echo "Updating 2.4GHz channel width from $current_htmode_radio0 to $new_htmode_2g (${channel_width_2g}MHz)"
            uci set wireless.radio0.htmode="$new_htmode_2g"
            radio_changed=true
            network_changed=true
        fi
    fi

    if [ "$transmit_power_2g" != "" ] && [ "$transmit_power_2g" != "null" ]; then
        if [ "$current_txpower_radio0" != "$transmit_power_2g" ]; then
            echo "Updating 2.4GHz transmit power from '$current_txpower_radio0' to ${transmit_power_2g}dBm"
            uci set wireless.radio0.txpower="$transmit_power_2g"
            radio_changed=true
        fi
    fi

    # Check and update 5GHz radio settings
    if [ "$channel_5g" != "" ] && [ "$channel_5g" != "null" ]; then
        if [ "$current_channel_radio1" != "$channel_5g" ]; then
            echo "Updating 5GHz channel from $current_channel_radio1 to $channel_5g"
            uci set wireless.radio1.channel="$channel_5g"
            radio_changed=true
        fi
    fi

    if [ "$channel_width_5g" != "" ] && [ "$channel_width_5g" != "null" ]; then
        new_htmode_5g=$(get_htmode "5g" "$channel_width_5g")
        if [ "$current_htmode_radio1" != "$new_htmode_5g" ]; then
            echo "Updating 5GHz channel width from $current_htmode_radio1 to $new_htmode_5g (${channel_width_5g}MHz)"
            uci set wireless.radio1.htmode="$new_htmode_5g"
            radio_changed=true
        fi
    fi

    if [ "$transmit_power_5g" != "" ] && [ "$transmit_power_5g" != "null" ]; then
        if [ "$current_txpower_radio1" != "$transmit_power_5g" ]; then
            echo "Updating 5GHz transmit power from '$current_txpower_radio1' to ${transmit_power_5g}dBm"
            uci set wireless.radio1.txpower="$transmit_power_5g"
            radio_changed=true
        fi
    fi

    # Just commit wireless changes here, restart will be done at the end
    if [ "$ssid_changed" = true ] || [ "$password_changed" = true ] || [ "$visibility_changed" = true ] || [ "$radio_changed" = true ]; then
        echo "Wireless configuration changed, committing changes..."
        uci commit wireless
        echo "Wireless changes committed (restart will be done at the end)"
    fi


    if [ "$captive_portal_whitelist_servers" != "" ] && [ "$captive_portal_whitelist_servers" != "null" ]; then
        echo "Updating captive portal whitelist servers from $current_captive_portal_whitelist_servers to $captive_portal_whitelist_servers"
        uci set chilli.@chilli[0].uamallowed="$captive_portal_whitelist_servers"
        chilli_changed=true
    fi

    if [ "$captive_portal_whitelist_domains" != "" ] && [ "$captive_portal_whitelist_domains" != "null" ]; then
        echo "Updating captive portal whitelist domains from $current_captive_portal_whitelist_domains to $captive_portal_whitelist_domains"
        uci set chilli.@chilli[0].uamdomain="$captive_portal_whitelist_domains"
        chilli_changed=true
    fi

    # Check and update captive portal IP if it has changed
    if [ "$chilli_ip" != "" ] && [ "$chilli_ip" != "null" ]; then
        if [ "$current_chilli_ip" != "$chilli_ip" ]; then
            echo "Updating chilli IP from $current_chilli_ip to $chilli_ip"
            uci set chilli.@chilli[0].net="$chilli_ip"
            uci set chilli.@chilli[0].dynip="$chilli_ip"
            uci set chilli.@chilli[0].dhcplisten="$captive_portal_ip"

            # Update dhcpif to use the correct VLAN interface
            if [ "$vlan_enabled" = "true" ]; then
                echo "VLAN mode enabled"
                # Use effective captive portal VLAN (calculated in configure_vlan_interfaces)
                effective_captive_vlan="$captive_portal_vlan"
                if [ "$effective_captive_vlan" = "null" ] || [ -z "$effective_captive_vlan" ]; then
                    effective_captive_vlan="1"
                fi
                uci set chilli.@chilli[0].dhcpif="br-lan.$effective_captive_vlan"
                echo "Chilli dhcpif set to br-lan.$effective_captive_vlan (VLAN mode)"
            else
                echo "VLAN mode disabled"
                uci set chilli.@chilli[0].dhcpif="br-lan.1"
                echo "Chilli dhcpif set to br-lan.1 (non-VLAN mode)"
            fi

            chilli_changed=true
            echo "Chilli IP changed"
        fi
    fi

    if [ "$captive_portal_netmask" != "" ] && [ "$captive_portal_netmask" != "null" ]; then
        if [ "$current_captive_portal_netmask" != "$captive_portal_netmask" ]; then
            echo "Updating captive portal netmask from $current_captive_portal_netmask to $captive_portal_netmask"
            uci set network.network1.netmask="$captive_portal_netmask"
            # uci commit network
            network_changed=true
        fi
    fi

    # Configure Chilli DNS to use local captive portal IP as DNS server
    current_chilli_dns1=$(uci get chilli.@chilli[0].dns1)
    current_chilli_dns2=$(uci get chilli.@chilli[0].dns2)

    if [ "$captive_portal_ip" != "" ] && [ "$captive_portal_ip" != "null" ]; then
        if [ "$current_chilli_dns1" != "$captive_portal_ip" ]; then
            uci set chilli.@chilli[0].dns1="$captive_portal_ip"
            chilli_changed=true
            echo "Chilli DNS1 changed to local captive portal IP: $captive_portal_ip"
        fi

        if [ "$current_chilli_dns2" != "$captive_portal_ip" ]; then
            uci set chilli.@chilli[0].dns2="$captive_portal_ip"
            chilli_changed=true
            echo "Chilli DNS2 changed to local captive portal IP: $captive_portal_ip"
        fi
    fi

    # Handle Captive Portal DNS based on blocked domains
    # Note: Captive portal network does not allow DHCP
    if [ "$has_blocked_domains" = true ]; then
        # Use local captive portal IP as DNS server when blocked domains are present
        echo "Blocked domains detected, setting Captive Portal DNS to local IP: $captive_portal_ip"

        if [ "$current_captive_portal_dns1" != "$captive_portal_ip" ]; then
            uci del_list network.network1.dns="$current_captive_portal_dns1"
            uci add_list network.network1.dns="$captive_portal_ip"
            network_changed=true
            echo "Network DNS1 updated to local IP: $captive_portal_ip"
        fi

        # Remove any second DNS entry when using local DNS
        if [ -n "$current_captive_portal_dns2" ]; then
            uci del_list network.network1.dns="$current_captive_portal_dns2"
            network_changed=true
        fi
    else
        # Use DNS from API when no blocked domains
        echo "No blocked domains, using API DNS servers for Captive Portal"

        if [ "$captive_portal_dns1" != "" ] && [ "$captive_portal_dns1" != "null" ]; then
            if [ "$current_captive_portal_dns1" != "$captive_portal_dns1" ]; then
                uci del_list network.network1.dns="$current_captive_portal_dns1"
                uci commit network
                uci add_list network.network1.dns="$captive_portal_dns1"
                # uci commit network
                network_changed=true
                echo "Network DNS1 updated: $captive_portal_dns1"
            fi
        fi

        if [ "$captive_portal_dns2" != "" ] && [ "$captive_portal_dns2" != "null" ]; then
            if [ "$current_captive_portal_dns2" != "$captive_portal_dns2" ]; then
                uci del_list network.network1.dns="$current_captive_portal_dns2"
                uci commit network
                uci add_list network.network1.dns="$captive_portal_dns2"
                # uci commit network
                network_changed=true
                echo "Network DNS2 updated: $captive_portal_dns2"
            fi
        fi
    fi

    # Handle Password WiFi Network Configuration
    echo "Password WiFi IP Mode: '$password_wifi_ip_mode'"

    if [ "$password_wifi_ip_mode" = "STATIC" ] || [ "$password_wifi_ip_mode" = "static" ]; then
        # STATIC mode - configure IP address and netmask
        echo "Configuring Password WiFi in STATIC mode"

        # Function to validate IP address
        validate_ip() {
            local ip=$1
            if echo "$ip" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' > /dev/null; then
                # Check each octet is 0-255
                for octet in $(echo "$ip" | tr '.' ' '); do
                    if [ "$octet" -gt 255 ] || [ "$octet" -lt 0 ]; then
                        return 1
                    fi
                done
                return 0
            else
                return 1
            fi
        }

        # Function to validate netmask
        validate_netmask() {
            local mask=$1
            case "$mask" in
                255.255.255.0|255.255.0.0|255.0.0.0|255.255.255.128|255.255.255.192|255.255.255.224|255.255.255.240|255.255.255.248|255.255.255.252|255.255.255.254)
                    return 0
                    ;;
                *)
                    return 1
                    ;;
            esac
        }

        # Set IP address and netmask
        use_default_ip=false

        if [ "$password_wifi_ip" != "" ] && [ "$password_wifi_ip" != "null" ] && validate_ip "$password_wifi_ip"; then
            echo "DEBUG: IP validation PASSED for: $password_wifi_ip"
            echo "DEBUG: Checking netmask validation..."
            if validate_netmask "$password_wifi_netmask"; then
                echo "DEBUG: Netmask validation PASSED for: $password_wifi_netmask"
            else
                echo "DEBUG: Netmask validation FAILED for: $password_wifi_netmask"
            fi

            if [ "$password_wifi_netmask" != "" ] && [ "$password_wifi_netmask" != "null" ] && validate_netmask "$password_wifi_netmask"; then
                # Use API provided IP and netmask
                if [ "$current_password_wifi_ip" != "$password_wifi_ip" ]; then
                    echo "Updating Password WiFi IP from $current_password_wifi_ip to $password_wifi_ip"
                    uci set network.lan.ipaddr="$password_wifi_ip"
                    network_changed=true
                    password_wifi_ip_changed=true
                    echo "Updated Password WiFi IP to: $password_wifi_ip"
                fi

                if [ "$current_password_wifi_netmask" != "$password_wifi_netmask" ]; then
                    echo "Updating Password WiFi netmask from $current_password_wifi_netmask to $password_wifi_netmask"
                    uci set network.lan.netmask="$password_wifi_netmask"
                    network_changed=true
                    password_wifi_netmask_changed=true
                    echo "Updated Password WiFi netmask to: $password_wifi_netmask"
                fi
            else
                echo "Invalid netmask from API, using default values"
                use_default_ip=true
            fi
        else
            echo "Invalid or missing IP from API, using default values"
            use_default_ip=true
        fi

        # Use default IP if validation failed
        if [ "$use_default_ip" = true ]; then
            default_ip="192.168.100.1"
            default_netmask="255.255.255.0"

            if [ "$current_password_wifi_ip" != "$default_ip" ]; then
                uci set network.lan.ipaddr="$default_ip"
                network_changed=true
                password_wifi_ip_changed=true
                echo "Set Password WiFi IP to default: $default_ip"
            fi

            if [ "$current_password_wifi_netmask" != "$default_netmask" ]; then
                uci set network.lan.netmask="$default_netmask"
                network_changed=true
                password_wifi_netmask_changed=true
                echo "Set Password WiFi netmask to default: $default_netmask"
            fi
        fi
        # Enable DHCP for STATIC mode
        current_dhcp_ignore=$(uci get dhcp.lan.ignore 2>/dev/null || echo "0")
        if [ "$current_dhcp_ignore" != "0" ]; then
            uci set dhcp.lan.ignore=0
            dhcp_changed=true
            echo "Enabled DHCP for Password WiFi (STATIC mode)"
        fi

    elif [ "$password_wifi_ip_mode" = "DHCP" ] || [ "$password_wifi_ip_mode" = "dhcp" ]; then
        # DHCP mode - disable DHCP server
        echo "Configuring Password WiFi in DHCP mode"
        current_dhcp_ignore=$(uci get dhcp.lan.ignore 2>/dev/null || echo "0")
        if [ "$current_dhcp_ignore" != "1" ]; then
            uci set dhcp.lan.ignore=1
            dhcp_changed=true
            echo "Disabled DHCP for Password WiFi (DHCP mode)"
        fi
    else
        echo "Password WiFi IP mode '$password_wifi_ip_mode' not recognized (expected 'STATIC', 'static', 'DHCP', or 'dhcp')"
    fi

    if [ "$captive_portal_dhcp_start" != "" ] && [ "$captive_portal_dhcp_start" != "null" ]; then
        # Validate that captive_dhcp_start_octet is numeric and in valid range (1-254)
        if [[ "$captive_dhcp_start_octet" =~ ^[0-9]+$ ]] && [ "$captive_dhcp_start_octet" -ge 1 ] && [ "$captive_dhcp_start_octet" -le 254 ]; then
            if [ "$current_captive_portal_dhcp_start" != "$captive_dhcp_start_octet" ]; then
                uci set chilli.@chilli[0].dhcpstart="$captive_dhcp_start_octet"
                chilli_changed=true
                echo "Chilli DHCP start changed"
            fi
        else
            echo "Error: Invalid captive portal DHCP start value: $captive_dhcp_start_octet (must be 1-254)"
        fi
    fi

    if [ "$captive_portal_dhcp_end" != "" ] && [ "$captive_portal_dhcp_end" != "null" ]; then
        # Validate that captive_dhcp_end_octet is numeric and in valid range (1-254)
        if [[ "$captive_dhcp_end_octet" =~ ^[0-9]+$ ]] && [ "$captive_dhcp_end_octet" -ge 1 ] && [ "$captive_dhcp_end_octet" -le 254 ]; then
            # Check that end is greater than or equal to start
            if [ -n "$captive_dhcp_start_octet" ] && [ "$captive_dhcp_end_octet" -lt "$captive_dhcp_start_octet" ]; then
                echo "Error: Captive portal DHCP end ($captive_dhcp_end_octet) is less than start ($captive_dhcp_start_octet)"
            elif [ "$current_captive_portal_dhcp_end" != "$captive_dhcp_end_octet" ]; then
                uci set chilli.@chilli[0].dhcpend="$captive_dhcp_end_octet"
                chilli_changed=true
                echo "Chilli DHCP end changed"
            fi
        else
            echo "Error: Invalid captive portal DHCP end value: $captive_dhcp_end_octet (must be 1-254)"
        fi
    fi

    if [ "$password_wifi_dhcp_start" != "" ] && [ "$password_wifi_dhcp_start" != "null" ]; then
        # Validate that password_wifi_dhcp_start_octet is numeric and in valid range (1-254)
        if [[ "$password_wifi_dhcp_start_octet" =~ ^[0-9]+$ ]] && [ "$password_wifi_dhcp_start_octet" -ge 1 ] && [ "$password_wifi_dhcp_start_octet" -le 254 ]; then
            if [ "$current_password_wifi_dhcp_start" != "$password_wifi_dhcp_start_octet" ]; then
                uci set dhcp.lan.start="$password_wifi_dhcp_start_octet"
                dhcp_changed=true
            fi
        else
            echo "Error: Invalid password WiFi DHCP start value: $password_wifi_dhcp_start_octet (must be 1-254)"
        fi
    fi

    if [ "$password_wifi_dhcp_end" != "" ] && [ "$password_wifi_dhcp_end" != "null" ]; then
        # Validate that password_wifi_dhcp_limit is numeric and in valid range
        if [[ "$password_wifi_dhcp_limit" =~ ^[0-9]+$ ]] && [ "$password_wifi_dhcp_limit" -ge 1 ] && [ "$password_wifi_dhcp_limit" -le 254 ]; then
            # Ensure end value is greater than start value
            if [ -n "$password_wifi_dhcp_start_octet" ] && [ "$password_wifi_dhcp_end_octet" -lt "$password_wifi_dhcp_start_octet" ]; then
                echo "Error: Password WiFi DHCP end ($password_wifi_dhcp_end_octet) is less than start ($password_wifi_dhcp_start_octet)"
            elif [ "$current_password_wifi_dhcp_end" != "$password_wifi_dhcp_limit" ]; then
                uci set dhcp.lan.limit="$password_wifi_dhcp_limit"
                dhcp_changed=true
            fi
        else
            echo "Error: Invalid password WiFi DHCP limit value: $password_wifi_dhcp_limit (must be 1-254)"
        fi
    fi

    # Handle Password WiFi DNS based on blocked domains
    blocked_domains_json=$(echo "$response" | jq -r '.settings.blocked_domains // empty')
    has_blocked_domains=false

    if [ -n "$blocked_domains_json" ] && [ "$blocked_domains_json" != "null" ] && [ "$blocked_domains_json" != "[]" ]; then
        domain_count=$(echo "$blocked_domains_json" | jq -r 'length')
        if [ "$domain_count" -gt 0 ]; then
            has_blocked_domains=true
        fi
    fi

    if [ "$has_blocked_domains" = true ]; then
        # Use local IP as DNS server when blocked domains are present
        local_ip=$(uci get network.lan.ipaddr)
        echo "Blocked domains detected, setting Password WiFi DNS to local IP: $local_ip"

        if [ "$current_password_wifi_dns1" != "$local_ip" ]; then
            uci del_list network.lan.dns="$current_password_wifi_dns1"
            uci commit network
            uci add_list network.lan.dns="$local_ip"
            network_changed=true
        fi

        # Remove any second DNS entry when using local DNS
        if [ -n "$current_password_wifi_dns2" ]; then
            uci del_list network.lan.dns="$current_password_wifi_dns2"
            uci commit network
            network_changed=true
        fi
    else
        # Use DNS from API when no blocked domains
        echo "No blocked domains, using API DNS servers for Password WiFi"

        if [ "$password_wifi_dns1" != "" ] && [ "$password_wifi_dns1" != "null" ]; then
            # Validate that password_wifi_dns1 is a valid IP address
            if echo "$password_wifi_dns1" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' > /dev/null; then
                if [ "$current_password_wifi_dns1" != "$password_wifi_dns1" ]; then
                    uci del_list network.lan.dns="$current_password_wifi_dns1"
                    uci commit network
                    uci add_list network.lan.dns="$password_wifi_dns1"
                    network_changed=true
                fi
            else
                echo "Error: Invalid password WiFi DNS1 value: $password_wifi_dns1"
            fi
        fi

        if [ "$password_wifi_dns2" != "" ] && [ "$password_wifi_dns2" != "null" ]; then
            # Validate that password_wifi_dns2 is a valid IP address
            if echo "$password_wifi_dns2" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' > /dev/null; then
                if [ "$current_password_wifi_dns2" != "$password_wifi_dns2" ]; then
                    uci del_list network.lan.dns="$current_password_wifi_dns2"
                    uci commit network
                    uci add_list network.lan.dns="$password_wifi_dns2"
                    network_changed=true
                fi
            else
                echo "Error: Invalid password WiFi DNS2 value: $password_wifi_dns2"
            fi
        fi
    fi

    if [ "$dhcp_changed" = true ]; then
        uci commit dhcp
        /etc/init.d/dnsmasq restart
    fi

    # Configure VLAN interfaces based on API settings
    echo "Configuring VLAN interfaces..."
    configure_vlan_interfaces "$vlan_enabled" "$captive_portal_vlan" "$password_wifi_vlan" \
                             "$password_wifi_ip" "$password_wifi_netmask" \
                             "$captive_portal_ip" "$captive_portal_netmask" \
                             "$captive_portal_vlan_tagging" "$password_wifi_vlan_tagging"

    # Always update Chilli dhcpif to use the correct VLAN interface
    # This ensures dhcpif is updated even when chilli IP hasn't changed
    echo "Updating Chilli dhcpif for VLAN configuration..."
    if [ "$vlan_enabled" = "true" ]; then
        # Use effective captive portal VLAN (same logic as in configure_vlan_interfaces)
        effective_captive_vlan="$captive_portal_vlan"
        if [ "$effective_captive_vlan" = "null" ] || [ -z "$effective_captive_vlan" ]; then
            effective_captive_vlan="1"
        fi

        current_dhcpif=$(uci get chilli.@chilli[0].dhcpif 2>/dev/null || echo "")
        new_dhcpif="br-lan.$effective_captive_vlan"

        if [ "$current_dhcpif" != "$new_dhcpif" ]; then
            uci set chilli.@chilli[0].dhcpif="$new_dhcpif"
            chilli_changed=true
            echo "Chilli dhcpif updated to $new_dhcpif (VLAN mode)"
        else
            echo "Chilli dhcpif already set to $new_dhcpif"
        fi
    else
        # VLAN mode disabled - use default VLAN interface
        current_dhcpif=$(uci get chilli.@chilli[0].dhcpif 2>/dev/null || echo "")
        new_dhcpif="br-lan.1"

        if [ "$current_dhcpif" != "$new_dhcpif" ]; then
            uci set chilli.@chilli[0].dhcpif="$new_dhcpif"
            chilli_changed=true
            echo "Chilli dhcpif updated to $new_dhcpif (default VLAN mode)"
        else
            echo "Chilli dhcpif already set to $new_dhcpif"
        fi
    fi

    # Update Chilli conup.sh script with correct VLAN interface
    # This ensures the conup.sh script uses the correct bridge interface for VLAN configuration
    conup_script="/etc/chilli/conup.sh"
    if [ -f "$conup_script" ]; then
        echo "Updating Chilli conup.sh script with correct VLAN interface..."

        if [ "$vlan_enabled" = "true" ]; then
            # Use effective captive portal VLAN (same logic as dhcpif)
            effective_captive_vlan="$captive_portal_vlan"
            if [ "$effective_captive_vlan" = "null" ] || [ -z "$effective_captive_vlan" ]; then
                effective_captive_vlan="1"
            fi

            new_conup_dev="br-lan.$effective_captive_vlan"

            # Check if the device line needs to be updated
            current_conup_dev=$(grep '^[[:space:]]*dev=' "$conup_script" | cut -d'"' -f2)

            if [ "$current_conup_dev" != "$new_conup_dev" ]; then
                # Update the device line using sed
                sed -i 's/^[[:space:]]*dev=.*/            dev="'"$new_conup_dev"'"/' "$conup_script"
                echo "Updated conup.sh device to: $new_conup_dev (VLAN mode)"
            else
                echo "conup.sh device already set to: $new_conup_dev"
            fi
        else
            # VLAN mode disabled - use default VLAN interface
            new_conup_dev="br-lan.1"

            # Check if the device line needs to be updated
            current_conup_dev=$(grep '^[[:space:]]*dev=' "$conup_script" | cut -d'"' -f2)

            if [ "$current_conup_dev" != "$new_conup_dev" ]; then
                # Update the device line using sed
                sed -i 's/^[[:space:]]*dev=.*/            dev="'"$new_conup_dev"'"/' "$conup_script"
                echo "Updated conup.sh device to: $new_conup_dev (default VLAN mode)"
            else
                echo "conup.sh device already set to: $new_conup_dev"
            fi
        fi
    else
        echo "Warning: Chilli conup.sh script not found at $conup_script"
    fi

    # Always restart network after VLAN configuration or other network changes
    if [ "$network_changed" = true ] || [ "$vlan_enabled" = "true" ] || [ "$vlan_enabled" = "false" ]; then
        echo "Restarting network services due to VLAN or network configuration changes..."
        uci commit network
        /etc/init.d/network restart

        # Ensure bridge interfaces are properly configured after network restart
        ensure_bridge_configuration

        # Mark that network was restarted for VLAN configuration
        network_changed=true
    fi


    # Restart Chilli if captive portal SSID has changed
    if [ "$captive_ssid_changed" = true ] || [ "$visibility_changed" = true ]; then
        echo "Restarting chilli"
        uci commit chilli
        /etc/init.d/chilli restart
    fi

    # Check for Coova Chilli configuration in API response
    # Extract Chilli parameters from API response using the new data structure
    radius_ip=$(echo "$response" | jq -r '.radius_settings.radius_ip // empty')
    radius_secret=$(echo "$response" | jq -r '.radius_settings.radius_secret // empty')
    login_url=$(echo "$response" | jq -r '.guest_settings.login_url // empty')
    whitelist_servers=$(echo "$response" | jq -r '.guest_settings.whitelist_servers // empty')
    whitelist_domains=$(echo "$response" | jq -r '.guest_settings.whitelist_domains // empty')
    location_id=$(echo "$response" | jq -r '.settings.location_id // empty')

    # Get current Chilli configuration values
    current_radius_server1=$(uci get chilli.@chilli[0].radiusserver1)
    current_radius_server2=$(uci get chilli.@chilli[0].radiusserver2)
    current_radius_secret=$(uci get chilli.@chilli[0].radiussecret)
    current_uamserver=$(uci get chilli.@chilli[0].uamserver)
    current_uamallowed=$(uci get chilli.@chilli[0].uamallowed)
    current_uamdomain=$(uci get chilli.@chilli[0].uamdomain)
    current_radiusnasid=$(uci get chilli.@chilli[0].radiusnasid)

    # Check if any Chilli parameters exist in the API response and update only if changed
    if [ -n "$radius_ip" ] || [ -n "$radius_secret" ] || [ -n "$login_url" ] ||
       [ -n "$whitelist_servers" ] || [ -n "$whitelist_domains" ] || [ -n "$location_id" ]; then

        # Update Chilli configuration for parameters that exist in API response and have changed
        if [ -n "$radius_ip" ]; then
            if [ "$current_radius_server1" != "$radius_ip" ]; then
                uci set chilli.@chilli[0].radiusserver1="$radius_ip"
                chilli_changed=true
            fi

            if [ "$current_radius_server2" != "$radius_ip" ]; then
                uci set chilli.@chilli[0].radiusserver2="$radius_ip"
                chilli_changed=true
            fi
        fi

        if [ -n "$radius_secret" ] && [ "$current_radius_secret" != "$radius_secret" ]; then
            uci set chilli.@chilli[0].radiussecret="$radius_secret"
            chilli_changed=true
        fi

        if [ -n "$login_url" ] && [ "$current_uamserver" != "$login_url" ]; then
            uci set chilli.@chilli[0].uamserver="$login_url"
            chilli_changed=true
        fi

        if [ -n "$whitelist_servers" ] && [ "$current_uamallowed" != "$whitelist_servers" ]; then
            uci set chilli.@chilli[0].uamallowed="$whitelist_servers"
            chilli_changed=true
        fi

        if [ -n "$whitelist_domains" ] && [ "$current_uamdomain" != "$whitelist_domains" ]; then
            uci set chilli.@chilli[0].uamdomain="$whitelist_domains"
            chilli_changed=true
        fi

        if [ -n "$location_id" ] && [ "$current_radiusnasid" != "$location_id" ]; then
            uci set chilli.@chilli[0].radiusnasid="$location_id"
            chilli_changed=true
        fi

        # Commit Chilli changes and restart service if needed
        if [ "$chilli_changed" = true ]; then
            echo "Restarting chilli"
            uci commit chilli
            /etc/init.d/chilli restart
        fi
    fi

    # Handle blocked domains from API response
    domains_changed=false

    # Get current blocked domains from dhcp configuration
    current_address_list=$(uci show dhcp.@dnsmasq[0].address 2>/dev/null | cut -d'=' -f2- | tr -d "'" | tr ' ' '\n')
    current_blocked_domains=""
    for entry in $current_address_list; do
        if echo "$entry" | grep -q "/$captive_portal_ip$"; then
            domain=$(echo "$entry" | sed "s|^/||" | sed "s|/$captive_portal_ip$||")
            if [ -n "$domain" ]; then
                current_blocked_domains="$current_blocked_domains $domain"
            fi
        fi
    done
    current_blocked_domains=$(echo "$current_blocked_domains" | xargs)

    if [ -n "$blocked_domains_json" ] && [ "$blocked_domains_json" != "null" ] && [ "$blocked_domains_json" != "[]" ]; then
        # Extract domain names from JSON array
        new_blocked_domains=$(echo "$blocked_domains_json" | jq -r '.[].domain' | tr '\n' ' ')

        echo "API blocked domains: $new_blocked_domains"
        echo "Current blocked domains: $current_blocked_domains"

        # Compare current domains with new domains
        if [ "$current_blocked_domains" != "$new_blocked_domains" ]; then
            # Clear existing blocked domain entries
            if [ -n "$current_blocked_domains" ]; then
                for domain in $current_blocked_domains; do
                    if [ -n "$domain" ]; then
                        uci del_list dhcp.@dnsmasq[0].address="/$domain/$captive_portal_ip"
                        echo "Removed blocked domain: $domain"
                    fi
                done
            fi

            # Add new blocked domains
            for domain in $new_blocked_domains; do
                if [ -n "$domain" ]; then
                    uci add_list dhcp.@dnsmasq[0].address="/$domain/$captive_portal_ip"
                    echo "Added blocked domain: $domain"
                fi
            done

            domains_changed=true
        fi
    else
        # No blocked domains in API response, remove all existing blocked domains
        if [ -n "$current_blocked_domains" ]; then
            echo "No blocked domains in API, removing existing blocked domains"
            for domain in $current_blocked_domains; do
                if [ -n "$domain" ]; then
                    uci del_list dhcp.@dnsmasq[0].address="/$domain/$captive_portal_ip"
                    echo "Removed blocked domain: $domain"
                fi
            done
            domains_changed=true
        fi
    fi

    # Configure IPv6 AAAA record filtering based on domain filtering status
    current_filter_aaaa=$(uci get dhcp.@dnsmasq[0].filter_aaaa 2>/dev/null || echo "0")

    # Set filter_aaaa based on domain filtering status
    if [ "$has_blocked_domains" = true ]; then
        if [ "$current_filter_aaaa" != "1" ]; then
            uci set dhcp.@dnsmasq[0].filter_aaaa=1
            domains_changed=true
            echo "Enabled IPv6 AAAA filtering (filter_aaaa=1) - Domain filtering is active"
        fi
    else
        if [ "$current_filter_aaaa" != "0" ]; then
            uci set dhcp.@dnsmasq[0].filter_aaaa=0
            domains_changed=true
            echo "Disabled IPv6 AAAA filtering (filter_aaaa=0) - Domain filtering is inactive"
        fi
    fi

    # Commit dhcp changes and restart dnsmasq if domains or filter settings changed
    if [ "$domains_changed" = true ]; then
        uci commit dhcp
        /etc/init.d/dnsmasq restart
        echo "DNS configuration updated and dnsmasq restarted"
    fi

    # Handle DNS redirect based on blocked domains configuration
    dns_redirect_script="/etc/citypassenger/dns_redirect.sh"
    dns_redirect_flag="/tmp/dns_redirect_enabled"

    # Check current DNS redirect status
    dns_redirect_currently_enabled=false
    if [ -f "$dns_redirect_flag" ]; then
        dns_redirect_currently_enabled=true
    fi

    echo "DNS redirect status check:"
    echo "  Has blocked domains: $has_blocked_domains"
    echo "  DNS redirect currently enabled: $dns_redirect_currently_enabled"

    # Enable DNS redirect if blocked domains are present and it's not already enabled
    if [ "$has_blocked_domains" = true ] && [ "$dns_redirect_currently_enabled" = false ]; then
        echo "Enabling DNS redirect due to blocked domains..."
        if [ -f "$dns_redirect_script" ]; then
            "$dns_redirect_script" enable
            echo "DNS redirect enabled successfully"
        else
            echo "Warning: DNS redirect script not found at $dns_redirect_script"
        fi
    # Disable DNS redirect if no blocked domains and it's currently enabled
    elif [ "$has_blocked_domains" = false ] && [ "$dns_redirect_currently_enabled" = true ]; then
        echo "Disabling DNS redirect as no blocked domains are configured..."
        if [ -f "$dns_redirect_script" ]; then
            "$dns_redirect_script" disable
            echo "DNS redirect disabled successfully"
        else
            echo "Warning: DNS redirect script not found at $dns_redirect_script"
        fi
    else
        echo "DNS redirect status unchanged (appropriate for current configuration)"
    fi

    # Handle MAC address filtering for password WiFi (secured_mac_filter_list) - BLACKLIST ONLY
    secured_mac_filter_json=$(echo "$response" | jq -r '.settings.secured_mac_filter_list // empty')
    mac_filter_changed=false
    
    if [ -n "$secured_mac_filter_json" ] && [ "$secured_mac_filter_json" != "null" ] && [ "$secured_mac_filter_json" != "[]" ]; then
        # Extract only blacklist MAC addresses
        blacklist_macs=$(echo "$secured_mac_filter_json" | jq -r '.[] | select(.type == "blacklist") | .mac' | tr '\n' ' ')
        blacklist_macs=$(echo "$blacklist_macs" | xargs)  # Trim whitespace
        
        echo "Processing MAC filtering for password WiFi..."
        echo "Blacklist MACs: $blacklist_macs"
        
        # Get current MAC filter settings
        current_macfilter_radio0=$(uci get wireless.default_radio0.macfilter 2>/dev/null || echo "disable")
        current_macfilter_radio1=$(uci get wireless.default_radio1.macfilter 2>/dev/null || echo "disable")
        current_maclist_radio0=$(uci get wireless.default_radio0.maclist 2>/dev/null || echo "")
        current_maclist_radio1=$(uci get wireless.default_radio1.maclist 2>/dev/null || echo "")
        
        if [ -n "$blacklist_macs" ]; then
            # Apply blacklist filtering
            echo "Applying blacklist MAC filtering: $blacklist_macs"
            
            # Update MAC filter settings for 2.4GHz radio
            if [ "$current_macfilter_radio0" != "deny" ]; then
                uci set wireless.default_radio0.macfilter="deny"
                mac_filter_changed=true
                echo "Enabled blacklist MAC filtering for 2.4GHz radio"
            fi
            
            if [ "$current_maclist_radio0" != "$blacklist_macs" ]; then
                # Clear existing MAC list
                uci delete wireless.default_radio0.maclist 2>/dev/null || true
                # Add blacklisted MAC addresses
                for mac in $blacklist_macs; do
                    if [ -n "$mac" ]; then
                        uci add_list wireless.default_radio0.maclist="$mac"
                    fi
                done
                mac_filter_changed=true
                echo "Updated 2.4GHz blacklist: $blacklist_macs"
            fi
            
            # Update MAC filter settings for 5GHz radio
            if [ "$current_macfilter_radio1" != "deny" ]; then
                uci set wireless.default_radio1.macfilter="deny"
                mac_filter_changed=true
                echo "Enabled blacklist MAC filtering for 5GHz radio"
            fi
            
            if [ "$current_maclist_radio1" != "$blacklist_macs" ]; then
                # Clear existing MAC list
                uci delete wireless.default_radio1.maclist 2>/dev/null || true
                # Add blacklisted MAC addresses
                for mac in $blacklist_macs; do
                    if [ -n "$mac" ]; then
                        uci add_list wireless.default_radio1.maclist="$mac"
                    fi
                done
                mac_filter_changed=true
                echo "Updated 5GHz blacklist: $blacklist_macs"
            fi
            
        else
            # No blacklist MACs found (only whitelist or empty), disable MAC filtering
            echo "No blacklist MACs found, disabling MAC filtering (whitelist bypassed)"
            
            if [ "$current_macfilter_radio0" != "disable" ]; then
                uci set wireless.default_radio0.macfilter="disable"
                uci delete wireless.default_radio0.maclist 2>/dev/null || true
                mac_filter_changed=true
                echo "Disabled MAC filtering for 2.4GHz radio"
            fi
            
            if [ "$current_macfilter_radio1" != "disable" ]; then
                uci set wireless.default_radio1.macfilter="disable"
                uci delete wireless.default_radio1.maclist 2>/dev/null || true
                mac_filter_changed=true
                echo "Disabled MAC filtering for 5GHz radio"
            fi
        fi
        
    else
        # No MAC filtering configured, disable it
        echo "No MAC filtering configured, ensuring it's disabled"
        current_macfilter_radio0=$(uci get wireless.default_radio0.macfilter 2>/dev/null || echo "disable")
        current_macfilter_radio1=$(uci get wireless.default_radio1.macfilter 2>/dev/null || echo "disable")
        
        if [ "$current_macfilter_radio0" != "disable" ]; then
            uci set wireless.default_radio0.macfilter="disable"
            uci delete wireless.default_radio0.maclist 2>/dev/null || true
            mac_filter_changed=true
            echo "Disabled MAC filtering for 2.4GHz radio"
        fi
        
        if [ "$current_macfilter_radio1" != "disable" ]; then
            uci set wireless.default_radio1.macfilter="disable"
            uci delete wireless.default_radio1.maclist 2>/dev/null || true
            mac_filter_changed=true
            echo "Disabled MAC filtering for 5GHz radio"
        fi
    fi

    # Final wireless restart - handle all wireless changes at once
    if [ "$ssid_changed" = true ] || [ "$password_changed" = true ] || [ "$visibility_changed" = true ] || [ "$radio_changed" = true ] || [ "$mac_filter_changed" = true ]; then
        echo "Performing final wireless restart for all changes..."
        
        # Commit MAC filtering changes if needed
        if [ "$mac_filter_changed" = true ]; then
            uci commit wireless
        fi

        # For radio-level changes (channel, power, country, etc.) or MAC filtering changes, use full restart
        if [ "$radio_changed" = true ] || [ "$mac_filter_changed" = true ]; then
            echo "Radio settings or MAC filtering changed, performing full WiFi restart..."
            wifi down
            sleep 3
            wifi up
        else
            echo "Interface settings changed, performing WiFi reload..."
            wifi reload
        fi

        echo "Final wireless restart completed"
    fi
fi

echo "=================================="
echo "PRODUCTION MODE COMPLETE"
echo "=================================="

