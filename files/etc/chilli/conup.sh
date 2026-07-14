#!/bin/sh

ip=${FRAMED_IP_ADDRESS}
tun=${DEV}
case $tun in
        "tun1")
            dev="br-lan.1"
	    dev_id="1"
            ;;
        "tun2")
            dev="br-network2"
	    dev_id="2"
            ;;
        "tun3")
            dev="br-network3"
	    dev_id="3"
            ;;
        "tun4")
            dev="br-network4"
	    dev_id="4"
            ;;
        *)
            logger "Unknown TUNTAP device: $tun"
            return
            ;;
esac
up=${WISPR_BANDWIDTH_MAX_UP}
dl=${WISPR_BANDWIDTH_MAX_DOWN}
up_mb=$((up / 1000000))
dl_mb=$((dl / 1000000))
mac=${CALLING_STATION_ID}
cnt="$dev_id$(tc class show dev $dev | wc -l)"

ip_entry=$(uci -c /tmp show chilli_users_$dev_id | grep "$ip" | cut -d'=' -f1 | sed 's/\.[^\.]*$//') # Extract the section path
if [ -n "$ip_entry" ]; then
    echo "Entry for IP $ip found: $ip_entry. Deleting..."
    uci -c /tmp delete "$ip_entry"
    uci -c /tmp commit chilli_users_$dev_id
else
    echo "No entry for IP $ip found. Proceeding to add a new entry..."
fi

mac_entry=$(uci -c /tmp show chilli_users_$dev_id | grep "$mac" | cut -d'=' -f1 | sed 's/\.[^\.]*$//') # Extract t
if [ -n "$mac_entry" ]; then
    echo "Entry for MAC $mac found: $mac_entry. Deleting..."
    uci -c /tmp delete "$mac_entry"
    uci -c /tmp commit chilli_users_$dev_id
else
    echo "No entry for mac $mac found. Proceeding to add a new entry..."
fi

while :; do
    id_entry=$(uci -c /tmp show chilli_users_$dev_id | grep "id='$cnt'" | cut -d'=' -f1 | sed 's/\.[^\.]*$//' | head -n 1)
    
    if [ -n "$id_entry" ]; then
        echo "Deleting entry: $id_entry"
        uci -c /tmp delete "$id_entry"
        uci -c /tmp commit chilli_users_$dev_id
    else
        echo "No more entries for ID $cnt found. Exiting..."
        break
    fi
done


# Add a new entry using @device[-1] for the last section
uci -c /tmp add chilli_users_$dev_id device
uci -c /tmp set chilli_users_$dev_id.@device[-1].id="$cnt"
uci -c /tmp set chilli_users_$dev_id.@device[-1].ip="$ip"
uci -c /tmp set chilli_users_$dev_id.@device[-1].mac="$mac"
uci -c /tmp set chilli_users_$dev_id.@device[-1].max_up="$up_mb"
uci -c /tmp set chilli_users_$dev_id.@device[-1].max_down="$dl_mb"

# Commit changes
uci -c /tmp commit chilli_users_$dev_id

if [[ "$up" = 0 || "$dl" = 0 ]]; then
	
	logger "Skipping bandwidth limitation for $mac with IP:$ip. Setting to Unlimited"

else
	logger "setting bandwidth limitation to $mac with IP:$ip."

	tc class replace dev $dev parent 1:1 classid 1:1$cnt htb rate ${dl_mb}mbit ceil ${dl_mb}mbit
	tc filter replace dev $dev parent 1:0 protocol ip u32 match ip dst $ip flowid 1:1$cnt

	tc class replace dev ${dev}-ifb parent 1:1 classid 1:1$cnt htb rate ${up_mb}mbit ceil ${up_mb}mbit
	tc filter replace dev ${dev}-ifb parent 1:0 protocol ip u32 match ip src $ip flowid 1:1$cnt
	
	logger "Bandwidth set to MAX_UP="$up_mb"Mb/sec MAX_DOWN="$dl_mb"Mb/sec for $mac IP:$ip"
fi
