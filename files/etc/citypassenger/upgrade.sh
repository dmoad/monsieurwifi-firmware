key=$(uci get citypassenger.@device[0].key)
secret=$(uci get citypassenger.@device[0].secret)
api_domain=$(uci get citypassenger.@device[0].api_domain)
api="$api_domain/api/devices/$key/$secret/settings"
response=$(curl -s "$api")
echo $api
echo $response

status=$(echo "$response" | jq -r '.status')

if [ "$status" = "success" ]; then
    # Handle firmware updates from API response
    firmware_version=$(echo "$response" | jq -r '.firmware.version // empty')
    firmware_file_path=$(echo "$response" | jq -r '.firmware.file_path // empty')
    
    if [ -n "$firmware_version" ] && [ -n "$firmware_file_path" ]; then
        # Check if firmware_version is numeric (integer or decimal)
        if ! echo "$firmware_version" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
            echo "Error: firmware_version '$firmware_version' is not numeric. Aborting upgrade."
            exit 1
        fi
        echo "Checking firmware version..."

        # Get current local firmware version (stored in UCI)
        current_firmware_version=$(uci get citypassenger.@device[0].firmware_version 2>/dev/null || echo "0")

        echo "Current firmware version: $current_firmware_version"
        echo "API firmware version: $firmware_version"

        if [ "$current_firmware_version" != "$firmware_version" ]; then
            echo "Firmware update available, downloading and installing..."

            # Create temporary directory for firmware download
            firmware_temp_dir="/tmp/firmware_update"
            rm -rf $firmware_temp_dir
            mkdir -p "$firmware_temp_dir"

            # Download firmware file
            firmware_filename=$(basename "$firmware_file_path")
            echo "Downloading firmware from: $firmware_file_path"

            if curl -L -o "$firmware_temp_dir/$firmware_filename" "$firmware_file_path"; then
                echo "Firmware download completed successfully"

                # Extract firmware file
                cd "$firmware_temp_dir"
                if tar -xzf "$firmware_filename"; then
                    echo "Firmware extraction completed"

                    # Check if the expected directory structure exists
                    if [ -d "monsieur-wifi-firmware/src" ]; then
                        cd "monsieur-wifi-firmware/src"

                        # Check if configure.sh exists and is executable
                        if [ -f "configure.sh" ]; then
                            echo "Running firmware configuration script..."
                            chmod +x configure.sh

                            if ./configure.sh; then
                                echo "Firmware configuration completed successfully"
                                
                                # Update local firmware version in UCI
                                uci set citypassenger.@device[0].firmware_version="$firmware_version"
                                uci set citypassenger.@device[0].config_version="0"
                                uci commit citypassenger
                                echo "Updated local firmware version to: $firmware_version"
                            else
                                echo "Error: Firmware configuration script failed"
                            fi
                        else
                            echo "Warning: configure.sh not found in firmware package"
                        fi
                    else
                        echo "Error: Expected firmware directory structure not found"
                    fi
                else
                    echo "Error: Failed to extract firmware file"
                fi

                # Clean up temporary files
                rm -rf "$firmware_temp_dir"
                echo "Firmware update process completed, temporary files cleaned up"
            else
                echo "Error: Failed to download firmware file"
                rm -rf "$firmware_temp_dir"
            fi
        else
            echo "Firmware is up to date (version $firmware_version)"
        fi
    else
        echo "No firmware information in API response"
    fi

else
    echo "API request failed or invalid response"
fi