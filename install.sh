#!/bin/bash
#
# https://github.com/Nyr/wireguard-install
#
# Copyright (c) 2020 Nyr. Released under the MIT License.


# Detect Debian users running the script with "sh" instead of bash
if readlink /proc/$$/exe | grep -q "dash"; then
	echo 'This installer needs to be run with "bash", not "sh".'
	exit
fi

# Discard stdin. Needed when running from a one-liner which includes a newline
read -N 999999 -t 0.001

# Detect OS
# $os_version variables aren't always in use, but are kept here for convenience
if grep -qs "ubuntu" /etc/os-release; then
	os="ubuntu"
	os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
elif [[ -e /etc/debian_version ]]; then
	os="debian"
	os_version=$(grep -oE '[0-9]+' /etc/debian_version | head -1)
elif [[ -e /etc/almalinux-release || -e /etc/rocky-release || -e /etc/centos-release ]]; then
	os="centos"
	os_version=$(grep -shoE '[0-9]+' /etc/almalinux-release /etc/rocky-release /etc/centos-release | head -1)
elif [[ -e /etc/fedora-release ]]; then
	os="fedora"
	os_version=$(grep -oE '[0-9]+' /etc/fedora-release | head -1)
else
	echo "This installer seems to be running on an unsupported distribution.
Supported distros are Ubuntu, Debian, AlmaLinux, Rocky Linux, CentOS and Fedora."
	exit
fi

if [[ "$os" == "ubuntu" && "$os_version" -lt 2204 ]]; then
	echo "Ubuntu 22.04 or higher is required to use this installer.
This version of Ubuntu is too old and unsupported."
	exit
fi

if [[ "$os" == "debian" ]]; then
	if grep -q '/sid' /etc/debian_version; then
		echo "Debian Testing and Debian Unstable are unsupported by this installer."
		exit
	fi
	if [[ "$os_version" -lt 11 ]]; then
		echo "Debian 11 or higher is required to use this installer.
This version of Debian is too old and unsupported."
		exit
	fi
fi

if [[ "$os" == "centos" && "$os_version" -lt 9 ]]; then
	os_name=$(sed 's/ release.*//' /etc/almalinux-release /etc/rocky-release /etc/centos-release 2>/dev/null | head -1)
	echo "$os_name 9 or higher is required to use this installer.
This version of $os_name is too old and unsupported."
	exit
fi

# Detect environments where $PATH does not include the sbin directories
if ! grep -q sbin <<< "$PATH"; then
	echo '$PATH does not include sbin. Try using "su -" instead of "su".'
	exit
fi

# Detect if BoringTun (userspace WireGuard) needs to be used
if ! systemd-detect-virt -cq; then
	# Not running inside a container
	use_boringtun="0"
elif grep -q '^wireguard ' /proc/modules; then
	# Running inside a container, but the wireguard kernel module is available
	use_boringtun="0"
else
	# Running inside a container and the wireguard kernel module is not available
	use_boringtun="1"
fi

if [[ "$EUID" -ne 0 ]]; then
	echo "This installer needs to be run with superuser privileges."
	exit
fi

if [[ "$use_boringtun" -eq 1 ]]; then
	if [ "$(uname -m)" != "x86_64" ]; then
		echo "In containerized systems without the wireguard kernel module, this installer
supports only the x86_64 architecture.
The system runs on $(uname -m) and is unsupported."
		exit
	fi
	# TUN device is required to use BoringTun
	if [[ ! -e /dev/net/tun ]] || ! ( exec 7<>/dev/net/tun ) 2>/dev/null; then
		echo "The system does not have the TUN device available.
TUN needs to be enabled before running this installer."
		exit
	fi
fi

# Store the absolute path of the directory where the script is located
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

sync_awg_quick_config () {
	local src="$1"
	local dst="$2"
	[[ -e "$src" ]] || return
	mkdir -p "$(dirname "$dst")"
	cat "$src" > "$dst"
	chmod 600 "$dst"
}

sync_main_awg_config () {
	sync_awg_quick_config /etc/wireguard/wg0.conf /etc/amnezia/amneziawg/wg0.conf
}

valid_ipv4_octet () {
	[[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 0 && 10#$1 <= 255 ))
}

valid_ipv4_subnet () {
	local first second third extra
	IFS=. read -r first second third extra <<< "$1"
	[[ -z "$extra" ]] || return 1
	valid_ipv4_octet "$first" && valid_ipv4_octet "$second" && valid_ipv4_octet "$third"
}

wg_ipv4_address () {
	grep '^Address' /etc/wireguard/wg0.conf | cut -d " " -f 3 | tr ',' '\n' | grep -m 1 -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+'
}

wg_ipv4_subnet () {
	wg_ipv4_address | cut -d "/" -f 1 | cut -d "." -f 1-3
}

wg_ipv4_cidr () {
	echo "$(wg_ipv4_subnet).0/24"
}

next_ipv4_subnet () {
	local first second third extra
	IFS=. read -r first second third extra <<< "$1"
	if (( 10#$third < 255 )); then
		echo "$first.$second.$((10#$third+1))"
	else
		echo "$first.$second.254"
	fi
}

wg_ipv6_cidr () {
	grep '^Address' /etc/wireguard/wg0.conf | cut -d " " -f 3- | tr ',' '\n' | grep -m 1 -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}/[0-9]+' | sed 's/::1\/64$/::\/64/'
}

sync_extra_in_peers () {
	return
}

write_extra_rules_script () {
	cat << 'EOF' > /usr/local/sbin/awg-route-rules
#!/bin/bash
set -e

env_file="${AWG_ROUTE_ENV:-${WG_EXTRA_TUN_ENV:-${2:-/etc/wireguard/awg-default.env}}}"
. "$env_file"

add_iptables_rule () {
	local table="$1"
	shift
	"$IPTABLES_PATH" -w 5 -t "$table" -C "$@" 2>/dev/null || "$IPTABLES_PATH" -w 5 -t "$table" -A "$@"
}

insert_iptables_rule () {
	local table="$1"
	local chain="$2"
	shift 2
	"$IPTABLES_PATH" -w 5 -t "$table" -C "$chain" "$@" 2>/dev/null || "$IPTABLES_PATH" -w 5 -t "$table" -I "$chain" 1 "$@"
}

del_iptables_rule () {
	local table="$1"
	shift
	while "$IPTABLES_PATH" -w 5 -t "$table" -C "$@" 2>/dev/null; do
		"$IPTABLES_PATH" -w 5 -t "$table" -D "$@"
	done
}

add_ip6tables_rule () {
	local table="$1"
	shift
	"$IP6TABLES_PATH" -w 5 -t "$table" -C "$@" 2>/dev/null || "$IP6TABLES_PATH" -w 5 -t "$table" -A "$@"
}

insert_ip6tables_rule () {
	local table="$1"
	local chain="$2"
	shift 2
	"$IP6TABLES_PATH" -w 5 -t "$table" -C "$chain" "$@" 2>/dev/null || "$IP6TABLES_PATH" -w 5 -t "$table" -I "$chain" 1 "$@"
}

del_ip6tables_rule () {
	local table="$1"
	shift
	while "$IP6TABLES_PATH" -w 5 -t "$table" -C "$@" 2>/dev/null; do
		"$IP6TABLES_PATH" -w 5 -t "$table" -D "$@"
	done
}

firewalld_direct () {
	firewall-cmd --direct "$@" 2>/dev/null || true
}

set_kernel_settings () {
	echo 1 > /proc/sys/net/ipv4/ip_forward
	echo 1 > /proc/sys/net/ipv4/conf/all/src_valid_mark 2>/dev/null || true
	for iface in all default "$EXTRA_IN_IF" "$EXTRA_UP_IF"; do
		if [[ -e "/proc/sys/net/ipv4/conf/$iface/rp_filter" ]]; then
			echo 0 > "/proc/sys/net/ipv4/conf/$iface/rp_filter"
		fi
	done
	if [[ -n "$VPN6_CIDR" ]]; then
		echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
	fi
}

start_routes () {
	ip rule show | grep -q "iif $EXTRA_IN_IF lookup $EXTRA_TABLE" || ip rule add iif "$EXTRA_IN_IF" table "$EXTRA_TABLE" priority "$EXTRA_IIF_PRIORITY"
	ip rule show | grep -q "fwmark $EXTRA_MARK lookup $EXTRA_TABLE" || ip rule add fwmark "$EXTRA_MARK" table "$EXTRA_TABLE" priority "$EXTRA_MARK_PRIORITY"
	ip route replace "$VPN_CIDR" dev "$EXTRA_IN_IF" table "$EXTRA_TABLE"
	ip route replace default dev "$EXTRA_UP_IF" table "$EXTRA_TABLE"
	if [[ -n "$VPN6_CIDR" ]]; then
		ip -6 rule show | grep -q "iif $EXTRA_IN_IF lookup $EXTRA_TABLE" || ip -6 rule add iif "$EXTRA_IN_IF" table "$EXTRA_TABLE" priority "$EXTRA_IIF_PRIORITY"
		ip -6 rule show | grep -q "fwmark $EXTRA_MARK lookup $EXTRA_TABLE" || ip -6 rule add fwmark "$EXTRA_MARK" table "$EXTRA_TABLE" priority "$EXTRA_MARK_PRIORITY"
		ip -6 route replace "$VPN6_CIDR" dev "$EXTRA_IN_IF" table "$EXTRA_TABLE"
		ip -6 route replace default dev "$EXTRA_UP_IF" table "$EXTRA_TABLE"
	fi
	ip route flush cache
}

stop_routes () {
	ip route del default dev "$EXTRA_UP_IF" table "$EXTRA_TABLE" 2>/dev/null || true
	ip route del "$VPN_CIDR" dev "$EXTRA_IN_IF" table "$EXTRA_TABLE" 2>/dev/null || true
	while ip rule show | grep -q "iif $EXTRA_IN_IF lookup $EXTRA_TABLE"; do
		ip rule del iif "$EXTRA_IN_IF" table "$EXTRA_TABLE" priority "$EXTRA_IIF_PRIORITY" 2>/dev/null || break
	done
	while ip rule show | grep -q "fwmark $EXTRA_MARK lookup $EXTRA_TABLE"; do
		ip rule del fwmark "$EXTRA_MARK" table "$EXTRA_TABLE" priority "$EXTRA_MARK_PRIORITY" 2>/dev/null || break
	done
	if [[ -n "$VPN6_CIDR" ]]; then
		ip -6 route del default dev "$EXTRA_UP_IF" table "$EXTRA_TABLE" 2>/dev/null || true
		ip -6 route del "$VPN6_CIDR" dev "$EXTRA_IN_IF" table "$EXTRA_TABLE" 2>/dev/null || true
		while ip -6 rule show | grep -q "iif $EXTRA_IN_IF lookup $EXTRA_TABLE"; do
			ip -6 rule del iif "$EXTRA_IN_IF" table "$EXTRA_TABLE" priority "$EXTRA_IIF_PRIORITY" 2>/dev/null || break
		done
		while ip -6 rule show | grep -q "fwmark $EXTRA_MARK lookup $EXTRA_TABLE"; do
			ip -6 rule del fwmark "$EXTRA_MARK" table "$EXTRA_TABLE" priority "$EXTRA_MARK_PRIORITY" 2>/dev/null || break
		done
	fi
	ip route flush cache
}

start_firewall () {
	if systemctl is-active --quiet firewalld.service; then
		firewall-cmd --add-port="$EXTRA_PORT"/udp
		firewalld_direct --add-rule ipv4 mangle PREROUTING 0 -i "$EXTRA_IN_IF" -j MARK --set-mark "$EXTRA_MARK"
		firewalld_direct --add-rule ipv4 mangle PREROUTING 0 -i "$EXTRA_IN_IF" -j CONNMARK --save-mark
		firewalld_direct --add-rule ipv4 mangle PREROUTING 0 -i "$EXTRA_UP_IF" -j CONNMARK --restore-mark
		firewalld_direct --add-rule ipv4 mangle FORWARD 0 -i "$EXTRA_IN_IF" -o "$EXTRA_UP_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
		firewalld_direct --add-rule ipv4 mangle FORWARD 0 -i "$EXTRA_UP_IF" -o "$EXTRA_IN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
		firewalld_direct --add-rule ipv4 nat POSTROUTING -10 -s "$VPN_CIDR" -o "$EXTRA_UP_IF" -j MASQUERADE
		firewalld_direct --add-rule ipv4 filter FORWARD 0 -i "$EXTRA_IN_IF" -o "$EXTRA_UP_IF" -s "$VPN_CIDR" -j ACCEPT
		firewalld_direct --add-rule ipv4 filter FORWARD 0 -i "$EXTRA_UP_IF" -o "$EXTRA_IN_IF" -d "$VPN_CIDR" -m state --state RELATED,ESTABLISHED -j ACCEPT
		if [[ -n "$VPN6_CIDR" ]]; then
			firewalld_direct --add-rule ipv6 mangle PREROUTING 0 -i "$EXTRA_IN_IF" -j MARK --set-mark "$EXTRA_MARK"
			firewalld_direct --add-rule ipv6 mangle PREROUTING 0 -i "$EXTRA_IN_IF" -j CONNMARK --save-mark
			firewalld_direct --add-rule ipv6 mangle PREROUTING 0 -i "$EXTRA_UP_IF" -j CONNMARK --restore-mark
			firewalld_direct --add-rule ipv6 mangle FORWARD 0 -i "$EXTRA_IN_IF" -o "$EXTRA_UP_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
			firewalld_direct --add-rule ipv6 mangle FORWARD 0 -i "$EXTRA_UP_IF" -o "$EXTRA_IN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
			firewalld_direct --add-rule ipv6 nat POSTROUTING -10 -s "$VPN6_CIDR" -o "$EXTRA_UP_IF" -j MASQUERADE
			firewalld_direct --add-rule ipv6 filter FORWARD 0 -i "$EXTRA_IN_IF" -o "$EXTRA_UP_IF" -s "$VPN6_CIDR" -j ACCEPT
			firewalld_direct --add-rule ipv6 filter FORWARD 0 -i "$EXTRA_UP_IF" -o "$EXTRA_IN_IF" -d "$VPN6_CIDR" -m state --state RELATED,ESTABLISHED -j ACCEPT
		fi
	else
		add_iptables_rule mangle PREROUTING -i "$EXTRA_IN_IF" -j MARK --set-mark "$EXTRA_MARK"
		add_iptables_rule mangle PREROUTING -i "$EXTRA_IN_IF" -j CONNMARK --save-mark
		add_iptables_rule mangle PREROUTING -i "$EXTRA_UP_IF" -j CONNMARK --restore-mark
		add_iptables_rule mangle FORWARD -i "$EXTRA_IN_IF" -o "$EXTRA_UP_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
		add_iptables_rule mangle FORWARD -i "$EXTRA_UP_IF" -o "$EXTRA_IN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
		insert_iptables_rule nat POSTROUTING -s "$VPN_CIDR" -o "$EXTRA_UP_IF" -j MASQUERADE
		add_iptables_rule filter INPUT -p udp --dport "$EXTRA_PORT" -j ACCEPT
		add_iptables_rule filter FORWARD -i "$EXTRA_IN_IF" -o "$EXTRA_UP_IF" -s "$VPN_CIDR" -j ACCEPT
		add_iptables_rule filter FORWARD -i "$EXTRA_UP_IF" -o "$EXTRA_IN_IF" -d "$VPN_CIDR" -m state --state RELATED,ESTABLISHED -j ACCEPT
		if [[ -n "$VPN6_CIDR" ]]; then
			add_ip6tables_rule mangle PREROUTING -i "$EXTRA_IN_IF" -j MARK --set-mark "$EXTRA_MARK"
			add_ip6tables_rule mangle PREROUTING -i "$EXTRA_IN_IF" -j CONNMARK --save-mark
			add_ip6tables_rule mangle PREROUTING -i "$EXTRA_UP_IF" -j CONNMARK --restore-mark
			add_ip6tables_rule mangle FORWARD -i "$EXTRA_IN_IF" -o "$EXTRA_UP_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
			add_ip6tables_rule mangle FORWARD -i "$EXTRA_UP_IF" -o "$EXTRA_IN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
			insert_ip6tables_rule nat POSTROUTING -s "$VPN6_CIDR" -o "$EXTRA_UP_IF" -j MASQUERADE
			add_ip6tables_rule filter FORWARD -i "$EXTRA_IN_IF" -o "$EXTRA_UP_IF" -s "$VPN6_CIDR" -j ACCEPT
			add_ip6tables_rule filter FORWARD -i "$EXTRA_UP_IF" -o "$EXTRA_IN_IF" -d "$VPN6_CIDR" -m state --state RELATED,ESTABLISHED -j ACCEPT
		fi
	fi
}

stop_firewall () {
	if systemctl is-active --quiet firewalld.service; then
		firewall-cmd --remove-port="$EXTRA_PORT"/udp 2>/dev/null || true
		firewalld_direct --remove-rule ipv4 mangle PREROUTING 0 -i "$EXTRA_IN_IF" -j MARK --set-mark "$EXTRA_MARK"
		firewalld_direct --remove-rule ipv4 mangle PREROUTING 0 -i "$EXTRA_IN_IF" -j CONNMARK --save-mark
		firewalld_direct --remove-rule ipv4 mangle PREROUTING 0 -i "$EXTRA_UP_IF" -j CONNMARK --restore-mark
		firewalld_direct --remove-rule ipv4 mangle FORWARD 0 -i "$EXTRA_IN_IF" -o "$EXTRA_UP_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
		firewalld_direct --remove-rule ipv4 mangle FORWARD 0 -i "$EXTRA_UP_IF" -o "$EXTRA_IN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
		firewalld_direct --remove-rule ipv4 nat POSTROUTING -10 -s "$VPN_CIDR" -o "$EXTRA_UP_IF" -j MASQUERADE
		firewalld_direct --remove-rule ipv4 nat POSTROUTING 0 -s "$VPN_CIDR" -o "$EXTRA_UP_IF" -j MASQUERADE
		firewalld_direct --remove-rule ipv4 filter FORWARD 0 -i "$EXTRA_IN_IF" -o "$EXTRA_UP_IF" -s "$VPN_CIDR" -j ACCEPT
		firewalld_direct --remove-rule ipv4 filter FORWARD 0 -i "$EXTRA_UP_IF" -o "$EXTRA_IN_IF" -d "$VPN_CIDR" -m state --state RELATED,ESTABLISHED -j ACCEPT
		if [[ -n "$VPN6_CIDR" ]]; then
			firewalld_direct --remove-rule ipv6 mangle PREROUTING 0 -i "$EXTRA_IN_IF" -j MARK --set-mark "$EXTRA_MARK"
			firewalld_direct --remove-rule ipv6 mangle PREROUTING 0 -i "$EXTRA_IN_IF" -j CONNMARK --save-mark
			firewalld_direct --remove-rule ipv6 mangle PREROUTING 0 -i "$EXTRA_UP_IF" -j CONNMARK --restore-mark
			firewalld_direct --remove-rule ipv6 mangle FORWARD 0 -i "$EXTRA_IN_IF" -o "$EXTRA_UP_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
			firewalld_direct --remove-rule ipv6 mangle FORWARD 0 -i "$EXTRA_UP_IF" -o "$EXTRA_IN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
			firewalld_direct --remove-rule ipv6 nat POSTROUTING -10 -s "$VPN6_CIDR" -o "$EXTRA_UP_IF" -j MASQUERADE
			firewalld_direct --remove-rule ipv6 nat POSTROUTING 0 -s "$VPN6_CIDR" -o "$EXTRA_UP_IF" -j MASQUERADE
			firewalld_direct --remove-rule ipv6 filter FORWARD 0 -i "$EXTRA_IN_IF" -o "$EXTRA_UP_IF" -s "$VPN6_CIDR" -j ACCEPT
			firewalld_direct --remove-rule ipv6 filter FORWARD 0 -i "$EXTRA_UP_IF" -o "$EXTRA_IN_IF" -d "$VPN6_CIDR" -m state --state RELATED,ESTABLISHED -j ACCEPT
		fi
	else
		del_iptables_rule mangle PREROUTING -i "$EXTRA_IN_IF" -j MARK --set-mark "$EXTRA_MARK"
		del_iptables_rule mangle PREROUTING -i "$EXTRA_IN_IF" -j CONNMARK --save-mark
		del_iptables_rule mangle PREROUTING -i "$EXTRA_UP_IF" -j CONNMARK --restore-mark
		del_iptables_rule mangle FORWARD -i "$EXTRA_IN_IF" -o "$EXTRA_UP_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
		del_iptables_rule mangle FORWARD -i "$EXTRA_UP_IF" -o "$EXTRA_IN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
		del_iptables_rule nat POSTROUTING -s "$VPN_CIDR" -o "$EXTRA_UP_IF" -j MASQUERADE
		del_iptables_rule filter INPUT -p udp --dport "$EXTRA_PORT" -j ACCEPT
		del_iptables_rule filter FORWARD -i "$EXTRA_IN_IF" -o "$EXTRA_UP_IF" -s "$VPN_CIDR" -j ACCEPT
		del_iptables_rule filter FORWARD -i "$EXTRA_UP_IF" -o "$EXTRA_IN_IF" -d "$VPN_CIDR" -m state --state RELATED,ESTABLISHED -j ACCEPT
		if [[ -n "$VPN6_CIDR" ]]; then
			del_ip6tables_rule mangle PREROUTING -i "$EXTRA_IN_IF" -j MARK --set-mark "$EXTRA_MARK"
			del_ip6tables_rule mangle PREROUTING -i "$EXTRA_IN_IF" -j CONNMARK --save-mark
			del_ip6tables_rule mangle PREROUTING -i "$EXTRA_UP_IF" -j CONNMARK --restore-mark
			del_ip6tables_rule mangle FORWARD -i "$EXTRA_IN_IF" -o "$EXTRA_UP_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
			del_ip6tables_rule mangle FORWARD -i "$EXTRA_UP_IF" -o "$EXTRA_IN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
			del_ip6tables_rule nat POSTROUTING -s "$VPN6_CIDR" -o "$EXTRA_UP_IF" -j MASQUERADE
			del_ip6tables_rule filter FORWARD -i "$EXTRA_IN_IF" -o "$EXTRA_UP_IF" -s "$VPN6_CIDR" -j ACCEPT
			del_ip6tables_rule filter FORWARD -i "$EXTRA_UP_IF" -o "$EXTRA_IN_IF" -d "$VPN6_CIDR" -m state --state RELATED,ESTABLISHED -j ACCEPT
		fi
	fi
}

case "$1" in
	start)
		set_kernel_settings
		start_routes
		start_firewall
	;;
	stop)
		stop_firewall
		stop_routes
	;;
	*)
		echo "Usage: $0 {start|stop}"
		exit 1
	;;
esac
EOF
	chmod +x /usr/local/sbin/awg-route-rules
}

add_extra_tun () {
	echo
	echo "Legacy 2nd hop setup is retired. Use the web panel upstreams; it creates awg-up-* and awg-in-* interfaces."
	return 1
	if [[ -e /etc/wireguard/wg-extra-tun.env ]]; then
		echo
		echo "2nd hop upstream tun is already installed."
		exit
	fi
	shopt -s nullglob
	config_files=("$script_dir"/*.conf)
	shopt -u nullglob
	if [[ "${#config_files[@]}" -eq 0 ]]; then
		echo
		echo "No .conf files were found in $script_dir."
		exit
	fi
	echo
	echo "Select the WireGuard config for the upstream server:"
	for i in "${!config_files[@]}"; do
		echo "   $((i+1))) $(basename "${config_files[$i]}")"
	done
	read -p "Config: " config_number
	until [[ "$config_number" =~ ^[0-9]+$ && "$config_number" -ge 1 && "$config_number" -le "${#config_files[@]}" ]]; do
		echo "$config_number: invalid selection."
		read -p "Config: " config_number
	done
	upstream_config="${config_files[$((config_number-1))]}"
	if ! grep -q '^\[Interface\]' "$upstream_config" || ! grep -q '^\[Peer\]' "$upstream_config" || ! grep -q '^Endpoint' "$upstream_config"; then
		echo
		echo "$(basename "$upstream_config") does not look like a complete WireGuard client config."
		exit
	fi
	main_port=$(grep '^ListenPort' /etc/wireguard/wg0.conf | cut -d " " -f 3)
	echo
	echo "What port should the extra WireGuard entry listen on?"
	read -p "Port [51821]: " extra_port
	until [[ -z "$extra_port" || "$extra_port" =~ ^[0-9]+$ && "$extra_port" -le 65535 && "$extra_port" != "$main_port" ]]; do
		echo "$extra_port: invalid port."
		read -p "Port [51821]: " extra_port
	done
	[[ -z "$extra_port" ]] && extra_port="51821"
	if [[ "$extra_port" == "$main_port" ]]; then
		echo
		echo "2nd hop upstream tun port cannot be the same as the main WireGuard port."
		exit
	fi
	main_subnet=$(wg_ipv4_subnet)
	default_extra_subnet=$(next_ipv4_subnet "$main_subnet")
	echo
	echo "What IPv4 subnet should 2nd hop upstream tun use?"
	read -p "2nd hop subnet [$default_extra_subnet]: " extra_subnet
	until [[ -z "$extra_subnet" ]] || { valid_ipv4_subnet "$extra_subnet" && [[ "$extra_subnet" != "$main_subnet" ]]; }; do
		echo "$extra_subnet: invalid subnet. Use the first three IPv4 octets and do not reuse $main_subnet."
		read -p "2nd hop subnet [$default_extra_subnet]: " extra_subnet
	done
	[[ -z "$extra_subnet" ]] && extra_subnet="$default_extra_subnet"
	awk '
		/^[[:space:]]*\[Interface\][[:space:]]*$/ {
			in_interface=1
			table_seen=0
			print
			next
		}
		/^[[:space:]]*\[/ {
			if (in_interface && !table_seen) {
				print "Table = off"
			}
			in_interface=0
		}
		in_interface && /^[[:space:]]*DNS[[:space:]]*=/ {
			next
		}
		in_interface && /^[[:space:]]*Table[[:space:]]*=/ {
			if (!table_seen) {
				print "Table = off"
			}
			table_seen=1
			next
		}
		{ print }
		END {
			if (in_interface && !table_seen) {
				print "Table = off"
			}
		}
	' "$upstream_config" > /etc/wireguard/wg-extra-up.conf
	chmod 600 /etc/wireguard/wg-extra-up.conf
	sync_awg_quick_config /etc/wireguard/wg-extra-up.conf /etc/amnezia/amneziawg/wg-extra-up.conf
	write_extra_in_config "$extra_port" "$extra_subnet"
	iptables_path=$(command -v iptables)
	ip6tables_path=$(command -v ip6tables)
	if [[ $(systemd-detect-virt) == "openvz" ]] && readlink -f "$(command -v iptables)" | grep -q "nft" && hash iptables-legacy 2>/dev/null; then
		iptables_path=$(command -v iptables-legacy)
		ip6tables_path=$(command -v ip6tables-legacy)
	fi
	cat << EOF > /etc/wireguard/wg-extra-tun.env
EXTRA_PORT=$extra_port
EXTRA_TABLE=$extra_port
EXTRA_MARK=0xca6d
EXTRA_IIF_PRIORITY=10021
EXTRA_MARK_PRIORITY=10022
EXTRA_IN_IF=wg-extra-in
EXTRA_UP_IF=wg-extra-up
EXTRA_VPN_SUBNET=$extra_subnet
VPN_CIDR=$extra_subnet.0/24
VPN6_CIDR=
IPTABLES_PATH=$iptables_path
IP6TABLES_PATH=$ip6tables_path
EOF
	chmod 600 /etc/wireguard/wg-extra-tun.env
	generated_extra_configs=0
	old_client="$client"
	while read -r existing_client; do
		if [[ -e "$script_dir"/"$existing_client.conf" ]]; then
			client="$existing_client"
			new_client_extra_setup
			(( generated_extra_configs++ ))
		fi
	done < <(grep '^# BEGIN_PEER' /etc/wireguard/wg0.conf | cut -d ' ' -f 3)
	client="$old_client"
	write_extra_rules_script
	cat << EOF > /etc/systemd/system/wg-extra-tun.service
[Unit]
After=network-online.target awg-quick@wg-extra-up.service awg-quick@wg-extra-in.service
Wants=network-online.target awg-quick@wg-extra-up.service awg-quick@wg-extra-in.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wg-extra-tun-rules start
ExecStop=/usr/local/sbin/wg-extra-tun-rules stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now awg-quick@wg-extra-up.service
	systemctl enable --now awg-quick@wg-extra-in.service
	systemctl enable --now wg-extra-tun.service
	echo
	echo "2nd hop upstream tun added. Clients using port $extra_port will be routed through $(basename "$upstream_config")."
	echo "2nd hop upstream tun clients will use the $extra_subnet.0/24 subnet."
	if [[ "$generated_extra_configs" -gt 0 ]]; then
		echo "Generated $generated_extra_configs 2nd hop upstream tun client config(s) in $script_dir."
	fi
}

remove_extra_tun () {
	if [[ ! -e /etc/wireguard/wg-extra-tun.env ]]; then
		echo
		echo "2nd hop upstream tun is not installed."
		exit
	fi
	systemctl disable --now wg-extra-tun.service 2>/dev/null || true
	systemctl disable --now awg-quick@wg-extra-in.service 2>/dev/null || true
	systemctl disable --now awg-quick@wg-extra-up.service 2>/dev/null || true
	rm -f /etc/systemd/system/wg-extra-tun.service
	rm -f /usr/local/sbin/wg-extra-tun-rules
	rm -f /etc/wireguard/wg-extra-tun.env
	rm -f /etc/wireguard/wg-extra-in.conf
	rm -f /etc/wireguard/wg-extra-up.conf
	rm -f /etc/amnezia/amneziawg/wg-extra-in.conf
	rm -f /etc/amnezia/amneziawg/wg-extra-up.conf
	systemctl daemon-reload
	echo
	echo "2nd hop upstream tun removed."
}

cleanup_web_manager_networks () {
	systemctl disable --now awg-quick@wg0.service 2>/dev/null || true
	systemctl disable --now wg-iptables.service 2>/dev/null || true
	ip link del wg0 2>/dev/null || true
	rm -f /etc/systemd/system/wg-iptables.service /etc/sysctl.d/99-wireguard-forward.conf
	if [[ -e /usr/local/sbin/wg-extra-tun-rules ]]; then
		for env_file in /etc/wireguard/wg-extra-tun.env /etc/wireguard/wg-extra-tun-*.env; do
			[[ -e "$env_file" ]] || continue
			WG_EXTRA_TUN_ENV="$env_file" /usr/local/sbin/wg-extra-tun-rules stop 2>/dev/null || true
		done
	fi
	systemctl disable --now wg-extra-tun.service awg-quick@wg-extra-in.service awg-quick@wg-extra-up.service 2>/dev/null || true
	for service_file in /etc/systemd/system/wg-extra-tun-*.service; do
		[[ -e "$service_file" ]] || continue
		service_name=$(basename "$service_file")
		systemctl disable --now "$service_name" 2>/dev/null || true
		rm -f "$service_file"
	done
	for conf_file in /etc/wireguard/wg-in-*.conf /etc/wireguard/wg-up-*.conf; do
		[[ -e "$conf_file" ]] || continue
		iface=$(basename "$conf_file" .conf)
		systemctl disable --now "awg-quick@$iface.service" 2>/dev/null || true
		ip link del "$iface" 2>/dev/null || true
		rm -f "$conf_file"
	done
	for conf_file in /etc/amnezia/amneziawg/wg-in-*.conf /etc/amnezia/amneziawg/wg-up-*.conf; do
		[[ -e "$conf_file" ]] || continue
		iface=$(basename "$conf_file" .conf)
		systemctl disable --now "awg-quick@$iface.service" 2>/dev/null || true
		ip link del "$iface" 2>/dev/null || true
		rm -f "$conf_file"
	done
	for conf_file in /etc/wireguard/awg-d-*.conf /etc/wireguard/awg-u-*.conf /etc/amnezia/amneziawg/awg-direct.conf /etc/amnezia/amneziawg/awg-default.conf /etc/amnezia/amneziawg/awg-in-*.conf /etc/amnezia/amneziawg/awg-up-*.conf /etc/amnezia/amneziawg/awgo-direct.conf /etc/amnezia/amneziawg/awgo-default.conf /etc/amnezia/amneziawg/awgo-*.conf /etc/amnezia/amneziawg/awg-d-*.conf /etc/amnezia/amneziawg/awg-u-*.conf /etc/amnezia/amneziawg/ad-*.conf /etc/amnezia/amneziawg/au-*.conf /etc/amnezia/amneziawg/a?-*.conf /etc/amnezia/amneziawg/a??-*.conf; do
		[[ -e "$conf_file" ]] || continue
		iface=$(basename "$conf_file" .conf)
		systemctl disable --now "awg-quick@$iface.service" "$iface.service" 2>/dev/null || true
		ip link del "$iface" 2>/dev/null || true
		rm -f "$conf_file" /etc/wireguard/"$iface".env /etc/systemd/system/"$iface".service
	done
	for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1); do
		case "$iface" in
			wg-up-*|awg-up-*|awg-direct|awg-default|awg-in-*|awgo-direct|awgo-default|awgo-*|ad-*|au-*|awg-d-*|awg-u-*|a[0-9a-z]-*|a[0-9a-z][0-9a-z]-*)
				systemctl disable --now "awg-quick@$iface.service" "$iface.service" 2>/dev/null || true
				ip link del "$iface" 2>/dev/null || true
			;;
		esac
	done
	ip link del wg-extra-in 2>/dev/null || true
	ip link del wg-extra-up 2>/dev/null || true
	rm -f /etc/wireguard/wg-extra-tun-*.env
	rm -f /etc/wireguard/wg-extra-tun.env /etc/wireguard/wg-extra-in.conf /etc/wireguard/wg-extra-up.conf
	rm -f /etc/amnezia/amneziawg/wg-extra-in.conf /etc/amnezia/amneziawg/wg-extra-up.conf /etc/amnezia/amneziawg/wg-in-*.conf /etc/amnezia/amneziawg/wg-up-*.conf /etc/amnezia/amneziawg/awg-direct.conf /etc/amnezia/amneziawg/awg-default.conf /etc/amnezia/amneziawg/awg-in-*.conf /etc/amnezia/amneziawg/awg-up-*.conf /etc/amnezia/amneziawg/awgo-direct.conf /etc/amnezia/amneziawg/awgo-default.conf /etc/amnezia/amneziawg/awgo-*.conf /etc/amnezia/amneziawg/ad-*.conf /etc/amnezia/amneziawg/au-*.conf /etc/amnezia/amneziawg/a?-*.conf /etc/amnezia/amneziawg/a??-*.conf
	rm -f /etc/wireguard/awg-default.env /etc/wireguard/awg-in-*.env /etc/wireguard/awgo-default.env /etc/wireguard/awgo-*.env /etc/wireguard/ad-*.env /etc/wireguard/au-*.env /etc/wireguard/a?-*.env /etc/wireguard/a??-*.env
	rm -f /etc/systemd/system/awg-default.service /etc/systemd/system/awg-in-*.service /etc/systemd/system/awgo-default.service /etc/systemd/system/awgo-*.service /etc/systemd/system/ad-*.service /etc/systemd/system/au-*.service /etc/systemd/system/a?-*.service /etc/systemd/system/a??-*.service
	systemctl daemon-reload 2>/dev/null || true
}

new_client_dns () {
	echo "Select a DNS server for the client:"
	echo "   1) Default system resolvers"
	echo "   2) Google"
	echo "   3) 1.1.1.1"
	echo "   4) OpenDNS"
	echo "   5) Quad9"
	echo "   6) Gcore"
	echo "   7) AdGuard"
	echo "   8) Specify custom resolvers"
	read -p "DNS server [1]: " dns
	until [[ -z "$dns" || "$dns" =~ ^[1-8]$ ]]; do
		echo "$dns: invalid selection."
		read -p "DNS server [1]: " dns
	done
	case "$dns" in
		1|"")
			# Locate the proper resolv.conf
			# Needed for systems running systemd-resolved
			if grep '^nameserver' "/etc/resolv.conf" | grep -qv '127.0.0.53' ; then
				resolv_conf="/etc/resolv.conf"
			else
				resolv_conf="/run/systemd/resolve/resolv.conf"
			fi
			# Extract nameservers and provide them in the required format
			dns=$(grep -v '^#\|^;' "$resolv_conf" | grep '^nameserver' | grep -v '127.0.0.53' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | xargs | sed -e 's/ /, /g')
		;;
		2)
			dns="8.8.8.8, 8.8.4.4"
		;;
		3)
			dns="1.1.1.1, 1.0.0.1"
		;;
		4)
			dns="208.67.222.222, 208.67.220.220"
		;;
		5)
			dns="9.9.9.9, 149.112.112.112"
		;;
		6)
			dns="95.85.95.85, 2.56.220.2"
		;;
		7)
			dns="94.140.14.14, 94.140.15.15"
		;;
		8)
			echo
			until [[ -n "$custom_dns" ]]; do
				echo "Enter DNS servers (one or more IPv4 addresses, separated by commas or spaces):"
				read -p "DNS servers: " dns_input
				# Convert comma delimited to space delimited
				dns_input=$(echo "$dns_input" | tr ',' ' ')
				# Validate and build custom DNS IP list
				for dns_ip in $dns_input; do
					if [[ "$dns_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
						if [[ -z "$custom_dns" ]]; then
							custom_dns="$dns_ip"
						else
							custom_dns="$custom_dns, $dns_ip"
						fi
					fi
				done
				if [ -z "$custom_dns" ]; then
					echo "Invalid input."
				else
					dns="$custom_dns"
				fi
			done
		;;
	esac
}

new_client_setup () {
	vpn_subnet=$(wg_ipv4_subnet)
	# Given a list of the assigned internal IPv4 addresses, obtain the lowest still
	# available octet. Important to start looking at 2, because 1 is our gateway.
	octet=2
	while grep AllowedIPs /etc/wireguard/wg0.conf | cut -d "." -f 4 | cut -d "/" -f 1 | grep -q "^$octet$"; do
		(( octet++ ))
	done
	# Don't break the WireGuard configuration in case the address space is full
	if [[ "$octet" -eq 255 ]]; then
		echo "253 clients are already configured. The WireGuard internal subnet is full!"
		exit
	fi
	key=$(awg genkey)
	psk=$(awg genpsk)
	# Configure client in the server
	cat << EOF >> /etc/wireguard/wg0.conf
# BEGIN_PEER $client
[Peer]
PublicKey = $(awg pubkey <<< $key)
PresharedKey = $psk
AllowedIPs = $vpn_subnet.$octet/32$(grep -q 'fddd:2c4:2c4:2c4::1' /etc/wireguard/wg0.conf && echo ", fddd:2c4:2c4:2c4::$octet/128")
# END_PEER $client
EOF
	sync_main_awg_config
	# Create client configuration
	cat << EOF > "$script_dir"/"$client".conf
[Interface]
Address = $vpn_subnet.$octet/24$(grep -q 'fddd:2c4:2c4:2c4::1' /etc/wireguard/wg0.conf && echo ", fddd:2c4:2c4:2c4::$octet/64")
DNS = $dns
PrivateKey = $key

[Peer]
PublicKey = $(grep PrivateKey /etc/wireguard/wg0.conf | cut -d " " -f 3 | awg pubkey)
PresharedKey = $psk
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $(grep '^# ENDPOINT' /etc/wireguard/wg0.conf | cut -d " " -f 3):$(grep ListenPort /etc/wireguard/wg0.conf | cut -d " " -f 3)
PersistentKeepalive = 25
EOF
}

new_client_extra_setup () {
	return
	if [[ ! -e /etc/wireguard/wg-extra-tun.env ]]; then
		return
	fi
	extra_port=$(grep '^EXTRA_PORT=' /etc/wireguard/wg-extra-tun.env | cut -d "=" -f 2)
	extra_subnet=$(grep '^EXTRA_VPN_SUBNET=' /etc/wireguard/wg-extra-tun.env | cut -d "=" -f 2)
	if [[ -z "$extra_port" || -z "$extra_subnet" ]]; then
		return
	fi
	awk -v extra_port="$extra_port" -v extra_subnet="$extra_subnet" '
		/^Address = / {
			split($3, ip_parts, ".")
			split(ip_parts[4], last_octet, "/")
			print "Address = " extra_subnet "." last_octet[1] "/24"
			next
		}
		/^Endpoint = / {
			sub(/:[0-9]+$/, ":" extra_port)
			print
			next
		}
		/^AllowedIPs = / {
			print "AllowedIPs = 0.0.0.0/0"
			next
		}
		{ print }
	' "$script_dir"/"$client.conf" > "$script_dir"/"$client-2nd-hop-upstream.conf"
}

print_client_qr_codes () {
	echo
	echo "DIRECT CONFIG ($client.conf)"
	echo
	qrencode -t ANSI256UTF8 < "$script_dir"/"$client.conf"
	echo
	echo "Direct client configuration is available in:" "$script_dir"/"$client.conf"
	if [[ -e "$script_dir"/"$client-2nd-hop-upstream.conf" ]]; then
		printf '\n\n\n\n\n\n\n\n'
		echo "2ND HOP UPSTREAM TUN CONFIG ($client-2nd-hop-upstream.conf)"
		echo
		qrencode -t ANSI256UTF8 < "$script_dir"/"$client-2nd-hop-upstream.conf"
		echo
		echo "2nd hop upstream tun client configuration is available in:" "$script_dir"/"$client-2nd-hop-upstream.conf"
	fi
}

install_amneziawg_support () {
	if hash awg 2>/dev/null && hash awg-quick 2>/dev/null; then
		return
	fi
	echo
	echo "Installing required AmneziaWG packages."
	if [[ "$os" == "ubuntu" ]]; then
		apt-get update
		apt-get install -y software-properties-common python3-launchpadlib gnupg2 "linux-headers-$(uname -r)"
		add-apt-repository -y ppa:amnezia/ppa
		apt-get update
		apt-get install -y amneziawg
	elif [[ "$os" == "debian" ]]; then
		apt-get update
		apt-get install -y software-properties-common python3-launchpadlib gnupg2 "linux-headers-$(uname -r)"
		apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 57290828
		echo "deb https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main" >> /etc/apt/sources.list
		echo "deb-src https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main" >> /etc/apt/sources.list
		apt-get update
		apt-get install -y amneziawg
	elif [[ "$os" == "centos" || "$os" == "fedora" ]]; then
		dnf -y copr enable amneziavpn/amneziawg
		dnf install -y amneziawg-dkms amneziawg-tools
	else
		echo "Automatic AmneziaWG installation is not supported on this distribution."
		exit 1
	fi
	if ! hash awg 2>/dev/null || ! hash awg-quick 2>/dev/null; then
		echo "AmneziaWG installation failed."
		exit 1
	fi
}

install_web_manager () {
	if [[ "$os" != "ubuntu" || "$os_version" -lt 2404 ]]; then
		echo
		echo "The web management panel is supported by this installer on Ubuntu 24.04 or higher."
		exit
	fi

	missing_web_packages=()
	hash openssl 2>/dev/null || missing_web_packages+=("openssl")
	hash curl 2>/dev/null || missing_web_packages+=("curl")
	if [[ "${#missing_web_packages[@]}" -gt 0 ]]; then
		apt-get update
		apt-get install -y "${missing_web_packages[@]}"
	fi

	echo
	echo "Set the web panel admin password."
	echo "Leave it empty to generate a strong password automatically."
	read -rsp "Admin password [auto-generate]: " wg_web_password
	echo
	if [[ -z "$wg_web_password" ]]; then
		wg_web_password="$(openssl rand -base64 18 | tr -d '\n')"
	fi
	wg_web_salt="$(openssl rand -hex 16)"
	wg_web_hash="$(printf '%s%s' "$wg_web_salt" "$wg_web_password" | sha256sum | awk '{print $1}')"
	wg_web_host="$(grep '^# ENDPOINT' /etc/wireguard/wg0.conf | cut -d " " -f 3)"
	[[ -z "$wg_web_host" ]] && wg_web_host="$(hostname -I | awk '{print $1}')"
	wg_bot_token_file=/etc/wireguard/wg-web/bot-api-token
	mkdir -p /etc/wireguard/wg-web
	if [[ ! -s "$wg_bot_token_file" ]]; then
		openssl rand -hex 32 > "$wg_bot_token_file"
		chmod 600 "$wg_bot_token_file"
	fi
	wg_bot_api_token="$(cat "$wg_bot_token_file")"
	echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-awg-forward.conf
	echo 1 > /proc/sys/net/ipv4/ip_forward
	if grep -qs 'fddd:2c4:2c4:2c4::1/64' /etc/wireguard/wg0.conf; then
		echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-awg-forward.conf
		echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
	fi

	if ! hash docker 2>/dev/null || ! docker compose version >/dev/null 2>&1; then
		apt-get update
		apt-get install -y docker.io docker-compose-v2 openssl
	fi
	install_amneziawg_support

	mkdir -p /opt/wg-web/app/app/api/[[...path]]
	mkdir -p /opt/wg-web/app/app/lib
	mkdir -p /opt/wg-web/app/public
	mkdir -p /opt/wg-web/certs /opt/wg-web/acme /opt/wg-web/data /etc/wireguard/clients /etc/wireguard/upstreams /etc/wireguard/wg-web /etc/amnezia/amneziawg
	chmod 700 /etc/wireguard/clients /etc/wireguard/upstreams /etc/wireguard/wg-web

	if [[ ! -e /opt/wg-web/certs/wg-web.crt || ! -e /opt/wg-web/certs/wg-web.key ]]; then
		openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
			-keyout /opt/wg-web/certs/wg-web.key \
			-out /opt/wg-web/certs/wg-web.crt \
			-subj "/CN=$wg_web_host" \
			-addext "subjectAltName=DNS:$wg_web_host,IP:$wg_web_host" >/dev/null 2>&1 || \
		openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
			-keyout /opt/wg-web/certs/wg-web.key \
			-out /opt/wg-web/certs/wg-web.crt \
			-subj "/CN=$wg_web_host" >/dev/null 2>&1
	fi

	cat > /opt/wg-web/.env << EOF
ADMIN_USER=admin
ADMIN_PASSWORD_SALT=$wg_web_salt
ADMIN_PASSWORD_HASH=$wg_web_hash
SESSION_SECRET=$(openssl rand -hex 32)
WG_WEB_PUBLIC_HOST=$wg_web_host
WG_WEB_HTTPS_PORT=8443
WG_WEB_NSENTER=1
BOT_API_TOKEN=$wg_bot_api_token
EOF
	chmod 600 /opt/wg-web/.env

	cat > /opt/wg-web/docker-compose.yml << 'EOF'
services:
  app:
    build: ./app
    restart: unless-stopped
    network_mode: host
    privileged: true
    pid: host
    env_file: .env
    volumes:
      - /etc/wireguard:/etc/wireguard
      - /etc/amnezia:/etc/amnezia
      - /etc/systemd/system:/etc/systemd/system
      - /usr/local/sbin:/usr/local/sbin
      - /run:/run
    environment:
      HOSTNAME: 127.0.0.1
      PORT: 3000

  https:
    image: caddy:2-alpine
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./certs:/certs:ro
      - ./acme:/acme
EOF

	cat > /opt/wg-web/Caddyfile << 'EOF'
http://:80 {
	header {
		X-Robots-Tag "noindex, nofollow, noarchive"
	}
	handle /.well-known/acme-challenge/* {
		root * /acme
		file_server
	}
	respond "WireGuard Control Panel" 200
}

https://:8443 {
	header {
		X-Robots-Tag "noindex, nofollow, noarchive"
	}
	tls /certs/wg-web.crt /certs/wg-web.key
	reverse_proxy 127.0.0.1:3000
}
EOF

	cat > /opt/wg-web/app/Dockerfile << 'EOF'
FROM node:20-bookworm-slim

RUN apt-get update \
	&& apt-get install -y --no-install-recommends bash ca-certificates curl iproute2 iptables util-linux \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json ./
RUN npm install
COPY . .
RUN npm run build

CMD ["sh", "-c", "node worker.js & npm start"]
EOF

	cat > /opt/wg-web/app/package.json << 'EOF'
{
  "private": true,
  "scripts": {
    "build": "next build",
    "start": "next start -H 127.0.0.1 -p 3000"
  },
  "dependencies": {
    "next": "latest",
    "qrcode": "latest",
    "react": "latest",
    "react-dom": "latest"
  }
}
EOF

	cat > /opt/wg-web/app/next.config.js << 'EOF'
const nextConfig = {
  output: "standalone"
};

module.exports = nextConfig;
EOF

	cat > /opt/wg-web/app/public/robots.txt << 'EOF'
User-agent: *
Disallow: /
EOF

	cat > /opt/wg-web/app/app/layout.js << 'EOF'
import "./globals.css";

export const metadata = {
  title: "DD WG Control Panel",
  description: "WireGuard web management panel"
};

export default function RootLayout({ children }) {
  return (
    <html lang="ru">
      <body>{children}</body>
    </html>
  );
}
EOF

	cat > /opt/wg-web/app/app/globals.css << 'EOF'
:root {
  color-scheme: dark;
  --bg: #080a0f;
  --panel: #11151d;
  --panel-2: #171d27;
  --line: #273142;
  --text: #f5f7fb;
  --muted: #97a3b6;
  --accent: #48d597;
  --accent-2: #55a7ff;
  --danger: #ff5d6c;
  --warn: #ffd166;
}

* { box-sizing: border-box; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
button, input, select, textarea {
  font: inherit;
}
button {
  border: 1px solid var(--line);
  background: var(--panel-2);
  color: var(--text);
  border-radius: 8px;
  min-height: 38px;
  padding: 0 12px;
  cursor: pointer;
}
button.primary {
  border-color: transparent;
  background: var(--accent);
  color: #062115;
  font-weight: 700;
}
button.danger {
  border-color: rgba(255, 93, 108, .45);
  color: #ffd5da;
}
input, select, textarea {
  width: 100%;
  min-height: 42px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: #0c1017;
  color: var(--text);
  padding: 10px 12px;
}
input[type="file"] {
  padding: 9px 12px;
}
input[type="checkbox"] {
  width: auto;
  min-height: 0;
  margin-right: 8px;
}
label {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  gap: 7px;
  color: var(--text);
  font-size: 13px;
  font-weight: 650;
  line-height: 1.25;
}
label:has(input[type="checkbox"]) {
  flex-direction: row;
  align-items: center;
  gap: 8px;
  font-weight: 500;
}
label:has(input[type="checkbox"]) input {
  flex: 0 0 auto;
}
textarea { min-height: 92px; resize: vertical; }
.shell {
  min-height: 100vh;
  display: grid;
  grid-template-columns: 260px minmax(0, 1fr);
}
.side {
  border-right: 1px solid var(--line);
  background: #0b0e14;
  padding: 22px 16px;
}
.brand {
  font-weight: 800;
  font-size: 20px;
  margin-bottom: 24px;
}
.nav button {
  width: 100%;
  justify-content: flex-start;
  text-align: left;
  margin-bottom: 8px;
  background: transparent;
}
.nav button.active { background: var(--panel-2); border-color: #3a465a; }
.main { padding: 24px; max-width: 1480px; width: 100%; }
.top {
  display: grid;
  grid-template-columns: repeat(4, minmax(140px, 1fr));
  gap: 12px;
  margin-bottom: 18px;
}
.metric, .panel, .card {
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 8px;
}
.metric { padding: 14px; }
.metric b { display: block; font-size: 22px; margin-top: 6px; }
.muted { color: var(--muted); }
.grid {
  display: grid;
  grid-template-columns: minmax(0, 1.15fr) minmax(320px, .85fr);
  gap: 14px;
}
.panel { padding: 18px; min-width: 0; }
.panel h2 { font-size: 16px; margin: 0 0 16px; }
.row {
  display: grid;
  grid-template-columns: 1fr auto;
  gap: 10px;
  align-items: center;
  padding: 10px 0;
  border-top: 1px solid var(--line);
}
.row:first-of-type { border-top: 0; }
.actions { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
.actions select { width: auto; min-width: 150px; }
.form { display: grid; gap: 14px; align-content: start; }
.form > h2:not(:first-child) {
  margin-top: 8px;
  padding-top: 16px;
  border-top: 1px solid var(--line);
}
.two { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
.chart {
  width: 100%;
  height: 210px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: #0a0d13;
}
.pill {
  display: inline-flex;
  align-items: center;
  min-height: 24px;
  padding: 0 8px;
  border-radius: 999px;
  border: 1px solid var(--line);
  color: var(--muted);
  font-size: 12px;
}
.ok { color: var(--accent); }
.bad { color: var(--danger); }
.warn { color: var(--warn); }
.login {
  min-height: 100vh;
  display: grid;
  place-items: center;
  padding: 20px;
}
.login .panel { width: min(420px, 100%); }
.qr {
  width: min(310px, 100%);
  background: #fff;
  border-radius: 8px;
  padding: 10px;
}
.qr img { width: 100%; display: block; }
@media (max-width: 900px) {
  .shell { grid-template-columns: 1fr; }
  .side { border-right: 0; border-bottom: 1px solid var(--line); }
  .top, .grid, .two { grid-template-columns: 1fr; }
  .row { grid-template-columns: 1fr; align-items: stretch; }
  .actions { justify-content: flex-start; }
  .actions select, .actions button, .actions a { width: 100%; }
  .actions a button { width: 100%; }
  .main { padding: 16px; }
}
EOF

	cat > /opt/wg-web/app/app/lib/core.mjs << 'EOF'
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import fss from "node:fs";
import path from "node:path";
import QRCode from "qrcode";

const execFileAsync = promisify(execFile);
const WG_DIR = "/etc/wireguard";
const AWG_DIR = "/etc/amnezia/amneziawg";
const MAIN_CONF = path.join(WG_DIR, "wg0.conf");
const MAIN_AWG_CONF = path.join(AWG_DIR, "wg0.conf");
const WEB_DIR = "/etc/wireguard/wg-web";
const CLIENT_DIR = "/etc/wireguard/clients";
const UPSTREAM_DIR = "/etc/wireguard/upstreams";
const STATS_FILE = path.join(WEB_DIR, "stats.jsonl");
const CLIENT_META_FILE = path.join(WEB_DIR, "clients-meta.json");
const UPSTREAMS_FILE = path.join(WEB_DIR, "upstreams.json");
const DEFAULT_UPSTREAM_FILE = path.join(WEB_DIR, "default-upstream");
const AWG_STATE_FILE = path.join(WEB_DIR, "awg-state.json");
const HEALTH_FILE = path.join(WEB_DIR, "health.json");
const TELEGRAM_FILE = path.join(WEB_DIR, "telegram.json");
const NOTIFY_STATE_FILE = path.join(WEB_DIR, "notify-state.json");
const CERTBOT_LOG_FILE = path.join(WEB_DIR, "certbot.log");
const DEFAULT_HEALTH = { intervalSeconds: 60, checks: [{ url: "https://www.cloudflare.com/cdn-cgi/trace", expected: "h=" }] };
const AWG_KEYS = ["Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4", "I1"];
const AWG_STRIP_KEYS = [...AWG_KEYS, "I2", "I3", "I4", "I5"];
const DEFAULT_AWG_PARAMS = {
  Jc: "5",
  Jmin: "10",
  Jmax: "50",
  S1: "139",
  S2: "74",
  S3: "44",
  S4: "7",
  H1: "1595333716-1658757027",
  H2: "1948639090-1960026857",
  H3: "2108680017-2134852416",
  H4: "2146018799-2146885576",
  I1: "<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>"
};

async function ensureDirs() {
  await fs.mkdir(AWG_DIR, { recursive: true });
  await fs.mkdir(WEB_DIR, { recursive: true });
  await fs.mkdir(CLIENT_DIR, { recursive: true });
  await fs.mkdir(UPSTREAM_DIR, { recursive: true });
}

export function sanitizeName(name) {
  return String(name || "").replace(/[^0-9a-zA-Z-]/g, "-").slice(0, 14);
}

function strictName(name) {
  const value = String(name || "").trim();
  if (!/^[A-Za-z0-9-]{1,14}$/.test(value)) {
    throw new Error("Name must be 1-14 characters: English letters, numbers and hyphen only");
  }
  return value;
}

function commentText(value) {
  return String(value || "").slice(0, 300);
}

function lookupName(name) {
  return String(name || "").replace(/[^0-9a-zA-Z-]/g, "-").slice(0, 32);
}

export function shaPassword(password) {
  return crypto.createHash("sha256").update(`${process.env.ADMIN_PASSWORD_SALT || ""}${password}`).digest("hex");
}

export function signSession() {
  const payload = `${process.env.ADMIN_USER || "admin"}:${Date.now() + 1000 * 60 * 60 * 12}`;
  const sig = crypto.createHmac("sha256", process.env.SESSION_SECRET || "dev").update(payload).digest("hex");
  return Buffer.from(`${payload}:${sig}`).toString("base64url");
}

export function verifySession(token) {
  try {
    const raw = Buffer.from(token || "", "base64url").toString("utf8");
    const parts = raw.split(":");
    if (parts.length !== 3) return false;
    const [user, expires, sig] = parts;
    if (user !== (process.env.ADMIN_USER || "admin") || Number(expires) < Date.now()) return false;
    const expected = crypto.createHmac("sha256", process.env.SESSION_SECRET || "dev").update(`${user}:${expires}`).digest("hex");
    return crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected));
  } catch {
    return false;
  }
}

async function readText(file, fallback = "") {
  try { return await fs.readFile(file, "utf8"); } catch { return fallback; }
}

async function writeText(file, data, mode = 0o600) {
  await ensureDirs();
  await fs.writeFile(file, data, { mode });
}

async function syncQuickConfig(src, dst) {
  const data = await readText(src);
  if (!data) return;
  await writeText(dst, data);
}

async function writeMainConfig(data) {
  await writeText(MAIN_CONF, data);
  await writeText(MAIN_AWG_CONF, data);
}

async function readJson(file, fallback) {
  try { return JSON.parse(await fs.readFile(file, "utf8")); } catch { return fallback; }
}

async function writeJson(file, data) {
  await writeText(file, JSON.stringify(data, null, 2) + "\n");
}

async function clientMeta() {
  return readJson(CLIENT_META_FILE, {});
}

async function writeClientMeta(data) {
  await writeJson(CLIENT_META_FILE, data);
}

async function awgState() {
  return readJson(AWG_STATE_FILE, {});
}

async function writeAwgState(data) {
  await writeJson(AWG_STATE_FILE, data);
}

function awgParamsForOctet(octet = 1) {
  return { ...DEFAULT_AWG_PARAMS };
}

function normalizeAwgParams(input = {}, fallback = DEFAULT_AWG_PARAMS) {
  const next = {};
  for (const key of AWG_KEYS) next[key] = String(input[key] ?? fallback[key] ?? DEFAULT_AWG_PARAMS[key] ?? "").trim();
  const intRules = {
    Jc: [0, 128],
    Jmin: [0, 1279],
    Jmax: [1, 1280],
    S1: [0, 1132],
    S2: [0, 1188],
    S3: [0, 1216],
    S4: [0, 1280]
  };
  for (const [key, [min, max]] of Object.entries(intRules)) {
    if (!/^[0-9]+$/.test(next[key])) throw new Error(`${key} must be a number`);
    const value = Number(next[key]);
    if (value < min || value > max) throw new Error(`${key} must be between ${min} and ${max}`);
    next[key] = String(value);
  }
  if (Number(next.Jmin) >= Number(next.Jmax)) throw new Error("Jmin must be less than Jmax");
  const ranges = [];
  for (const key of ["H1", "H2", "H3", "H4"]) {
    const value = next[key];
    if (!/^[0-9]+(-[0-9]+)?$/.test(value)) throw new Error(`${key} must be a number or range`);
    const [startRaw, endRaw] = value.split("-");
    const start = Number(startRaw);
    const end = Number(endRaw || startRaw);
    if (start > end || start < 5 || end > 2147483647) throw new Error(`${key} must be a range between 5 and 2147483647`);
    ranges.push({ key, start, end });
  }
  for (let i = 0; i < ranges.length; i++) {
    for (let j = i + 1; j < ranges.length; j++) {
      if (ranges[i].start <= ranges[j].end && ranges[j].start <= ranges[i].end) {
        throw new Error(`${ranges[i].key} and ${ranges[j].key} ranges must not overlap`);
      }
    }
  }
  if (next.I1 && !/^<[^>\n]+>(<[^>\n]+>)*$/.test(next.I1)) {
    throw new Error("I1 must be empty or use AWG tag format like <r 2><b 0x...>");
  }
  return next;
}

function awgParamLines(params) {
  const normalized = normalizeAwgParams(params);
  return AWG_KEYS
    .filter((key) => key !== "I1" || normalized.I1)
    .map((key) => `${key} = ${normalized[key]}`)
    .join("\n");
}

function clientAwgParams(meta, peer) {
  return normalizeAwgParams(DEFAULT_AWG_PARAMS);
}

const SUBSCRIPTION_PLANS = {
  "7d": 7 * 24 * 60 * 60 * 1000,
  "1m": 30 * 24 * 60 * 60 * 1000,
  "3m": 90 * 24 * 60 * 60 * 1000,
  "6m": 180 * 24 * 60 * 60 * 1000,
  "12m": 365 * 24 * 60 * 60 * 1000,
  "24m": 730 * 24 * 60 * 60 * 1000
};
const SUBSCRIPTION_LABELS = { "7d": "7d", "1m": "1m", "3m": "3m", "6m": "6m", "12m": "12m", "24m": "24m", unlimited: "Unlimited" };

function accessKey() {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  let out = "";
  for (let i = 0; i < 16; i++) out += alphabet[crypto.randomInt(alphabet.length)];
  return out;
}

function uniqueAccessKey(meta) {
  let key = accessKey();
  const used = new Set(Object.values(meta || {}).map((item) => item?.accessKey).filter(Boolean));
  while (used.has(key)) key = accessKey();
  return key;
}

function addSubscription(current, plan) {
  if (plan === "unlimited") return null;
  const ms = SUBSCRIPTION_PLANS[plan] || SUBSCRIPTION_PLANS["1m"];
  const base = current && Date.parse(current) > Date.now() ? Date.parse(current) : Date.now();
  return new Date(base + ms).toISOString();
}

function subscriptionExpired(value) {
  return Boolean(value) && Date.parse(value) <= Date.now();
}

function clientSubscription(meta, name) {
  const item = meta[name] || {};
  return {
    expiresAt: item.expiresAt === undefined ? null : item.expiresAt,
    accessKey: item.accessKey || "",
    expired: subscriptionExpired(item.expiresAt)
  };
}

function clientIsDisabled(peer, meta, name) {
  const sub = clientSubscription(meta, name);
  return Boolean(peer.disabled || meta[name]?.disabled || sub.expired);
}

function normalizeClientRoute(input = {}) {
  const value = typeof input === "string" ? { mode: input } : input || {};
  const protocol = value.protocol === "awg" ? "awg" : "wg";
  const mode = value.mode === "direct" ? "direct" : value.mode === "upstream" ? "upstream" : "default";
  const upstreamId = mode === "upstream" ? String(value.upstreamId || "") : "";
  if (mode === "upstream" && !upstreamId) throw new Error("Upstream route requires upstreamId");
  return { protocol, mode, upstreamId };
}

function clientRoute(meta, name) {
  return normalizeClientRoute(meta[name]?.route || { protocol: "wg", mode: "default" });
}

function stripAwgParams(conf) {
  return String(conf || "").replace(new RegExp(`^(${AWG_STRIP_KEYS.join("|")})\\s*=.*\\n?`, "gm"), "");
}

function withAwgParams(conf, params) {
  const cleaned = stripAwgParams(conf).trimEnd();
  const lines = cleaned.split("\n");
  let insertAt = lines.findIndex((line, index) => index > 0 && /^\s*\[/.test(line));
  if (insertAt < 0) insertAt = lines.length;
  lines.splice(insertAt, 0, ...awgParamLines(params).split("\n"));
  return lines.join("\n").trimEnd() + "\n";
}

function protocolTools(protocol = "awg") {
  return {
    protocol: "awg",
    cmd: "awg",
    quick: "awg-quick",
    servicePrefix: "awg-quick@"
  };
}

function quickConfPath(iface, protocol = "awg") {
  return path.join(AWG_DIR, `${iface}.conf`);
}

async function ensureAwgTools() {
  try {
    await hostShell("command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1", 5000);
    return true;
  } catch {
    throw new Error("AmneziaWG tools are not installed. Re-run the installer.");
  }
}

async function host(command, args = [], options = {}) {
  const finalArgs = process.env.WG_WEB_NSENTER === "1"
    ? ["-t", "1", "-m", "-u", "-n", "-i", "--", command, ...args]
    : args;
  const bin = process.env.WG_WEB_NSENTER === "1" ? "nsenter" : command;
  const { stdout, stderr } = await execFileAsync(bin, finalArgs, { timeout: options.timeout || 20000, maxBuffer: 1024 * 1024 * 4 });
  return { stdout, stderr };
}

async function hostShell(script, timeout = 20000) {
  return host("bash", ["-lc", script], { timeout });
}

function peerBlocks(conf) {
  const blocks = [];
  const re = /^# BEGIN_PEER ([^\n]+)\n([\s\S]*?)^# END_PEER \1$/gm;
  let match;
  while ((match = re.exec(conf))) {
    const body = match[2];
    blocks.push({
      name: match[1].trim(),
      body,
      publicKey: (body.match(/^PublicKey = (.+)$/m) || [])[1] || "",
      allowedIPs: (body.match(/^AllowedIPs = (.+)$/m) || [])[1] || "",
      disabled: false
    });
  }
  const disabledRe = /^# BEGIN_DISABLED_PEER ([^\n]+)\n([\s\S]*?)^# END_DISABLED_PEER \1$/gm;
  while ((match = disabledRe.exec(conf))) {
    const body = match[2].split("\n").map((line) => line.startsWith("# ") ? line.slice(2) : line).join("\n");
    blocks.push({
      name: match[1].trim(),
      body,
      publicKey: (body.match(/^PublicKey = (.+)$/m) || [])[1] || "",
      allowedIPs: (body.match(/^AllowedIPs = (.+)$/m) || [])[1] || "",
      disabled: true
    });
  }
  return blocks;
}

function peerBlockPattern(name, disabled = false) {
  const escaped = String(name).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`^# BEGIN_${disabled ? "DISABLED_" : ""}PEER ${escaped}\\n[\\s\\S]*?^# END_${disabled ? "DISABLED_" : ""}PEER ${escaped}\\n?`, "m");
}

function disabledPeerText(name, body) {
  return `# BEGIN_DISABLED_PEER ${name}\n${body.trimEnd().split("\n").map((line) => `# ${line}`).join("\n")}\n# END_DISABLED_PEER ${name}\n`;
}

function activePeerText(name, body) {
  return `# BEGIN_PEER ${name}\n${body.trimEnd()}\n# END_PEER ${name}\n`;
}

function wg0Subnet(conf) {
  const address = (conf.match(/^Address = ([0-9.]+)\.1\/24/m) || [])[1];
  return address || "10.7.0";
}

function wg0Endpoint(conf) {
  return (conf.match(/^# ENDPOINT (.+)$/m) || [])[1] || process.env.WG_WEB_PUBLIC_HOST || "";
}

function wg0Port(conf) {
  return (conf.match(/^ListenPort = ([0-9]+)/m) || [])[1] || "51820";
}

async function wgPubkey(privateKey) {
  const safe = privateKey.replace(/'/g, "'\\''");
  const { stdout } = await hostShell(`printf '%s' '${safe}' | awg pubkey`);
  return stdout.trim();
}

async function transfers(iface = "wg0") {
  try {
    const { stdout } = await host("awg", ["show", iface, "dump"]);
    const rows = stdout.trim().split("\n").slice(1).filter(Boolean);
    const out = {};
    for (const row of rows) {
      const cols = row.split("\t");
      out[cols[0]] = {
        endpoint: cols[2] || "",
        latestHandshake: Number(cols[4] || 0),
        rx: Number(cols[5] || 0),
        tx: Number(cols[6] || 0)
      };
    }
    return out;
  } catch {
    return {};
  }
}

function mergeTransferMaps(...maps) {
  const merged = {};
  for (const map of maps) {
    for (const [key, value] of Object.entries(map || {})) {
      if (!merged[key]) merged[key] = value;
      else {
        merged[key] = {
          endpoint: value.endpoint || merged[key].endpoint,
          latestHandshake: Math.max(merged[key].latestHandshake || 0, value.latestHandshake || 0),
          rx: (merged[key].rx || 0) + (value.rx || 0),
          tx: (merged[key].tx || 0) + (value.tx || 0)
        };
      }
    }
  }
  return merged;
}

export async function listClients() {
  const conf = await readText(MAIN_CONF);
  const upstreams = await listUpstreams();
  const direct = mergeTransferMaps(
    await transfers(awgClientIface("", "direct", 0, null, "wg")),
    await transfers(awgClientIface("", "direct", 0, null, "awg"))
  );
  const upstream = mergeTransferMaps(
    await transfers(awgClientIface("", "default", 0, null, "wg")),
    await transfers(awgClientIface("", "default", 0, null, "awg"))
  );
  for (const [upstreamIndex, item] of upstreams.entries()) {
    Object.assign(upstream, mergeTransferMaps(
      upstream,
      await transfers(awgClientIface("", "upstream", upstreamIndex + 1, item, "wg")),
      await transfers(awgClientIface("", "upstream", upstreamIndex + 1, item, "awg"))
    ));
  }
  const meta = await clientMeta();
  return peerBlocks(conf).map((peer) => ({
    ...peer,
    comment: meta[peer.name]?.comment || "",
    awg: clientAwgParams(meta, peer),
    route: clientRoute(meta, peer.name),
    subscription: clientSubscription(meta, peer.name),
    accessKey: meta[peer.name]?.accessKey || "",
    disabled: clientIsDisabled(peer, meta, peer.name),
    direct: clientIsDisabled(peer, meta, peer.name) ? null : direct[peer.publicKey] || null,
    upstream: clientIsDisabled(peer, meta, peer.name) ? null : upstream[peer.publicKey] || null
  }));
}

export async function createClient({ name, dns = "8.8.8.8, 8.8.4.4", comment = "", route = null, protocol = "", mode = "", upstreamId = "", subscription = "1m" }) {
  await ensureDirs();
  const client = strictName(name);
  let conf = await readText(MAIN_CONF);
  if (new RegExp(`^# BEGIN_PEER ${client}$`, "m").test(conf)) throw new Error("Client already exists");
  const subnet = wg0Subnet(conf);
  const used = new Set(peerBlocks(conf).map((peer) => {
    const m = peer.allowedIPs.match(/\.([0-9]+)\/32/);
    return m ? Number(m[1]) : 0;
  }));
  let octet = 2;
  while (used.has(octet) && octet < 255) octet++;
  if (octet >= 255) throw new Error("WireGuard subnet is full");
  const { stdout: keyOut } = await hostShell("awg genkey");
  const privateKey = keyOut.trim();
  const publicKey = await wgPubkey(privateKey);
  const { stdout: pskOut } = await hostShell("awg genpsk");
  const psk = pskOut.trim();
  const serverPrivate = (conf.match(/^PrivateKey = (.+)$/m) || [])[1];
  const serverPublic = await wgPubkey(serverPrivate);
  const block = `# BEGIN_PEER ${client}\n[Peer]\nPublicKey = ${publicKey}\nPresharedKey = ${psk}\nAllowedIPs = ${subnet}.${octet}/32\n# END_PEER ${client}\n`;
  conf = `${conf.trimEnd()}\n${block}`;
  await writeMainConfig(conf + "\n");
  const clientConf = `[Interface]\nAddress = ${subnet}.${octet}/24\nDNS = ${dns}\nPrivateKey = ${privateKey}\n\n[Peer]\nPublicKey = ${serverPublic}\nPresharedKey = ${psk}\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = ${wg0Endpoint(conf)}:${wg0Port(conf)}\nPersistentKeepalive = 25\n`;
  await writeText(path.join(CLIENT_DIR, `${client}.conf`), clientConf);
  const meta = await clientMeta();
  meta[client] = {
    comment: commentText(comment),
    disabled: false,
    expiresAt: addSubscription(null, subscription),
    accessKey: uniqueAccessKey(meta),
    awg: normalizeAwgParams(awgParamsForOctet(octet)),
    route: normalizeClientRoute(route || { protocol, mode, upstreamId })
  };
  await writeClientMeta(meta);
  await applyUpstreamTunnels();
  return { name: client };
}

export async function removeClient(name) {
  const client = lookupName(name);
  let conf = await readText(MAIN_CONF);
  const block = peerBlocks(conf).find((peer) => peer.name === client);
  if (!block) throw new Error("Client not found");
  conf = conf.replace(peerBlockPattern(client, block.disabled), "");
  await writeMainConfig(conf);
  await fs.rm(path.join(CLIENT_DIR, `${client}.conf`), { force: true });
  const meta = await clientMeta();
  delete meta[client];
  await writeClientMeta(meta);
  await applyUpstreamTunnels();
  return { ok: true };
}

export async function updateClient(name, data) {
  const client = lookupName(name);
  const nextName = data.name !== undefined ? strictName(data.name) : client;
  let conf = await readText(MAIN_CONF);
  const blocks = peerBlocks(conf);
  const block = blocks.find((peer) => peer.name === client);
  if (!block) throw new Error("Client not found");
  if (nextName !== client && blocks.some((peer) => peer.name === nextName)) throw new Error("Client already exists");
  if (nextName !== client) {
    conf = conf.replace(peerBlockPattern(client, block.disabled), block.disabled ? disabledPeerText(nextName, block.body) : activePeerText(nextName, block.body));
    await fs.rename(path.join(CLIENT_DIR, `${client}.conf`), path.join(CLIENT_DIR, `${nextName}.conf`)).catch(async () => {
      await writeText(path.join(CLIENT_DIR, `${nextName}.conf`), await readText(path.join(CLIENT_DIR, `${client}.conf`)));
      await fs.rm(path.join(CLIENT_DIR, `${client}.conf`), { force: true });
    });
  }
  await writeMainConfig(conf);
  const meta = await clientMeta();
  meta[nextName] = {
    ...meta[client],
    comment: commentText(data.comment ?? meta[client]?.comment ?? ""),
    awg: normalizeAwgParams(data.awg || meta[client]?.awg || awgParamsForOctet(clientOctet(block)), awgParamsForOctet(clientOctet(block))),
    route: normalizeClientRoute(data.route || meta[client]?.route || { protocol: "wg", mode: "default" }),
    disabled: Boolean(block.disabled || meta[client]?.disabled),
    expiresAt: data.expiresAt !== undefined ? data.expiresAt : meta[client]?.expiresAt,
    accessKey: meta[client]?.accessKey || uniqueAccessKey(meta)
  };
  if (nextName !== client) delete meta[client];
  await writeClientMeta(meta);
  await applyUpstreamTunnels();
  return { ok: true, name: nextName };
}

export async function setClientEnabled(name, enabled) {
  const client = lookupName(name);
  let conf = await readText(MAIN_CONF);
  const block = peerBlocks(conf).find((peer) => peer.name === client);
  if (!block) throw new Error("Client not found");
  const nextEnabled = Boolean(enabled);
  if (nextEnabled && block.disabled) {
    conf = conf.replace(peerBlockPattern(client, true), activePeerText(client, block.body));
  }
  if (!nextEnabled && !block.disabled) {
    conf = conf.replace(peerBlockPattern(client, false), disabledPeerText(client, block.body));
  }
  await writeMainConfig(conf);
  const meta = await clientMeta();
  meta[client] = { ...meta[client], disabled: !nextEnabled };
  await writeClientMeta(meta);
  await applyUpstreamTunnels();
  return { ok: true, enabled: nextEnabled };
}

export async function extendClientSubscription(name, plan) {
  const client = lookupName(name);
  const meta = await clientMeta();
  if (!meta[client]) throw new Error("Client not found");
  meta[client] = {
    ...meta[client],
    expiresAt: addSubscription(meta[client]?.expiresAt, plan),
    expiredApplied: false,
    accessKey: meta[client]?.accessKey || uniqueAccessKey(meta)
  };
  await writeClientMeta(meta);
  await applyUpstreamTunnels();
  return { ok: true, subscription: clientSubscription(meta, client) };
}

export async function cancelClientSubscription(name) {
  const client = lookupName(name);
  const meta = await clientMeta();
  if (!meta[client]) throw new Error("Client not found");
  meta[client] = { ...meta[client], expiresAt: "1970-01-01T00:00:00.000Z", expiredApplied: false, accessKey: meta[client]?.accessKey || uniqueAccessKey(meta) };
  await writeClientMeta(meta);
  await applyUpstreamTunnels();
  return { ok: true, subscription: clientSubscription(meta, client) };
}

export async function enforceSubscriptions() {
  const meta = await clientMeta();
  let changed = false;
  for (const [name, value] of Object.entries(meta)) {
    if (subscriptionExpired(value?.expiresAt) && !value.expiredApplied) {
      meta[name] = { ...value, expiredApplied: true };
      changed = true;
    }
  }
  if (changed) {
    await writeClientMeta(meta);
    await applyUpstreamTunnels();
  }
  return { changed };
}

export async function clientConfig(name, mode = "", upstreamId = "", protocol = "") {
  const client = lookupName(name);
  const direct = await readText(path.join(CLIENT_DIR, `${client}.conf`));
  if (!direct) throw new Error("Client config not found");
  const conf = await readText(MAIN_CONF);
  const meta = await clientMeta();
  const peer = peerBlocks(conf).find((item) => item.name === client);
  if (!peer) throw new Error("Client not found");
  if (clientIsDisabled(peer, meta, client)) throw new Error("Client subscription is expired or disabled");
  const savedRoute = clientRoute(meta, client);
  const requestedProtocol = protocol === "awg" ? "awg" : protocol === "wg" ? "wg" : savedRoute.protocol;
  const effectiveRoute = normalizeClientRoute({ protocol: requestedProtocol, mode: mode || savedRoute.mode, upstreamId: upstreamId || savedRoute.upstreamId });
  const endpointFor = async () => {
    if (effectiveRoute.mode === "direct") return awgClientEndpoint(client, "direct", 0, effectiveRoute.protocol);
    const upstreams = await listUpstreams();
    if (!upstreams.length) throw new Error("No upstream tunnels configured");
    const defaultId = await defaultUpstreamId(upstreams);
    const target = effectiveRoute.mode === "default"
      ? upstreams.find((item) => item.id === defaultId)
      : upstreams.find((item) => item.id === effectiveRoute.upstreamId);
    if (!target) throw new Error("Upstream tunnel not found");
    const useDefaultEntry = effectiveRoute.mode === "default";
    const targetIndex = upstreams.findIndex((item) => item.id === target.id);
    return awgClientEndpoint(client, useDefaultEntry ? "default" : "upstream", useDefaultEntry ? 0 : targetIndex + 1, effectiveRoute.protocol);
  };
  const endpoint = await endpointFor();
  const awgParams = clientAwgParams(meta, peer);
  const out = direct
    .replace(/^Address = .+$/m, `Address = ${endpoint.clientAddress}`)
    .replace(/^Endpoint = (.+):[0-9]+$/m, `Endpoint = ${wg0Endpoint(conf)}:${endpoint.port}`)
    .replace(/^AllowedIPs = .+$/m, "AllowedIPs = 0.0.0.0/0");
  return effectiveRoute.protocol === "awg" ? withAwgParams(out, awgParams) : stripAwgParams(out);
}

export async function clientQr(name, mode, upstreamId, protocol) {
  return QRCode.toDataURL(await clientConfig(name, mode, upstreamId, protocol), { margin: 1, width: 640 });
}

function cleanAccessKey(value) {
  return String(value || "").trim().toUpperCase().replace(/[^A-Z0-9]/g, "");
}

async function clientByAccessKey(value) {
  const key = cleanAccessKey(value);
  if (!/^[A-Z0-9]{16}$/.test(key)) throw new Error("Invalid access key");
  const meta = await clientMeta();
  const found = Object.entries(meta).find(([, item]) => item?.accessKey === key);
  if (!found) throw new Error("Invalid access key");
  const [name] = found;
  const conf = await readText(MAIN_CONF);
  const peer = peerBlocks(conf).find((item) => item.name === name);
  if (!peer) throw new Error("Client not found");
  return {
    name,
    comment: meta[name]?.comment || "",
    route: clientRoute(meta, name),
    subscription: clientSubscription(meta, name),
    disabled: clientIsDisabled(peer, meta, name)
  };
}

export async function botAuthorize(key) {
  return { ok: true, client: await clientByAccessKey(key) };
}

export async function botUpstreams(key) {
  const client = await clientByAccessKey(key);
  if (client.disabled) throw new Error("Client subscription is expired or disabled");
  return (await listUpstreams()).filter((item) => item.enabled).map((item) => ({
    id: item.id,
    name: item.name,
    isDefault: item.isDefault,
    status: item.status
  }));
}

export async function botClientConfig(key, mode = "", upstreamId = "", protocol = "") {
  const client = await clientByAccessKey(key);
  if (client.disabled) throw new Error("Client subscription is expired or disabled");
  const normalizedProtocol = protocol === "awg" ? "awg" : "wg";
  const normalizedMode = mode === "direct" || mode === "upstream" ? mode : "default";
  const suffix = `${normalizedMode === "default" ? "-default" : normalizedMode === "upstream" ? "-upstream" : ""}-${normalizedProtocol}`;
  return {
    name: client.name,
    filename: `${client.name}${suffix}.conf`,
    content: await clientConfig(client.name, normalizedMode, upstreamId || "", normalizedProtocol)
  };
}

export async function botClientQr(key, mode = "", upstreamId = "", protocol = "") {
  const config = await botClientConfig(key, mode, upstreamId, protocol);
  return { name: config.name, dataUrl: await QRCode.toDataURL(config.content, { margin: 1, width: 640 }) };
}

function normalizeUpstreamConfig(data) {
  const lines = String(data || "").replace(/\r\n/g, "\n").split("\n");
  let inInterface = false;
  let tableSeen = false;
  const out = [];
  for (const line of lines) {
    if (/^\s*\[Interface\]\s*$/.test(line)) {
      inInterface = true;
      tableSeen = false;
      out.push(line);
      continue;
    }
    if (/^\s*\[/.test(line) && inInterface) {
      if (!tableSeen) out.push("Table = off");
      inInterface = false;
    }
    if (inInterface && /^\s*DNS\s*=/.test(line)) continue;
    if (inInterface && /^\s*(I[1-5]|Jc|Jmin|Jmax|S[1-4]|H[1-4])\s*=\s*$/.test(line)) continue;
    if (inInterface && /^\s*Table\s*=/.test(line)) {
      if (!tableSeen) out.push("Table = off");
      tableSeen = true;
      continue;
    }
    out.push(line);
  }
  if (inInterface && !tableSeen) out.push("Table = off");
  return out.join("\n").trim() + "\n";
}

function detectUpstreamProtocol(config) {
  return /^\s*S3\s*=\s*\S+/m.test(config || "") && /^\s*S4\s*=\s*\S+/m.test(config || "") ? "awg" : "wg";
}

async function defaultUpstreamId(upstreams = null) {
  const items = upstreams || await readJson(UPSTREAMS_FILE, []);
  const saved = (await readText(DEFAULT_UPSTREAM_FILE)).trim();
  if (saved && items.some((item) => item.id === saved && item.enabled)) return saved;
  const fallback = items.find((item) => item.enabled)?.id || items[0]?.id || "";
  if (fallback) await writeText(DEFAULT_UPSTREAM_FILE, fallback);
  return fallback;
}

async function setDefaultUpstream(id) {
  const upstreams = await readJson(UPSTREAMS_FILE, []);
  const upstream = upstreams.find((item) => item.id === id);
  if (!upstream) throw new Error("Upstream tunnel not found");
  if (!upstream.enabled) throw new Error("Cannot set a disabled upstream as default");
  await writeText(DEFAULT_UPSTREAM_FILE, id);
}

async function upstreamServerIp(upstream) {
  const conf = await readText(upstream.configPath || "");
  const endpoint = (conf.match(/^\s*Endpoint\s*=\s*(.+)$/m) || [])[1] || "";
  const host = endpoint.trim().replace(/^\[/, "").replace(/\](:[0-9]+)?$/, "").replace(/:[0-9]+$/, "");
  return host || "";
}

export async function listUpstreams() {
  const upstreams = await readJson(UPSTREAMS_FILE, []);
  let changed = false;
  for (let index = 0; index < upstreams.length; index++) {
    const detectedProtocol = detectUpstreamProtocol(await readText(upstreams[index].configPath || ""));
    if (!upstreams[index].protocol || upstreams[index].protocol !== detectedProtocol) {
      upstreams[index].protocol = detectedProtocol;
      changed = true;
    }
    if (!upstreams[index].port || Number(upstreams[index].port) === 51821) {
      upstreams[index].port = await nextUpstreamPort(upstreams, index);
      changed = true;
    }
    if (!upstreams[index].subnet) {
      upstreams[index].subnet = await upstreamSubnet(upstreams[index], upstreams);
      changed = true;
    }
  }
  if (changed) await writeJson(UPSTREAMS_FILE, upstreams);
  const defaultId = await defaultUpstreamId(upstreams);
  const result = [];
  for (const item of upstreams) {
    result.push({ ...item, serverIp: await upstreamServerIp(item), isDefault: item.id === defaultId });
  }
  return result;
}

export async function createUpstream({ name, config, port = 51821, comment = "" }) {
  await ensureDirs();
  if (!/^\s*\[Interface\]/m.test(config) || !/^\s*\[Peer\]/m.test(config) || !/^\s*Endpoint\s*=/m.test(config)) {
    throw new Error("Uploaded file does not look like a WireGuard/AmneziaWG client config");
  }
  const upstreamProtocol = detectUpstreamProtocol(config);
  await ensureAwgTools();
  const upstreams = (await listUpstreams()).map(({ isDefault, ...item }) => item);
  const upstreamName = strictName(name);
  if (upstreams.some((item) => item.name === upstreamName)) throw new Error("Upstream name already exists");
  const id = crypto.randomBytes(4).toString("hex");
  const filename = path.join(UPSTREAM_DIR, `${id}.conf`);
  await writeText(filename, normalizeUpstreamConfig(config));
  const requestedPort = Number(port);
  const item = {
    id,
    name: upstreamName,
    protocol: upstreamProtocol,
    comment: commentText(comment),
    configPath: filename,
    priority: upstreams.length + 1,
    enabled: true,
    port: requestedPort && requestedPort !== 51821 ? requestedPort : await nextUpstreamPort(upstreams),
    subnet: await upstreamSubnet({ id }, upstreams),
    status: "unchecked",
    lastCheckAt: null,
    lastError: ""
  };
  upstreams.push(item);
  await writeJson(UPSTREAMS_FILE, upstreams);
  if (!(await defaultUpstreamId(upstreams))) await setDefaultUpstream(item.id);
  try {
    await applyUpstreamTunnels();
  } catch (error) {
    item.status = "down";
    item.lastCheckAt = new Date().toISOString();
    item.lastError = String(error.message || error).slice(0, 3000);
    await writeJson(UPSTREAMS_FILE, upstreams.map((upstream) => upstream.id === item.id ? item : upstream));
  }
  return item;
}

export async function updateUpstreams(data) {
  let upstreams = (await listUpstreams()).map(({ isDefault, ...item }) => item);
  const defaultOnly = Boolean(data.defaultId) && !data.order && !data.toggle && !data.update && !data.notify;
  if (Array.isArray(data.order)) {
    const map = new Map(upstreams.map((item) => [item.id, item]));
    upstreams = data.order.map((id) => map.get(id)).filter(Boolean);
    upstreams.forEach((item, index) => item.priority = index + 1);
  }
  if (data.toggle) {
    upstreams = upstreams.map((item) => item.id === data.toggle.id ? { ...item, enabled: Boolean(data.toggle.enabled) } : item);
  }
  if (data.defaultId) {
    await setDefaultUpstream(data.defaultId);
  }
  if (data.update) {
    const nextName = data.update.name !== undefined ? strictName(data.update.name) : null;
    if (nextName && upstreams.some((item) => item.id !== data.update.id && item.name === nextName)) {
      throw new Error("Upstream name already exists");
    }
    upstreams = upstreams.map((item) => item.id === data.update.id ? {
      ...item,
      name: nextName || item.name,
      comment: commentText(data.update.comment ?? item.comment ?? "")
    } : item);
  }
  if (data.notify) {
    upstreams = upstreams.map((item) => item.id === data.notify.id ? {
      ...item,
      notify: {
        down: Boolean(data.notify.down),
        recovered: Boolean(data.notify.recovered)
      }
    } : item);
  }
  await writeJson(UPSTREAMS_FILE, upstreams);
  if (defaultOnly) {
    const refreshed = await listUpstreams();
    await applyDefaultUpstream(refreshed);
    await applyAwgDefaultClientTunnel(refreshed);
    return refreshed;
  }
  await applyUpstreamTunnels();
  return upstreams;
}

export async function deleteUpstream(id) {
  let upstreams = (await listUpstreams()).map(({ isDefault, ...item }) => item);
  const item = upstreams.find((upstream) => upstream.id === id);
  upstreams = upstreams.filter((upstream) => upstream.id !== id).map((upstream, index) => ({ ...upstream, priority: index + 1 }));
  await writeJson(UPSTREAMS_FILE, upstreams);
  const meta = await clientMeta();
  let metaChanged = false;
  for (const [name, value] of Object.entries(meta)) {
    if (value?.route?.mode === "upstream" && value.route.upstreamId === id) {
      meta[name] = { ...value, route: { protocol: value?.route?.protocol === "awg" ? "awg" : "wg", mode: "default", upstreamId: "" } };
      metaChanged = true;
    }
  }
  if (metaChanged) await writeClientMeta(meta);
  if (item) await fs.rm(item.configPath, { force: true });
  if (item) await removeDedicatedUpstream(item);
  await defaultUpstreamId(upstreams);
  await applyUpstreamTunnels();
  return { ok: true };
}

async function extraSubnet() {
  const existing = await readText(path.join(WG_DIR, "wg-extra-tun.env"));
  const fromEnv = (existing.match(/^EXTRA_VPN_SUBNET=(.+)$/m) || [])[1];
  if (fromEnv) return fromEnv;
  const main = wg0Subnet(await readText(MAIN_CONF));
  const parts = main.split(".").map(Number);
  parts[2] = Math.min(parts[2] + 1, 254);
  return parts.join(".");
}

function clientOctet(peer) {
  return Number((peer.allowedIPs.match(/\.([0-9]+)\/32/) || [])[1] || 0);
}

async function awgClientEndpoint(name, kind, slot = 0, protocol = "wg") {
  const conf = await readText(MAIN_CONF);
  const peer = peerBlocks(conf).find((item) => item.name === name);
  if (!peer) throw new Error("Client not found");
  const octet = clientOctet(peer);
  if (!octet) throw new Error("Client address not found");
  const direct = kind === "direct";
  const upstream = kind === "upstream";
  const upstreamSlot = Math.max(1, Number(slot || 1));
  if (upstream && upstreamSlot > 44) throw new Error("Too many upstreams for automatic AWG client port allocation");
  const obfuscated = protocol === "awg";
  const port = obfuscated
    ? direct ? 55000 : upstream ? 57000 + upstreamSlot : 56000
    : direct ? 52000 : upstream ? 54000 + upstreamSlot : 53000;
  const third = obfuscated
    ? direct ? 80 : upstream ? 81 + upstreamSlot : 81
    : direct ? 64 : upstream ? 65 + upstreamSlot : 65;
  return {
    port,
    serverAddress: `100.${third}.0.1/24`,
    clientAddress: `100.${third}.0.${octet}/32`,
    cidr: `100.${third}.0.0/24`
  };
}

async function nextUpstreamPort(upstreams, currentIndex = -1) {
  const used = new Set(upstreams.filter((_, index) => index !== currentIndex).map((item) => Number(item.port)).filter(Boolean));
  let port = 51822;
  while (used.has(port)) port++;
  return port;
}

async function upstreamSubnet(upstream, upstreams) {
  if (upstream.subnet) return upstream.subnet;
  const main = wg0Subnet(await readText(MAIN_CONF));
  const used = new Set(upstreams.map((item) => item.subnet).filter(Boolean));
  used.add(await extraSubnet());
  const parts = main.split(".").map(Number);
  for (let offset = 2; offset < 250; offset++) {
    const candidate = `${parts[0]}.${parts[1]}.${Math.min(parts[2] + offset, 254)}`;
    if (!used.has(candidate)) return candidate;
  }
  throw new Error("No free upstream subnet is available");
}

async function writeExtraInConfig(port, subnet, file = path.join(AWG_DIR, "wg-extra-in.conf")) {
  return;
  const conf = await readText(MAIN_CONF);
  const privateKey = (conf.match(/^PrivateKey = (.+)$/m) || [])[1] || "";
  let out = `# Generated by wg-web manager\n[Interface]\nAddress = ${subnet}.1/24\nPrivateKey = ${privateKey}\nListenPort = ${port}\nTable = off\n\n`;
  for (const peer of peerBlocks(conf)) {
    if (peer.disabled) continue;
    const octet = (peer.allowedIPs.match(/\.([0-9]+)\/32/) || [])[1];
    if (!octet) continue;
    out += `# BEGIN_PEER ${peer.name}\n[Peer]\nPublicKey = ${peer.publicKey}\n`;
    const psk = (peer.body.match(/^PresharedKey = (.+)$/m) || [])[1];
    if (psk) out += `PresharedKey = ${psk}\n`;
    out += `AllowedIPs = ${subnet}.${octet}/32\n# END_PEER ${peer.name}\n`;
  }
  await writeText(file, out);
  const mirror = path.join(file.startsWith(AWG_DIR) ? WG_DIR : AWG_DIR, path.basename(file));
  if (mirror !== file) await writeText(mirror, out);
}

async function syncExtraInPeers() {
  return;
  if (!fss.existsSync(path.join(WG_DIR, "wg-extra-tun.env"))) return;
  const extraEnv = await readText(path.join(WG_DIR, "wg-extra-tun.env"));
  const port = Number(extraEnv.match(/^EXTRA_PORT=(.+)$/m)?.[1] || 51821);
  const subnet = await extraSubnet();
  await writeExtraInConfig(port, subnet);
}

function upstreamShortId(upstream) {
  return String(upstream.id || "").replace(/[^0-9a-zA-Z]/g, "").slice(0, 8);
}

function upstreamIfaces(upstream) {
  const id = upstreamShortId(upstream);
  return {
    id,
    upIface: `awg-up-${id}`,
    upConf: path.join(AWG_DIR, `awg-up-${id}.conf`)
  };
}

async function writeTunEnv(file, data) {
  await writeText(file, `EXTRA_PORT=${data.port}\nEXTRA_TABLE=${data.table}\nEXTRA_MARK=${data.mark}\nEXTRA_IIF_PRIORITY=${data.iifPriority}\nEXTRA_MARK_PRIORITY=${data.markPriority}\nEXTRA_IN_IF=${data.inIface}\nEXTRA_UP_IF=${data.upIface}\nEXTRA_VPN_SUBNET=${data.subnet}\nVPN_CIDR=${data.subnet}.0/24\nVPN6_CIDR=\nIPTABLES_PATH=/usr/sbin/iptables\nIP6TABLES_PATH=/usr/sbin/ip6tables\n`);
}

async function writeTunService(file, envFile, upIface, inIface, upProtocol = "awg", inProtocol = "awg") {
  const upPrefix = protocolTools(upProtocol).servicePrefix;
  const inPrefix = protocolTools(inProtocol).servicePrefix;
  await writeText(file, `[Unit]\nAfter=network-online.target ${upPrefix}${upIface}.service ${inPrefix}${inIface}.service\nWants=network-online.target ${upPrefix}${upIface}.service ${inPrefix}${inIface}.service\n\n[Service]\nType=oneshot\nEnvironment=AWG_ROUTE_ENV=${envFile}\nExecStart=/usr/local/sbin/awg-route-rules start\nExecStop=/usr/local/sbin/awg-route-rules stop\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target\n`, 0o644);
}

function shQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

async function stopTunRules(envFile) {
  await hostShell(`if [ -e ${shQuote(envFile)} ]; then if [ -x /usr/local/sbin/awg-route-rules ]; then AWG_ROUTE_ENV=${shQuote(envFile)} /usr/local/sbin/awg-route-rules stop 2>/dev/null || true; elif [ -x /usr/local/sbin/wg-extra-tun-rules ]; then WG_EXTRA_TUN_ENV=${shQuote(envFile)} /usr/local/sbin/wg-extra-tun-rules stop 2>/dev/null || true; fi; fi`);
}

async function serviceDiagnostics(service) {
  try {
    const { stdout, stderr } = await hostShell(`systemctl status ${service} --no-pager -l 2>&1 || true; journalctl -u ${service} -n 25 --no-pager 2>&1 || true`, 10000);
    return `${stdout}\n${stderr}`.trim().slice(-3000);
  } catch (error) {
    return String(error.message || error).slice(0, 1000);
  }
}

async function assertInterfaceUp(iface, service) {
  try {
    await host("ip", ["link", "show", iface], { timeout: 5000 });
  } catch (error) {
    const details = await serviceDiagnostics(service);
    throw new Error(`${iface} was not created by ${service}. ${details || String(error.message || error)}`);
  }
}

async function applyDefaultUpstream(upstreamList) {
  const enabled = upstreamList.filter((item) => item.enabled);
  const defaultId = await defaultUpstreamId(upstreamList);
  const selected = enabled.find((item) => item.id === defaultId) || enabled.sort((a, b) => a.priority - b.priority)[0];
  if (!selected) {
    await hostShell("systemctl disable --now wg-extra-tun.service awg-quick@wg-extra-in.service awg-quick@wg-extra-up.service 2>/dev/null || true");
    return;
  }
  const names = upstreamIfaces(selected);
  await hostShell("systemctl disable --now wg-extra-tun.service awg-quick@wg-extra-in.service awg-quick@wg-extra-up.service 2>/dev/null || true");
  await fs.rm(path.join(WG_DIR, "wg-extra-tun.env"), { force: true });
  await fs.rm(path.join(WG_DIR, "wg-extra-in.conf"), { force: true });
  await fs.rm(path.join(WG_DIR, "wg-extra-up.conf"), { force: true });
  await fs.rm(path.join(AWG_DIR, "wg-extra-in.conf"), { force: true });
  await fs.rm(path.join(AWG_DIR, "wg-extra-up.conf"), { force: true });
  await fs.rm("/etc/systemd/system/wg-extra-tun.service", { force: true });
  await assertInterfaceUp(names.upIface, `${protocolTools().servicePrefix}${names.upIface}.service`);
}

async function applyDedicatedUpstream(upstream, index) {
  const names = upstreamIfaces(upstream);
  await ensureAwgTools();
  await hostShell(`systemctl disable --now awg-quick@${names.upIface}.service 2>/dev/null || true`);
  await writeText(quickConfPath(names.upIface), normalizeUpstreamConfig(await readText(upstream.configPath)));
  const upService = `${protocolTools().servicePrefix}${names.upIface}.service`;
  await hostShell(`systemctl daemon-reload && systemctl enable --now ${upService}`, 30000);
  await assertInterfaceUp(names.upIface, upService);
}

async function removeDedicatedUpstream(upstream) {
  const names = upstreamIfaces(upstream);
  await hostShell(`systemctl disable --now awg-quick@${names.upIface}.service 2>/dev/null || true`);
  await fs.rm(names.upConf, { force: true });
}

function awgClientIface(client, kind, slot = 0, upstream = null, protocol = "wg") {
  const obfuscated = protocol === "awg";
  if (kind === "direct") return obfuscated ? "awgo-direct" : "awg-direct";
  if (kind === "default") return obfuscated ? "awgo-default" : "awg-default";
  if (obfuscated) return `awgo-${upstreamShortId(upstream) || Math.max(1, Number(slot || 1)).toString(36)}`;
  return `awg-in-${upstreamShortId(upstream) || Math.max(1, Number(slot || 1)).toString(36)}`;
}

function awgClientNatLines(endpoint) {
  return [
    `PostUp = iptables -w 5 -t nat -A POSTROUTING -s ${endpoint.cidr} ! -d ${endpoint.cidr} -j MASQUERADE`,
    `PostUp = iptables -w 5 -I INPUT -p udp --dport ${endpoint.port} -j ACCEPT`,
    `PostUp = iptables -w 5 -I FORWARD -s ${endpoint.cidr} -j ACCEPT`,
    `PostUp = iptables -w 5 -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT`,
    `PostDown = iptables -w 5 -t nat -D POSTROUTING -s ${endpoint.cidr} ! -d ${endpoint.cidr} -j MASQUERADE`,
    `PostDown = iptables -w 5 -D INPUT -p udp --dport ${endpoint.port} -j ACCEPT`,
    `PostDown = iptables -w 5 -D FORWARD -s ${endpoint.cidr} -j ACCEPT`,
    `PostDown = iptables -w 5 -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT`
  ].join("\n");
}

function cidrSubnetPrefix(cidr) {
  return String(cidr || "").replace(/\.0\/24$/, "").replace(/\.0\/30$/, "");
}

async function writeAwgClientInConfig(peers, kind, file, params, slot = 0, protocol = "wg") {
  const conf = await readText(MAIN_CONF);
  const privateKey = (conf.match(/^PrivateKey = (.+)$/m) || [])[1] || "";
  const activePeers = Array.isArray(peers) ? peers : [peers];
  const firstPeer = activePeers[0];
  if (!firstPeer) return;
  const endpoint = await awgClientEndpoint(firstPeer.name, kind, slot, protocol);
  let out = `# Generated by wg-web manager for AmneziaWG ${kind}\n[Interface]\nAddress = ${endpoint.serverAddress}\nPrivateKey = ${privateKey}\nListenPort = ${endpoint.port}\n`;
  const paramsText = params && Object.keys(params).length ? awgParamLines(params) : "";
  if (paramsText) out += `${paramsText}\n`;
  if (kind === "direct") out += `${awgClientNatLines(endpoint)}\n`;
  else out += "Table = off\n";
  for (const peer of activePeers) {
    const peerEndpoint = await awgClientEndpoint(peer.name, kind, slot, protocol);
    const psk = (peer.body.match(/^PresharedKey = (.+)$/m) || [])[1];
    out += `\n# BEGIN_PEER ${peer.name}\n[Peer]\nPublicKey = ${peer.publicKey}\n`;
    if (psk) out += `PresharedKey = ${psk}\n`;
    out += `AllowedIPs = ${peerEndpoint.clientAddress}\n# END_PEER ${peer.name}\n`;
  }
  await writeText(file, out);
}

async function writeAwgClientDefault(peers, defaultUpstream, protocol = "wg") {
  const iface = awgClientIface("", "default", 0, null, protocol);
  const endpoint = await awgClientEndpoint(peers[0].name, "default", 0, protocol);
  const env = path.join(WG_DIR, `${iface}.env`);
  const conf = quickConfPath(iface, "awg");
  const service = `/etc/systemd/system/${iface}.service`;
  await stopTunRules(env);
  await writeAwgClientInConfig(peers, "default", conf, protocol === "awg" ? normalizeAwgParams(DEFAULT_AWG_PARAMS) : {}, 0, protocol);
  await writeTunEnv(env, {
    port: endpoint.port,
    table: endpoint.port,
    mark: protocol === "awg" ? "0xcb51" : "0xcb50",
    iifPriority: protocol === "awg" ? 11100 : 11000,
    markPriority: protocol === "awg" ? 11101 : 11001,
    inIface: iface,
    upIface: upstreamIfaces(defaultUpstream).upIface,
    subnet: cidrSubnetPrefix(endpoint.cidr)
  });
  await writeTunService(service, env, upstreamIfaces(defaultUpstream).upIface, iface);
  await hostShell(`systemctl daemon-reload && systemctl restart awg-quick@${iface}.service && systemctl enable awg-quick@${iface}.service && systemctl restart ${iface}.service && systemctl enable ${iface}.service`, 30000);
}

async function writeAwgClientUpstream(peers, slot, ruleIndex, upstream, protocol = "wg") {
  const names = upstreamIfaces(upstream);
  const iface = awgClientIface("", "upstream", slot, upstream, protocol);
  const endpoint = await awgClientEndpoint(peers[0].name, "upstream", slot, protocol);
  const env = path.join(WG_DIR, `${iface}.env`);
  const conf = quickConfPath(iface, "awg");
  const service = `/etc/systemd/system/${iface}.service`;
  await stopTunRules(env);
  await writeAwgClientInConfig(peers, "upstream", conf, protocol === "awg" ? normalizeAwgParams(DEFAULT_AWG_PARAMS) : {}, slot, protocol);
  await writeTunEnv(env, {
    port: endpoint.port,
    table: endpoint.port,
    mark: `0xcd${(ruleIndex % 256).toString(16).padStart(2, "0")}`,
    iifPriority: 12000 + ruleIndex * 2,
    markPriority: 12001 + ruleIndex * 2,
    inIface: iface,
    upIface: names.upIface,
    subnet: cidrSubnetPrefix(endpoint.cidr)
  });
  await writeTunService(service, env, names.upIface, iface);
  await hostShell(`systemctl daemon-reload && systemctl restart awg-quick@${iface}.service && systemctl enable awg-quick@${iface}.service && systemctl restart ${iface}.service && systemctl enable ${iface}.service`, 30000);
}

async function applyAwgClientTunnels(upstreams) {
  const conf = await readText(MAIN_CONF);
  const meta = await clientMeta();
  const peers = peerBlocks(conf).filter((peer) => !clientIsDisabled(peer, meta, peer.name));
  const defaultId = await defaultUpstreamId(upstreams);
  const defaultUpstream = upstreams.find((item) => item.enabled && item.id === defaultId);
  const files = [...new Set([...(await fs.readdir(AWG_DIR).catch(() => [])), ...(await fs.readdir(WG_DIR).catch(() => []))])];
  const awgClientFile = (item) => /^(awg-direct|awg-default|awg-in-[0-9A-Za-z]+|awgo-direct|awgo-default|awgo-[0-9A-Za-z]+|awg-[du]-|ad-|au-|a[0-9a-z]+-)/.test(item);
  if (!peers.length && !files.some(awgClientFile)) return;
  if (peers.length) await ensureAwgTools();
  const active = new Set();
  if (peers.length) {
    for (const protocol of ["wg", "awg"]) {
      const directIface = awgClientIface("", "direct", 0, null, protocol);
      await writeAwgClientInConfig(peers, "direct", quickConfPath(directIface, "awg"), protocol === "awg" ? normalizeAwgParams(DEFAULT_AWG_PARAMS) : {}, 0, protocol);
      await hostShell(`systemctl restart awg-quick@${directIface}.service && systemctl enable awg-quick@${directIface}.service`, 30000);
      active.add(`${directIface}.conf`);
    }
  }
  if (peers.length && defaultUpstream) {
    for (const protocol of ["wg", "awg"]) {
      const defaultIface = awgClientIface("", "default", 0, null, protocol);
      await writeAwgClientDefault(peers, defaultUpstream, protocol);
      active.add(`${defaultIface}.conf`);
      active.add(`${defaultIface}.env`);
    }
  }
  for (const [upstreamIndex, upstream] of upstreams.entries()) {
    if (!peers.length || !upstream.enabled) continue;
    const slot = upstreamIndex + 1;
    for (const protocol of ["wg", "awg"]) {
      const upstreamIface = awgClientIface("", "upstream", slot, upstream, protocol);
      await writeAwgClientUpstream(peers, slot, (protocol === "awg" ? 400 : 200) + upstreamIndex, upstream, protocol);
      active.add(`${upstreamIface}.conf`);
      active.add(`${upstreamIface}.env`);
    }
  }
  for (const file of files.filter(awgClientFile)) {
    const name = file.replace(/\.(conf|env)$/, "");
    if (active.has(file)) continue;
    await hostShell(`systemctl disable --now awg-quick@${name}.service ${name}.service 2>/dev/null || true`);
    await fs.rm(path.join(WG_DIR, file), { force: true });
    await fs.rm(path.join(AWG_DIR, file), { force: true });
    await fs.rm(`/etc/systemd/system/${name}.service`, { force: true });
  }
}

async function applyAwgDefaultClientTunnel(upstreams) {
  const conf = await readText(MAIN_CONF);
  const meta = await clientMeta();
  const peers = peerBlocks(conf).filter((peer) => !clientIsDisabled(peer, meta, peer.name));
  const defaultId = await defaultUpstreamId(upstreams);
  const defaultUpstream = upstreams.find((item) => item.enabled && item.id === defaultId);
  if (!peers.length || !defaultUpstream) {
    for (const protocol of ["wg", "awg"]) {
      const iface = awgClientIface("", "default", 0, null, protocol);
      await hostShell(`systemctl disable --now awg-quick@${iface}.service ${iface}.service 2>/dev/null || true`);
      await fs.rm(quickConfPath(iface, "awg"), { force: true });
      await fs.rm(path.join(WG_DIR, `${iface}.env`), { force: true });
      await fs.rm(`/etc/systemd/system/${iface}.service`, { force: true });
    }
    return;
  }
  await ensureAwgTools();
  await writeAwgClientDefault(peers, defaultUpstream, "wg");
  await writeAwgClientDefault(peers, defaultUpstream, "awg");
}

export async function applyUpstreamTunnels() {
  const upstreams = await listUpstreams();
  for (const [index, upstream] of upstreams.entries()) {
    if (upstream.enabled) await applyDedicatedUpstream(upstream, index);
    else await removeDedicatedUpstream(upstream);
  }
  await applyDefaultUpstream(upstreams);
  await applyAwgClientTunnels(upstreams);
}

export async function healthSettings(nextValue) {
  if (nextValue) {
    const checks = Array.isArray(nextValue.checks) ? nextValue.checks.slice(0, 10).map((item) => ({
      url: String(item.url || "").trim(),
      expected: String(item.expected || "")
    })).filter((item) => item.url) : [];
    await writeJson(HEALTH_FILE, { intervalSeconds: Number(nextValue.intervalSeconds || 60), checks });
  }
  return readJson(HEALTH_FILE, DEFAULT_HEALTH);
}

export async function telegramSettings(nextValue) {
  if (nextValue) {
    await writeJson(TELEGRAM_FILE, {
      enabled: Boolean(nextValue.enabled),
      token: String(nextValue.token || ""),
      chatId: String(nextValue.chatId || ""),
      notificationIntervalSeconds: Number(nextValue.notificationIntervalSeconds || 300),
      domain: String(nextValue.domain || "")
    });
  }
  return readJson(TELEGRAM_FILE, { enabled: false, token: "", chatId: "", notificationIntervalSeconds: 300, domain: "" });
}

export async function probeHealthService(url) {
  const target = String(url || "").trim();
  if (!/^https?:\/\//i.test(target)) throw new Error("URL must start with http:// or https://");
  const { stdout } = await host("curl", ["-fsSL", "--max-time", "20", target], { timeout: 30000 });
  return { url: target, expected: stdout.slice(0, 8000) };
}

async function notify(text, key) {
  const settings = await telegramSettings();
  if (!settings.enabled || !settings.token || !settings.chatId) return;
  const state = await readJson(NOTIFY_STATE_FILE, {});
  const now = Date.now();
  const cooldown = Math.max(60, Number(settings.notificationIntervalSeconds || 300)) * 1000;
  if (state[key] && now - state[key] < cooldown) return;
  state[key] = now;
  await writeJson(NOTIFY_STATE_FILE, state);
  const body = new URLSearchParams({ chat_id: settings.chatId, text });
  await fetch(`https://api.telegram.org/bot${settings.token}/sendMessage`, { method: "POST", body }).catch(() => {});
}

async function notifyTunnel(upstream, eventName) {
  const notifySettings = upstream.notify || {};
  if (!notifySettings[eventName]) return;
  const label = eventName === "recovered" ? "recovered" : "down";
  const comment = upstream.comment ? `\nComment: ${upstream.comment}` : "";
  await notify(`AmneziaWG upstream "${upstream.name}" is ${label}.${comment}`, `${upstream.id}:${eventName}`);
}

async function checkOne(upstream, settings) {
  const iface = upstreamIfaces(upstream).upIface;
  const service = `${protocolTools().servicePrefix}${upstreamIfaces(upstream).upIface}.service`;
  try {
    try {
      await host("ip", ["link", "show", iface], { timeout: 5000 });
    } catch (error) {
      throw new Error(`${String(error.message || error).slice(0, 240)}\n${await serviceDiagnostics(service)}`);
    }
    for (const check of settings.checks || []) {
      const { stdout } = await host("curl", ["-fsSL", "--max-time", "15", "--interface", iface, check.url], { timeout: 25000 });
      if (check.expected && !stdout.includes(check.expected)) throw new Error(`Unexpected response from ${check.url}`);
    }
    return { status: "healthy", lastError: "" };
  } catch (error) {
    return { status: "down", lastError: String(error.message || error).slice(0, 240) };
  }
}

export async function runHealthCheck() {
  const settings = await healthSettings();
  const upstreams = await listUpstreams();
  let changed = false;
  for (const upstream of upstreams.filter((item) => item.enabled).sort((a, b) => a.priority - b.priority)) {
    const before = upstream.status;
    const result = await checkOne(upstream, settings);
    upstream.status = result.status;
    upstream.lastError = result.lastError;
    upstream.lastCheckAt = new Date().toISOString();
    if (before !== upstream.status) {
      changed = true;
      await notifyTunnel(upstream, upstream.status === "healthy" ? "recovered" : "down");
    }
  }
  await writeJson(UPSTREAMS_FILE, upstreams);
  if (changed) await applyUpstreamTunnels();
  return upstreams;
}

export async function requestCertificate({ domain }) {
  const target = String(domain || "").trim().toLowerCase();
  if (!/^[a-z0-9.-]+\.[a-z]{2,}$/.test(target)) throw new Error("Invalid domain");
  const script = `set -e
apt-get update
apt-get install -y certbot
mkdir -p /opt/wg-web/acme /opt/wg-web/certs
docker compose -f /opt/wg-web/docker-compose.yml up -d https
certbot certonly --webroot -w /opt/wg-web/acme --non-interactive --agree-tos --register-unsafely-without-email -d '${target}'
install -m 600 /etc/letsencrypt/live/'${target}'/privkey.pem /opt/wg-web/certs/wg-web.key
install -m 644 /etc/letsencrypt/live/'${target}'/fullchain.pem /opt/wg-web/certs/wg-web.crt
cat >/etc/cron.d/wg-web-certbot <<CRON
17 3 * * * root certbot renew --quiet --webroot -w /opt/wg-web/acme --deploy-hook "install -m 600 /etc/letsencrypt/live/${target}/privkey.pem /opt/wg-web/certs/wg-web.key && install -m 644 /etc/letsencrypt/live/${target}/fullchain.pem /opt/wg-web/certs/wg-web.crt && docker compose -f /opt/wg-web/docker-compose.yml restart https"
CRON
docker compose -f /opt/wg-web/docker-compose.yml restart https`;
  try {
    const { stdout, stderr } = await hostShell(script, 180000);
    const log = `${new Date().toISOString()}\n${stdout}\n${stderr}\n`;
    await writeText(CERTBOT_LOG_FILE, log, 0o600);
    const settings = await telegramSettings();
    await telegramSettings({ ...settings, domain: target });
    return { ok: true, log };
  } catch (error) {
    const log = `${new Date().toISOString()}\n${String(error.message || error)}\n`;
    await writeText(CERTBOT_LOG_FILE, log, 0o600);
    return { ok: false, log };
  }
}

export async function certbotLog() {
  return { log: await readText(CERTBOT_LOG_FILE) };
}

export async function collectStats() {
  await ensureDirs();
  const clients = await listClients();
  const now = Date.now();
  const rows = [];
  for (const client of clients) {
    for (const [mode, value] of [["direct", client.direct], ["upstream", client.upstream]]) {
      if (value) rows.push(JSON.stringify({ ts: now, name: client.name, publicKey: client.publicKey, mode, rx: value.rx, tx: value.tx }));
    }
  }
  if (rows.length) await fs.appendFile(STATS_FILE, rows.join("\n") + "\n");
}

function rangeStart(range) {
  const now = Date.now();
  if (range === "day") return now - 24 * 60 * 60 * 1000;
  if (range === "week") return now - 7 * 24 * 60 * 60 * 1000;
  if (range === "month") return now - 30 * 24 * 60 * 60 * 1000;
  return 0;
}

export async function stats(range = "day") {
  const start = rangeStart(range);
  const lines = (await readText(STATS_FILE)).trim().split("\n").filter(Boolean);
  const samples = lines.map((line) => { try { return JSON.parse(line); } catch { return null; } }).filter(Boolean).filter((row) => row.ts >= start);
  const byKey = new Map();
  for (const row of samples) {
    const key = `${row.publicKey}:${row.mode}`;
    if (!byKey.has(key)) byKey.set(key, []);
    byKey.get(key).push(row);
  }
  const users = {};
  const buckets = new Map();
  const userBuckets = {};
  for (const rows of byKey.values()) {
    rows.sort((a, b) => a.ts - b.ts);
    for (let i = 1; i < rows.length; i++) {
      const prev = rows[i - 1];
      const row = rows[i];
      const delta = Math.max(0, row.rx - prev.rx) + Math.max(0, row.tx - prev.tx);
      users[row.name] = (users[row.name] || 0) + delta;
      const bucket = new Date(row.ts);
      bucket.setMinutes(0, 0, 0);
      const key = bucket.toISOString();
      buckets.set(key, (buckets.get(key) || 0) + delta);
      if (!userBuckets[row.name]) userBuckets[row.name] = new Map();
      userBuckets[row.name].set(key, (userBuckets[row.name].get(key) || 0) + delta);
    }
  }
  const userPoints = {};
  for (const [name, map] of Object.entries(userBuckets)) {
    userPoints[name] = [...map.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([ts, bytes]) => ({ ts, bytes }));
  }
  return {
    total: Object.values(users).reduce((sum, value) => sum + value, 0),
    users,
    userPoints,
    points: [...buckets.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([ts, bytes]) => ({ ts, bytes }))
  };
}
EOF

	cat > /opt/wg-web/app/app/api/[[...path]]/route.js << 'EOF'
import {
  shaPassword,
  signSession,
  verifySession,
  listClients,
  createClient,
  updateClient,
  setClientEnabled,
  extendClientSubscription,
  cancelClientSubscription,
  removeClient,
  clientConfig,
  clientQr,
  botAuthorize,
  botUpstreams,
  botClientConfig,
  botClientQr,
  listUpstreams,
  createUpstream,
  updateUpstreams,
  deleteUpstream,
  healthSettings,
  probeHealthService,
  telegramSettings,
  requestCertificate,
  certbotLog,
  runHealthCheck,
  collectStats,
  enforceSubscriptions,
  stats
} from "../../lib/core.mjs";

export const dynamic = "force-dynamic";

function cookie(req, name) {
  return (req.headers.get("cookie") || "").split(";").map((item) => item.trim()).find((item) => item.startsWith(`${name}=`))?.slice(name.length + 1) || "";
}

function json(data, status = 200, headers = {}) {
  return Response.json(data, { status, headers: { "Cache-Control": "no-store", ...headers } });
}

async function requireAuth(req) {
  if (!verifySession(cookie(req, "wg_session"))) throw new Error("Unauthorized");
}

function bearerToken(req) {
  const header = req.headers.get("authorization") || "";
  return header.toLowerCase().startsWith("bearer ") ? header.slice(7).trim() : "";
}

async function requireBot(req) {
  if (!process.env.BOT_API_TOKEN || bearerToken(req) !== process.env.BOT_API_TOKEN) throw new Error("Unauthorized");
}

async function dispatch(req, params) {
  const path = params.path || [];
  const method = req.method;
  if (method === "POST" && path[0] === "login") {
    const body = await req.json();
    if (shaPassword(body.password || "") !== process.env.ADMIN_PASSWORD_HASH) return json({ error: "Invalid password" }, 401);
    return json({ ok: true }, 200, { "Set-Cookie": `wg_session=${signSession()}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=43200` });
  }
  if (method === "POST" && path[0] === "logout") {
    return json({ ok: true }, 200, { "Set-Cookie": "wg_session=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0" });
  }
  if (path[0] === "bot") {
    await requireBot(req);
    const url = new URL(req.url);
    const key = url.searchParams.get("key") || "";
    if (method === "POST" && path[1] === "auth") return json(await botAuthorize((await req.json()).key));
    if (method === "GET" && path[1] === "upstreams") return json(await botUpstreams(key));
    if (method === "GET" && path[1] === "qr") return json(await botClientQr(key, url.searchParams.get("mode") || "", url.searchParams.get("upstreamId") || "", url.searchParams.get("protocol") || ""));
    if (method === "GET" && path[1] === "config") {
      const result = await botClientConfig(key, url.searchParams.get("mode") || "", url.searchParams.get("upstreamId") || "", url.searchParams.get("protocol") || "");
      return new Response(result.content, {
        headers: {
          "Cache-Control": "no-store",
          "Content-Type": "text/plain; charset=utf-8",
          "Content-Disposition": `attachment; filename="${result.filename}"`
        }
      });
    }
    return json({ error: "Not found" }, 404);
  }
  await requireAuth(req);
  await enforceSubscriptions().catch(() => null);
  if (method === "GET" && path[0] === "me") return json({ user: process.env.ADMIN_USER || "admin" });
  if (method === "GET" && path[0] === "clients" && path[1] && path[2] === "config") {
    const url = new URL(req.url);
    const mode = url.searchParams.get("mode") || "";
    const protocol = url.searchParams.get("protocol") === "awg" ? "awg" : "wg";
    const suffix = `${mode === "default" ? "-default" : mode === "upstream" ? "-upstream" : ""}${protocol === "awg" ? "-awg" : "-wg"}`;
    return new Response(await clientConfig(path[1], mode, url.searchParams.get("upstreamId") || "", protocol), {
      headers: {
        "Cache-Control": "no-store",
        "Content-Type": "text/plain; charset=utf-8",
        "Content-Disposition": `attachment; filename="${path[1]}${suffix}.conf"`
      }
    });
  }
  if (method === "GET" && path[0] === "clients" && path[1] && path[2] === "qr") {
    const url = new URL(req.url);
    return json({ dataUrl: await clientQr(path[1], url.searchParams.get("mode") || "", url.searchParams.get("upstreamId") || "", url.searchParams.get("protocol") === "awg" ? "awg" : "wg") });
  }
  if (method === "GET" && path[0] === "clients") return json(await listClients());
  if (method === "POST" && path[0] === "clients" && path[1] && path[2] === "subscription" && path[3] === "extend") return json(await extendClientSubscription(path[1], (await req.json()).plan));
  if (method === "POST" && path[0] === "clients" && path[1] && path[2] === "subscription" && path[3] === "cancel") return json(await cancelClientSubscription(path[1]));
  if (method === "POST" && path[0] === "clients") return json(await createClient(await req.json()));
  if (method === "PATCH" && path[0] === "clients" && path[1] && path[2] === "enabled") return json(await setClientEnabled(path[1], (await req.json()).enabled));
  if (method === "PATCH" && path[0] === "clients" && path[1]) return json(await updateClient(path[1], await req.json()));
  if (method === "DELETE" && path[0] === "clients" && path[1]) return json(await removeClient(path[1]));
  if (method === "GET" && path[0] === "upstreams") return json(await listUpstreams());
  if (method === "POST" && path[0] === "upstreams") {
    const form = await req.formData();
    const file = form.get("file");
    return json(await createUpstream({ name: form.get("name"), comment: form.get("comment"), port: form.get("port"), config: await file.text() }));
  }
  if (method === "PATCH" && path[0] === "upstreams") return json(await updateUpstreams(await req.json()));
  if (method === "DELETE" && path[0] === "upstreams" && path[1]) return json(await deleteUpstream(path[1]));
  if (method === "POST" && path[0] === "health-check") return json(await runHealthCheck());
  if (method === "GET" && path[0] === "settings" && path[1] === "health") return json(await healthSettings());
  if (method === "POST" && path[0] === "settings" && path[1] === "health" && path[2] === "probe") return json(await probeHealthService((await req.json()).url));
  if (method === "POST" && path[0] === "settings" && path[1] === "health") return json(await healthSettings(await req.json()));
  if (method === "GET" && path[0] === "settings" && path[1] === "telegram") return json(await telegramSettings());
  if (method === "POST" && path[0] === "settings" && path[1] === "telegram") return json(await telegramSettings(await req.json()));
  if (method === "GET" && path[0] === "settings" && path[1] === "certbot") return json(await certbotLog());
  if (method === "POST" && path[0] === "settings" && path[1] === "certbot") return json(await requestCertificate(await req.json()));
  if (method === "GET" && path[0] === "stats") {
    const url = new URL(req.url);
    return json(await stats(url.searchParams.get("range") || "day"));
  }
  if (method === "POST" && path[0] === "stats" && path[1] === "collect") {
    await collectStats();
    return json({ ok: true });
  }
  return json({ error: "Not found" }, 404);
}

async function run(req, ctx) {
  const params = await ctx.params;
  return dispatch(req, params || {});
}

export async function GET(req, ctx) { try { return await run(req, ctx); } catch (error) { return json({ error: error.message }, error.message === "Unauthorized" ? 401 : 500); } }
export async function POST(req, ctx) { try { return await run(req, ctx); } catch (error) { return json({ error: error.message }, error.message === "Unauthorized" ? 401 : 500); } }
export async function PATCH(req, ctx) { try { return await run(req, ctx); } catch (error) { return json({ error: error.message }, error.message === "Unauthorized" ? 401 : 500); } }
export async function DELETE(req, ctx) { try { return await run(req, ctx); } catch (error) { return json({ error: error.message }, error.message === "Unauthorized" ? 401 : 500); } }
EOF

	cat > /opt/wg-web/app/worker.js << 'EOF'
import { applyUpstreamTunnels, collectStats, enforceSubscriptions, healthSettings, runHealthCheck } from "./app/lib/core.mjs";

async function loop() {
  try { await enforceSubscriptions(); } catch (error) { console.error("subscriptions:", error.message); }
  try { await collectStats(); } catch (error) { console.error("stats:", error.message); }
  try { await runHealthCheck(); } catch (error) { console.error("health:", error.message); }
  const settings = await healthSettings().catch(() => ({ intervalSeconds: 60 }));
  setTimeout(loop, Math.max(15, Number(settings.intervalSeconds || 60)) * 1000);
}

async function boot() {
  try { await applyUpstreamTunnels(); } catch (error) { console.error("apply:", error.message); }
  loop();
}

boot();
EOF

	cat > /opt/wg-web/app/app/page.js << 'EOF'
"use client";

import { useEffect, useMemo, useState } from "react";

const ranges = ["day", "week", "month", "all"];

function bytes(value) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let number = Number(value || 0);
  let index = 0;
  while (number >= 1024 && index < units.length - 1) {
    number /= 1024;
    index++;
  }
  return `${number.toFixed(index ? 1 : 0)} ${units[index]}`;
}

function statusText(status) {
  if (status === "healthy") return "Р Р°Р±РѕС‚Р°РµС‚";
  if (status === "down") return "РќРµРґРѕСЃС‚СѓРїРµРЅ";
  return "РќРµ РїСЂРѕРІРµСЂСЏР»СЃСЏ";
}

async function api(path, options = {}) {
  const headers = options.body && typeof options.body === "string" ? { "Content-Type": "application/json", ...(options.headers || {}) } : options.headers;
  const res = await fetch(`/api/${path}`, { cache: "no-store", ...options, headers });
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || "Request failed");
  return res.json();
}

function Chart({ points }) {
  const max = Math.max(...(points || []).map((point) => point.bytes), 1);
  const path = (points || []).map((point, index) => {
    const x = points.length < 2 ? 0 : (index / (points.length - 1)) * 100;
    const y = 100 - (point.bytes / max) * 86 - 7;
    return `${index ? "L" : "M"} ${x.toFixed(2)} ${y.toFixed(2)}`;
  }).join(" ");
  return (
    <svg className="chart" viewBox="0 0 100 100" preserveAspectRatio="none">
      <path d={path || "M 0 94 L 100 94"} fill="none" stroke="#48d597" strokeWidth="2" vectorEffect="non-scaling-stroke" />
    </svg>
  );
}

export default function Page() {
  const [authed, setAuthed] = useState(null);
  const [password, setPassword] = useState("");
  const [view, setView] = useState("dashboard");
  const [range, setRange] = useState("day");
  const [clients, setClients] = useState([]);
  const [upstreams, setUpstreams] = useState([]);
  const [stat, setStat] = useState({ total: 0, users: {}, userPoints: {}, points: [] });
  const [selectedUser, setSelectedUser] = useState("");
  const [clientTargets, setClientTargets] = useState({});
  const [qr, setQr] = useState(null);
  const [error, setError] = useState("");
  const [health, setHealth] = useState({ intervalSeconds: 60, checks: [] });
  const [telegram, setTelegram] = useState({ enabled: false, token: "", chatId: "", events: {} });

  async function refresh() {
    const [c, u, s] = await Promise.all([api("clients"), api("upstreams"), api(`stats?range=${range}`)]);
    setClients(c);
    setUpstreams(u);
    setStat(s);
  }

  useEffect(() => {
    api("me").then(() => setAuthed(true)).catch(() => setAuthed(false));
  }, []);

  useEffect(() => {
    if (authed) refresh().catch((err) => setError(err.message));
  }, [authed, range]);

  useEffect(() => {
    if (authed && view === "settings") {
      api("settings/health").then(setHealth).catch((err) => setError(err.message));
      api("settings/telegram").then(setTelegram).catch((err) => setError(err.message));
    }
  }, [authed, view]);

  async function login(event) {
    event.preventDefault();
    setError("");
    try {
      await api("login", { method: "POST", body: JSON.stringify({ password }) });
      setAuthed(true);
    } catch (err) {
      setError(err.message);
    }
  }

  async function addClient(event) {
    event.preventDefault();
    setError("");
    const formEl = event.currentTarget;
    try {
      const form = new FormData(formEl);
      await api("clients", { method: "POST", body: JSON.stringify({ name: form.get("name"), dns: form.get("dns") }) });
      formEl.reset();
      await refresh();
    } catch (err) {
      setError(err.message);
    }
  }

  async function addUpstream(event) {
    event.preventDefault();
    setError("");
    const formEl = event.currentTarget;
    try {
      const form = new FormData(formEl);
      await api("upstreams", { method: "POST", body: form });
      formEl.reset();
      await refresh();
    } catch (err) {
      setError(err.message);
    }
  }

  function targetOptions() {
    return [
      { value: "direct", label: "DIRECT" },
      { value: "default", label: "DEFAULT" },
      ...upstreams.map((up) => ({ value: `upstream:${up.id}`, label: up.name }))
    ];
  }

  function selectedTarget(name) {
    return clientTargets[name] || "direct";
  }

  function targetParams(value) {
    if (value === "default") return { mode: "default", upstreamId: "" };
    if (value.startsWith("upstream:")) return { mode: "upstream", upstreamId: value.slice("upstream:".length) };
    return { mode: "direct", upstreamId: "" };
  }

  function configUrl(name, value) {
    const target = targetParams(value);
    const query = new URLSearchParams({ mode: target.mode });
    if (target.upstreamId) query.set("upstreamId", target.upstreamId);
    return `/api/clients/${name}/config?${query.toString()}`;
  }

  function configFilename(name, value) {
    const target = targetParams(value);
    if (target.mode === "direct") return `${name}.conf`;
    if (target.mode === "default") return `${name}-default.conf`;
    const upstream = upstreams.find((item) => item.id === target.upstreamId);
    return `${name}-${upstream?.name || "upstream"}.conf`;
  }

  async function showQr(name, targetValue = "direct") {
    setError("");
    try {
      const target = targetParams(targetValue);
      const query = new URLSearchParams({ mode: target.mode });
      if (target.upstreamId) query.set("upstreamId", target.upstreamId);
      const result = await api(`clients/${name}/qr?${query.toString()}`);
      if (!result.dataUrl?.startsWith("data:image/")) throw new Error("QR code response is invalid");
      const label = targetOptions().find((item) => item.value === targetValue)?.label || "DIRECT";
      setQr({ title: `${name} В· ${label}`, dataUrl: result.dataUrl });
    } catch (err) {
      setError(err.message);
    }
  }

  async function reorder(dragId, dropId) {
    const ids = upstreams.map((item) => item.id);
    const from = ids.indexOf(dragId);
    const to = ids.indexOf(dropId);
    if (from < 0 || to < 0 || from === to) return;
    ids.splice(to, 0, ids.splice(from, 1)[0]);
    try {
      await api("upstreams", { method: "PATCH", body: JSON.stringify({ order: ids }) });
      await refresh();
    } catch (err) {
      setError(err.message);
    }
  }

  const activeUsers = useMemo(() => clients.filter((client) => client.direct?.latestHandshake || client.upstream?.latestHandshake).length, [clients]);

  if (authed === false) {
    return (
      <main className="login">
        <form className="panel form" onSubmit={login}>
          <h1>WireGuard Control</h1>
          <input type="password" value={password} onChange={(event) => setPassword(event.target.value)} placeholder="РџР°СЂРѕР»СЊ Р°РґРјРёРЅРёСЃС‚СЂР°С‚РѕСЂР°" autoFocus />
          <button className="primary">Р’РѕР№С‚Рё</button>
          {error && <span className="bad">{error}</span>}
        </form>
      </main>
    );
  }
  if (!authed) return null;

  return (
    <main className="shell">
      <aside className="side">
        <div className="brand">WireGuard Control</div>
        <div className="nav">
          {[
            ["dashboard", "РћР±Р·РѕСЂ"],
            ["clients", "РљР»РёРµРЅС‚С‹"],
            ["upstreams", "Upstream-С‚СѓРЅРЅРµР»Рё"],
            ["settings", "РќР°СЃС‚СЂРѕР№РєРё"]
          ].map(([id, label]) => (
            <button key={id} className={view === id ? "active" : ""} onClick={() => setView(id)}>{label}</button>
          ))}
        </div>
      </aside>
      <section className="main">
        <div className="top">
          <div className="metric"><span className="muted">РћР±С‰РёР№ С‚СЂР°С„РёРє</span><b>{bytes(stat.total)}</b></div>
          <div className="metric"><span className="muted">РљР»РёРµРЅС‚С‹</span><b>{clients.length}</b></div>
          <div className="metric"><span className="muted">РђРєС‚РёРІРЅС‹Рµ</span><b>{activeUsers}</b></div>
          <div className="metric">
            <span className="muted">РџРµСЂРёРѕРґ</span>
            <select value={range} onChange={(event) => setRange(event.target.value)}>
              <option value="day">Р”РµРЅСЊ</option>
              <option value="week">РќРµРґРµР»СЏ</option>
              <option value="month">РњРµСЃСЏС†</option>
              <option value="all">Р’СЃРµ РІСЂРµРјСЏ</option>
            </select>
          </div>
        </div>
        {error && <p className="bad">{error}</p>}
        {view === "dashboard" && (
          <div className="grid">
            <div className="panel"><h2>РџРѕС‚СЂРµР±Р»РµРЅРёРµ С‚СЂР°С„РёРєР°</h2><Chart points={stat.points} /></div>
            <div className="panel">
              <h2>РџРѕС‚СЂРµР±Р»РµРЅРёРµ РїРѕ РєР»РёРµРЅС‚Р°Рј</h2>
              {Object.entries(stat.users).map(([name, value]) => <div className="row" key={name}><button type="button" onClick={() => setSelectedUser(name)}>{name}</button><b>{bytes(value)}</b></div>)}
              {(selectedUser || Object.keys(stat.users)[0]) && (
                <>
                  <h2>{selectedUser || Object.keys(stat.users)[0]}</h2>
                  <Chart points={stat.userPoints?.[selectedUser || Object.keys(stat.users)[0]] || []} />
                </>
              )}
            </div>
          </div>
        )}
        {view === "clients" && (
          <div className="grid">
            <div className="panel">
              <h2>РљР»РёРµРЅС‚С‹ WireGuard</h2>
              {clients.map((client) => (
                <div className="row" key={client.name}>
                  <div><b>{client.name}</b><div className="muted">{client.allowedIPs}</div></div>
                  <div className="actions">
                    <select value={selectedTarget(client.name)} onChange={(event) => setClientTargets({ ...clientTargets, [client.name]: event.target.value })}>
                      {targetOptions().map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
                    </select>
                    <button type="button" onClick={() => showQr(client.name, selectedTarget(client.name))}>РџРѕРєР°Р·Р°С‚СЊ QR</button>
                    <a href={configUrl(client.name, selectedTarget(client.name))} download={configFilename(client.name, selectedTarget(client.name))}><button type="button">РЎРєР°С‡Р°С‚СЊ .conf</button></a>
                    <button type="button" className="danger" onClick={async () => { await api(`clients/${client.name}`, { method: "DELETE" }); await refresh(); }}>РЈРґР°Р»РёС‚СЊ</button>
                  </div>
                </div>
              ))}
            </div>
            <form className="panel form" onSubmit={addClient}>
              <h2>РќРѕРІС‹Р№ РєР»РёРµРЅС‚</h2>
              <input name="name" placeholder="РРјСЏ РєР»РёРµРЅС‚Р°" required />
              <input name="dns" placeholder="1.1.1.1, 1.0.0.1" defaultValue="1.1.1.1, 1.0.0.1" />
              <button className="primary">РЎРѕР·РґР°С‚СЊ РєР»РёРµРЅС‚Р°</button>
            </form>
          </div>
        )}
        {view === "upstreams" && (
          <div className="grid">
            <div className="panel">
              <h2>РџСЂРёРѕСЂРёС‚РµС‚ Upstream-С‚СѓРЅРЅРµР»РµР№</h2>
              {upstreams.map((up) => (
                <div className="row" key={up.id} draggable onDragStart={(event) => event.dataTransfer.setData("text/plain", up.id)} onDragOver={(event) => event.preventDefault()} onDrop={(event) => reorder(event.dataTransfer.getData("text/plain"), up.id)}>
                  <div><b>{up.name}</b> {up.isDefault && <span className="pill ok">DEFAULT</span>}<div className={up.status === "healthy" ? "ok" : up.status === "down" ? "bad" : "warn"}>{statusText(up.status)}</div><div className="muted">{up.lastError}</div></div>
                  <div className="actions">
                    {!up.isDefault && <button type="button" onClick={async () => { await api("upstreams", { method: "PATCH", body: JSON.stringify({ defaultId: up.id }) }); await refresh(); }}>РЎРґРµР»Р°С‚СЊ Default</button>}
                    <button type="button" onClick={async () => { await api("upstreams", { method: "PATCH", body: JSON.stringify({ toggle: { id: up.id, enabled: !up.enabled } }) }); await refresh(); }}>{up.enabled ? "РћС‚РєР»СЋС‡РёС‚СЊ" : "Р’РєР»СЋС‡РёС‚СЊ"}</button>
                    <button type="button" className="danger" onClick={async () => { await api(`upstreams/${up.id}`, { method: "DELETE" }); await refresh(); }}>РЈРґР°Р»РёС‚СЊ</button>
                  </div>
                </div>
              ))}
              <button type="button" onClick={async () => { await api("health-check", { method: "POST" }); await refresh(); }}>РџСЂРѕРІРµСЂРёС‚СЊ СЃРµР№С‡Р°СЃ</button>
            </div>
            <form className="panel form" onSubmit={addUpstream}>
              <h2>РќРѕРІС‹Р№ Upstream</h2>
              <input name="name" placeholder="РќР°Р·РІР°РЅРёРµ С‚СѓРЅРЅРµР»СЏ" required />
              <input name="port" placeholder="РџРѕСЂС‚ РєР»РёРµРЅС‚Р°, Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРё РµСЃР»Рё РїСѓСЃС‚Рѕ" />
              <input name="file" type="file" accept=".conf" required />
              <button className="primary">Р—Р°РіСЂСѓР·РёС‚СЊ РєРѕРЅС„РёРі</button>
            </form>
          </div>
        )}
        {view === "settings" && (
          <div className="grid">
            <form className="panel form" onSubmit={async (event) => {
              event.preventDefault();
              await api("settings/health", { method: "POST", body: JSON.stringify(health) });
            }}>
              <h2>РџСЂРѕРІРµСЂРєР° РґРѕСЃС‚СѓРїРЅРѕСЃС‚Рё</h2>
              <input type="number" min="15" value={health.intervalSeconds || 60} onChange={(event) => setHealth({ ...health, intervalSeconds: Number(event.target.value) })} />
              <textarea value={JSON.stringify(health.checks || [], null, 2)} onChange={(event) => setHealth({ ...health, checks: JSON.parse(event.target.value || "[]") })} />
              <button className="primary">РЎРѕС…СЂР°РЅРёС‚СЊ РїСЂРѕРІРµСЂРєСѓ</button>
            </form>
            <form className="panel form" onSubmit={async (event) => {
              event.preventDefault();
              await api("settings/telegram", { method: "POST", body: JSON.stringify(telegram) });
            }}>
              <h2>РЈРІРµРґРѕРјР»РµРЅРёСЏ Telegram</h2>
              <label><input type="checkbox" checked={telegram.enabled || false} onChange={(event) => setTelegram({ ...telegram, enabled: event.target.checked })} /> Р’РєР»СЋС‡РёС‚СЊ СѓРІРµРґРѕРјР»РµРЅРёСЏ</label>
              <input value={telegram.token || ""} onChange={(event) => setTelegram({ ...telegram, token: event.target.value })} placeholder="Bot token" />
              <input value={telegram.chatId || ""} onChange={(event) => setTelegram({ ...telegram, chatId: event.target.value })} placeholder="Chat ID" />
              <label><input type="checkbox" checked={telegram.events?.upstreamRecovered ?? true} onChange={(event) => setTelegram({ ...telegram, events: { ...(telegram.events || {}), upstreamRecovered: event.target.checked } })} /> Upstream РІРѕСЃСЃС‚Р°РЅРѕРІРёР»СЃСЏ</label>
              <label><input type="checkbox" checked={telegram.events?.upstreamDown ?? true} onChange={(event) => setTelegram({ ...telegram, events: { ...(telegram.events || {}), upstreamDown: event.target.checked } })} /> Upstream РЅРµРґРѕСЃС‚СѓРїРµРЅ</label>
              <label><input type="checkbox" checked={telegram.events?.allUpstreamsDown ?? true} onChange={(event) => setTelegram({ ...telegram, events: { ...(telegram.events || {}), allUpstreamsDown: event.target.checked } })} /> Р’СЃРµ Upstream РЅРµРґРѕСЃС‚СѓРїРЅС‹</label>
              <button className="primary">РЎРѕС…СЂР°РЅРёС‚СЊ Telegram</button>
            </form>
          </div>
        )}
        {qr && <div className="panel" style={{ marginTop: 14 }}><h2>{qr.title}</h2><div className="qr"><img src={qr.dataUrl} alt={`QR ${qr.title}`} /></div><button type="button" onClick={() => setQr(null)}>Р—Р°РєСЂС‹С‚СЊ</button></div>}
      </section>
    </main>
  );
}
EOF

	cat > /opt/wg-web/app/app/page.js << 'EOF'
"use client";

import { useEffect, useMemo, useState } from "react";

const rangeLabels = { day: "24 С‡Р°СЃР°", week: "7 РґРЅРµР№", month: "30 РґРЅРµР№", all: "Р’СЃРµ РІСЂРµРјСЏ" };
const dnsPresets = [
  ["8.8.8.8, 8.8.4.4", "Google"],
  ["1.1.1.1, 1.0.0.1", "Cloudflare"],
  ["208.67.222.222, 208.67.220.220", "OpenDNS"],
  ["9.9.9.9, 149.112.112.112", "Quad9"],
  ["95.85.95.85, 2.56.220.2", "Gcore"],
  ["94.140.14.14, 94.140.15.15", "AdGuard"]
];

function bytes(value) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let number = Number(value || 0);
  let index = 0;
  while (number >= 1024 && index < units.length - 1) {
    number /= 1024;
    index++;
  }
  return `${number.toFixed(index ? 1 : 0)} ${units[index]}`;
}

function statusText(status) {
  if (status === "healthy") return "Р Р°Р±РѕС‚Р°РµС‚";
  if (status === "down") return "РќРµРґРѕСЃС‚СѓРїРµРЅ";
  return "РћР¶РёРґР°РµС‚ РїСЂРѕРІРµСЂРєРё";
}

function statusClass(status) {
  if (status === "healthy") return "good";
  if (status === "down") return "danger-dot";
  return "idle";
}

async function api(path, options = {}) {
  const headers = options.body && typeof options.body === "string" ? { "Content-Type": "application/json", ...(options.headers || {}) } : options.headers;
  const res = await fetch(`/api/${path}`, { cache: "no-store", ...options, headers });
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || "Request failed");
  return res.json();
}

function TrafficChart({ points }) {
  const safePoints = points || [];
  if (!safePoints.length) {
    return <div className="chart empty-chart">Р”Р°РЅРЅС‹Рµ РїРѕСЏРІСЏС‚СЃСЏ РїРѕСЃР»Рµ РїРµСЂРІС‹С… Р·Р°РјРµСЂРѕРІ С‚СЂР°С„РёРєР°</div>;
  }
  const max = Math.max(...safePoints.map((point) => point.bytes), 1);
  const line = safePoints.map((point, index) => {
    const x = safePoints.length < 2 ? 0 : (index / (safePoints.length - 1)) * 100;
    const y = 100 - (point.bytes / max) * 86 - 7;
    return `${index ? "L" : "M"} ${x.toFixed(2)} ${y.toFixed(2)}`;
  }).join(" ");
  return (
    <svg className="chart" viewBox="0 0 100 100" preserveAspectRatio="none">
      <path d={`${line} L 100 100 L 0 100 Z`} fill="rgba(72,213,151,.12)" />
      <path d={line} fill="none" stroke="#48d597" strokeWidth="2.2" vectorEffect="non-scaling-stroke" />
    </svg>
  );
}

export default function Page() {
  const [authed, setAuthed] = useState(null);
  const [password, setPassword] = useState("");
  const [view, setView] = useState("dashboard");
  const [range, setRange] = useState("day");
  const [clients, setClients] = useState([]);
  const [upstreams, setUpstreams] = useState([]);
  const [stat, setStat] = useState({ total: 0, users: {}, userPoints: {}, points: [] });
  const [clientTargets, setClientTargets] = useState({});
  const [clientDrafts, setClientDrafts] = useState({});
  const [upstreamDrafts, setUpstreamDrafts] = useState({});
  const [qr, setQr] = useState(null);
  const [error, setError] = useState("");
  const [health, setHealth] = useState({ intervalSeconds: 60, checks: [] });
  const [telegram, setTelegram] = useState({ enabled: false, token: "", chatId: "", events: {} });

  async function refresh({ check = false } = {}) {
    if (check) await api("health-check", { method: "POST" }).catch(() => null);
    const [c, u, s] = await Promise.all([api("clients"), api("upstreams"), api(`stats?range=${range}`)]);
    setClients(c);
    setUpstreams(u);
    setStat(s);
  }

  useEffect(() => {
    api("me").then(() => setAuthed(true)).catch(() => setAuthed(false));
  }, []);

  useEffect(() => {
    if (!authed) return;
    refresh({ check: true }).catch((err) => setError(err.message));
    const timer = setInterval(() => refresh({ check: true }).catch((err) => setError(err.message)), 60000);
    return () => clearInterval(timer);
  }, [authed, range]);

  useEffect(() => {
    if (authed && view === "settings") {
      api("settings/health").then(setHealth).catch((err) => setError(err.message));
      api("settings/telegram").then(setTelegram).catch((err) => setError(err.message));
    }
  }, [authed, view]);

  async function login(event) {
    event.preventDefault();
    setError("");
    try {
      await api("login", { method: "POST", body: JSON.stringify({ password }) });
      setAuthed(true);
    } catch (err) {
      setError(err.message);
    }
  }

  async function addClient(event) {
    event.preventDefault();
    setError("");
    const formEl = event.currentTarget;
    try {
      const form = new FormData(formEl);
      await api("clients", { method: "POST", body: JSON.stringify({ name: form.get("name"), dns: form.get("dns"), comment: form.get("comment") }) });
      formEl.reset();
      await refresh();
    } catch (err) {
      setError(err.message);
    }
  }

  async function addUpstream(event) {
    event.preventDefault();
    setError("");
    const formEl = event.currentTarget;
    try {
      const form = new FormData(formEl);
      await api("upstreams", { method: "POST", body: form });
      formEl.reset();
      await refresh({ check: true });
    } catch (err) {
      setError(err.message);
    }
  }

  async function saveClient(client) {
    const draft = clientDrafts[client.name] || {};
    await api(`clients/${client.name}`, { method: "PATCH", body: JSON.stringify({ name: draft.name ?? client.name, comment: draft.comment ?? client.comment ?? "" }) });
    setClientDrafts({});
    await refresh();
  }

  async function saveUpstream(upstream) {
    const draft = upstreamDrafts[upstream.id] || {};
    await api("upstreams", { method: "PATCH", body: JSON.stringify({ update: { id: upstream.id, name: draft.name ?? upstream.name, comment: draft.comment ?? upstream.comment ?? "" } }) });
    setUpstreamDrafts({});
    await refresh({ check: true });
  }

  function targetOptions() {
    return [
      { value: "direct", label: "DIRECT" },
      { value: "default", label: "DEFAULT" },
      ...upstreams.map((up) => ({ value: `upstream:${up.id}`, label: up.name }))
    ];
  }

  function selectedTarget(name) {
    return clientTargets[name] || "direct";
  }

  function targetParams(value) {
    if (value === "default") return { mode: "default", upstreamId: "" };
    if (value.startsWith("upstream:")) return { mode: "upstream", upstreamId: value.slice("upstream:".length) };
    return { mode: "direct", upstreamId: "" };
  }

  function configUrl(name, value) {
    const target = targetParams(value);
    const query = new URLSearchParams({ mode: target.mode });
    if (target.upstreamId) query.set("upstreamId", target.upstreamId);
    return `/api/clients/${name}/config?${query.toString()}`;
  }

  function configFilename(name, value) {
    const target = targetParams(value);
    if (target.mode === "direct") return `${name}.conf`;
    if (target.mode === "default") return `${name}-default.conf`;
    const upstream = upstreams.find((item) => item.id === target.upstreamId);
    return `${name}-${upstream?.name || "upstream"}.conf`;
  }

  async function showQr(name, targetValue = "direct") {
    setError("");
    try {
      const target = targetParams(targetValue);
      const query = new URLSearchParams({ mode: target.mode });
      if (target.upstreamId) query.set("upstreamId", target.upstreamId);
      const result = await api(`clients/${name}/qr?${query.toString()}`);
      if (!result.dataUrl?.startsWith("data:image/")) throw new Error("QR code response is invalid");
      const label = targetOptions().find((item) => item.value === targetValue)?.label || "DIRECT";
      setQr({ title: `${name} В· ${label}`, dataUrl: result.dataUrl });
    } catch (err) {
      setError(err.message);
    }
  }

  async function reorder(dragId, dropId) {
    const ids = upstreams.map((item) => item.id);
    const from = ids.indexOf(dragId);
    const to = ids.indexOf(dropId);
    if (from < 0 || to < 0 || from === to) return;
    ids.splice(to, 0, ids.splice(from, 1)[0]);
    await api("upstreams", { method: "PATCH", body: JSON.stringify({ order: ids }) });
    await refresh({ check: true });
  }

  const activeUsers = useMemo(() => clients.filter((client) => client.direct?.latestHandshake || client.upstream?.latestHandshake).length, [clients]);
  const topClients = useMemo(() => Object.entries(stat.users || {}).sort((a, b) => b[1] - a[1]), [stat.users]);

  if (authed === false) {
    return (
      <main className="login">
        <form className="panel form" onSubmit={login}>
          <h1>WireGuard Control</h1>
          <input type="password" value={password} onChange={(event) => setPassword(event.target.value)} placeholder="РџР°СЂРѕР»СЊ Р°РґРјРёРЅРёСЃС‚СЂР°С‚РѕСЂР°" autoFocus />
          <button className="primary">Р’РѕР№С‚Рё</button>
          {error && <span className="bad">{error}</span>}
        </form>
      </main>
    );
  }
  if (!authed) return null;

  return (
    <main className="shell">
      <aside className="side">
        <div className="brand">WireGuard Control</div>
        <div className="nav">
          {[["dashboard", "РћР±Р·РѕСЂ"], ["clients", "РљР»РёРµРЅС‚С‹"], ["upstreams", "Upstream"], ["settings", "РќР°СЃС‚СЂРѕР№РєРё"]].map(([id, label]) => (
            <button key={id} className={view === id ? "active" : ""} onClick={() => setView(id)}>{label}</button>
          ))}
        </div>
      </aside>
      <section className="main">
        <div className="page-head">
          <div>
            <h1>{view === "dashboard" ? "РћР±Р·РѕСЂ СЃРµС‚Рё" : view === "clients" ? "РљР»РёРµРЅС‚С‹" : view === "upstreams" ? "Upstream-С‚СѓРЅРЅРµР»Рё" : "РќР°СЃС‚СЂРѕР№РєРё"}</h1>
            <p>РЈРїСЂР°РІР»РµРЅРёРµ РґРѕСЃС‚СѓРїР°РјРё, РјР°СЂС€СЂСѓС‚Р°РјРё Рё РїРѕС‚СЂРµР±Р»РµРЅРёРµРј WireGuard.</p>
          </div>
          <button type="button" onClick={() => refresh({ check: true })}>РћР±РЅРѕРІРёС‚СЊ</button>
        </div>

        <div className="upstream-strip">
          {upstreams.length ? upstreams.map((up) => (
            <div className="upstream-chip" key={up.id} title={up.comment || ""}>
              <span className={`status-dot ${statusClass(up.status)}`} />
              <b>{up.name}</b>
              {up.isDefault && <span className="pill ok">DEFAULT</span>}
              <span className="muted">{statusText(up.status)}</span>
            </div>
          )) : <span className="muted">Upstream-С‚СѓРЅРЅРµР»Рё РЅРµ РґРѕР±Р°РІР»РµРЅС‹</span>}
        </div>

        <div className="top">
          <div className="metric"><span className="muted">РўСЂР°С„РёРє Р·Р° РїРµСЂРёРѕРґ</span><b>{bytes(stat.total)}</b></div>
          <div className="metric"><span className="muted">РљР»РёРµРЅС‚С‹</span><b>{clients.length}</b></div>
          <div className="metric"><span className="muted">РђРєС‚РёРІРЅС‹Рµ</span><b>{activeUsers}</b></div>
          <div className="metric">
            <span className="muted">РџРµСЂРёРѕРґ</span>
            <select value={range} onChange={(event) => setRange(event.target.value)}>
              {Object.entries(rangeLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
            </select>
          </div>
        </div>

        {error && <p className="bad">{error}</p>}

        {view === "dashboard" && (
          <div className="dashboard-grid">
            <div className="panel wide">
              <div className="panel-title"><h2>Р”РёРЅР°РјРёРєР° РїРѕС‚СЂРµР±Р»РµРЅРёСЏ</h2><span className="muted">{rangeLabels[range]}</span></div>
              <TrafficChart points={stat.points} />
            </div>
            <div className="panel">
              <h2>РўРѕРї РєР»РёРµРЅС‚РѕРІ</h2>
              {topClients.length ? topClients.slice(0, 8).map(([name, value]) => (
                <button className="rank-row" type="button" key={name}><span>{name}</span><b>{bytes(value)}</b></button>
              )) : <p className="muted">РџРѕРєР° РЅРµС‚ РЅР°РєРѕРїР»РµРЅРЅРѕР№ СЃС‚Р°С‚РёСЃС‚РёРєРё.</p>}
            </div>
            <div className="panel wide">
              <div className="panel-title"><h2>РљР»РёРµРЅС‚С‹</h2><span className="muted">РџРѕС‚СЂРµР±Р»РµРЅРёРµ, handshakes Рё РєРѕРјРјРµРЅС‚Р°СЂРёРё</span></div>
              <div className="table">
                <div className="table-head"><span>РРјСЏ</span><span>РџРµСЂРёРѕРґ</span><span>Live RX/TX</span><span>Endpoint</span></div>
                {clients.map((client) => (
                  <div className="table-row" key={client.name}>
                    <span className="tooltip" data-tip={client.comment || "РљРѕРјРјРµРЅС‚Р°СЂРёР№ РЅРµ Р·Р°РґР°РЅ"}>{client.name}</span>
                    <b>{bytes(stat.users?.[client.name] || 0)}</b>
                    <span>{bytes((client.direct?.rx || 0) + (client.upstream?.rx || 0))} / {bytes((client.direct?.tx || 0) + (client.upstream?.tx || 0))}</span>
                    <span className="muted">{client.direct?.endpoint || client.upstream?.endpoint || "-"}</span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        )}

        {view === "clients" && (
          <div className="grid">
            <div className="panel">
              <h2>РљР»РёРµРЅС‚С‹ WireGuard</h2>
              {clients.map((client) => (
                <div className="row" key={client.name}>
                  <div>
                    <b className="tooltip" data-tip={client.comment || "РљРѕРјРјРµРЅС‚Р°СЂРёР№ РЅРµ Р·Р°РґР°РЅ"}>{client.name}</b>
                    <div className="muted">{client.allowedIPs}</div>
                    {clientDrafts[client.name] && (
                      <div className="edit-box">
                        <input maxLength="12" pattern="[A-Za-z-]{1,12}" value={clientDrafts[client.name].name} onChange={(event) => setClientDrafts({ ...clientDrafts, [client.name]: { ...clientDrafts[client.name], name: event.target.value } })} />
                        <textarea maxLength="300" value={clientDrafts[client.name].comment} onChange={(event) => setClientDrafts({ ...clientDrafts, [client.name]: { ...clientDrafts[client.name], comment: event.target.value } })} />
                      </div>
                    )}
                  </div>
                  <div className="actions">
                    <select value={selectedTarget(client.name)} onChange={(event) => setClientTargets({ ...clientTargets, [client.name]: event.target.value })}>{targetOptions().map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select>
                    <button type="button" onClick={() => showQr(client.name, selectedTarget(client.name))}>QR</button>
                    <a href={configUrl(client.name, selectedTarget(client.name))} download={configFilename(client.name, selectedTarget(client.name))}><button type="button">.conf</button></a>
                    {clientDrafts[client.name] ? <button type="button" className="primary" onClick={() => saveClient(client)}>РЎРѕС…СЂР°РЅРёС‚СЊ</button> : <button type="button" onClick={() => setClientDrafts({ ...clientDrafts, [client.name]: { name: client.name, comment: client.comment || "" } })}>Р РµРґР°РєС‚РёСЂРѕРІР°С‚СЊ</button>}
                    <button type="button" className="danger" onClick={async () => { await api(`clients/${client.name}`, { method: "DELETE" }); await refresh(); }}>РЈРґР°Р»РёС‚СЊ</button>
                  </div>
                </div>
              ))}
            </div>
            <form className="panel form" onSubmit={addClient}>
              <h2>РќРѕРІС‹Р№ РєР»РёРµРЅС‚</h2>
              <input name="name" maxLength="12" pattern="[A-Za-z-]{1,12}" placeholder="client-name" required />
              <select name="dns" defaultValue="8.8.8.8, 8.8.4.4">{dnsPresets.map(([value, label]) => <option key={label} value={value}>{label} - {value}</option>)}</select>
              <textarea name="comment" maxLength="300" placeholder="РљРѕРјРјРµРЅС‚Р°СЂРёР№, РґРѕ 300 СЃРёРјРІРѕР»РѕРІ" />
              <button className="primary">РЎРѕР·РґР°С‚СЊ РєР»РёРµРЅС‚Р°</button>
            </form>
          </div>
        )}

        {view === "upstreams" && (
          <div className="grid">
            <div className="panel">
              <h2>Upstream-С‚СѓРЅРЅРµР»Рё</h2>
              {upstreams.map((up) => (
                <div className="row" key={up.id} draggable onDragStart={(event) => event.dataTransfer.setData("text/plain", up.id)} onDragOver={(event) => event.preventDefault()} onDrop={(event) => reorder(event.dataTransfer.getData("text/plain"), up.id)}>
                  <div>
                    <b>{up.name}</b> {up.isDefault && <span className="pill ok">DEFAULT</span>}
                    <div><span className={`status-dot ${statusClass(up.status)}`} /> {statusText(up.status)}</div>
                    <div className="muted">{up.comment || up.lastError || "РљРѕРјРјРµРЅС‚Р°СЂРёР№ РЅРµ Р·Р°РґР°РЅ"}</div>
                    {upstreamDrafts[up.id] && (
                      <div className="edit-box">
                        <input maxLength="12" pattern="[A-Za-z-]{1,12}" value={upstreamDrafts[up.id].name} onChange={(event) => setUpstreamDrafts({ ...upstreamDrafts, [up.id]: { ...upstreamDrafts[up.id], name: event.target.value } })} />
                        <textarea maxLength="300" value={upstreamDrafts[up.id].comment} onChange={(event) => setUpstreamDrafts({ ...upstreamDrafts, [up.id]: { ...upstreamDrafts[up.id], comment: event.target.value } })} />
                      </div>
                    )}
                  </div>
                  <div className="actions">
                    {!up.isDefault && <button type="button" onClick={async () => { await api("upstreams", { method: "PATCH", body: JSON.stringify({ defaultId: up.id }) }); await refresh({ check: true }); }}>Default</button>}
                    {upstreamDrafts[up.id] ? <button type="button" className="primary" onClick={() => saveUpstream(up)}>РЎРѕС…СЂР°РЅРёС‚СЊ</button> : <button type="button" onClick={() => setUpstreamDrafts({ ...upstreamDrafts, [up.id]: { name: up.name, comment: up.comment || "" } })}>Р РµРґР°РєС‚РёСЂРѕРІР°С‚СЊ</button>}
                    <button type="button" onClick={async () => { await api("upstreams", { method: "PATCH", body: JSON.stringify({ toggle: { id: up.id, enabled: !up.enabled } }) }); await refresh({ check: true }); }}>{up.enabled ? "РћС‚РєР»СЋС‡РёС‚СЊ" : "Р’РєР»СЋС‡РёС‚СЊ"}</button>
                    <button type="button" className="danger" onClick={async () => { await api(`upstreams/${up.id}`, { method: "DELETE" }); await refresh({ check: true }); }}>РЈРґР°Р»РёС‚СЊ</button>
                  </div>
                </div>
              ))}
              <button type="button" onClick={async () => { await api("health-check", { method: "POST" }); await refresh(); }}>РџСЂРѕРІРµСЂРёС‚СЊ СЃРµР№С‡Р°СЃ</button>
            </div>
            <form className="panel form" onSubmit={addUpstream}>
              <h2>РќРѕРІС‹Р№ Upstream</h2>
              <input name="name" maxLength="12" pattern="[A-Za-z-]{1,12}" placeholder="main-node" required />
              <textarea name="comment" maxLength="300" placeholder="РљРѕРјРјРµРЅС‚Р°СЂРёР№, РґРѕ 300 СЃРёРјРІРѕР»РѕРІ" />
              <input name="port" placeholder="РџРѕСЂС‚ РєР»РёРµРЅС‚Р°, Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРё РµСЃР»Рё РїСѓСЃС‚Рѕ" />
              <input name="file" type="file" accept=".conf" required />
              <button className="primary">Р—Р°РіСЂСѓР·РёС‚СЊ РєРѕРЅС„РёРі</button>
            </form>
          </div>
        )}

        {view === "settings" && (
          <div className="grid">
            <form className="panel form" onSubmit={async (event) => { event.preventDefault(); await api("settings/health", { method: "POST", body: JSON.stringify(health) }); }}>
              <h2>РџСЂРѕРІРµСЂРєР° РґРѕСЃС‚СѓРїРЅРѕСЃС‚Рё</h2>
              <input type="number" min="15" value={health.intervalSeconds || 60} onChange={(event) => setHealth({ ...health, intervalSeconds: Number(event.target.value) })} />
              <textarea value={JSON.stringify(health.checks || [], null, 2)} onChange={(event) => setHealth({ ...health, checks: JSON.parse(event.target.value || "[]") })} />
              <button className="primary">РЎРѕС…СЂР°РЅРёС‚СЊ РїСЂРѕРІРµСЂРєСѓ</button>
            </form>
            <form className="panel form" onSubmit={async (event) => { event.preventDefault(); await api("settings/telegram", { method: "POST", body: JSON.stringify(telegram) }); }}>
              <h2>РЈРІРµРґРѕРјР»РµРЅРёСЏ Telegram</h2>
              <label><input type="checkbox" checked={telegram.enabled || false} onChange={(event) => setTelegram({ ...telegram, enabled: event.target.checked })} /> Р’РєР»СЋС‡РёС‚СЊ СѓРІРµРґРѕРјР»РµРЅРёСЏ</label>
              <input value={telegram.token || ""} onChange={(event) => setTelegram({ ...telegram, token: event.target.value })} placeholder="Bot token" />
              <input value={telegram.chatId || ""} onChange={(event) => setTelegram({ ...telegram, chatId: event.target.value })} placeholder="Chat ID" />
              <label><input type="checkbox" checked={telegram.events?.upstreamRecovered ?? true} onChange={(event) => setTelegram({ ...telegram, events: { ...(telegram.events || {}), upstreamRecovered: event.target.checked } })} /> Upstream РІРѕСЃСЃС‚Р°РЅРѕРІРёР»СЃСЏ</label>
              <label><input type="checkbox" checked={telegram.events?.upstreamDown ?? true} onChange={(event) => setTelegram({ ...telegram, events: { ...(telegram.events || {}), upstreamDown: event.target.checked } })} /> Upstream РЅРµРґРѕСЃС‚СѓРїРµРЅ</label>
              <label><input type="checkbox" checked={telegram.events?.allUpstreamsDown ?? true} onChange={(event) => setTelegram({ ...telegram, events: { ...(telegram.events || {}), allUpstreamsDown: event.target.checked } })} /> Р’СЃРµ Upstream РЅРµРґРѕСЃС‚СѓРїРЅС‹</label>
              <button className="primary">РЎРѕС…СЂР°РЅРёС‚СЊ Telegram</button>
            </form>
          </div>
        )}

        {qr && <div className="panel" style={{ marginTop: 14 }}><h2>{qr.title}</h2><div className="qr"><img src={qr.dataUrl} alt={`QR ${qr.title}`} /></div><button type="button" onClick={() => setQr(null)}>Р—Р°РєСЂС‹С‚СЊ</button></div>}
      </section>
    </main>
  );
}
EOF

	cat >> /opt/wg-web/app/app/globals.css << 'EOF'
.page-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 16px;
  margin-bottom: 16px;
}
.page-head h1 { margin: 0 0 4px; font-size: 26px; }
.page-head p { margin: 0; color: var(--muted); }
.upstream-strip {
  display: flex;
  gap: 10px;
  flex-wrap: wrap;
  margin-bottom: 14px;
}
.upstream-chip {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  min-height: 38px;
  padding: 0 12px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--panel);
}
.status-dot {
  width: 9px;
  height: 9px;
  border-radius: 50%;
  background: var(--warn);
  box-shadow: 0 0 0 3px rgba(255, 209, 102, .12);
}
.status-dot.good { background: var(--accent); box-shadow: 0 0 0 3px rgba(72, 213, 151, .12); }
.status-dot.danger-dot { background: var(--danger); box-shadow: 0 0 0 3px rgba(255, 93, 108, .12); }
.dashboard-grid {
  display: grid;
  grid-template-columns: minmax(0, 1.45fr) minmax(320px, .75fr);
  gap: 14px;
}
.wide { grid-column: span 1; }
.panel-title {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
  margin-bottom: 12px;
}
.panel-title h2 { margin: 0; }
.empty-chart {
  display: grid;
  place-items: center;
  color: var(--muted);
}
.rank-row {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 8px;
}
.table { width: 100%; overflow-x: auto; }
.table-head, .table-row {
  display: grid;
  grid-template-columns: 1fr 120px 160px minmax(140px, 1fr);
  gap: 10px;
  align-items: center;
  min-height: 40px;
  border-top: 1px solid var(--line);
}
.table-head {
  color: var(--muted);
  font-size: 12px;
  text-transform: uppercase;
  border-top: 0;
}
.tooltip {
  position: relative;
  width: max-content;
  max-width: 100%;
}
.tooltip:hover::after {
  content: attr(data-tip);
  position: absolute;
  left: 0;
  top: 26px;
  z-index: 10;
  min-width: 220px;
  max-width: 360px;
  padding: 10px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: #070a10;
  color: var(--text);
  white-space: normal;
  box-shadow: 0 16px 40px rgba(0,0,0,.35);
}
.edit-box {
  display: grid;
  gap: 8px;
  margin-top: 10px;
}
@media (max-width: 900px) {
  .page-head, .dashboard-grid { display: block; }
  .page-head button { margin-top: 12px; }
  .dashboard-grid .panel { margin-bottom: 14px; }
  .table-head, .table-row { grid-template-columns: 1fr; padding: 10px 0; }
}
EOF

	cat > /opt/wg-web/app/app/page.js << 'EOF'
"use client";

import { useEffect, useMemo, useState } from "react";

const dict = {
  en: {
    overview: "Overview", clients: "Clients", upstreams: "Upstreams", settings: "Settings", refresh: "Refresh",
    subtitle: "Production WireGuard management, routing and traffic analytics.", traffic: "Traffic", active: "Active",
    period: "Period", day: "24h", week: "7d", month: "30d", all: "All time", dynamics: "Traffic dynamics",
    topClients: "Top clients", noStats: "Statistics will appear after traffic samples are collected.",
    name: "Name", comment: "Comment", actions: "Actions", endpoint: "Endpoint", live: "Live RX/TX",
    newClient: "New client", createClient: "Create client", edit: "Edit", save: "Save", delete: "Delete",
    newUpstream: "New upstream", upload: "Upload config", makeDefault: "Set default", disable: "Disable", enable: "Enable",
    notifications: "Notifications", down: "Down", recovered: "Recovered", close: "Close", qr: "QR",
    health: "Health checks", addService: "Add service", url: "URL", fetch: "Fetch data", confirm: "Confirm expected data",
    remove: "Remove", interval: "Check interval", telegram: "Telegram", domain: "Domain", cert: "Get certificate",
    certLog: "Certificate log", botToken: "Bot token", chatId: "Chat ID", signIn: "Sign in", password: "Admin password",
    healthy: "Healthy", failed: "Down", pending: "Pending"
  },
  ru: {
    overview: "РћР±Р·РѕСЂ", clients: "РљР»РёРµРЅС‚С‹", upstreams: "Upstream", settings: "РќР°СЃС‚СЂРѕР№РєРё", refresh: "РћР±РЅРѕРІРёС‚СЊ",
    subtitle: "РџСЂРѕРґР°РєС€РЅ-РїР°РЅРµР»СЊ WireGuard: РґРѕСЃС‚СѓРїС‹, РјР°СЂС€СЂСѓС‚С‹ Рё Р°РЅР°Р»РёС‚РёРєР° С‚СЂР°С„РёРєР°.", traffic: "РўСЂР°С„РёРє", active: "РђРєС‚РёРІРЅС‹Рµ",
    period: "РџРµСЂРёРѕРґ", day: "24С‡", week: "7Рґ", month: "30Рґ", all: "Р’СЃРµ РІСЂРµРјСЏ", dynamics: "Р”РёРЅР°РјРёРєР° С‚СЂР°С„РёРєР°",
    topClients: "РўРѕРї РєР»РёРµРЅС‚РѕРІ", noStats: "РЎС‚Р°С‚РёСЃС‚РёРєР° РїРѕСЏРІРёС‚СЃСЏ РїРѕСЃР»Рµ РїРµСЂРІС‹С… Р·Р°РјРµСЂРѕРІ С‚СЂР°С„РёРєР°.",
    name: "РРјСЏ", comment: "РљРѕРјРјРµРЅС‚Р°СЂРёР№", actions: "Р”РµР№СЃС‚РІРёСЏ", endpoint: "Endpoint", live: "Live RX/TX",
    newClient: "РќРѕРІС‹Р№ РєР»РёРµРЅС‚", createClient: "РЎРѕР·РґР°С‚СЊ РєР»РёРµРЅС‚Р°", edit: "Р РµРґР°РєС‚РёСЂРѕРІР°С‚СЊ", save: "РЎРѕС…СЂР°РЅРёС‚СЊ", delete: "РЈРґР°Р»РёС‚СЊ",
    newUpstream: "РќРѕРІС‹Р№ upstream", upload: "Р—Р°РіСЂСѓР·РёС‚СЊ РєРѕРЅС„РёРі", makeDefault: "РЎРґРµР»Р°С‚СЊ default", disable: "РћС‚РєР»СЋС‡РёС‚СЊ", enable: "Р’РєР»СЋС‡РёС‚СЊ",
    notifications: "РЈРІРµРґРѕРјР»РµРЅРёСЏ", down: "РџР°РґРµРЅРёРµ", recovered: "Р’РѕСЃСЃС‚Р°РЅРѕРІР»РµРЅРёРµ", close: "Р—Р°РєСЂС‹С‚СЊ", qr: "QR",
    health: "РџСЂРѕРІРµСЂРѕС‡РЅС‹Рµ СЃРµСЂРІРёСЃС‹", addService: "Р”РѕР±Р°РІРёС‚СЊ СЃРµСЂРІРёСЃ", url: "URL", fetch: "РџРѕР»СѓС‡РёС‚СЊ РґР°РЅРЅС‹Рµ", confirm: "РџРѕРґС‚РІРµСЂРґРёС‚СЊ РѕР¶РёРґР°РµРјС‹Рµ РґР°РЅРЅС‹Рµ",
    remove: "РЈРґР°Р»РёС‚СЊ", interval: "РРЅС‚РµСЂРІР°Р» РїСЂРѕРІРµСЂРєРё", telegram: "Telegram", domain: "Р”РѕРјРµРЅ", cert: "РџРѕР»СѓС‡РёС‚СЊ СЃРµСЂС‚РёС„РёРєР°С‚",
    certLog: "Р›РѕРі СЃРµСЂС‚РёС„РёРєР°С‚Р°", botToken: "Bot token", chatId: "Chat ID", signIn: "Р’РѕР№С‚Рё", password: "РџР°СЂРѕР»СЊ Р°РґРјРёРЅРёСЃС‚СЂР°С‚РѕСЂР°",
    healthy: "Р Р°Р±РѕС‚Р°РµС‚", failed: "РќРµРґРѕСЃС‚СѓРїРµРЅ", pending: "РћР¶РёРґР°РµС‚"
  }
};
const ranges = { day: "day", week: "week", month: "month", all: "all" };
const dnsPresets = [["8.8.8.8, 8.8.4.4", "Google"], ["1.1.1.1, 1.0.0.1", "Cloudflare"], ["208.67.222.222, 208.67.220.220", "OpenDNS"], ["9.9.9.9, 149.112.112.112", "Quad9"], ["95.85.95.85, 2.56.220.2", "Gcore"], ["94.140.14.14, 94.140.15.15", "AdGuard"]];
const notifyIntervals = [[60, "1 min"], [300, "5 min"], [900, "15 min"], [3600, "1 h"], [21600, "6 h"], [43200, "12 h"], [86400, "24 h"]];
const awgKeys = ["Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4", "I1"];

function getCookieLang() {
  if (typeof document === "undefined") return "en";
  return document.cookie.split("; ").find((x) => x.startsWith("wg_lang="))?.split("=")[1] || "en";
}
function bytes(value) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let n = Number(value || 0), i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(i ? 1 : 0)} ${units[i]}`;
}
function dot(status) { return status === "healthy" ? "good" : status === "down" ? "danger-dot" : "idle"; }
async function api(path, options = {}) {
  const headers = options.body && typeof options.body === "string" ? { "Content-Type": "application/json", ...(options.headers || {}) } : options.headers;
  const res = await fetch(`/api/${path}`, { cache: "no-store", ...options, headers });
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || "Request failed");
  return res.json();
}
function Chart({ points, empty }) {
  const p = points || [];
  if (!p.length) return <div className="chart empty-chart">{empty}</div>;
  const max = Math.max(...p.map((x) => x.bytes), 1);
  const line = p.map((x, i) => `${i ? "L" : "M"} ${(p.length < 2 ? 0 : i / (p.length - 1) * 100).toFixed(2)} ${(100 - x.bytes / max * 86 - 7).toFixed(2)}`).join(" ");
  return <svg className="chart" viewBox="0 0 100 100" preserveAspectRatio="none"><path d={`${line} L 100 100 L 0 100 Z`} fill="rgba(72,213,151,.12)" /><path d={line} fill="none" stroke="#48d597" strokeWidth="2.2" vectorEffect="non-scaling-stroke" /></svg>;
}
function Modal({ title, children, onClose }) {
  return <div className="modal-backdrop"><div className="modal panel"><div className="panel-title"><h2>{title}</h2><button type="button" onClick={onClose}>x</button></div>{children}</div></div>;
}

export default function Page() {
  const [lang, setLang] = useState(getCookieLang());
  const t = dict[lang] || dict.en;
  const [authed, setAuthed] = useState(null);
  const [password, setPassword] = useState("");
  const [view, setView] = useState("dashboard");
  const [range, setRange] = useState("day");
  const [clients, setClients] = useState([]);
  const [upstreams, setUpstreams] = useState([]);
  const [stat, setStat] = useState({ total: 0, users: {}, points: [] });
  const [telegram, setTelegram] = useState({ enabled: false, token: "", chatId: "", notificationIntervalSeconds: 300, domain: "" });
  const [health, setHealth] = useState({ intervalSeconds: 60, checks: [] });
  const [probe, setProbe] = useState({ url: "", data: "" });
  const [certLog, setCertLog] = useState("");
  const [modal, setModal] = useState(null);
  const [target, setTarget] = useState({});
  const [qr, setQr] = useState(null);
  const [error, setError] = useState("");

  function setLanguage(next) {
    setLang(next);
    document.cookie = `wg_lang=${next}; Path=/; Max-Age=31536000; SameSite=Lax`;
  }
  async function refresh(check = false) {
    if (check) await api("health-check", { method: "POST" }).catch(() => null);
    const [c, u, s] = await Promise.all([api("clients"), api("upstreams"), api(`stats?range=${range}`)]);
    setClients(c); setUpstreams(u); setStat(s);
  }
  useEffect(() => { api("me").then(() => setAuthed(true)).catch(() => setAuthed(false)); }, []);
  useEffect(() => {
    if (!authed) return;
    refresh(true).catch((e) => setError(e.message));
    api("settings/health").then(setHealth).catch(() => {});
    api("settings/telegram").then(setTelegram).catch(() => {});
    api("settings/certbot").then((r) => setCertLog(r.log || "")).catch(() => {});
    const timer = setInterval(() => refresh(true).catch((e) => setError(e.message)), 60000);
    return () => clearInterval(timer);
  }, [authed, range]);

  async function login(e) { e.preventDefault(); try { await api("login", { method: "POST", body: JSON.stringify({ password }) }); setAuthed(true); } catch (err) { setError(err.message); } }
  async function addClient(e) {
    e.preventDefault(); const form = new FormData(e.currentTarget);
    await api("clients", { method: "POST", body: JSON.stringify({ name: form.get("name"), dns: form.get("dns"), comment: form.get("comment") }) });
    e.currentTarget.reset(); await refresh();
  }
  async function addUpstream(e) {
    e.preventDefault(); const form = new FormData(e.currentTarget);
    await api("upstreams", { method: "POST", body: form });
    e.currentTarget.reset(); await refresh(true);
  }
  async function saveEntity() {
    if (modal?.type === "client") await api(`clients/${modal.item.name}`, { method: "PATCH", body: JSON.stringify({ name: modal.name, comment: modal.comment }) });
    if (modal?.type === "upstream") await api("upstreams", { method: "PATCH", body: JSON.stringify({ update: { id: modal.item.id, name: modal.name, comment: modal.comment } }) });
    setModal(null); await refresh(true);
  }
  async function saveNotify() {
    await api("upstreams", { method: "PATCH", body: JSON.stringify({ notify: { id: modal.item.id, down: modal.down, recovered: modal.recovered } }) });
    setModal(null); await refresh();
  }
  async function probeUrl() {
    const result = await api("settings/health/probe", { method: "POST", body: JSON.stringify({ url: probe.url }) });
    setProbe({ url: result.url, data: result.expected });
  }
  async function confirmProbe() {
    const checks = [...(health.checks || []), { url: probe.url, expected: probe.data }].slice(0, 10);
    const next = { ...health, checks };
    setHealth(next); setProbe({ url: "", data: "" }); setModal(null);
    await api("settings/health", { method: "POST", body: JSON.stringify(next) });
  }
  async function removeCheck(index) {
    const next = { ...health, checks: health.checks.filter((_, i) => i !== index) };
    setHealth(next); await api("settings/health", { method: "POST", body: JSON.stringify(next) });
  }
  async function saveTelegram() { await api("settings/telegram", { method: "POST", body: JSON.stringify(telegram) }); }
  async function getCert() {
    const result = await api("settings/certbot", { method: "POST", body: JSON.stringify({ domain: telegram.domain }) });
    setCertLog(result.log || ""); await api("settings/telegram", { method: "POST", body: JSON.stringify(telegram) });
  }
  function targetOptions() { return [{ value: "direct", label: "AWG DIRECT" }, { value: "default", label: "AWG DEFAULT" }, ...upstreams.map((u) => ({ value: `upstream:${u.id}`, label: `AWG ${u.name}` }))]; }
  function params(value) { if (value === "default") return "mode=default"; if (value?.startsWith("upstream:")) return `mode=upstream&upstreamId=${value.slice(9)}`; return "mode=direct"; }
  async function showQr(client) { const q = params(target[client.name] || "direct"); const r = await api(`clients/${client.name}/qr?${q}`); setQr({ title: client.name, dataUrl: r.dataUrl }); }
  const active = clients.filter((c) => c.direct?.latestHandshake || c.upstream?.latestHandshake).length;
  const top = useMemo(() => Object.entries(stat.users || {}).sort((a, b) => b[1] - a[1]), [stat.users]);

  if (authed === false) return <main className="login"><form className="panel form" onSubmit={login}><h1>WireGuard Control</h1><input type="password" placeholder={t.password} value={password} onChange={(e) => setPassword(e.target.value)} /><button className="primary">{t.signIn}</button>{error && <span className="bad">{error}</span>}</form></main>;
  if (!authed) return null;

  return <main className="shell">
    <aside className="side"><div className="brand">WireGuard Control</div><div className="nav">{[["dashboard", t.overview], ["clients", t.clients], ["upstreams", t.upstreams], ["settings", t.settings]].map(([id, label]) => <button key={id} className={view === id ? "active" : ""} onClick={() => setView(id)}>{label}</button>)}</div></aside>
    <section className="main">
      <div className="page-head"><div><h1>{view === "dashboard" ? t.overview : view === "clients" ? t.clients : view === "upstreams" ? t.upstreams : t.settings}</h1><p>{t.subtitle}</p></div><div className="actions"><button onClick={() => setLanguage("en")}>рџ‡¬рџ‡§</button><button onClick={() => setLanguage("ru")}>рџ‡·рџ‡є</button><button onClick={() => refresh(true)}>{t.refresh}</button></div></div>
      <div className="upstream-strip">{upstreams.map((u) => <div className="upstream-chip" key={u.id} title={u.comment || ""}><span className={`status-dot ${dot(u.status)}`} /><b>{u.name}</b>{u.isDefault && <span className="pill ok">DEFAULT</span>}<span className="muted">{u.status === "healthy" ? t.healthy : u.status === "down" ? t.failed : t.pending}</span></div>)}</div>
      <div className="top"><div className="metric"><span className="muted">{t.traffic}</span><b>{bytes(stat.total)}</b></div><div className="metric"><span className="muted">{t.clients}</span><b>{clients.length}</b></div><div className="metric"><span className="muted">{t.active}</span><b>{active}</b></div><div className="metric"><span className="muted">{t.period}</span><select value={range} onChange={(e) => setRange(e.target.value)}>{Object.keys(ranges).map((r) => <option key={r} value={r}>{t[r]}</option>)}</select></div></div>
      {error && <p className="bad">{error}</p>}
      {view === "dashboard" && <div className="dashboard-grid"><div className="panel wide"><div className="panel-title"><h2>{t.dynamics}</h2><span className="muted">{t[range]}</span></div><Chart points={stat.points} empty={t.noStats} /></div><div className="panel"><h2>{t.topClients}</h2>{top.length ? top.slice(0, 8).map(([n, v]) => <div className="rank-row" key={n}><span>{n}</span><b>{bytes(v)}</b></div>) : <p className="muted">{t.noStats}</p>}</div><div className="panel wide"><div className="table"><div className="table-head"><span>{t.name}</span><span>{t.period}</span><span>{t.live}</span><span>{t.endpoint}</span></div>{clients.map((c) => <div className="table-row" key={c.name}><span className="tooltip" data-tip={c.comment || ""}>{c.name}</span><b>{bytes(stat.users?.[c.name] || 0)}</b><span>{bytes((c.direct?.rx || 0) + (c.upstream?.rx || 0))} / {bytes((c.direct?.tx || 0) + (c.upstream?.tx || 0))}</span><span className="muted">{c.direct?.endpoint || c.upstream?.endpoint || "-"}</span></div>)}</div></div></div>}
      {view === "clients" && <div className="grid"><div className="panel"><h2>{t.clients}</h2>{clients.map((c) => <div className="row" key={c.name}><div><b className="tooltip" data-tip={c.comment || ""}>{c.name}</b><div className="muted">{c.allowedIPs}</div></div><div className="actions"><select value={target[c.name] || "direct"} onChange={(e) => setTarget({ ...target, [c.name]: e.target.value })}>{targetOptions().map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}</select><button onClick={() => showQr(c)}>{t.qr}</button><a href={`/api/clients/${c.name}/config?${params(target[c.name] || "direct")}`} download><button>.conf</button></a><button onClick={() => setModal({ type: "client", item: c, name: c.name, comment: c.comment || "", awg: c.awg || {} })}>{t.edit}</button><button className="danger" onClick={async () => { await api(`clients/${c.name}`, { method: "DELETE" }); await refresh(); }}>{t.delete}</button></div></div>)}</div><form className="panel form" onSubmit={addClient}><h2>{t.newClient}</h2><label>{t.name}<input name="name" maxLength="12" pattern="[A-Za-z-]{1,12}" required /></label><label>DNS<select name="dns" defaultValue="8.8.8.8, 8.8.4.4">{dnsPresets.map(([v, l]) => <option key={l} value={v}>{l} - {v}</option>)}</select></label><label>{t.comment}<textarea name="comment" maxLength="300" /></label><button className="primary">{t.createClient}</button></form></div>}
      {view === "upstreams" && <div className="grid"><div className="panel"><h2>{t.upstreams}</h2>{upstreams.map((u) => <div className="row" key={u.id}><div><b>{u.name}</b> {u.isDefault && <span className="pill ok">DEFAULT</span>}<div><span className={`status-dot ${dot(u.status)}`} /> {u.status === "healthy" ? t.healthy : u.status === "down" ? t.failed : t.pending}</div><div className="muted">{(u.protocol === "awg" ? "AWG 2.0 · " : "AWG native · ")}{u.comment || u.lastError}</div></div><div className="actions">{!u.isDefault && <button onClick={async () => { await api("upstreams", { method: "PATCH", body: JSON.stringify({ defaultId: u.id }) }); await refresh(true); }}>{t.makeDefault}</button>}<button onClick={() => setModal({ type: "upstream", item: u, name: u.name, comment: u.comment || "" })}>{t.edit}</button><button onClick={() => setModal({ type: "notify", item: u, down: u.notify?.down || false, recovered: u.notify?.recovered || false })}>{t.notifications}</button><button onClick={async () => { await api("upstreams", { method: "PATCH", body: JSON.stringify({ toggle: { id: u.id, enabled: !u.enabled } }) }); await refresh(true); }}>{u.enabled ? t.disable : t.enable}</button><button className="danger" onClick={async () => { await api(`upstreams/${u.id}`, { method: "DELETE" }); await refresh(true); }}>{t.delete}</button></div></div>)}</div><form className="panel form" onSubmit={addUpstream}><h2>{t.newUpstream}</h2><label>{t.name}<input name="name" maxLength="12" pattern="[A-Za-z-]{1,12}" required /></label><label>{t.comment}<textarea name="comment" maxLength="300" /></label><input name="file" type="file" accept=".conf" required /><button className="primary">{t.upload}</button></form></div>}
      {view === "settings" && <div className="grid"><div className="panel form"><h2>{t.health}</h2><label>{t.interval}<select value={health.intervalSeconds || 60} onChange={async (e) => { const next = { ...health, intervalSeconds: Number(e.target.value) }; setHealth(next); await api("settings/health", { method: "POST", body: JSON.stringify(next) }); }}>{notifyIntervals.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label><div className="list">{(health.checks || []).map((c, i) => <div className="row" key={`${c.url}-${i}`}><div><b>{c.url}</b><div className="muted">{bytes((c.expected || "").length)} expected response</div></div><button type="button" onClick={() => removeCheck(i)}>{t.remove}</button></div>)}{!(health.checks || []).length && <p className="muted">{t.noStats}</p>}</div><button type="button" className="primary" disabled={(health.checks || []).length >= 10} onClick={() => { setProbe({ url: "", data: "" }); setModal({ type: "health" }); }}>{t.addService}</button></div><div className="panel form"><h2>{t.telegram}</h2><label><input type="checkbox" checked={telegram.enabled || false} onChange={(e) => setTelegram({ ...telegram, enabled: e.target.checked })} /> Enabled</label><label>{t.botToken}<input value={telegram.token || ""} onChange={(e) => setTelegram({ ...telegram, token: e.target.value })} /></label><label>{t.chatId}<input value={telegram.chatId || ""} onChange={(e) => setTelegram({ ...telegram, chatId: e.target.value })} /></label><label>{t.interval}<select value={telegram.notificationIntervalSeconds || 300} onChange={(e) => setTelegram({ ...telegram, notificationIntervalSeconds: Number(e.target.value) })}>{notifyIntervals.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label><button className="primary" onClick={saveTelegram}>{t.save}</button><h2>{t.domain}</h2><input value={telegram.domain || ""} onChange={(e) => setTelegram({ ...telegram, domain: e.target.value })} placeholder="vpn.example.com" /><button onClick={getCert}>{t.cert}</button><h2>{t.certLog}</h2><textarea readOnly value={certLog} /></div></div>}
      {(modal?.type === "client" || modal?.type === "upstream") && <Modal title={t.edit} onClose={() => setModal(null)}><div className="form"><label>{t.name}<input maxLength="12" pattern="[A-Za-z-]{1,12}" value={modal.name} onChange={(e) => setModal({ ...modal, name: e.target.value })} /></label><label>{t.comment}<textarea maxLength="300" value={modal.comment} onChange={(e) => setModal({ ...modal, comment: e.target.value })} /></label>{modal?.type === "client" && <AwgFields value={modal.awg || {}} onChange={(awg) => setModal({ ...modal, awg })} />}<button className="primary" onClick={saveEntity}>{t.save}</button></div></Modal>}
      {modal?.type === "notify" && <Modal title={`${t.notifications}: ${modal.item.name}`} onClose={() => setModal(null)}><div className="form"><label><input type="checkbox" checked={modal.down} onChange={(e) => setModal({ ...modal, down: e.target.checked })} /> {t.down}</label><label><input type="checkbox" checked={modal.recovered} onChange={(e) => setModal({ ...modal, recovered: e.target.checked })} /> {t.recovered}</label><button className="primary" onClick={saveNotify}>{t.save}</button></div></Modal>}
      {modal?.type === "health" && <Modal title={t.addService} onClose={() => setModal(null)}><div className="form"><label>{t.url}<input value={probe.url} onChange={(e) => setProbe({ ...probe, url: e.target.value })} placeholder="https://example.com/status" /></label><button type="button" onClick={probeUrl}>{t.fetch}</button>{probe.data && <textarea readOnly value={probe.data} />}{probe.data && <button type="button" className="primary" onClick={confirmProbe}>{t.confirm}</button>}</div></Modal>}
      {qr && <Modal title={qr.title} onClose={() => setQr(null)}><div className="qr"><img src={qr.dataUrl} alt={qr.title} /></div></Modal>}
    </section>
  </main>;
}
EOF

	cat > /opt/wg-web/app/app/page.js << 'EOF'
"use client";

import { useEffect, useMemo, useState } from "react";

const namePattern = /^[A-Za-z0-9-]{1,14}$/;
const awgKeys = ["Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4", "I1"];
const dict = {
  en: {
    overview: "Overview", clients: "Clients", upstreams: "Upstreams", settings: "Settings", refresh: "Refresh",
    subtitle: "Production WireGuard/AWG management, routing and traffic analytics.", traffic: "Traffic", active: "Active",
    period: "Period", day: "24h", week: "7d", month: "30d", all: "All time", dynamics: "Traffic dynamics",
    topClients: "Top clients", noStats: "Statistics will appear after traffic samples are collected.", name: "Name",
    comment: "Comment", endpoint: "Endpoint", live: "Live RX/TX", newClient: "New client", createClient: "Create client",
    edit: "Edit", save: "Save", delete: "Delete", copy: "Copy", copied: "Config copied", download: ".conf",
    newUpstream: "New upstream", upload: "Upload config", makeDefault: "Set default", disable: "Disable", enable: "Enable",
    notifications: "Notifications", down: "Down", recovered: "Recovered", qr: "QR", health: "Health checks",
    addService: "Add service", url: "URL", fetch: "Fetch data", confirm: "Confirm expected data", remove: "Remove",
    interval: "Check interval", telegram: "Telegram", domainCert: "Domain and certificate", domain: "Domain",
    cert: "Get certificate", certLog: "Certificate log", botToken: "Bot token", chatId: "Chat ID", signIn: "Sign in",
    password: "Admin password", healthy: "Healthy", failed: "Down", pending: "Pending", serverIp: "Server IP",
    nameRule: "Use 1-14 characters: English letters, numbers and hyphen only.", lastActive: "Last active", never: "Never",
    subscription: "Subscription", expiresAt: "Valid until", accessKey: "Access key", extendSubscription: "Extend subscription",
    cancelSubscription: "Cancel subscription", unlimited: "Unlimited", expired: "Expired", activeSubscription: "Active",
    choosePeriod: "Choose period", annul: "Annul"
  },
  ru: {
    overview: "Обзор", clients: "Клиенты", upstreams: "Upstreams", settings: "Настройки", refresh: "Обновить",
    subtitle: "Панель управления WireGuard/AWG: доступы, маршруты и аналитика трафика.", traffic: "Трафик", active: "Активные",
    period: "Период", day: "24ч", week: "7д", month: "30д", all: "Все время", dynamics: "Динамика трафика",
    topClients: "Топ клиентов", noStats: "Статистика появится после первых замеров трафика.", name: "Имя",
    comment: "Комментарий", endpoint: "Endpoint", live: "Live RX/TX", newClient: "Новый клиент", createClient: "Создать клиента",
    edit: "Редактировать", save: "Сохранить", delete: "Удалить", copy: "Копировать", copied: "Конфиг скопирован",
    download: ".conf", newUpstream: "Новый upstream", upload: "Загрузить конфиг", makeDefault: "Сделать default",
    disable: "Отключить", enable: "Включить", notifications: "Уведомления", down: "Падение", recovered: "Восстановление",
    qr: "QR", health: "Проверочные сервисы", addService: "Добавить сервис", url: "URL", fetch: "Получить данные",
    confirm: "Подтвердить ожидаемые данные", remove: "Удалить", interval: "Интервал проверки", telegram: "Telegram",
    domainCert: "Домен и сертификат", domain: "Домен", cert: "Получить сертификат", certLog: "Лог сертификата",
    botToken: "Bot token", chatId: "Chat ID", signIn: "Войти", password: "Пароль администратора", healthy: "Работает",
    failed: "Недоступен", pending: "Ожидает", serverIp: "IP сервера",
	    nameRule: "Используйте 1-14 символов: английские буквы, цифры и дефис.", lastActive: "Последняя активность", never: "Никогда",
	    subscription: "Подписка", expiresAt: "Действует до", accessKey: "Ключ доступа", extendSubscription: "Продлить подписку",
	    cancelSubscription: "Аннулировать подписку", unlimited: "Анлим", expired: "Истекла", activeSubscription: "Активна",
	    choosePeriod: "Выберите срок", annul: "Аннулировать"
  }
};
const ranges = { day: "day", week: "week", month: "month", all: "all" };
const dnsPresets = [["8.8.8.8, 8.8.4.4", "Google"], ["1.1.1.1, 1.0.0.1", "Cloudflare"], ["208.67.222.222, 208.67.220.220", "OpenDNS"], ["9.9.9.9, 149.112.112.112", "Quad9"], ["95.85.95.85, 2.56.220.2", "Gcore"], ["94.140.14.14, 94.140.15.15", "AdGuard"]];
const notifyIntervals = [[60, "1 min"], [300, "5 min"], [900, "15 min"], [3600, "1 h"], [21600, "6 h"], [43200, "12 h"], [86400, "24 h"]];
const subscriptionPlans = [["7d", "7д"], ["1m", "1м"], ["3m", "3м"], ["6m", "6м"], ["12m", "12м"], ["24m", "24м"]];
const extendPlans = [...subscriptionPlans, ["unlimited", "Анлим"]];

function getCookieLang() {
  if (typeof document === "undefined") return "en";
  return document.cookie.split("; ").find((x) => x.startsWith("wg_lang="))?.split("=")[1] || "en";
}
function bytes(value) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let n = Number(value || 0), i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(i ? 1 : 0)} ${units[i]}`;
}
function dot(status) { return status === "healthy" ? "good" : status === "down" ? "danger-dot" : "idle"; }
function statusTitle(t, status) { return status === "healthy" ? t.healthy : status === "down" ? t.failed : t.pending; }
function lastHandshake(client) { return Math.max(client.direct?.latestHandshake || 0, client.upstream?.latestHandshake || 0); }
function ago(ts, t) {
  if (!ts) return t.never;
  let seconds = Math.max(1, Math.floor(Date.now() / 1000 - ts));
  const d = Math.floor(seconds / 86400); seconds %= 86400;
  const h = Math.floor(seconds / 3600); seconds %= 3600;
  const m = Math.floor(seconds / 60);
  return `${d ? `${d}d` : ""}${h ? `${h}h` : ""}${m || (!d && !h) ? `${m}m` : ""} ago`;
}
function subscriptionText(client, t, lang) {
  const sub = client.subscription || {};
  if (sub.expiresAt === null) return t.unlimited;
  if (!sub.expiresAt) return "-";
  const date = new Date(sub.expiresAt);
  if (Number.isNaN(date.getTime())) return "-";
  return `${date.toLocaleString(lang === "ru" ? "ru-RU" : "en-US")} (${sub.expired ? t.expired : t.activeSubscription})`;
}
async function api(path, options = {}) {
  const headers = options.body && typeof options.body === "string" ? { "Content-Type": "application/json", ...(options.headers || {}) } : options.headers;
  const res = await fetch(`/api/${path}`, { cache: "no-store", ...options, headers });
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || "Request failed");
  return res.json();
}
function configParams(value) {
  if (value === "awg-direct") return "mode=direct&protocol=awg";
  if (value === "awg-default") return "mode=default&protocol=awg";
  if (value?.startsWith("awg-upstream:")) return `mode=upstream&protocol=awg&upstreamId=${value.slice(13)}`;
  if (value === "default") return "mode=default&protocol=wg";
  if (value?.startsWith("upstream:")) return `mode=upstream&protocol=wg&upstreamId=${value.slice(9)}`;
  return "mode=direct&protocol=wg";
}
function routeValue(route = {}) {
  const prefix = route.protocol === "awg" ? "awg-" : "";
  if (route.mode === "direct") return `${prefix}direct`;
  if (route.mode === "upstream" && route.upstreamId) return `${prefix}upstream:${route.upstreamId}`;
  return `${prefix}default`;
}
function routePayload(value) {
  const raw = String(value || "");
  if (raw.startsWith("awg-upstream:")) return { protocol: "awg", mode: "upstream", upstreamId: raw.slice(13) };
  if (raw.startsWith("upstream:")) return { protocol: "wg", mode: "upstream", upstreamId: raw.slice(9) };
  if (raw === "awg-direct" || raw === "awg-default") return { protocol: "awg", mode: raw === "awg-direct" ? "direct" : "default", upstreamId: "" };
  return { protocol: "wg", mode: raw === "direct" ? "direct" : "default", upstreamId: "" };
}
function Chart({ points, empty }) {
  const p = points || [];
  if (!p.length) return <div className="chart empty-chart">{empty}</div>;
  const max = Math.max(...p.map((x) => x.bytes), 1);
  const line = p.map((x, i) => `${i ? "L" : "M"} ${(p.length < 2 ? 0 : i / (p.length - 1) * 100).toFixed(2)} ${(100 - x.bytes / max * 86 - 7).toFixed(2)}`).join(" ");
  return <svg className="chart" viewBox="0 0 100 100" preserveAspectRatio="none"><path d={`${line} L 100 100 L 0 100 Z`} fill="rgba(72,213,151,.12)" /><path d={line} fill="none" stroke="#48d597" strokeWidth="2.2" vectorEffect="non-scaling-stroke" /></svg>;
}
function Modal({ title, children, onClose }) {
  return <div className="modal-backdrop"><div className="modal panel"><div className="panel-title"><h2>{title}</h2><button type="button" onClick={onClose}>x</button></div>{children}</div></div>;
}
function NameInput({ value, onChange, name = "name", t }) {
  return <label>{t.name}<input name={name} maxLength="14" pattern="[A-Za-z0-9-]{1,14}" title={t.nameRule} required value={value} onChange={onChange} onInvalid={(e) => e.currentTarget.setCustomValidity(t.nameRule)} onInput={(e) => e.currentTarget.setCustomValidity("")} /><span className="hint">{t.nameRule}</span></label>;
}
function AwgFields({ value = {}, onChange }) {
  return <div className="awg-grid">{awgKeys.map((key) => <label key={key}>{key}<input value={value[key] || ""} onChange={(e) => onChange({ ...value, [key]: e.target.value })} /></label>)}</div>;
}

export default function Page() {
  const [lang, setLang] = useState(getCookieLang());
  const t = dict[lang] || dict.en;
  const [authed, setAuthed] = useState(null);
  const [password, setPassword] = useState("");
  const [view, setView] = useState("dashboard");
  const [range, setRange] = useState("day");
  const [clients, setClients] = useState([]);
  const [upstreams, setUpstreams] = useState([]);
  const [stat, setStat] = useState({ total: 0, users: {}, points: [] });
  const [telegram, setTelegram] = useState({ enabled: false, token: "", chatId: "", notificationIntervalSeconds: 300, domain: "" });
  const [health, setHealth] = useState({ intervalSeconds: 60, checks: [] });
  const [probe, setProbe] = useState({ url: "", data: "" });
  const [certLog, setCertLog] = useState("");
  const [modal, setModal] = useState(null);
  const [target, setTarget] = useState({});
  const [qr, setQr] = useState(null);
  const [error, setError] = useState("");

  function setLanguage(next) { setLang(next); document.cookie = `wg_lang=${next}; Path=/; Max-Age=31536000; SameSite=Lax`; }
  function validateName(value) { if (!namePattern.test(String(value || ""))) { window.alert(t.nameRule); return false; } return true; }
  async function run(fn) { try { setError(""); await fn(); } catch (err) { setError(err.message); window.alert(err.message); } }
  async function refresh(check = false) {
    if (check) await api("health-check", { method: "POST" }).catch(() => null);
    const [c, u, s] = await Promise.all([api("clients"), api("upstreams"), api(`stats?range=${range}`)]);
    setClients(c); setUpstreams(u); setStat(s);
    setTarget((prev) => {
      const next = { ...prev };
      for (const client of c) {
        if (!next[client.name]) next[client.name] = routeValue(client.route || {});
      }
      return next;
    });
  }
  async function refreshAfterMutation() {
    await refresh(false);
    setTimeout(() => refresh(true).catch((e) => setError(e.message)), 300);
  }
  useEffect(() => { api("me").then(() => setAuthed(true)).catch(() => setAuthed(false)); }, []);
  useEffect(() => {
    if (!authed) return;
    refresh(true).catch((e) => setError(e.message));
    api("settings/health").then(setHealth).catch(() => {});
    api("settings/telegram").then(setTelegram).catch(() => {});
    api("settings/certbot").then((r) => setCertLog(r.log || "")).catch(() => {});
    const timer = setInterval(() => refresh(true).catch((e) => setError(e.message)), 60000);
    return () => clearInterval(timer);
  }, [authed, range]);

  async function login(e) { e.preventDefault(); await run(async () => { await api("login", { method: "POST", body: JSON.stringify({ password }) }); setAuthed(true); }); }
  async function addClient(e) {
    e.preventDefault(); const formEl = e.currentTarget; const form = new FormData(formEl); const name = form.get("name");
    if (!validateName(name)) return;
    await run(async () => { await api("clients", { method: "POST", body: JSON.stringify({ name, dns: form.get("dns"), comment: form.get("comment"), subscription: form.get("subscription") }) }); formEl.reset(); await refreshAfterMutation(); });
  }
  async function addUpstream(e) {
    e.preventDefault(); const formEl = e.currentTarget; const form = new FormData(formEl);
    if (!validateName(form.get("name"))) return;
    await run(async () => { await api("upstreams", { method: "POST", body: form }); formEl.reset(); await refreshAfterMutation(); });
  }
  async function saveEntity() {
    if (!validateName(modal.name)) return;
    await run(async () => {
      if (modal?.type === "client") await api(`clients/${modal.item.name}`, { method: "PATCH", body: JSON.stringify({ name: modal.name, comment: modal.comment, awg: modal.awg }) });
      if (modal?.type === "upstream") await api("upstreams", { method: "PATCH", body: JSON.stringify({ update: { id: modal.item.id, name: modal.name, comment: modal.comment } }) });
      setModal(null); await refresh(true);
    });
  }
  async function saveNotify() { await run(async () => { await api("upstreams", { method: "PATCH", body: JSON.stringify({ notify: { id: modal.item.id, down: modal.down, recovered: modal.recovered } }) }); setModal(null); await refresh(); }); }
  async function probeUrl() { await run(async () => { const result = await api("settings/health/probe", { method: "POST", body: JSON.stringify({ url: probe.url }) }); setProbe({ url: result.url, data: result.expected }); }); }
  async function confirmProbe() { await run(async () => { const next = { ...health, checks: [...(health.checks || []), { url: probe.url, expected: probe.data }].slice(0, 10) }; setHealth(next); setProbe({ url: "", data: "" }); setModal(null); await api("settings/health", { method: "POST", body: JSON.stringify(next) }); }); }
  async function removeCheck(index) { await run(async () => { const next = { ...health, checks: health.checks.filter((_, i) => i !== index) }; setHealth(next); await api("settings/health", { method: "POST", body: JSON.stringify(next) }); }); }
  async function saveTelegram() { await run(async () => { await api("settings/telegram", { method: "POST", body: JSON.stringify(telegram) }); }); }
  async function getCert() { await run(async () => { const result = await api("settings/certbot", { method: "POST", body: JSON.stringify({ domain: telegram.domain }) }); setCertLog(result.log || ""); await api("settings/telegram", { method: "POST", body: JSON.stringify(telegram) }); }); }
  async function setClientEnabled(client, enabled) { await run(async () => { await api(`clients/${client.name}/enabled`, { method: "PATCH", body: JSON.stringify({ enabled }) }); await refresh(true); }); }
  async function extendSubscription() {
    await run(async () => {
      await api(`clients/${modal.item.name}/subscription/extend`, { method: "POST", body: JSON.stringify({ plan: modal.plan || "1m" }) });
      setModal(null);
      await refreshAfterMutation();
    });
  }
  async function cancelSubscription(client) {
    if (!window.confirm(t.cancelSubscription + "?")) return;
    await run(async () => { await api(`clients/${client.name}/subscription/cancel`, { method: "POST" }); await refreshAfterMutation(); });
  }
  function targetOptions() {
    return [
      { value: "direct", label: "WG NATIVE DIRECT" },
      { value: "default", label: "WG NATIVE DEFAULT" },
      ...upstreams.map((u) => ({ value: `upstream:${u.id}`, label: `WG NATIVE ${u.name}` })),
      { value: "awg-direct", label: "AWG DIRECT" },
      { value: "awg-default", label: "AWG DEFAULT" },
      ...upstreams.map((u) => ({ value: `awg-upstream:${u.id}`, label: `AWG ${u.name}` }))
    ];
  }
  async function showQr(client) { await run(async () => { const r = await api(`clients/${client.name}/qr?${configParams(target[client.name] || "default")}`); setQr({ title: client.name, dataUrl: r.dataUrl }); }); }
  async function copyConfig(client) {
    await run(async () => {
      const res = await fetch(`/api/clients/${client.name}/config?${configParams(target[client.name] || "default")}`, { cache: "no-store" });
      if (!res.ok) throw new Error("Config request failed");
      await navigator.clipboard.writeText(await res.text());
      window.alert(t.copied);
    });
  }
  const active = clients.filter((c) => !c.disabled && (c.direct?.latestHandshake || c.upstream?.latestHandshake)).length;
  const top = useMemo(() => Object.entries(stat.users || {}).sort((a, b) => b[1] - a[1]).map(([name, value]) => ({ name, value, client: clients.find((c) => c.name === name) })), [stat.users, clients]);

  if (authed === false) return <main className="login"><form className="panel form" onSubmit={login}><h1>DD WG Control Panel</h1><input type="password" placeholder={t.password} value={password} onChange={(e) => setPassword(e.target.value)} /><button className="primary">{t.signIn}</button>{error && <span className="bad">{error}</span>}</form></main>;
  if (!authed) return null;

  return <main className="shell">
    <aside className="side"><div className="brand">DD WG Control Panel</div><div className="nav">{[["dashboard", t.overview], ["clients", t.clients], ["upstreams", t.upstreams], ["settings", t.settings]].map(([id, label]) => <button key={id} className={view === id ? "active" : ""} onClick={() => setView(id)}>{label}</button>)}</div></aside>
    <section className="main">
      <div className="page-head"><div><h1>{view === "dashboard" ? t.overview : view === "clients" ? t.clients : view === "upstreams" ? t.upstreams : t.settings}</h1><p>{t.subtitle}</p></div><div className="actions"><button onClick={() => setLanguage("en")}>EN</button><button onClick={() => setLanguage("ru")}>RU</button><button onClick={() => refresh(true)}>{t.refresh}</button></div></div>
      <div className="upstream-strip">{upstreams.map((u) => <div className="upstream-chip" key={u.id} title={`${statusTitle(t, u.status)}${u.serverIp ? ` - ${u.serverIp}` : ""}`}><span className={`status-dot ${dot(u.status)}`} /><b>{u.name}</b>{u.isDefault && <span className="pill ok">DEFAULT</span>}</div>)}</div>
      <div className="top"><div className="metric"><span className="muted">{t.traffic}</span><b>{bytes(stat.total)}</b></div><div className="metric"><span className="muted">{t.clients}</span><b>{clients.length}</b></div><div className="metric"><span className="muted">{t.active}</span><b>{active}</b></div><div className="metric"><span className="muted">{t.period}</span><select value={range} onChange={(e) => setRange(e.target.value)}>{Object.keys(ranges).map((r) => <option key={r} value={r}>{t[r]}</option>)}</select></div></div>
      {error && <p className="bad">{error}</p>}
      {view === "dashboard" && <div className="dashboard-grid"><div className="panel wide"><div className="panel-title"><h2>{t.dynamics}</h2><span className="muted">{t[range]}</span></div><Chart points={stat.points} empty={t.noStats} /></div><div className="panel"><h2>{t.topClients}</h2>{top.length ? top.slice(0, 8).map(({ name, value, client }) => { const last = lastHandshake(client || {}); return <div className={`rank-row ${last && Date.now() / 1000 - last > 604800 ? "stale" : ""}`} key={name}><div><b>{name}</b><div className="muted">{t.lastActive}: {ago(last, t)}</div></div><b>{bytes(value)}</b></div>; }) : <p className="muted">{t.noStats}</p>}</div><div className="panel wide"><div className="table"><div className="table-head"><span>{t.name}</span><span>{t.period}</span><span>{t.live}</span><span>{t.endpoint}</span></div>{clients.map((c) => <div className={`table-row ${c.disabled ? "disabled-row" : ""}`} key={c.name}><span className="tooltip" data-tip={c.comment || ""}>{c.name}</span><b>{bytes(stat.users?.[c.name] || 0)}</b><span>{bytes((c.direct?.rx || 0) + (c.upstream?.rx || 0))} / {bytes((c.direct?.tx || 0) + (c.upstream?.tx || 0))}</span><span className="muted">{c.disabled ? t.disable : c.direct?.endpoint || c.upstream?.endpoint || "-"}</span></div>)}</div></div></div>}
      {view === "clients" && <div className="grid"><div className="panel"><h2>{t.clients}</h2>{clients.map((c) => <div className={`row ${c.disabled ? "disabled-row" : ""}`} key={c.name}><div><b className="tooltip" data-tip={c.comment || ""}>{c.name}</b><div className="muted">{c.allowedIPs} - {t.lastActive}: {ago(lastHandshake(c), t)}</div><div className="muted">{t.expiresAt}: {subscriptionText(c, t, lang)}</div><div className="muted">{t.accessKey}: <b>{c.accessKey || "-"}</b></div></div><div className="actions"><select value={target[c.name] || "default"} onChange={(e) => setTarget({ ...target, [c.name]: e.target.value })}>{targetOptions().map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}</select><button onClick={() => showQr(c)} disabled={c.disabled}>{t.qr}</button>{c.disabled ? <button disabled>{t.download}</button> : <a className="button-link" href={`/api/clients/${c.name}/config?${configParams(target[c.name] || "default")}`} download>{t.download}</a>}<button onClick={() => copyConfig(c)} disabled={c.disabled}>{t.copy}</button><button onClick={() => setModal({ type: "subscription", item: c, plan: "1m" })}>{t.extendSubscription}</button><button className="danger" onClick={() => cancelSubscription(c)}>{t.cancelSubscription}</button><button onClick={() => setModal({ type: "client", item: c, name: c.name, comment: c.comment || "", awg: c.awg || {} })}>{t.edit}</button><button onClick={() => setClientEnabled(c, c.disabled)}>{c.disabled ? t.enable : t.disable}</button><button className="danger" onClick={() => run(async () => { await api(`clients/${c.name}`, { method: "DELETE" }); await refresh(); })}>{t.delete}</button></div></div>)}</div><form className="panel form" onSubmit={addClient}><h2>{t.newClient}</h2><NameInput t={t} /><label>{t.subscription}<select name="subscription" defaultValue="1m">{subscriptionPlans.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label><label>DNS<select name="dns" defaultValue="8.8.8.8, 8.8.4.4">{dnsPresets.map(([v, l]) => <option key={l} value={v}>{l} - {v}</option>)}</select></label><label>{t.comment}<textarea name="comment" maxLength="300" /></label><button className="primary">{t.createClient}</button></form></div>}
      {view === "upstreams" && <div className="grid"><div className="panel"><h2>{t.upstreams}</h2>{upstreams.map((u) => <div className="row" key={u.id}><div><b>{u.name}</b> {u.isDefault && <span className="pill ok">DEFAULT</span>}<div className="compact-meta"><span className={`status-dot ${dot(u.status)}`} title={statusTitle(t, u.status)} /> <span className="muted">{t.serverIp}: {u.serverIp || "-"}</span></div><div className="muted">{(u.protocol === "awg" ? "AWG 2.0 · " : "AWG native · ")}{u.comment || u.lastError}</div></div><div className="actions">{!u.isDefault && <button className="default-action" onClick={() => run(async () => { await api("upstreams", { method: "PATCH", body: JSON.stringify({ defaultId: u.id }) }); await refresh(true); })}>{t.makeDefault}</button>}<button onClick={() => setModal({ type: "upstream", item: u, name: u.name, comment: u.comment || "" })}>{t.edit}</button><button className="notify-action" onClick={() => setModal({ type: "notify", item: u, down: u.notify?.down || false, recovered: u.notify?.recovered || false })}>{t.notifications}</button><button onClick={() => run(async () => { await api("upstreams", { method: "PATCH", body: JSON.stringify({ toggle: { id: u.id, enabled: !u.enabled } }) }); await refresh(true); })}>{u.enabled ? t.disable : t.enable}</button><button className="danger" onClick={() => run(async () => { await api(`upstreams/${u.id}`, { method: "DELETE" }); await refresh(true); })}>{t.delete}</button></div></div>)}</div><form className="panel form" onSubmit={addUpstream}><h2>{t.newUpstream}</h2><NameInput t={t} /><label>{t.comment}<textarea name="comment" maxLength="300" /></label><input name="file" type="file" accept=".conf" required /><button className="primary">{t.upload}</button></form></div>}
      {view === "settings" && <div className="settings-grid"><div className="panel form"><h2>{t.health}</h2><label>{t.interval}<select value={health.intervalSeconds || 60} onChange={(e) => run(async () => { const next = { ...health, intervalSeconds: Number(e.target.value) }; setHealth(next); await api("settings/health", { method: "POST", body: JSON.stringify(next) }); })}>{notifyIntervals.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label><div className="list">{(health.checks || []).map((c, i) => <div className="row" key={`${c.url}-${i}`}><div><b>{c.url}</b><div className="muted">{bytes((c.expected || "").length)} expected response</div></div><button type="button" onClick={() => removeCheck(i)}>{t.remove}</button></div>)}{!(health.checks || []).length && <p className="muted">{t.noStats}</p>}</div><button type="button" className="primary" disabled={(health.checks || []).length >= 10} onClick={() => { setProbe({ url: "", data: "" }); setModal({ type: "health" }); }}>{t.addService}</button></div><div className="panel form"><h2>{t.telegram}</h2><label><input type="checkbox" checked={telegram.enabled || false} onChange={(e) => setTelegram({ ...telegram, enabled: e.target.checked })} /> Enabled</label><label>{t.botToken}<input value={telegram.token || ""} onChange={(e) => setTelegram({ ...telegram, token: e.target.value })} /></label><label>{t.chatId}<input value={telegram.chatId || ""} onChange={(e) => setTelegram({ ...telegram, chatId: e.target.value })} /></label><label>{t.interval}<select value={telegram.notificationIntervalSeconds || 300} onChange={(e) => setTelegram({ ...telegram, notificationIntervalSeconds: Number(e.target.value) })}>{notifyIntervals.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label><button className="primary" onClick={saveTelegram}>{t.save}</button></div><div className="panel form"><h2>{t.domainCert}</h2><label>{t.domain}<input value={telegram.domain || ""} onChange={(e) => setTelegram({ ...telegram, domain: e.target.value })} placeholder="vpn.example.com" /></label><button onClick={getCert}>{t.cert}</button><label>{t.certLog}<textarea readOnly value={certLog} /></label></div></div>}
      {(modal?.type === "client" || modal?.type === "upstream") && <Modal title={t.edit} onClose={() => setModal(null)}><div className="form"><NameInput t={t} value={modal.name} onChange={(e) => setModal({ ...modal, name: e.target.value })} /><label>{t.comment}<textarea maxLength="300" value={modal.comment} onChange={(e) => setModal({ ...modal, comment: e.target.value })} /></label>{modal?.type === "client" && <AwgFields value={modal.awg || {}} onChange={(awg) => setModal({ ...modal, awg })} />}<button className="primary" onClick={saveEntity}>{t.save}</button></div></Modal>}
      {modal?.type === "notify" && <Modal title={`${t.notifications}: ${modal.item.name}`} onClose={() => setModal(null)}><div className="form"><label><input type="checkbox" checked={modal.down} onChange={(e) => setModal({ ...modal, down: e.target.checked })} /> {t.down}</label><label><input type="checkbox" checked={modal.recovered} onChange={(e) => setModal({ ...modal, recovered: e.target.checked })} /> {t.recovered}</label><button className="primary" onClick={saveNotify}>{t.save}</button></div></Modal>}
      {modal?.type === "subscription" && <Modal title={`${t.extendSubscription}: ${modal.item.name}`} onClose={() => setModal(null)}><div className="form"><p className="muted">{t.expiresAt}: {subscriptionText(modal.item, t, lang)}</p><label>{t.choosePeriod}<select value={modal.plan || "1m"} onChange={(e) => setModal({ ...modal, plan: e.target.value })}>{extendPlans.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label><button className="primary" onClick={extendSubscription}>{t.extendSubscription}</button></div></Modal>}
      {modal?.type === "health" && <Modal title={t.addService} onClose={() => setModal(null)}><div className="form"><label>{t.url}<input value={probe.url} onChange={(e) => setProbe({ ...probe, url: e.target.value })} placeholder="https://example.com/status" /></label><button type="button" onClick={probeUrl}>{t.fetch}</button>{probe.data && <textarea readOnly value={probe.data} />}{probe.data && <button type="button" className="primary" onClick={confirmProbe}>{t.confirm}</button>}</div></Modal>}
      {qr && <Modal title={qr.title} onClose={() => setQr(null)}><div className="qr"><img src={qr.dataUrl} alt={qr.title} /></div></Modal>}
    </section>
  </main>;
}
EOF

	cat >> /opt/wg-web/app/app/globals.css << 'EOF'
.modal-backdrop {
  position: fixed;
  inset: 0;
  z-index: 50;
  display: grid;
  place-items: center;
  padding: 18px;
  background: rgba(0,0,0,.62);
}
.modal {
  width: min(620px, 100%);
  max-height: min(760px, 92vh);
  overflow: auto;
  box-shadow: 0 24px 80px rgba(0,0,0,.45);
}
.settings-grid {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(280px, .85fr) minmax(300px, .9fr);
  gap: 14px;
}
.hint {
  color: var(--muted);
  font-size: 12px;
  font-weight: 500;
}
.button-link {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 38px;
  padding: 0 12px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--panel-2);
  color: var(--text);
  text-decoration: none;
}
.default-action {
  border-color: transparent;
  background: var(--accent);
  color: #062115;
  font-weight: 700;
}
.notify-action {
  border-color: rgba(255, 209, 102, .55);
  background: rgba(255, 209, 102, .14);
  color: #ffe5a3;
}
.compact-meta {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-top: 4px;
}
.awg-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
  gap: 8px;
}
.awg-grid label {
  gap: 4px;
}
.rank-row {
  padding: 8px;
  border-radius: 8px;
}
.rank-row.stale,
.disabled-row {
  background: rgba(255, 93, 108, .10);
}
button:disabled {
  opacity: .55;
  cursor: not-allowed;
}
@media (max-width: 1100px) {
  .settings-grid { grid-template-columns: 1fr; }
}
EOF

	cleanup_web_manager_networks
	write_extra_rules_script
	systemctl enable --now docker.service
	docker compose -f /opt/wg-web/docker-compose.yml up -d --build

	echo
	echo "WireGuard web management panel is ready."
	echo "URL: https://$wg_web_host:8443"
	echo "Login: admin"
	echo "Password: $wg_web_password"
	echo "Bot API token: $wg_bot_api_token"
	echo "The HTTPS certificate is self-signed; the browser will show a warning on first open."
}

if [[ ! -e /etc/wireguard/wg0.conf ]]; then
	# Detect some Debian minimal setups where neither wget nor curl are installed
	if ! hash wget 2>/dev/null && ! hash curl 2>/dev/null; then
		echo "Wget is required to use this installer."
		read -n1 -r -p "Press any key to install Wget and continue..."
		apt-get update
		apt-get install -y wget
	fi
	clear
	echo 'Welcome to this WireGuard road warrior installer!'
	cleanup_web_manager_networks
	# If system has a single IPv4, it is selected automatically. Else, ask the user
	if [[ $(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}') -eq 1 ]]; then
		ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}')
	else
		number_of_ip=$(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}')
		echo
		echo "Which IPv4 address should be used?"
		ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | nl -s ') '
		read -p "IPv4 address [1]: " ip_number
		until [[ -z "$ip_number" || "$ip_number" =~ ^[0-9]+$ && "$ip_number" -le "$number_of_ip" ]]; do
			echo "$ip_number: invalid selection."
			read -p "IPv4 address [1]: " ip_number
		done
		[[ -z "$ip_number" ]] && ip_number="1"
		ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | sed -n "$ip_number"p)
	fi
	#В If $ip is a private IP address, the server must be behind NAT
	if echo "$ip" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
		echo
		echo "This server is behind NAT. What is the public IPv4 address or hostname?"
		# Get public IP and sanitize with grep
		get_public_ip=$(grep -m 1 -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< "$(wget -T 10 -t 1 -4qO- "http://ip1.dynupdate.no-ip.com/" || curl -m 10 -4Ls "http://ip1.dynupdate.no-ip.com/")")
		read -p "Public IPv4 address / hostname [$get_public_ip]: " public_ip
		# If the checkip service is unavailable and user didn't provide input, ask again
		until [[ -n "$get_public_ip" || -n "$public_ip" ]]; do
			echo "Invalid input."
			read -p "Public IPv4 address / hostname: " public_ip
		done
		[[ -z "$public_ip" ]] && public_ip="$get_public_ip"
	fi
	# If system has a single IPv6, it is selected automatically
	if [[ $(ip -6 addr | grep -c 'inet6 [23]') -eq 1 ]]; then
		ip6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}')
	fi
	# If system has multiple IPv6, ask the user to select one
	if [[ $(ip -6 addr | grep -c 'inet6 [23]') -gt 1 ]]; then
		number_of_ip6=$(ip -6 addr | grep -c 'inet6 [23]')
		echo
		echo "Which IPv6 address should be used?"
		ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' | nl -s ') '
		read -p "IPv6 address [1]: " ip6_number
		until [[ -z "$ip6_number" || "$ip6_number" =~ ^[0-9]+$ && "$ip6_number" -le "$number_of_ip6" ]]; do
			echo "$ip6_number: invalid selection."
			read -p "IPv6 address [1]: " ip6_number
		done
		[[ -z "$ip6_number" ]] && ip6_number="1"
		ip6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' | sed -n "$ip6_number"p)
	fi
	echo
	echo "What IPv4 subnet should the VPN use?"
	read -p "Subnet [10.7.0]: " vpn_subnet
	until [[ -z "$vpn_subnet" ]] || valid_ipv4_subnet "$vpn_subnet"; do
		echo "$vpn_subnet: invalid subnet. Use the first three IPv4 octets, for example 10.7.0."
		read -p "Subnet [10.7.0]: " vpn_subnet
	done
	[[ -z "$vpn_subnet" ]] && vpn_subnet="10.7.0"
	echo
	echo "What port should AmneziaWG listen on?"
	read -p "Port [51820]: " port
	until [[ -z "$port" || "$port" =~ ^[0-9]+$ && "$port" -le 65535 ]]; do
		echo "$port: invalid port."
		read -p "Port [51820]: " port
	done
	[[ -z "$port" ]] && port="51820"
	echo
	echo "Clients will be created from the web management panel after installation."
	echo
	echo "AmneziaWG installation is ready to begin."
	# Install a firewall if firewalld or iptables are not already available
	if ! systemctl is-active --quiet firewalld.service && ! hash iptables 2>/dev/null; then
		if [[ "$os" == "centos" || "$os" == "fedora" ]]; then
			firewall="firewalld"
			# We don't want to silently enable firewalld, so we give a subtle warning
			# If the user continues, firewalld will be installed and enabled during setup
			echo "firewalld, which is required to manage routing tables, will also be installed."
		elif [[ "$os" == "debian" || "$os" == "ubuntu" ]]; then
			# iptables is way less invasive than firewalld so no warning is given
			firewall="iptables"
		fi
	fi
	read -n1 -r -p "Press any key to continue..."
	install_amneziawg_support
	if [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
		apt-get update
		apt-get install -y qrencode $firewall
	elif [[ "$os" == "centos" ]]; then
		dnf install -y epel-release
		dnf install -y qrencode $firewall
	elif [[ "$os" == "fedora" ]]; then
		dnf install -y qrencode $firewall
	fi
	mkdir -p /etc/wireguard/ /etc/amnezia/amneziawg/
	# If firewalld was just installed, enable it
	if [[ "$firewall" == "firewalld" ]]; then
		systemctl enable --now firewalld.service
	fi
	# Generate wg0.conf
cat << EOF > /etc/wireguard/wg0.conf
# Do not alter the commented lines
# They are used by wireguard-install
# ENDPOINT $([[ -n "$public_ip" ]] && echo "$public_ip" || echo "$ip")
# IPV4_SUBNET $vpn_subnet.0/24

[Interface]
Address = $vpn_subnet.1/24$([[ -n "$ip6" ]] && echo ", fddd:2c4:2c4:2c4::1/64")
PrivateKey = $(awg genkey)
ListenPort = $port

EOF
	chmod 600 /etc/wireguard/wg0.conf
	sync_main_awg_config
		# Enable packet forwarding for AWG ingress/upstream routing.
		echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-awg-forward.conf
	# Enable without waiting for a reboot or service restart
	echo 1 > /proc/sys/net/ipv4/ip_forward
	if [[ -n "$ip6" ]]; then
		# Enable net.ipv6.conf.all.forwarding for the system
			echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-awg-forward.conf
		# Enable without waiting for a reboot or service restart
		echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
	fi
		systemctl disable --now wg-iptables.service 2>/dev/null || true
		rm -f /etc/systemd/system/wg-iptables.service /etc/sysctl.d/99-wireguard-forward.conf
		echo
		install_web_manager
	echo "Finished!"
	echo
	echo "New clients can be added from the web management panel."
else
	clear
	echo "AmneziaWG server is already installed."
	echo
	echo "Select an option:"
	echo "   1) Install or repair web management panel"
	echo "   2) Remove AmneziaWG"
	echo "   3) Exit"
	read -p "Option: " option
	until [[ "$option" =~ ^[1-3]$ ]]; do
		echo "$option: invalid selection."
		read -p "Option: " option
	done
	if [[ "$option" = "1" ]]; then
		install_web_manager
		exit
	elif [[ "$option" = "2" ]]; then
		option="6"
	elif [[ "$option" = "3" ]]; then
		exit
	fi
	case "$option" in
		1)
			echo
			echo "Provide a name for the client:"
			read -p "Name: " unsanitized_client
			# Allow a limited lenght and set of characters to avoid conflicts
			client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client" | cut -c-15)
			while [[ -z "$client" ]] || grep -q "^# BEGIN_PEER $client$" /etc/wireguard/wg0.conf; do
				echo "$client: invalid name."
				read -p "Name: " unsanitized_client
				client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client" | cut -c-15)
			done
			echo
			new_client_dns
			new_client_setup
			sync_extra_in_peers
			new_client_extra_setup
			print_client_qr_codes
			echo "$client added. Configuration available in:" "$script_dir"/"$client.conf"
			if [[ -e "$script_dir"/"$client-2nd-hop-upstream.conf" ]]; then
				echo "$client 2nd hop upstream tun configuration available in:" "$script_dir"/"$client-2nd-hop-upstream.conf"
			fi
			exit
		;;
		2)
			# This option could be documented a bit better and maybe even be simplified
			# ...but what can I say, I want some sleep too
			number_of_clients=$(grep -c '^# BEGIN_PEER' /etc/wireguard/wg0.conf)
			if [[ "$number_of_clients" = 0 ]]; then
				echo
				echo "There are no existing clients!"
				exit
			fi
			echo
			echo "Select the client to remove:"
			grep '^# BEGIN_PEER' /etc/wireguard/wg0.conf | cut -d ' ' -f 3 | nl -s ') '
			read -p "Client: " client_number
			until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$number_of_clients" ]]; do
				echo "$client_number: invalid selection."
				read -p "Client: " client_number
			done
			client=$(grep '^# BEGIN_PEER' /etc/wireguard/wg0.conf | cut -d ' ' -f 3 | sed -n "$client_number"p)
			echo
			read -p "Confirm $client removal? [y/N]: " remove
			until [[ "$remove" =~ ^[yYnN]*$ ]]; do
				echo "$remove: invalid selection."
				read -p "Confirm $client removal? [y/N]: " remove
			done
				if [[ "$remove" =~ ^[yY]$ ]]; then
					# Remove from the registry; live AWG ingress interfaces are managed by the web panel.
					sed -i "/^# BEGIN_PEER $client$/,/^# END_PEER $client$/d" /etc/wireguard/wg0.conf
				sync_main_awg_config
				sync_extra_in_peers
				echo
				echo "$client removed!"
			else
				echo
				echo "$client removal aborted!"
			fi
			exit
		;;
		3)
			add_extra_tun
			exit
		;;
		4)
			remove_extra_tun
			exit
		;;
		5)
			install_web_manager
			exit
		;;
		6)
			echo
			read -p "Confirm AmneziaWG removal? [y/N]: " remove
			until [[ "$remove" =~ ^[yYnN]*$ ]]; do
				echo "$remove: invalid selection."
				read -p "Confirm AmneziaWG removal? [y/N]: " remove
			done
			if [[ "$remove" =~ ^[yY]$ ]]; then
				if [[ -e /opt/wg-web/docker-compose.yml ]]; then
					docker compose -f /opt/wg-web/docker-compose.yml down 2>/dev/null || true
					rm -rf /opt/wg-web
				fi
				cleanup_web_manager_networks
				if [[ -e /etc/wireguard/wg-extra-tun.env ]]; then
					remove_extra_tun
				fi
				port=$(grep '^ListenPort' /etc/wireguard/wg0.conf | cut -d " " -f 3)
				vpn_cidr=$(wg_ipv4_cidr)
				if systemctl is-active --quiet firewalld.service; then
					ip=$(firewall-cmd --direct --get-rules ipv4 nat POSTROUTING | grep -F -- "-s $vpn_cidr ! -d $vpn_cidr" | grep -oE '[^ ]+$')
					# Using both permanent and not permanent rules to avoid a firewalld reload.
					firewall-cmd --remove-port="$port"/udp
					firewall-cmd --zone=trusted --remove-source="$vpn_cidr"
					firewall-cmd --permanent --remove-port="$port"/udp
					firewall-cmd --permanent --zone=trusted --remove-source="$vpn_cidr"
					firewall-cmd --direct --remove-rule ipv4 nat POSTROUTING 0 -s "$vpn_cidr" ! -d "$vpn_cidr" -j SNAT --to "$ip"
					firewall-cmd --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s "$vpn_cidr" ! -d "$vpn_cidr" -j SNAT --to "$ip"
					if grep -qs 'fddd:2c4:2c4:2c4::1/64' /etc/wireguard/wg0.conf; then
						ip6=$(firewall-cmd --direct --get-rules ipv6 nat POSTROUTING | grep '\-s fddd:2c4:2c4:2c4::/64 '"'"'!'"'"' -d fddd:2c4:2c4:2c4::/64' | grep -oE '[^ ]+$')
						firewall-cmd --zone=trusted --remove-source=fddd:2c4:2c4:2c4::/64
						firewall-cmd --permanent --zone=trusted --remove-source=fddd:2c4:2c4:2c4::/64
						firewall-cmd --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:2c4:2c4:2c4::/64 ! -d fddd:2c4:2c4:2c4::/64 -j SNAT --to "$ip6"
						firewall-cmd --permanent --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:2c4:2c4:2c4::/64 ! -d fddd:2c4:2c4:2c4::/64 -j SNAT --to "$ip6"
					fi
				else
					systemctl disable --now wg-iptables.service
					rm -f /etc/systemd/system/wg-iptables.service
				fi
				systemctl disable --now awg-quick@wg0.service 2>/dev/null || true
				rm -f /etc/sysctl.d/99-awg-forward.conf /etc/sysctl.d/99-wireguard-forward.conf
				if [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
					apt-get remove --purge -y amneziawg
				elif [[ "$os" == "centos" || "$os" == "fedora" ]]; then
					dnf remove -y amneziawg-dkms amneziawg-tools
				fi
				rm -rf /etc/wireguard/ /etc/amnezia/
				echo
				echo "AmneziaWG removed!"
			else
				echo
				echo "AmneziaWG removal aborted!"
			fi
			exit
		;;
		7)
			exit
		;;
	esac
fi
