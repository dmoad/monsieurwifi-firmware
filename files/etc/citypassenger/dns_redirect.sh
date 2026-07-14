#!/bin/sh

# Default config (fallback values)
DEFAULT_ROUTER_IP1="192.168.15.1"
DEFAULT_ROUTER_IP2="192.168.2.1"
DEFAULT_SUBNET1="192.168.15.0/24"
DEFAULT_SUBNET2="192.168.2.0/24"

# Get dynamic configuration from UCI or use defaults
get_network_config() {
    # Get captive portal network settings from chilli configuration
    captive_portal_ip=$(uci get chilli.@chilli[0].dhcplisten 2>/dev/null || echo "$DEFAULT_ROUTER_IP1")
    captive_portal_net=$(uci get chilli.@chilli[0].net 2>/dev/null || echo "$DEFAULT_SUBNET1")
    
    # Get password wifi network settings from lan configuration
    password_wifi_ip=$(uci get network.lan.ipaddr 2>/dev/null || echo "$DEFAULT_ROUTER_IP2")
    password_wifi_netmask=$(uci get network.lan.netmask 2>/dev/null || echo "255.255.255.0")
    
    # Convert netmask to CIDR
    netmask_to_cidr() {
        local netmask=$1
        case "$netmask" in
            "255.255.255.0") echo "24" ;;
            "255.255.0.0") echo "16" ;;
            "255.0.0.0") echo "8" ;;
            "255.255.255.128") echo "25" ;;
            "255.255.255.192") echo "26" ;;
            "255.255.255.224") echo "27" ;;
            "255.255.255.240") echo "28" ;;
            "255.255.255.248") echo "29" ;;
            "255.255.255.252") echo "30" ;;
            *) echo "24" ;;  # Default fallback
        esac
    }
    
    # Calculate password wifi network address
    password_cidr=$(netmask_to_cidr "$password_wifi_netmask")
    password_network=$(echo "$password_wifi_ip" | cut -d. -f1-3).0
    
    # Set dynamic values
    ROUTER_IP1="$captive_portal_ip"
    ROUTER_IP2="$password_wifi_ip"
    SUBNET1="$captive_portal_net"  # Use chilli net directly (already in CIDR format)
    SUBNET2="$password_network/$password_cidr"
    
    echo "Dynamic network configuration:"
    echo "  Captive Portal: $ROUTER_IP1 (subnet: $SUBNET1)"
    echo "  Password WiFi: $ROUTER_IP2 (subnet: $SUBNET2)"
}

# Initialize network configuration
get_network_config

IPSET_NAME="doh_block"
FLAG_FILE="/tmp/dns_redirect_enabled"
DNSMASQ_CONF_INCLUDE="/etc/dnsmasq.d/doh-block.conf"

STATIC_DOH_DOMAINS="
cloudflare-dns.com
mozilla.cloudflare-dns.com
dns.google
dns.quad9.net
doh.opendns.com
doh.cleanbrowsing.org
dns.nextdns.io
dns.adguard.com
security.cloudflare-dns.com
use-application-dns.net
dns.tiar.app
dns.seby.io
"

update_doh_domains() {
    echo "[+] Updating DoH resolver list..."
    mkdir -p /etc/dnsmasq.d/
    echo "# Auto-generated DoH block config" > "$DNSMASQ_CONF_INCLUDE"

    echo "[!] Failed to download, falling back to static list"
    for domain in $STATIC_DOH_DOMAINS; do
        echo "ipset=/$domain/$IPSET_NAME" >> "$DNSMASQ_CONF_INCLUDE"
    done
}

populate_ipset() {
    echo "[+] Pre-loading DoH IPs into ipset..."
    grep '^ipset=/' "$DNSMASQ_CONF_INCLUDE" | cut -d'/' -f2 | while read -r domain; do
        nslookup "$domain" 127.0.0.1 >/dev/null 2>&1
    done
}

enable_dns_redirect() {
    echo "[+] Enabling DNS redirection and DoH blocking..."
    
    # Refresh network configuration before enabling
    get_network_config

    for SUBNET in $SUBNET1 $SUBNET2; do
        iptables -t nat -A PREROUTING -s "$SUBNET" -p udp --dport 53 -j DNAT --to-destination "$ROUTER_IP1":53
        iptables -t nat -A PREROUTING -s "$SUBNET" -p tcp --dport 53 -j DNAT --to-destination "$ROUTER_IP1":53
    done

    ipset create $IPSET_NAME hash:ip maxelem 1000 2>/dev/null

    update_doh_domains
    /etc/init.d/dnsmasq restart
    sleep 1
    populate_ipset

    iptables -I FORWARD -m set --match-set $IPSET_NAME dst -j REJECT
    iptables -I OUTPUT  -m set --match-set $IPSET_NAME dst -j REJECT

    touch $FLAG_FILE
    echo "[+] DNS redirection and DoH blocking is now active."
}

disable_dns_redirect() {
    echo "[-] Disabling DNS redirection and DoH blocking..."
    
    # Refresh network configuration before disabling
    get_network_config

    for SUBNET in $SUBNET1 $SUBNET2; do
        iptables -t nat -D PREROUTING -s "$SUBNET" -p udp --dport 53 -j DNAT --to-destination "$ROUTER_IP1":53 2>/dev/null
        iptables -t nat -D PREROUTING -s "$SUBNET" -p tcp --dport 53 -j DNAT --to-destination "$ROUTER_IP1":53 2>/dev/null
    done

    iptables -D FORWARD -m set --match-set $IPSET_NAME dst -j REJECT 2>/dev/null
    iptables -D OUTPUT  -m set --match-set $IPSET_NAME dst -j REJECT 2>/dev/null

    ipset flush $IPSET_NAME 2>/dev/null
    ipset destroy $IPSET_NAME 2>/dev/null

    rm -f "$DNSMASQ_CONF_INCLUDE"
    /etc/init.d/dnsmasq restart

    rm -f "$FLAG_FILE"
    echo "[-] DNS redirection and DoH blocking is now disabled."
}

case "$1" in
    enable)
        [ -f "$FLAG_FILE" ] && echo "[!] Already enabled." && exit 1
        enable_dns_redirect
        ;;
    disable)
        [ ! -f "$FLAG_FILE" ] && echo "[!] Already disabled." && exit 1
        disable_dns_redirect
        ;;
    *)
        echo "Usage: $0 {enable|disable}"
        exit 1
        ;;
esac
