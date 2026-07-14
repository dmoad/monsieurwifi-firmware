#!/bin/sh

# OpenWRT Network Client Synchronization Script
# Monitors connected devices and syncs changes to API endpoint
# Maintains state in /tmp/ and only pushes when there are changes

STATE_FILE="/tmp/network_clients_state.json"
TEMP_FILE="/tmp/network_clients_current.json"
LOCK_FILE="/tmp/network_sync.lock"
LOG_FILE="/tmp/network_sync.log"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Function to acquire lock
acquire_lock() {
    local timeout=30
    local count=0
    
    while [ $count -lt $timeout ]; do
        if mkdir "$LOCK_FILE" 2>/dev/null; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    
    log_message "ERROR: Could not acquire lock after $timeout seconds"
    return 1
}

# Function to release lock
release_lock() {
    rmdir "$LOCK_FILE" 2>/dev/null
}

# Function to check if an interface is a WAN interface
is_wan_interface() {
    local interface="$1"
    
    # Check if interface name contains wan
    if echo "$interface" | grep -qi "wan"; then
        return 0
    fi
    
    # Check if interface is configured as WAN in UCI
    local wan_device=$(uci get network.wan.device 2>/dev/null || uci get network.wan.ifname 2>/dev/null || echo "")
    local wan6_device=$(uci get network.wan6.device 2>/dev/null || uci get network.wan6.ifname 2>/dev/null || echo "")
    
    if [ "$interface" = "$wan_device" ] || [ "$interface" = "$wan6_device" ]; then
        return 0
    fi
    
    # Check common WAN interface patterns
    case "$interface" in
        eth0|eth0.*|wan|wan.*|pppoe-*|3g-*|lte-*|wwan*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to check if an IP is in WAN network range
is_wan_ip() {
    local ip="$1"
    
    # Common WAN IP ranges (public internet ranges we want to exclude)
    case "$ip" in
        192.168.*|10.*|172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*|169.254.*|127.*|0.0.0.0)
            return 1  # These are private/local ranges
            ;;
        *)
            return 0  # Potentially public IP
            ;;
    esac
}

# Function to get WiFi clients from all wireless interfaces
get_wifi_clients() {
    local wifi_clients=""
    local first_client=true
    
    echo "Scanning for WiFi clients..." >&2
    
    # Get all wireless interfaces
    for interface in $(iw dev | grep Interface | awk '{print $2}'); do
        # Skip non-existing interfaces
        if [ ! -e "/sys/class/net/$interface" ]; then
            continue
        fi
        
        # Skip WAN wireless interfaces (if any)
        if is_wan_interface "$interface"; then
            echo "  Skipping WAN interface: $interface" >&2
            continue
        fi
        
        # Get interface info
        local ssid=$(iwinfo "$interface" info 2>/dev/null | grep "ESSID" | cut -d'"' -f2)
        local mode=$(iwinfo "$interface" info 2>/dev/null | grep "Mode:" | awk '{print $2}')
        local frequency=$(iwinfo "$interface" info 2>/dev/null | grep "Channel:" | awk '{print $2}')
        
        echo "  Checking interface: $interface (SSID: $ssid, Mode: $mode)" >&2
        
        # Skip if not in AP mode or no SSID
        if [ "$mode" != "Master" ] || [ -z "$ssid" ]; then
            echo "    Skipping: not in AP mode or no SSID" >&2
            continue
        fi
        
        # Get associated clients for this interface
        local clients=$(iwinfo "$interface" assoclist 2>/dev/null)
        
        if [ -n "$clients" ]; then
            echo "    Found associated clients on $interface" >&2
            # Parse client information
            echo "$clients" | while read -r line; do
                if echo "$line" | grep -q "^[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]"; then
                    local mac=$(echo "$line" | awk '{print $1}')
                    local signal=$(echo "$line" | grep -o "Signal: [^/]*" | awk '{print $2}')
                    local rx_rate=$(echo "$line" | grep -o "RX: [^/]*" | awk '{print $2}')
                    local tx_rate=$(echo "$line" | grep -o "TX: [^/]*" | awk '{print $2}')
                    
                    # Add comma if not first entry
                    if [ "$first_client" = false ]; then
                        wifi_clients="$wifi_clients,"
                    fi
                    first_client=false
                    
                    # Create JSON entry for this client
                    wifi_clients="$wifi_clients{\"mac\":\"$mac\",\"type\":\"wifi\",\"interface\":\"$interface\",\"ssid\":\"$ssid\",\"signal\":\"$signal\",\"rx_rate\":\"$rx_rate\",\"tx_rate\":\"$tx_rate\",\"frequency\":\"$frequency\"}"
                fi
            done
        fi
    done
    
    echo "$wifi_clients"
}

# Function to get wired clients from ARP table and DHCP leases (LAN side only)
get_wired_clients() {
    local wired_clients=""
    local first_client=true
    
    echo "Scanning for wired clients..." >&2
    
    # Read DHCP leases to get IP assignments
    local dhcp_leases_file="/tmp/dhcp.leases"
    if [ ! -f "$dhcp_leases_file" ]; then
        dhcp_leases_file="/var/dhcp.leases"
    fi
    
    echo "  Using DHCP leases file: $dhcp_leases_file" >&2
    
    # Create temporary files for processing
    local temp_arp="/tmp/arp_table.tmp"
    local temp_dhcp="/tmp/dhcp_leases.tmp"
    
    # Get ARP table (active IP connections)
    cat /proc/net/arp | grep -v "IP address" > "$temp_arp"
    
    # Get DHCP leases if available
    if [ -f "$dhcp_leases_file" ]; then
        cat "$dhcp_leases_file" > "$temp_dhcp"
    else
        touch "$temp_dhcp"
    fi
    
    # Get LAN network ranges from UCI configuration
    local lan_ip=$(uci get network.lan.ipaddr 2>/dev/null || echo "")
    local lan_netmask=$(uci get network.lan.netmask 2>/dev/null || echo "")
    local network1_ip=$(uci get network.network1.ipaddr 2>/dev/null || echo "")
    local network1_netmask=$(uci get network.network1.netmask 2>/dev/null || echo "")
    
    # Process ARP entries
    while IFS= read -r arp_line; do
        if [ -n "$arp_line" ]; then
            local ip=$(echo "$arp_line" | awk '{print $1}')
            local mac=$(echo "$arp_line" | awk '{print $4}')
            local interface=$(echo "$arp_line" | awk '{print $6}')
            local flags=$(echo "$arp_line" | awk '{print $3}')
            
            # Skip incomplete entries (flag 0x0)
            if [ "$flags" = "0x0" ] || [ "$mac" = "00:00:00:00:00:00" ]; then
                continue
            fi
            
            # Skip WAN interfaces
            if is_wan_interface "$interface"; then
                continue
            fi
            
            # Skip WAN IP addresses
            if is_wan_ip "$ip"; then
                continue
            fi
            
            # Skip WiFi interfaces (they're handled separately)
            if echo "$interface" | grep -q "wlan"; then
                continue
            fi
            
            # Only include interfaces that are clearly LAN-side
            case "$interface" in
                br-lan|br-lan.*|lan|lan[1-9]|eth[1-9]|eth[1-9].*|switch*)
                    ;;
                *)
                    # For other interfaces, check if they're in our known LAN networks
                    local is_lan_ip=false
                    
                    # Check if IP is in LAN network range
                    if [ -n "$lan_ip" ] && [ -n "$lan_netmask" ]; then
                        # Simple subnet check for common netmasks
                        case "$lan_netmask" in
                            "255.255.255.0")
                                local lan_base=$(echo "$lan_ip" | cut -d. -f1-3)
                                local ip_base=$(echo "$ip" | cut -d. -f1-3)
                                if [ "$lan_base" = "$ip_base" ]; then
                                    is_lan_ip=true
                                fi
                                ;;
                            "255.255.0.0")
                                local lan_base=$(echo "$lan_ip" | cut -d. -f1-2)
                                local ip_base=$(echo "$ip" | cut -d. -f1-2)
                                if [ "$lan_base" = "$ip_base" ]; then
                                    is_lan_ip=true
                                fi
                                ;;
                        esac
                    fi
                    
                    # Check if IP is in network1 range (captive portal)
                    if [ -n "$network1_ip" ] && [ -n "$network1_netmask" ]; then
                        case "$network1_netmask" in
                            "255.255.255.0")
                                local net1_base=$(echo "$network1_ip" | cut -d. -f1-3)
                                local ip_base=$(echo "$ip" | cut -d. -f1-3)
                                if [ "$net1_base" = "$ip_base" ]; then
                                    is_lan_ip=true
                                fi
                                ;;
                        esac
                    fi
                    
                    # Skip if not in LAN network
                    if [ "$is_lan_ip" = false ]; then
                        continue
                    fi
                    ;;
            esac
            
            # Get hostname from DHCP leases
            local hostname=""
            if [ -f "$temp_dhcp" ]; then
                hostname=$(grep "$mac" "$temp_dhcp" | awk '{print $4}' | head -1)
            fi
            
            # Determine connection type based on interface
            local conn_type="wired"
            if echo "$interface" | grep -q "br-lan"; then
                conn_type="bridge"
            fi
            
            # Determine which network this client is on
            local network="lan"
            if [ -n "$network1_ip" ] && [ -n "$network1_netmask" ]; then
                case "$network1_netmask" in
                    "255.255.255.0")
                        local net1_base=$(echo "$network1_ip" | cut -d. -f1-3)
                        local ip_base=$(echo "$ip" | cut -d. -f1-3)
                        if [ "$net1_base" = "$ip_base" ]; then
                            network="captive"
                        fi
                        ;;
                esac
            fi
            
            # Add comma if not first entry
            if [ "$first_client" = false ]; then
                wired_clients="$wired_clients,"
            fi
            first_client=false
            
            # Create JSON entry for this client
            wired_clients="$wired_clients{\"mac\":\"$mac\",\"type\":\"$conn_type\",\"ip\":\"$ip\",\"interface\":\"$interface\",\"hostname\":\"$hostname\",\"network\":\"$network\"}"
        fi
    done < "$temp_arp"
    
    # Clean up temporary files
    rm -f "$temp_arp" "$temp_dhcp"
    
    echo "$wired_clients"
}

# Function to get current client data
get_current_clients() {
    local wifi_clients=$(get_wifi_clients)
    local wired_clients=$(get_wired_clients)
    
    # Combine WiFi and wired clients
    local all_clients=""
    if [ -n "$wifi_clients" ] && [ -n "$wired_clients" ]; then
        all_clients="$wifi_clients,$wired_clients"
    elif [ -n "$wifi_clients" ]; then
        all_clients="$wifi_clients"
    elif [ -n "$wired_clients" ]; then
        all_clients="$wired_clients"
    fi
    
    # Get counts
    local wifi_count=0
    local wired_count=0
    
    if [ -n "$wifi_clients" ]; then
        wifi_count=$(echo "$wifi_clients" | grep -o "\"type\":\"wifi\"" | wc -l)
    fi
    
    if [ -n "$wired_clients" ]; then
        wired_count=$(echo "$wired_clients" | grep -o "\"type\":\"wired\"\|\"type\":\"bridge\"" | wc -l)
    fi
    
    echo "Client counts: WiFi=$wifi_count, Wired=$wired_count, Total=$((wifi_count + wired_count))" >&2
    
    # Create JSON structure
    cat << EOF
{
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "clients": [$all_clients],
    "summary": {
        "total_clients": $((wifi_count + wired_count)),
        "wifi_clients": $wifi_count,
        "wired_clients": $wired_count
    },
    "synced": false
}
EOF
}

# Function to compare two client lists
clients_changed() {
    local current_file="$1"
    local previous_file="$2"
    
    # If previous file doesn't exist, consider it changed
    if [ ! -f "$previous_file" ]; then
        return 0
    fi
    
    # Extract and sort client MAC addresses from current file
    local current_macs=$(cat "$current_file" | grep -o '"mac":"[^"]*"' | sort)
    
    # Extract and sort client MAC addresses from previous file
    local previous_macs=$(cat "$previous_file" | grep -o '"mac":"[^"]*"' | sort)
    
    # Compare MAC address lists
    if [ "$current_macs" != "$previous_macs" ]; then
        return 0  # Changed
    fi
    
    return 1  # No change
}

# Function to push data to API
push_to_api() {
    local data_file="$1"
    
    # Get API credentials from UCI
    local key=$(uci get citypassenger.@device[0].key 2>/dev/null || echo "")
    local secret=$(uci get citypassenger.@device[0].secret 2>/dev/null || echo "")
    local api_domain=$(uci get citypassenger.@device[0].api_domain 2>/dev/null || echo "")
    
    echo "API Credentials - Key: $key, Domain: $api_domain"
    
    if [ -z "$key" ] || [ -z "$secret" ] || [ -z "$api_domain" ]; then
        echo "ERROR: Missing API credentials in UCI citypassenger config"
        log_message "ERROR: Missing API credentials in UCI citypassenger config"
        return 1
    fi
    
    # Construct API endpoint
    local api_endpoint="$api_domain/api/devices/$key/$secret/clients"
    echo "API Endpoint: $api_endpoint"
    
    # Read the JSON data
    local json_data=$(cat "$data_file")
    echo "Pushing data to API: $json_data"
    
    # Make API call
    local response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$json_data" \
        "$api_endpoint" 2>/dev/null)
    
    local curl_exit_code=$?
    
    echo "Curl exit code: $curl_exit_code"
    echo "API Response: $response"
    
    if [ $curl_exit_code -eq 0 ]; then
        # Check if response indicates success
        if echo "$response" | grep -q '"status":"success"' || echo "$response" | grep -q '"success":true'; then
            echo "API call successful"
            log_message "SUCCESS: Client data pushed to API successfully"
            return 0
        else
            echo "API returned error response"
            log_message "ERROR: API returned error response: $response"
            return 1
        fi
    else
        echo "Failed to connect to API endpoint"
        log_message "ERROR: Failed to connect to API endpoint: $api_endpoint (curl exit code: $curl_exit_code)"
        return 1
    fi
}

# Function to mark data as synced
mark_as_synced() {
    local file="$1"
    
    # Update the synced status in the JSON file
    sed -i 's/"synced": false/"synced": true/' "$file"
}

# Function to show current status
show_status() {
    if [ -f "$STATE_FILE" ]; then
        echo "Current state:"
        cat "$STATE_FILE"
    else
        echo "No state file found. Run sync to initialize."
    fi
}

# Function to show help
show_help() {
    echo "Usage: $0 [sync|status|force|help]"
    echo ""
    echo "Commands:"
    echo "  sync    - Check for changes and sync if needed (default)"
    echo "  status  - Show current client status"
    echo "  force   - Force sync regardless of changes"
    echo "  help    - Show this help message"
    echo ""
    echo "This script should be run via cron every minute:"
    echo "  * * * * * /path/to/sync_network_clients.sh sync"
}

# Main sync function
sync_clients() {
    local force_sync="$1"
    
    echo "Starting network client sync..."
    
    # Acquire lock
    if ! acquire_lock; then
        echo "ERROR: Could not acquire lock, sync aborted"
        log_message "ERROR: Could not acquire lock, sync aborted"
        exit 1
    fi
    
    echo "Lock acquired successfully"
    
    # Get current client data
    echo "Gathering current client data..."
    log_message "INFO: Gathering current client data"
    get_current_clients > "$TEMP_FILE"
    
    # Check if clients changed or force sync
    local should_sync=false
    
    if [ "$force_sync" = "true" ]; then
        should_sync=true
        echo "Force sync requested"
        log_message "INFO: Force sync requested"
    elif clients_changed "$TEMP_FILE" "$STATE_FILE"; then
        should_sync=true
        echo "Client changes detected - sync required"
        log_message "INFO: Client changes detected"
    else
        echo "No client changes detected - skipping sync"
        log_message "INFO: No client changes detected"
    fi
    
    if [ "$should_sync" = true ]; then
        # Push to API
        echo "Pushing client data to API..."
        if push_to_api "$TEMP_FILE"; then
            # Mark as synced and update state file
            mark_as_synced "$TEMP_FILE"
            mv "$TEMP_FILE" "$STATE_FILE"
            echo "SUCCESS: Client data synced successfully"
            log_message "INFO: Client data synced successfully"
        else
            # Keep as unsynced but update state file
            mv "$TEMP_FILE" "$STATE_FILE"
            echo "ERROR: Failed to sync client data to API"
            log_message "ERROR: Failed to sync client data to API"
        fi
    else
        # No changes, just clean up temp file
        rm -f "$TEMP_FILE"
    fi
    
    # Release lock
    echo "Releasing lock and finishing sync"
    release_lock
}

# Main script logic
echo "=== Network Client Sync Script ==="
echo "Command: ${1:-sync}"
echo "==============================="

case "$1" in
    "sync")
        sync_clients false
        ;;
    "force")
        sync_clients true
        ;;
    "status")
        show_status
        ;;
    "help"|"-h"|"--help")
        show_help
        ;;
    *)
        # Default action is sync
        sync_clients false
        ;;
esac 