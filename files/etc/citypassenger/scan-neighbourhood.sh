#!/bin/sh

# Scan 2.4GHz and 5.8GHz radio for neighbourhood and report to server API

# Get SCAN_ID from command line arguments
SCAN_ID="$1"
if [ -z "$SCAN_ID" ]; then
    echo "ERROR: SCAN_ID is required as first argument" >&2
    echo "Usage: $0 <scan_id>" >&2
    exit 1
fi

# Read configuration from UCI
echo "Reading device configuration from UCI..." >&2
DEVICE_KEY=$(uci get citypassenger.@device[0].key 2>/dev/null)
DEVICE_SECRET=$(uci get citypassenger.@device[0].secret 2>/dev/null)
SERVER_URL=$(uci get citypassenger.@device[0].api_domain 2>/dev/null)
echo "DEVICE_KEY: $DEVICE_KEY"
echo "DEVICE_SECRET: $DEVICE_SECRET"
echo "SERVER_URL: $SERVER_URL"

# Check if we got all required UCI values
if [ -z "$DEVICE_KEY" ]; then
    echo "ERROR: Could not read device key from UCI (citypassenger.@device[0].key)" >&2
    exit 1
fi

if [ -z "$DEVICE_SECRET" ]; then
    echo "ERROR: Could not read device secret from UCI (citypassenger.@device[0].secret)" >&2
    exit 1
fi

if [ -z "$SERVER_URL" ]; then
    echo "ERROR: Could not read server URL from UCI (citypassenger.@device[0].api_domain)" >&2
    exit 1
fi

echo "Configuration loaded successfully:" >&2
echo "  Device Key: ${DEVICE_KEY}" >&2
echo "  Device Secret: ${DEVICE_SECRET:0:10}..." >&2
echo "  Server URL: ${SERVER_URL}" >&2
echo "  Scan ID: ${SCAN_ID}" >&2

# API Base URL
API_BASE="$SERVER_URL/api/devices/$DEVICE_KEY/$DEVICE_SECRET/scan/$SCAN_ID"

# Function to make API calls
call_api() {
    local endpoint=$1
    local method=$2
    local data=$3
    local response_file=$(mktemp)
    
    echo "API Call: $method $endpoint" >&2
    
    if [ "$method" = "POST" ] && [ -n "$data" ]; then
        curl -s -X POST \
            -H "Content-Type: application/json" \
            -d "$data" \
            "$endpoint" \
            -w "%{http_code}" \
            -o "$response_file" 2>/dev/null
    else
        curl -s -X POST \
            -H "Content-Type: application/json" \
            -d "{}" \
            "$endpoint" \
            -w "%{http_code}" \
            -o "$response_file" 2>/dev/null
    fi
    
    local http_code=$?
    local response_body=$(cat "$response_file")
    
    echo "API Response: $response_body" >&2
    rm -f "$response_file"
    
    return $http_code
}

# Function to report scan started
report_scan_started() {
    echo "Reporting scan started to server..." >&2
    call_api "$API_BASE/started" "POST" "{}"
}

# Function to report scan failure
report_scan_failed() {
    local error_message=$1
    echo "Reporting scan failure to server: $error_message" >&2
    local data="{\"error_message\":\"$error_message\"}"
    call_api "$API_BASE/failed" "POST" "$data"
}

# Function to calculate interference level
calculate_interference_level() {
    local network_count=$1
    if [ $network_count -le 3 ]; then
        echo "low"
    elif [ $network_count -le 8 ]; then
        echo "medium"
    else
        echo "high"
    fi
}

# Function to convert scan results to enhanced format with ESSID
convert_scan_results_to_channels() {
    local scan_data=$1
    local frequency_band=$2
    local channel_results="{"
    local network_details="["
    local network_count=0
    local first_channel=true
    local first_network=true
    local temp_file=$(mktemp)
    
    echo "Debug: Converting scan data for $frequency_band" >&2
    echo "Debug: Raw scan data: $scan_data" >&2
    
    # Extract individual networks to temporary file to avoid subshell issues
    echo "$scan_data" | grep -o '{[^}]*}' > "$temp_file"
    
    # Process each network
    while read -r network; do
        echo "Debug: Processing network: $network" >&2
        
        # Extract all network data
        local channel=$(echo "$network" | grep -o '"channel":[0-9]*' | cut -d: -f2)
        local signal=$(echo "$network" | grep -o '"signal":-[0-9]*' | cut -d: -f2)
        local bssid=$(echo "$network" | grep -o '"bssid":"[^"]*"' | cut -d'"' -f4)
        local ssid=$(echo "$network" | grep -o '"ssid":"[^"]*"' | cut -d'"' -f4)
        
        echo "Debug: Extracted channel=$channel, signal=$signal, ssid=$ssid, bssid=$bssid" >&2
        
        if [ -n "$channel" ] && [ -n "$signal" ]; then
            # Validate channel for frequency band
            local valid_channel=false
            
            if [ "$frequency_band" = "2.4GHz" ]; then
                if [ $channel -ge 1 ] && [ $channel -le 14 ]; then
                    valid_channel=true
                fi
            elif [ "$frequency_band" = "5GHz" ]; then
                # 5GHz channels: 36,40,44,48,52,56,60,64,100,104,108,112,116,120,124,128,132,136,140,144,149,153,157,161,165
                case $channel in
                    36|40|44|48|52|56|60|64|100|104|108|112|116|120|124|128|132|136|140|144|149|153|157|161|165)
                        valid_channel=true
                        ;;
                esac
            fi
            
            if [ "$valid_channel" = "true" ]; then
                echo "Debug: Adding $frequency_band channel $channel with signal $signal, ssid=$ssid" >&2
                
                # Add to channel-based results (keep strongest signal per channel)
                if [ "$first_channel" = "true" ]; then
                    first_channel=false
                else
                    channel_results="${channel_results},"
                fi
                channel_results="${channel_results}\"$channel\":$signal"
                
                # Add to detailed network list
                if [ "$first_network" = "true" ]; then
                    first_network=false
                else
                    network_details="${network_details},"
                fi
                
                # Handle empty SSID and escape for JSON
                if [ -z "$ssid" ]; then
                    escaped_ssid="Hidden Network"
                else
                    escaped_ssid=$(echo "$ssid" | sed 's/\\/\\\\/g; s/"/\\"/g')
                fi
                network_details="${network_details}{\"channel\":$channel,\"signal\":$signal,\"bssid\":\"$bssid\",\"ssid\":\"$escaped_ssid\"}"
                
                network_count=$((network_count + 1))
            fi
        fi
    done < "$temp_file"
    
    rm -f "$temp_file"
    channel_results="${channel_results}}"
    network_details="${network_details}]"
    
    echo "Debug: Final channel_results=$channel_results, network_count=$network_count" >&2
    echo "Debug: Network details=$network_details" >&2
    echo "${channel_results}|${network_count}|${network_details}"
}

# Function to report 2.4GHz results
report_2g_results() {
    local scan_data=$1
    echo "Processing 2.4GHz scan results..." >&2
    
    # Check if scan data is empty
    if [ "$scan_data" = "[]" ] || [ -z "$scan_data" ]; then
        echo "2.4GHz scan returned no results - sending empty result set" >&2
        local api_data="{\"scan_results\":[],\"nearby_networks\":0,\"interference_level\":\"low\"}"
        echo "Reporting 2.4GHz results to server..." >&2
        call_api "$API_BASE/2g-results" "POST" "$api_data"
        return
    fi
    
    # Convert scan results to enhanced format
    local result=$(convert_scan_results_to_channels "$scan_data" "2.4GHz")
    local channel_results=$(echo "$result" | cut -d'|' -f1)
    local network_count=$(echo "$result" | cut -d'|' -f2)
    local network_details=$(echo "$result" | cut -d'|' -f3)
    local interference_level=$(calculate_interference_level $network_count)
    
    echo "2.4GHz Networks found: $network_count, Interference: $interference_level" >&2
    
    # Build API request data - use network_details as scan_results (API expects array format)
    local api_data="{\"scan_results\":$network_details,\"nearby_networks\":$network_count,\"interference_level\":\"$interference_level\"}"
    
    echo "Reporting 2.4GHz results to server..." >&2
    call_api "$API_BASE/2g-results" "POST" "$api_data"
}

# Function to report 5GHz results
report_5g_results() {
    local scan_data=$1
    echo "Processing 5GHz scan results..." >&2
    
    # Check if scan data is empty
    if [ "$scan_data" = "[]" ] || [ -z "$scan_data" ]; then
        echo "5GHz scan returned no results - sending empty result set" >&2
        local api_data="{\"scan_results\":[],\"nearby_networks\":0,\"interference_level\":\"low\"}"
        echo "Reporting 5GHz results to server..." >&2
        call_api "$API_BASE/5g-results" "POST" "$api_data"
        return
    fi
    
    # Convert scan results to enhanced format
    local result=$(convert_scan_results_to_channels "$scan_data" "5GHz")
    local channel_results=$(echo "$result" | cut -d'|' -f1)
    local network_count=$(echo "$result" | cut -d'|' -f2)
    local network_details=$(echo "$result" | cut -d'|' -f3)  
    local interference_level=$(calculate_interference_level $network_count)
    
    echo "5GHz Networks found: $network_count, Interference: $interference_level" >&2
    
    # Build API request data - use network_details as scan_results (API expects array format)
    local api_data="{\"scan_results\":$network_details,\"nearby_networks\":$network_count,\"interference_level\":\"$interference_level\"}"
    
    echo "Reporting 5GHz results to server..." >&2
    call_api "$API_BASE/5g-results" "POST" "$api_data"
}

# Function to find interface for a radio (optional - we can scan directly on radio)
find_interface_for_radio() {
    local radio=$1
    local interface=""
    
    # Look for existing interfaces associated with this radio
    for iface in $(iwinfo 2>/dev/null | grep -o '^[a-zA-Z0-9]*'); do
        # Check if this interface belongs to our radio
        iface_phy=$(iw dev "$iface" info 2>/dev/null | grep wiphy | awk '{print "phy"$2}')
        if [ "$iface_phy" = "$radio" ]; then
            interface="$iface"
            break
        fi
    done
    
    # Return existing interface or empty (we'll use radio directly)
    echo "$interface"
}

# Function to find UCI wireless section for a radio
find_wireless_section() {
    local radio=$1
    local section=""
    
    echo "Debug: Finding UCI wireless section for radio $radio" >&2
    
    # Map physical radio names to UCI radio names
    # phy0 -> radio0, phy1 -> radio1
    local uci_radio=""
    case "$radio" in
        "phy0") uci_radio="radio0" ;;
        "phy1") uci_radio="radio1" ;;
        "phy2") uci_radio="radio2" ;;
        "phy3") uci_radio="radio3" ;;
        *) uci_radio="$radio" ;;  # fallback to original name
    esac
    
    echo "Debug: Mapped $radio to UCI radio: $uci_radio" >&2
    
    # Check if this UCI radio section exists
    if uci get wireless.${uci_radio} >/dev/null 2>&1; then
        echo "Debug: Found UCI wireless section: $uci_radio for radio $radio" >&2
        echo "$uci_radio"
        return 0
    fi
    
    # Fallback: List all wireless sections and find the one with matching device
    for section_name in $(uci show wireless | grep -o 'wireless\.[^.]*' | sort -u | grep -v 'wireless\.@'); do
        local device=$(uci get ${section_name}.device 2>/dev/null)
        if [ "$device" = "$radio" ] || [ "$device" = "$uci_radio" ]; then
            section=$(echo "$section_name" | cut -d'.' -f2)
            echo "Debug: Found wireless section: $section for radio $radio" >&2
            echo "$section"
            return 0
        fi
    done
    
    # Try alternative approach - look for wifi-device sections
    for section_name in $(uci show wireless | grep 'wifi-device' | cut -d'=' -f1 | cut -d'.' -f2); do
        if [ "$section_name" = "$radio" ] || [ "$section_name" = "$uci_radio" ]; then
            echo "Debug: Found wifi-device section: $section_name for radio $radio" >&2
            echo "$section_name"
            return 0
        fi
    done
    
    echo "Debug: No UCI wireless section found for radio $radio" >&2
    echo ""
}

# Function to get current channel for a radio
get_current_channel() {
    local radio=$1
    local channel=""
    
    echo "Debug: Getting current channel for $radio" >&2
    
    # Find the correct UCI wireless section
    local wireless_section=$(find_wireless_section "$radio")
    echo "Debug: Using wireless section: $wireless_section" >&2
    
    # Try to get channel from UCI config first
    if [ -n "$wireless_section" ]; then
        channel=$(uci get wireless.${wireless_section}.channel 2>/dev/null)
        echo "Debug: UCI channel for $wireless_section: $channel" >&2
    fi
    
    # If not found in UCI, try to get from iwinfo
    if [ -z "$channel" ]; then
        local iface=$(find_interface_for_radio "$radio")
        echo "Debug: Trying iwinfo with interface: $iface" >&2
        if [ -n "$iface" ]; then
            local iwinfo_output=$(iwinfo "$iface" info 2>/dev/null)
            echo "Debug: iwinfo output: $iwinfo_output" >&2
            channel=$(echo "$iwinfo_output" | grep -o 'Channel: [0-9]*' | grep -o '[0-9]*')
        fi
    fi
    
    echo "Debug: Final detected channel: $channel" >&2
    echo "$channel"
}

# Function to set channel for a radio
set_channel() {
    local radio=$1
    local channel=$2
    
    echo "Debug: Setting channel $channel for radio $radio" >&2
    
    # Find the correct UCI wireless section
    local wireless_section=$(find_wireless_section "$radio")
    echo "Debug: Using wireless section: $wireless_section for channel setting" >&2
    
    if [ -n "$wireless_section" ]; then
        # Set channel in UCI
        uci set wireless.${wireless_section}.channel="$channel"
        uci commit wireless
        
        # Restart wifi to apply changes
        wifi reload
        sleep 5
        
        echo "Debug: Channel set to $channel for $radio via section $wireless_section" >&2
        return 0
    else
        echo "ERROR: Could not find UCI wireless section for radio $radio" >&2
        return 1
    fi
}

# Function to get current channel width for a radio
get_channel_width() {
    local radio=$1
    local width=""
    
    echo "Debug: Getting channel width for $radio" >&2
    
    # Find the correct UCI wireless section
    local wireless_section=$(find_wireless_section "$radio")
    echo "Debug: Using wireless section: $wireless_section for width detection" >&2
    
    # Try to get width from UCI config first
    if [ -n "$wireless_section" ]; then
        local htmode=$(uci get wireless.${wireless_section}.htmode 2>/dev/null)
        echo "Debug: UCI htmode for $wireless_section: $htmode" >&2
        
        if [ -n "$htmode" ]; then
            width=$(echo "$htmode" | sed 's/VHT//' | sed 's/HT//' | sed 's/HE//')
            echo "Debug: Extracted width from UCI: $width" >&2
        fi
    fi
    
    # If not found in UCI, try to get from iwinfo
    if [ -z "$width" ]; then
        local iface=$(find_interface_for_radio "$radio")
        echo "Debug: Trying iwinfo with interface: $iface" >&2
        if [ -n "$iface" ]; then
            local iwinfo_output=$(iwinfo "$iface" info 2>/dev/null)
            echo "Debug: iwinfo output: $iwinfo_output" >&2
            width=$(echo "$iwinfo_output" | grep -o 'Channel: [0-9]* ([0-9]*' | grep -o '[0-9]*$')
        fi
    fi
    
    # Default to 160 if we can't detect it
    if [ -z "$width" ]; then
        width="160"
        echo "Debug: Defaulting to 160MHz" >&2
    fi
    
    echo "Debug: Final detected width: $width" >&2
    echo "$width"
}

# Function to set channel width for a radio
set_channel_width() {
    local radio=$1
    local width=$2
    local current_htmode=""
    
    echo "Setting channel width to ${width}MHz for $radio" >&2
    
    # Find the correct UCI wireless section
    local wireless_section=$(find_wireless_section "$radio")
    echo "Debug: Using wireless section: $wireless_section for width setting" >&2
    
    if [ -z "$wireless_section" ]; then
        echo "ERROR: Could not find UCI wireless section for radio $radio" >&2
        return 1
    fi
    
    # Get current htmode to preserve VHT/HT prefix
    current_htmode=$(uci get wireless.${wireless_section}.htmode 2>/dev/null)
    
    # Determine the appropriate htmode based on width
    local new_htmode=""
    case "$width" in
        20) new_htmode="HT20" ;;
        40) new_htmode="HT40" ;;
        80) new_htmode="VHT80" ;;
        160) new_htmode="VHT160" ;;
        *) new_htmode="VHT80" ;;  # Default fallback
    esac
    
    # If we have 802.11ax support, use HE instead of VHT
    if echo "$current_htmode" | grep -q "HE"; then
        new_htmode=$(echo "$new_htmode" | sed 's/VHT/HE/')
    fi
    
    # Set the new htmode
    uci set wireless.${wireless_section}.htmode="$new_htmode" 2>/dev/null
    uci commit wireless 2>/dev/null
    
    # Apply the changes
    wifi reload 2>/dev/null
    sleep 2  # Wait for changes to take effect
    
    echo "Changed $radio htmode to $new_htmode via section $wireless_section" >&2
    return 0
}

# Function to scan WiFi networks
scan_wifi() {
    local interface=$1
    local radio=$2
    local band=$3
    local temp_file=$(mktemp)
    local cells_file=$(mktemp)
    local json="[]"
    
    echo "Scanning $band band on radio $radio..." >&2
    
    # Use existing interface if available, otherwise scan directly on radio
    if [ -n "$interface" ]; then
        echo "Using interface $interface for scan" >&2
        iwinfo $interface scan > "$temp_file" 2>/dev/null
        local scan_exit_code=$?
        echo "Debug: iwinfo $interface scan exit code: $scan_exit_code" >&2
    else
        echo "Using radio $radio directly for scan" >&2
        iwinfo $radio scan > "$temp_file" 2>/dev/null
        local scan_exit_code=$?
        echo "Debug: iwinfo $radio scan exit code: $scan_exit_code" >&2
    fi
    
    echo "Debug: Temp file size after scan: $(wc -c < "$temp_file") bytes" >&2
    if [ -s "$temp_file" ]; then
        echo "Debug: First few lines of scan output:" >&2
        head -5 "$temp_file" >&2
    else
        echo "Debug: Scan temp file is empty - trying alternative methods" >&2
        
        # Try alternative scanning methods
        if [ -n "$interface" ]; then
            echo "Debug: Trying iw scan on interface $interface" >&2
            iw dev "$interface" scan 2>/dev/null | awk '
                /^BSS / { 
                    gsub(/\(.*\)/, "", $2)
                    bssid = $2
                }
                /freq:/ { 
                    freq = $2
                    if (freq >= 2400 && freq <= 2500) channel = int((freq - 2412) / 5) + 1
                    else if (freq >= 5000) channel = int((freq - 5000) / 5)
                }
                /signal:/ { signal = $2 }
                /SSID:/ { 
                    ssid = $2
                    for(i=3; i<=NF; i++) ssid = ssid " " $i
                    print "Cell 01 - Address: " bssid
                    print "          ESSID:\"" ssid "\""  
                    print "          Mode:Master"
                    print "          Channel:" channel
                    print "          Signal level=" signal " dBm"
                    print ""
                }
            ' > "$temp_file"
        else
            echo "Debug: Trying direct phy scan" >&2
            # Create a temporary monitor interface for scanning
            local temp_mon="mon_tmp_$$"
            echo "Debug: Creating temporary monitor interface $temp_mon" >&2
            iw phy "$radio" interface add "$temp_mon" type monitor 2>/dev/null
            if [ $? -eq 0 ]; then
                ip link set "$temp_mon" up 2>/dev/null
                sleep 2
                iw dev "$temp_mon" scan 2>/dev/null | awk '
                    /^BSS / { 
                        gsub(/\(.*\)/, "", $2)
                        bssid = $2
                    }
                    /freq:/ { 
                        freq = $2
                        if (freq >= 2400 && freq <= 2500) channel = int((freq - 2412) / 5) + 1
                        else if (freq >= 5000) channel = int((freq - 5000) / 5)
                    }
                    /signal:/ { signal = $2 }
                    /SSID:/ { 
                        ssid = $2
                        for(i=3; i<=NF; i++) ssid = ssid " " $i
                        print "Cell 01 - Address: " bssid
                        print "          ESSID:\"" ssid "\""  
                        print "          Mode:Master"
                        print "          Channel:" channel
                        print "          Signal level=" signal " dBm"
                        print ""
                    }
                ' > "$temp_file"
                ip link set "$temp_mon" down 2>/dev/null
                iw dev "$temp_mon" del 2>/dev/null
            fi
        fi
        
        echo "Debug: Temp file size after alternative scan: $(wc -c < "$temp_file") bytes" >&2
        if [ -s "$temp_file" ]; then
            echo "Debug: Alternative scan worked, first few lines:" >&2
            head -5 "$temp_file" >&2
        fi
    fi
    
    sleep 2
    
    if [ -s "$temp_file" ]; then
        # Split the file into cells
        grep -A20 "Cell" "$temp_file" | sed 's/--/\nCELL_SEPARATOR\n/g' > "$cells_file"
        
        # Process each cell
        json="["
        local first=true
        local in_cell=false
        local cell_id=""
        local bssid=""
        local ssid=""
        local signal=""
        local channel=""
        
        while IFS= read -r line; do
            if echo "$line" | grep -q "Cell"; then
                # If we were processing a cell, add it to the JSON
                if [ "$in_cell" = "true" ] && [ -n "$bssid" ] && [ -n "$signal" ] && [ -n "$channel" ]; then
                    if [ "$first" = "true" ]; then
                        first=false
                    else
                        json="${json},"
                    fi
                    
                    # Escape special characters in SSID
                    ssid=$(echo "$ssid" | sed 's/\\/\\\\/g; s/"/\\"/g')
                    json="${json}{\"cell_id\":\"$cell_id\",\"bssid\":\"$bssid\",\"ssid\":\"$ssid\",\"signal\":$signal,\"channel\":$channel}"
                fi
                
                # Start a new cell and extract cell ID
                in_cell=true
                cell_id=$(echo "$line" | grep -o 'Cell [0-9]*' | grep -o '[0-9]*')
                bssid=$(echo "$line" | grep -o -E "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}")
                ssid=""
                signal=""
                channel=""
            elif echo "$line" | grep -q "CELL_SEPARATOR"; then
                # End of a cell, reset
                in_cell=false
            elif [ "$in_cell" = "true" ]; then
                # Extract data from the current cell
                if echo "$line" | grep -q "ESSID:"; then
                    ssid=$(echo "$line" | grep -o 'ESSID: ".*"' | cut -d'"' -f2)
                elif echo "$line" | grep -q "Signal:"; then
                    signal=$(echo "$line" | grep -o 'Signal: -[0-9]* dBm' | grep -o '\-[0-9]*')
                elif echo "$line" | grep -q "Channel:"; then
                    # Only capture primary channel, not secondary
                    if ! echo "$line" | grep -q "Secondary Channel"; then
                        channel=$(echo "$line" | grep -o 'Channel: [0-9]*' | grep -o '[0-9]*')
                    fi
                fi
            fi
        done < "$cells_file"
        
        # Add the last cell if we were processing one
        if [ "$in_cell" = "true" ] && [ -n "$bssid" ] && [ -n "$signal" ] && [ -n "$channel" ]; then
            if [ "$first" = "true" ]; then
                first=false
            else
                json="${json},"
            fi
            
            # Escape special characters in SSID
            ssid=$(echo "$ssid" | sed 's/\\/\\\\/g; s/"/\\"/g')
            json="${json}{\"cell_id\":\"$cell_id\",\"bssid\":\"$bssid\",\"ssid\":\"$ssid\",\"signal\":$signal,\"channel\":$channel}"
        fi
        
        json="${json}]"
    fi
    
    rm -f "$temp_file" "$cells_file"
    echo "Debug: Final JSON result: $json" >&2
    echo "$json"
}

# Cleanup temporary interfaces (no longer needed but kept for safety)
cleanup_temp_interfaces() {
    for iface in $(iwinfo 2>/dev/null | grep -o '^tmp_scan_[0-9]*'); do
        echo "Cleaning up temporary interface: $iface" >&2
        ip link set "$iface" down 2>/dev/null
        iw dev "$iface" del 2>/dev/null
    done
}

echo "=== Neighbourhood WiFi Scanner with API Reporting ===" >&2
echo "Scan ID: $SCAN_ID" >&2
echo >&2

# Report scan started to server
if ! report_scan_started; then
    echo "ERROR: Failed to report scan started to server" >&2
    exit 1
fi

# Step 1: Find the radio and interface for 2.4GHz and 5.8GHz
echo "Step 1: Detecting radios and interfaces..." >&2
radio_2_4=""
radio_5_8=""
interface_2_4=""
interface_5_8=""

for device in /sys/class/ieee80211/*/device; do
    if [ -e "$device" ]; then
        radio=$(basename $(dirname "$device"))
        echo "Found radio: $radio" >&2
        
        # Check if radio supports 2.4GHz
        if iwinfo "$radio" freqlist 2>/dev/null | grep -q "2\.[4-5][0-9][0-9] GHz"; then
            radio_2_4="$radio"
            interface_2_4=$(find_interface_for_radio "$radio")
            echo "  -> 2.4GHz radio: $radio_2_4, interface: $interface_2_4" >&2
        fi
        
        # Check if radio supports 5GHz
        if iwinfo "$radio" freqlist 2>/dev/null | grep -q "5\.[0-9][0-9][0-9] GHz"; then
            radio_5_8="$radio"
            interface_5_8=$(find_interface_for_radio "$radio")
            echo "  -> 5.8GHz radio: $radio_5_8, interface: $interface_5_8" >&2
        fi
    fi
done

# Check if we found required radios
if [ -z "$radio_2_4" ] && [ -z "$radio_5_8" ]; then
    error_msg="No WiFi radios detected"
    echo "ERROR: $error_msg" >&2
    report_scan_failed "$error_msg"
    exit 1
fi

echo >&2

# Step 2: Scan 2.4GHz and report results
echo "Step 2: Scanning 2.4GHz..." >&2
scan_2_4_result="[]"
if [ -n "$radio_2_4" ]; then
    scan_2_4_result=$(scan_wifi "$interface_2_4" "$radio_2_4" "2.4GHz")
    if [ $? -eq 0 ] && [ "$scan_2_4_result" != "[]" ]; then
        echo "2.4GHz scan completed successfully" >&2
        # Report 2.4GHz results to server
        if ! report_2g_results "$scan_2_4_result"; then
            error_msg="Failed to report 2.4GHz results to server"
            echo "ERROR: $error_msg" >&2
            report_scan_failed "$error_msg"
            exit 1
        fi
    else
        error_msg="2.4GHz scan failed or returned no results"
        echo "ERROR: $error_msg" >&2
        report_scan_failed "$error_msg"
        exit 1
    fi
else
    echo "No 2.4GHz radio available - skipping" >&2
fi

echo >&2

# Step 3-6: Handle 5.8GHz with channel and channel width management and report results
echo "Step 3-6: Scanning 5.8GHz with channel and channel width management..." >&2
scan_5_8_result="[]"
original_width=""
original_channel=""

if [ -n "$radio_5_8" ]; then
    # Get current channel and channel width
    original_channel=$(get_current_channel "$radio_5_8")
    original_width=$(get_channel_width "$radio_5_8")
    echo "Current 5.8GHz channel: ${original_channel}, width: ${original_width}MHz" >&2
    
    # Set channel to 36 for scanning
    echo "Setting channel to 36 for scanning..." >&2
    if ! set_channel "$radio_5_8" "36"; then
        error_msg="Failed to set 5.8GHz channel to 36"
        echo "ERROR: $error_msg" >&2
        report_scan_failed "$error_msg"
        exit 1
    fi
    
    # Change to 80MHz for scanning if needed
    if [ "$original_width" != "80" ]; then
        echo "Changing channel width to 80MHz for scanning..." >&2
        if ! set_channel_width "$radio_5_8" "80"; then
            error_msg="Failed to change 5.8GHz channel width to 80MHz"
            echo "ERROR: $error_msg" >&2
            report_scan_failed "$error_msg"
            exit 1
        fi
    fi
    
    # Update interface reference after wifi reload
    interface_5_8=$(find_interface_for_radio "$radio_5_8")
    
    # Scan 5.8GHz
    scan_5_8_result=$(scan_wifi "$interface_5_8" "$radio_5_8" "5.8GHz")
    if [ $? -eq 0 ]; then
        echo "5.8GHz scan completed successfully" >&2
        # Report 5.8GHz results to server (this completes the scan)
        if ! report_5g_results "$scan_5_8_result"; then
            error_msg="Failed to report 5.8GHz results to server"
            echo "ERROR: $error_msg" >&2
            report_scan_failed "$error_msg"
            exit 1
        fi
    else
        error_msg="5.8GHz scan failed"
        echo "ERROR: $error_msg" >&2
        report_scan_failed "$error_msg"
        exit 1
    fi
    
    # Restore original channel if it was changed
    if [ -n "$original_channel" ] && [ "$original_channel" != "36" ]; then
        echo "Restoring channel to ${original_channel}..." >&2
        if ! set_channel "$radio_5_8" "$original_channel"; then
            echo "WARNING: Failed to restore original channel" >&2
        fi
    fi
    
    # Restore original channel width if it was changed
    if [ "$original_width" != "80" ] && [ -n "$original_width" ]; then
        echo "Restoring channel width to ${original_width}MHz..." >&2
        if ! set_channel_width "$radio_5_8" "$original_width"; then
            echo "WARNING: Failed to restore original channel width" >&2
        fi
    fi
else
    echo "No 5.8GHz radio available - skipping" >&2
fi

echo >&2

# Clean up any temporary interfaces
cleanup_temp_interfaces

# Print the final result
echo "=== Scan Completed Successfully ===" >&2
echo "All results have been reported to the server via API" >&2
echo "Scan ID: $SCAN_ID" >&2

# Optional: still output local results for debugging
json_result="{\"scan_results\":{\"radio_2_4\":\"$radio_2_4\",\"radio_5_8\":\"$radio_5_8\",\"interface_2_4\":\"$interface_2_4\",\"interface_5_8\":\"$interface_5_8\",\"scan_2_4ghz\":$scan_2_4_result,\"scan_5_8ghz\":$scan_5_8_result}}"

echo "Local results: $json_result"


