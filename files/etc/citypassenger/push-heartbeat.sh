key=$(uci get citypassenger.@device[0].key)
secret=$(uci get citypassenger.@device[0].secret)
api_domain=$(uci get citypassenger.@device[0].api_domain)
api="$api_domain/api/devices/$key/$secret/heartbeat"
config_version=$(uci get citypassenger.@device[0].config_version)

init=$(uci get citypassenger.@device[0].init)
if [ "$init" = "0" ]; then
    echo "" > /etc/rc.local
    echo "sleep 10" >> /etc/rc.local
    echo "cp /etc/config/chilli_users* /tmp" >> /etc/rc.local
    uci set citypassenger.@device[0].init='1'
    uci commit citypassenger
    reboot -f
fi

# uptime in seconds in integer
uptime=$(cat /proc/uptime | awk '{print $1}' | cut -d'.' -f1)
heartbeat_url="$api?uptime=$uptime"
echo $heartbeat_url

response=$(curl -s "$heartbeat_url")
echo "$response"
new_config_version=$(echo "$response" | jq -r '.config_version')
new_reboot_count=$(echo "$response" | jq -r '.reboot_count')
new_scan_counter=$(echo "$response" | jq -r '.scan_counter')
new_firmware_version=$(echo "$response" | jq -r '.firmware_version')
new_captive_portal_enabled=$(echo "$response" | jq -r '.captive_portal_enabled')

# Get current reboot count, default to 0 if not set
reboot_count=$(uci get citypassenger.@device[0].reboot_count 2>/dev/null || echo "0")
firmware_version=$(uci get citypassenger.@device[0].firmware_version 2>/dev/null || echo "0")
# Get current scan counter, default to 0 if not set
scan_counter=$(uci get citypassenger.@device[0].scan_counter 2>/dev/null || echo "0")

# Handle captive portal enable/disable
if [ "$new_captive_portal_enabled" != "null" ]; then
    # Check if captive portal interfaces are currently disabled
    captive_disabled=$(uci get wireless.captive_radio0.disabled 2>/dev/null || echo "0")
    
    if [ "$new_captive_portal_enabled" = "1" ] && [ "$captive_disabled" = "1" ]; then
        echo "Enabling captive portal"
        uci set wireless.captive_radio0.disabled='0'
        uci set wireless.captive_radio1.disabled='0'
        uci commit wireless
        wifi reload
    elif [ "$new_captive_portal_enabled" = "0" ] && [ "$captive_disabled" = "0" ]; then
        echo "Disabling captive portal"
        uci set wireless.captive_radio0.disabled='1'
        uci set wireless.captive_radio1.disabled='1'
        uci commit wireless
        wifi reload
    fi
fi

if [ "$new_firmware_version" != "$firmware_version" ]; then
    echo "Firmware version changed from $firmware_version to $new_firmware_version - upgrading"
    /etc/citypassenger/upgrade.sh
    uci set citypassenger.@device[0].firmware_version="$new_firmware_version"
    uci commit citypassenger
elif [ "$new_config_version" != "$config_version" ]; then
    echo "Config version changed from $config_version to $new_config_version - updating"
    /etc/citypassenger/update.sh
    uci set citypassenger.@device[0].config_version="$new_config_version"
    uci commit citypassenger
elif [ "$new_reboot_count" != "$reboot_count" ]; then
    echo "Reboot count changed from $reboot_count to $new_reboot_count - rebooting"
    uci set citypassenger.@device[0].reboot_count="$new_reboot_count"
    uci commit citypassenger
    reboot -f
elif [ "$new_scan_counter" != "null" ] && [ "$new_scan_counter" != "0" ] && [ "$new_scan_counter" != "$scan_counter" ]; then
    echo "Scan counter changed from $scan_counter to $new_scan_counter - executing scan"
    uci set citypassenger.@device[0].scan_counter="$new_scan_counter"
    uci commit citypassenger
    # Execute scan script here
    /etc/citypassenger/scan-neighbourhood.sh $new_scan_counter
else
    echo "No new config version or firmware or reboot count change"
fi
