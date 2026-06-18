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
wg_web_creds_dir=/etc/wireguard/wg-web
wg_bot_token_file=$wg_web_creds_dir/bot-api-token

random_hex () {
	local bytes="${1:-32}"
	od -An -N"$bytes" -tx1 /dev/urandom | tr -d ' \n'
	echo
}

random_password () {
	random_hex 18
}

ensure_bot_api_token () {
	mkdir -p "$wg_web_creds_dir"
	chmod 700 "$wg_web_creds_dir"
	if [[ ! -s "$wg_bot_token_file" ]]; then
		if [[ -s /opt/wg-web/.env ]] && grep -q '^BOT_API_TOKEN=' /opt/wg-web/.env; then
			grep '^BOT_API_TOKEN=' /opt/wg-web/.env | tail -1 | cut -d '=' -f 2- > "$wg_bot_token_file"
		else
			random_hex 32 > "$wg_bot_token_file"
		fi
		chmod 600 "$wg_bot_token_file"
	fi
	cat "$wg_bot_token_file"
}

prompt_web_panel_password () {
	if [[ -n "${wg_web_hash:-}" && -n "${wg_web_salt:-}" && -n "${wg_web_password:-}" ]]; then
		return
	fi
	echo
	echo "Set the web panel admin password."
	echo "Leave it empty to generate a strong password automatically."
	read -rsp "Admin password [auto-generate]: " wg_web_password
	echo
	if [[ -z "$wg_web_password" ]]; then
		wg_web_password="$(random_password)"
	fi
	wg_web_salt="$(random_hex 16)"
	wg_web_hash="$(printf '%s%s' "$wg_web_salt" "$wg_web_password" | sha256sum | awk '{print $1}')"
	wg_web_password_changed=1
}

load_existing_web_panel_password () {
	if [[ -s /opt/wg-web/.env ]] && grep -q '^ADMIN_PASSWORD_SALT=' /opt/wg-web/.env && grep -q '^ADMIN_PASSWORD_HASH=' /opt/wg-web/.env; then
		wg_web_salt="$(grep '^ADMIN_PASSWORD_SALT=' /opt/wg-web/.env | tail -1 | cut -d '=' -f 2-)"
		wg_web_hash="$(grep '^ADMIN_PASSWORD_HASH=' /opt/wg-web/.env | tail -1 | cut -d '=' -f 2-)"
		wg_web_password=""
		wg_web_password_changed=0
		return 0
	fi
	return 1
}

prepare_web_panel_password () {
	if [[ -n "${wg_web_hash:-}" && -n "${wg_web_salt:-}" ]]; then
		return
	fi
	if load_existing_web_panel_password; then
		local reset_password
		echo
		read -rp "Do you want to reset and set a new web panel password? [n]: " reset_password
		reset_password="${reset_password:-n}"
		if [[ "$reset_password" =~ ^[Yy]$ ]]; then
			unset wg_web_hash wg_web_salt wg_web_password
			prompt_web_panel_password
		fi
		return
	fi
	prompt_web_panel_password
}

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
	mkdir -p "$(dirname "/usr/local/sbin/awg-route-rules")"
	cat > '/usr/local/sbin/awg-route-rules' <<'DD_WG_CP_USR_LOCAL_SBIN_AWG_ROUTE_RULES_EOF'
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
DD_WG_CP_USR_LOCAL_SBIN_AWG_ROUTE_RULES_EOF
	chmod +x /usr/local/sbin/awg-route-rules
}

add_extra_tun () {
	echo
	echo "Legacy 2nd hop setup is retired. Use the web panel upstreams; it creates one awg-up-* output per upstream."
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
	mkdir -p "$(dirname "/etc/systemd/system/wg-extra-tun.service")"
	cat > '/etc/systemd/system/wg-extra-tun.service' <<'DD_WG_CP_ETC_SYSTEMD_SYSTEM_WG_EXTRA_TUN_SERVICE_EOF'
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
DD_WG_CP_ETC_SYSTEMD_SYSTEM_WG_EXTRA_TUN_SERVICE_EOF
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
	for iface in wg-in awg-in vless-ifb; do
		systemctl disable --now "awg-quick@$iface.service" "wg-quick@$iface.service" "$iface.service" 2>/dev/null || true
		if ip link show "$iface" >/dev/null 2>&1; then
			if hash tc 2>/dev/null; then
				tc qdisc del dev "$iface" root 2>/dev/null || true
				tc qdisc del dev "$iface" ingress 2>/dev/null || true
				tc qdisc del dev "$iface" clsact 2>/dev/null || true
			fi
			ip link set "$iface" down 2>/dev/null || true
			ip link del "$iface" 2>/dev/null || true
		fi
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
	rm -f /etc/wireguard/wg-extra-tun.env /etc/wireguard/wg-extra-in.conf /etc/wireguard/wg-extra-up.conf /etc/wireguard/wg-in.conf /etc/wireguard/awg-in.conf
	rm -f /etc/amnezia/amneziawg/wg-extra-in.conf /etc/amnezia/amneziawg/wg-extra-up.conf /etc/amnezia/amneziawg/wg-in.conf /etc/amnezia/amneziawg/awg-in.conf /etc/amnezia/amneziawg/wg-in-*.conf /etc/amnezia/amneziawg/wg-up-*.conf /etc/amnezia/amneziawg/awg-direct.conf /etc/amnezia/amneziawg/awg-default.conf /etc/amnezia/amneziawg/awg-in-*.conf /etc/amnezia/amneziawg/awg-up-*.conf /etc/amnezia/amneziawg/awgo-direct.conf /etc/amnezia/amneziawg/awgo-default.conf /etc/amnezia/amneziawg/awgo-*.conf /etc/amnezia/amneziawg/ad-*.conf /etc/amnezia/amneziawg/au-*.conf /etc/amnezia/amneziawg/a?-*.conf /etc/amnezia/amneziawg/a??-*.conf
	rm -f /etc/wireguard/awg-default.env /etc/wireguard/awg-in-*.env /etc/wireguard/awgo-default.env /etc/wireguard/awgo-*.env /etc/wireguard/ad-*.env /etc/wireguard/au-*.env /etc/wireguard/a?-*.env /etc/wireguard/a??-*.env
	rm -f /etc/systemd/system/wg-in.service /etc/systemd/system/awg-in.service /etc/systemd/system/awg-default.service /etc/systemd/system/awg-in-*.service /etc/systemd/system/awgo-default.service /etc/systemd/system/awgo-*.service /etc/systemd/system/ad-*.service /etc/systemd/system/au-*.service /etc/systemd/system/a?-*.service /etc/systemd/system/a??-*.service
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

install_xray_core () {
	if hash xray 2>/dev/null; then
		return
	fi
	echo
	echo "Installing required Xray packages."
	if ! hash curl 2>/dev/null || ! hash unzip 2>/dev/null; then
		apt-get update
		apt-get install -y curl unzip ca-certificates
	fi
	bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --without-geodata
	systemctl disable --now xray.service xray@.service 2>/dev/null || true
	if ! hash xray 2>/dev/null; then
		echo "Xray installation failed."
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
	hash unzip 2>/dev/null || missing_web_packages+=("unzip")
	hash tc 2>/dev/null || missing_web_packages+=("iproute2")
	hash python3 2>/dev/null || missing_web_packages+=("python3")
	[[ -d /etc/ssl/certs ]] || missing_web_packages+=("ca-certificates")
	if [[ "${#missing_web_packages[@]}" -gt 0 ]]; then
		apt-get update
		apt-get install -y "${missing_web_packages[@]}"
	fi

	prepare_web_panel_password
	wg_web_host="$(grep '^# ENDPOINT' /etc/wireguard/wg0.conf | cut -d " " -f 3)"
	[[ -z "$wg_web_host" ]] && wg_web_host="$(hostname -I | awk '{print $1}')"
	wg_bot_api_token="$(ensure_bot_api_token)"
	echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-awg-forward.conf
	echo 1 > /proc/sys/net/ipv4/ip_forward
	if grep -qs 'fddd:2c4:2c4:2c4::1/64' /etc/wireguard/wg0.conf; then
		echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-awg-forward.conf
		echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
	fi

	if ! hash docker 2>/dev/null || ! docker compose version >/dev/null 2>&1; then
		apt-get update
		apt-get install -y docker.io docker-compose-v2 openssl python3 ca-certificates
	fi
	install_amneziawg_support
	install_xray_core

	mkdir -p /opt/wg-web/app/app/api/[[...path]]
	mkdir -p /opt/wg-web/app/app/lib
	mkdir -p /opt/wg-web/app/public
	mkdir -p /opt/wg-web/certs /opt/wg-web/acme /opt/wg-web/data /etc/wireguard/clients /etc/wireguard/upstreams /etc/wireguard/wg-web /etc/amnezia/amneziawg
	mkdir -p /opt/dd-awg-bot /etc/dd-awg-bot /etc/dd-awg-vless
	chmod 700 /etc/wireguard/clients /etc/wireguard/upstreams /etc/wireguard/wg-web
	chmod 700 /opt/dd-awg-bot /etc/dd-awg-bot /etc/dd-awg-vless

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

	mkdir -p "$(dirname "/opt/wg-web/docker-compose.yml")"
	cat > '/opt/wg-web/docker-compose.yml' <<'DD_WG_CP_OPT_WG_WEB_DOCKER_COMPOSE_YML_EOF'
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
      - /etc/dd-awg-bot:/etc/dd-awg-bot
      - /etc/dd-awg-vless:/etc/dd-awg-vless
      - /etc/amnezia:/etc/amnezia
      - /etc/systemd/system:/etc/systemd/system
      - /usr/local/sbin:/usr/local/sbin
      - /opt/dd-awg-bot:/opt/dd-awg-bot
      - /lib/modules:/lib/modules:ro
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
DD_WG_CP_OPT_WG_WEB_DOCKER_COMPOSE_YML_EOF
	mkdir -p "$(dirname "/opt/wg-web/Caddyfile")"
	cat > '/opt/wg-web/Caddyfile' <<'DD_WG_CP_OPT_WG_WEB_CADDYFILE_EOF'
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
DD_WG_CP_OPT_WG_WEB_CADDYFILE_EOF
	mkdir -p "$(dirname "/opt/wg-web/app/Dockerfile")"
	cat > '/opt/wg-web/app/Dockerfile' <<'DD_WG_CP_OPT_WG_WEB_APP_DOCKERFILE_EOF'
FROM node:20-bookworm-slim

RUN apt-get update \
	&& apt-get install -y --no-install-recommends bash ca-certificates curl iproute2 iptables kmod sqlite3 util-linux \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json ./
RUN npm install
COPY . .
RUN npm run build

CMD ["sh", "-c", "node worker.js & npm start"]
DD_WG_CP_OPT_WG_WEB_APP_DOCKERFILE_EOF
	mkdir -p "$(dirname "/opt/wg-web/app/package.json")"
	cat > '/opt/wg-web/app/package.json' <<'DD_WG_CP_OPT_WG_WEB_APP_PACKAGE_JSON_EOF'
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
DD_WG_CP_OPT_WG_WEB_APP_PACKAGE_JSON_EOF
	mkdir -p "$(dirname "/opt/wg-web/app/next.config.js")"
	cat > '/opt/wg-web/app/next.config.js' <<'DD_WG_CP_OPT_WG_WEB_APP_NEXT_CONFIG_JS_EOF'
const nextConfig = {
  output: "standalone"
};

module.exports = nextConfig;
DD_WG_CP_OPT_WG_WEB_APP_NEXT_CONFIG_JS_EOF
	mkdir -p "$(dirname "/opt/wg-web/app/public/robots.txt")"
	cat > '/opt/wg-web/app/public/robots.txt' <<'DD_WG_CP_OPT_WG_WEB_APP_PUBLIC_ROBOTS_TXT_EOF'
User-agent: *
Disallow: /
DD_WG_CP_OPT_WG_WEB_APP_PUBLIC_ROBOTS_TXT_EOF
	mkdir -p "$(dirname "/opt/wg-web/app/app/layout.js")"
	cat > '/opt/wg-web/app/app/layout.js' <<'DD_WG_CP_OPT_WG_WEB_APP_APP_LAYOUT_JS_EOF'
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
DD_WG_CP_OPT_WG_WEB_APP_APP_LAYOUT_JS_EOF
	mkdir -p "$(dirname "/opt/wg-web/app/app/globals.css")"
	cat > '/opt/wg-web/app/app/globals.css' <<'DD_WG_CP_OPT_WG_WEB_APP_APP_GLOBALS_CSS_EOF'
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
.settings-studio {
  display: grid;
  gap: 18px;
  width: 100%;
}
.settings-overview {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: 24px;
  align-items: center;
  padding: 22px;
}
.settings-overview h2 {
  margin: 2px 0 6px;
  font-size: 24px;
}
.settings-overview p {
  max-width: 720px;
  margin: 0;
  color: var(--muted);
  line-height: 1.55;
}
.eyebrow {
  color: var(--accent);
  font-size: 11px;
  font-weight: 850;
  letter-spacing: .08em;
  text-transform: uppercase;
}
.settings-kpis {
  display: grid;
  grid-template-columns: repeat(4, minmax(96px, 1fr));
  gap: 8px;
}
.settings-kpis div,
.module-stat {
  display: grid;
  gap: 6px;
  min-width: 118px;
  padding: 12px;
  border: 1px solid var(--line);
  border-radius: 14px;
  background: var(--surface-elevated);
}
.settings-kpis span,
.module-stat span {
  color: var(--muted);
  font-size: 11px;
  font-weight: 750;
}
.settings-kpis b,
.module-stat b {
  color: var(--text);
  font-size: 18px;
}
.settings-composer {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(280px, 340px);
  gap: 18px;
  align-items: start;
}
.settings-main-column,
.settings-side-column {
  display: grid;
  gap: 16px;
}
.settings-side-column {
  position: sticky;
  top: 18px;
}
.settings-module {
  display: grid;
  gap: 18px;
  padding: 18px;
}
.module-head,
.module-title {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 14px;
}
.module-title {
  justify-content: flex-start;
}
.module-title h2,
.admin-panel h3 {
  margin: 0;
  font-size: 18px;
}
.module-title p,
.admin-panel p {
  margin: 4px 0 0;
  color: var(--muted);
  font-size: 12px;
  line-height: 1.45;
}
.module-icon {
  display: grid;
  place-items: center;
  flex: 0 0 auto;
  width: 36px;
  height: 36px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: var(--surface-elevated);
  color: var(--accent);
}
.module-icon .icon {
  width: 18px;
  height: 18px;
}
.module-toolbar {
  display: grid;
  grid-template-columns: minmax(220px, .42fr) auto;
  gap: 12px;
  align-items: end;
}
.settings-table {
  overflow: hidden;
  border: 1px solid var(--line);
  border-radius: 14px;
  background: var(--panel-2);
}
.settings-table-head,
.settings-table-row {
  display: grid;
  grid-template-columns: minmax(220px, 1fr) minmax(120px, .28fr) auto;
  gap: 14px;
  align-items: center;
  padding: 12px 14px;
}
.settings-table-head {
  background: var(--surface-elevated);
  color: var(--muted);
  font-size: 11px;
  font-weight: 850;
  letter-spacing: .05em;
  text-transform: uppercase;
}
.settings-table-row {
  border-top: 1px solid var(--line);
}
.settings-table-row b {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.settings-empty {
  padding: 18px;
  color: var(--muted);
}
.telegram-settings-grid {
  display: grid;
  grid-template-columns: minmax(180px, .65fr) repeat(3, minmax(180px, 1fr));
  gap: 12px;
  align-items: end;
}
.shaper-grid {
  display: grid;
  grid-template-columns: minmax(260px, 1fr) minmax(180px, .45fr) minmax(180px, .45fr);
  gap: 12px;
  align-items: end;
}
.vless-grid {
  display: grid;
  grid-template-columns: minmax(240px, .8fr) repeat(2, minmax(180px, 1fr)) minmax(150px, .36fr);
  gap: 12px;
  align-items: end;
}
.transport-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 12px;
}
.transport-card {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 12px;
  padding: 14px;
  border: 1px solid var(--line);
  border-radius: 14px;
  background: var(--panel-2);
}
.transport-card .toggle-card {
  grid-column: 1 / -1;
}
.field-with-action {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: 8px;
  align-items: end;
}
.field-with-action button {
  white-space: nowrap;
}
.toggle-card {
  min-height: 68px;
  flex-direction: row;
  align-items: center;
  padding: 12px;
  border: 1px solid var(--line);
  border-radius: 14px;
  background: var(--surface-elevated);
}
.toggle-card b {
  display: block;
}
.toggle-card small {
  display: block;
  margin-top: 3px;
  color: var(--muted);
}
.admin-panel {
  display: grid;
  gap: 12px;
  padding-top: 16px;
  border-top: 1px solid var(--line);
}
.admin-chip-list {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
.admin-chip {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  min-height: 34px;
  padding: 0 8px 0 12px;
  border: 1px solid var(--line);
  border-radius: 999px;
  background: var(--surface-elevated);
  color: var(--text);
  font-weight: 750;
}
.admin-chip button {
  min-height: 24px;
  padding: 0 7px;
  border-radius: 999px;
}
.domain-grid {
  display: grid;
  grid-template-columns: minmax(240px, .36fr) minmax(0, 1fr);
  gap: 14px;
  align-items: start;
}
.cert-log-field textarea {
  min-height: 300px;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
  font-size: 12px;
  line-height: 1.5;
}
.side-module {
  gap: 12px;
}
.side-module .module-title {
  margin-bottom: 4px;
}
.danger-module {
  border-color: rgba(224,85,85,.42);
}
.danger-module .module-icon {
  color: var(--danger);
}
.danger-note {
  margin: 0;
  font-size: 12px;
  line-height: 1.45;
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
.client-row {
  align-items: flex-start;
}
.client-info {
  display: grid;
  gap: 4px;
  min-width: 240px;
}
.access-key {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 6px;
  margin-top: 4px;
}
.compact-row {
  grid-template-columns: 1fr auto;
}
.inline-add {
  display: grid;
  grid-template-columns: 1fr auto;
  gap: 8px;
}
.segmented {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
.segmented button {
  border-color: var(--line);
}
.segmented button.active {
  border-color: transparent;
  background: var(--accent);
  color: #062115;
  font-weight: 800;
}
.route-segments button {
  min-width: 112px;
}
.hard-block {
  z-index: 80;
}
.progress-modal {
  width: min(720px, 100%);
}
.loader {
  width: 42px;
  height: 42px;
  margin: 10px 0;
  border: 4px solid rgba(255,255,255,.18);
  border-top-color: var(--accent);
  border-radius: 50%;
  animation: spin .85s linear infinite;
}
.progress-log {
  min-height: 160px;
  max-height: 320px;
  overflow: auto;
  padding: 12px;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: rgba(0,0,0,.22);
  color: var(--text);
  white-space: pre-wrap;
}
@keyframes spin {
  to { transform: rotate(360deg); }
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
  .settings-overview,
  .settings-composer,
  .module-toolbar,
  .telegram-settings-grid,
  .shaper-grid,
  .vless-grid,
  .transport-grid,
  .domain-grid {
    grid-template-columns: 1fr;
  }
  .settings-side-column {
    position: static;
  }
  .module-head {
    flex-direction: column;
  }
  .settings-kpis {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}
@media (max-width: 760px) {
  .settings-kpis,
  .settings-table-head,
  .settings-table-row {
    grid-template-columns: 1fr;
  }
  .settings-table-head {
    display: none;
  }
  .settings-table-row {
    gap: 8px;
  }
}

/* Professional SaaS dashboard redesign */
:root {
  --bg: #F7F8FA;
  --panel: #FFFFFF;
  --panel-2: #FFFFFF;
  --text: #111827;
  --muted: #6B7280;
  --line: #E5E7EB;
  --accent: #22C55E;
  --warning: #F59E0B;
  --danger: #EF4444;
  --shadow-soft: 0 1px 3px rgba(0,0,0,.08);
}
body {
  background: var(--bg);
  color: var(--text);
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
.shell {
  display: grid;
  grid-template-columns: 240px minmax(0, 1fr);
  min-height: 100vh;
  background: var(--bg);
}
.side.app-sidebar {
  position: sticky;
  top: 0;
  height: 100vh;
  display: flex;
  flex-direction: column;
  gap: 24px;
  padding: 22px 16px;
  border-right: 1px solid var(--line);
  background: #fff;
  box-shadow: none;
}
.brand {
  display: flex;
  align-items: center;
  gap: 10px;
  color: var(--text);
  font-size: 16px;
  font-weight: 800;
  letter-spacing: -.02em;
}
.logo-mark {
  display: grid;
  width: 34px;
  height: 34px;
  place-items: center;
  border-radius: 11px;
  background: #111827;
  color: #fff;
  font-size: 12px;
  letter-spacing: .02em;
}
.nav {
  display: grid;
  gap: 6px;
}
.nav button,
.logout-button,
.server-item {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  min-height: 40px;
  border: 0;
  border-radius: 11px;
  background: transparent;
  color: #4B5563;
  font-weight: 650;
  text-align: left;
}
.nav button:hover,
.logout-button:hover,
.server-item:hover {
  background: #F3F4F6;
  color: var(--text);
}
.nav button.active {
  background: #ECFDF5;
  color: #047857;
}
.icon {
  width: 18px;
  height: 18px;
  flex: 0 0 auto;
  fill: none;
  stroke: currentColor;
  stroke-width: 1.8;
  stroke-linecap: round;
  stroke-linejoin: round;
}
.server-block {
  display: grid;
  gap: 8px;
  padding-top: 12px;
  border-top: 1px solid var(--line);
}
.side-label {
  padding: 0 10px;
  color: var(--muted);
  font-size: 12px;
  font-weight: 800;
  letter-spacing: .06em;
  text-transform: uppercase;
}
.server-item {
  min-height: 34px;
  padding: 0 10px;
  font-size: 13px;
}
.mini-badge {
  margin-left: auto;
  padding: 2px 6px;
  border-radius: 999px;
  background: #DCFCE7;
  color: #166534;
  font-size: 10px;
  font-weight: 800;
  text-transform: uppercase;
}
.logout-button {
  margin-top: auto;
  color: #6B7280;
}
.main {
  min-width: 0;
  padding: 0 32px 36px;
}
.app-header {
  position: sticky;
  top: 0;
  z-index: 20;
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 72px;
  margin: 0 -32px 24px;
  padding: 0 32px;
  border-bottom: 1px solid rgba(229,231,235,.82);
  background: rgba(247,248,250,.92);
  backdrop-filter: blur(14px);
}
.app-header h1 {
  margin: 0;
  color: var(--text);
  font-size: 32px;
  line-height: 1.1;
  font-weight: 750;
  letter-spacing: -.035em;
}
.app-header p {
  margin: 5px 0 0;
  color: var(--muted);
  font-size: 14px;
}
.header-actions {
  display: flex;
  align-items: center;
  gap: 10px;
}
button,
select,
input,
textarea {
  border-color: var(--line);
}
button {
  border-radius: 10px;
}
.header-actions button,
.header-actions select,
.table-toolbar button,
.table-toolbar input,
.filter-tabs button {
  min-height: 38px;
}
.header-actions button {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  background: #fff;
  color: var(--text);
  box-shadow: var(--shadow-soft);
}
.top.stats-grid {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 24px;
  margin-bottom: 24px;
}
.metric.stat-card {
  position: relative;
  display: grid;
  gap: 6px;
  min-height: 142px;
  padding: 22px;
  border: 0;
  border-radius: 16px;
  background: var(--panel);
  box-shadow: var(--shadow-soft);
}
.stat-card b {
  color: var(--text);
  font-size: 36px;
  line-height: 1;
  font-weight: 760;
  letter-spacing: -.04em;
}
.stat-card small {
  color: var(--muted);
  font-size: 12px;
}
.stat-card select {
  width: max-content;
  min-width: 94px;
  font-size: 16px;
  font-weight: 750;
}
.stat-icon {
  position: absolute;
  top: 20px;
  right: 20px;
  display: grid;
  width: 38px;
  height: 38px;
  place-items: center;
  border-radius: 13px;
  background: #F0FDF4;
  color: #16A34A;
}
.stat-icon.status-only .status-dot {
  width: 12px;
  height: 12px;
}
.panel {
  border: 0;
  border-radius: 16px;
  background: var(--panel);
  box-shadow: var(--shadow-soft);
}
.clients-layout {
  position: relative;
  display: grid;
  grid-template-columns: minmax(0, 7fr) minmax(300px, 3fr);
  gap: 24px;
  align-items: start;
}
.clients-table-card {
  min-width: 0;
  overflow: visible;
  padding: 0;
}
.table-toolbar {
  position: sticky;
  top: 72px;
  z-index: 15;
  display: grid;
  grid-template-columns: minmax(220px, 1fr) auto auto;
  gap: 14px;
  align-items: center;
  padding: 18px;
  border-bottom: 1px solid var(--line);
  border-radius: 16px 16px 0 0;
  background: rgba(255,255,255,.95);
  backdrop-filter: blur(12px);
}
.search-wrap input {
  width: 100%;
  border-radius: 12px;
  background: #F9FAFB;
}
.filter-tabs {
  display: inline-flex;
  padding: 3px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: #F9FAFB;
}
.filter-tabs button {
  border: 0;
  background: transparent;
  color: var(--muted);
  font-size: 13px;
  font-weight: 750;
}
.filter-tabs button.active {
  background: #fff;
  color: var(--text);
  box-shadow: var(--shadow-soft);
}
.new-client-button,
.create-cta {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  border: 0;
  background: var(--accent);
  color: #052E16;
  font-weight: 850;
}
.client-table {
  overflow-x: auto;
}
.client-table-head,
.client-table-row {
  display: grid;
  grid-template-columns: 42px minmax(230px, 1.6fr) minmax(135px, .8fr) minmax(130px, .72fr) minmax(190px, 1fr) minmax(220px, auto);
  gap: 16px;
  align-items: center;
  min-width: 980px;
  padding: 0 18px;
}
.client-table-head {
  position: sticky;
  top: 145px;
  z-index: 10;
  min-height: 44px;
  border-bottom: 1px solid var(--line);
  background: #fff;
  color: var(--muted);
  font-size: 12px;
  font-weight: 800;
  letter-spacing: .04em;
  text-transform: uppercase;
}
.client-table-row {
  min-height: 76px;
  border-bottom: 1px solid #F1F5F9;
  transition: background .16s ease, box-shadow .16s ease;
}
.client-table-row:hover {
  background: #F9FAFB;
}
.client-cell {
  min-width: 0;
  color: #374151;
  font-size: 14px;
}
.main-client {
  display: grid;
  gap: 6px;
}
.main-client b {
  color: var(--text);
  font-size: 14px;
}
.key-line {
  display: flex;
  align-items: center;
  gap: 6px;
  color: var(--muted);
  font-size: 12px;
}
.key-line code {
  max-width: 150px;
  overflow: hidden;
  color: #374151;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
.date-cell {
  display: grid;
  gap: 3px;
}
.date-cell small {
  color: var(--muted);
  font-size: 12px;
}
.status-badge {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  width: max-content;
  padding: 6px 9px;
  border-radius: 999px;
  font-size: 12px;
  font-weight: 800;
}
.status-badge.active {
  background: #DCFCE7;
  color: #166534;
}
.status-badge.disabled {
  background: #F3F4F6;
  color: #4B5563;
}
.status-badge.expired {
  background: #FEE2E2;
  color: #991B1B;
}
.client-actions {
  display: flex;
  justify-content: flex-end;
  gap: 6px;
}
.icon-button,
.ghost-icon {
  display: inline-grid;
  width: 34px;
  height: 34px;
  place-items: center;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: #fff;
  color: #4B5563;
  padding: 0;
}
.ghost-icon {
  width: 24px;
  height: 24px;
  border: 0;
  background: transparent;
}
.icon-button:hover,
.ghost-icon:hover {
  color: #047857;
  border-color: #BBF7D0;
  background: #F0FDF4;
}
.row-menu-wrap {
  position: relative;
}
.row-menu {
  position: absolute;
  right: 0;
  top: 40px;
  z-index: 30;
  display: grid;
  min-width: 190px;
  padding: 6px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: #fff;
  box-shadow: 0 18px 40px rgba(15,23,42,.14);
}
.row-menu button {
  justify-content: flex-start;
  border: 0;
  background: transparent;
  color: var(--text);
  text-align: left;
}
.row-menu button:hover {
  background: #F3F4F6;
}
.row-menu .danger-link {
  color: var(--danger);
}
.empty-table {
  padding: 42px 18px;
  color: var(--muted);
  text-align: center;
}
.create-client-card {
  position: sticky;
  top: 96px;
  display: grid;
  gap: 14px;
  padding: 22px;
}
.create-client-card .panel-title {
  margin-bottom: 4px;
}
.create-client-card h2 {
  margin: 0;
  font-size: 20px;
}
.create-client-card textarea {
  min-height: 92px;
}
.bulk-toolbar {
  position: fixed;
  left: calc(240px + 50%);
  bottom: 24px;
  z-index: 40;
  display: flex;
  align-items: center;
  gap: 10px;
  transform: translateX(-50%);
  padding: 12px;
  border: 1px solid var(--line);
  border-radius: 16px;
  background: rgba(17,24,39,.96);
  color: #fff;
  box-shadow: 0 18px 50px rgba(15,23,42,.28);
}
.bulk-toolbar button {
  border: 1px solid rgba(255,255,255,.16);
  background: rgba(255,255,255,.08);
  color: #fff;
}
.bulk-toolbar button.danger {
  border-color: rgba(239,68,68,.35);
  background: rgba(239,68,68,.18);
}
.danger-row {
  background: #FFFBFB;
}
.disabled-row {
  background: transparent;
}
.expired-row {
  background: #FFFBFB;
}
.good {
  background: var(--accent);
}
.danger-dot {
  background: var(--danger);
}
.idle {
  background: #D1D5DB;
}
.status-dot {
  display: inline-block;
  width: 8px;
  height: 8px;
  flex: 0 0 auto;
  border-radius: 999px;
}
.modal-backdrop {
  background: rgba(17,24,39,.45);
  backdrop-filter: blur(6px);
}
.modal {
  border-radius: 18px;
  background: #fff;
  color: var(--text);
}
.progress-log {
  background: #F9FAFB;
  color: var(--text);
}
.loader {
  border-color: #E5E7EB;
  border-top-color: var(--accent);
}
@media (max-width: 1280px) {
  .clients-layout { grid-template-columns: 1fr; }
  .create-client-card { position: static; }
}
@media (max-width: 900px) {
  .shell { grid-template-columns: 1fr; }
  .side.app-sidebar { position: static; height: auto; }
  .main { padding: 0 18px 28px; }
  .app-header { margin: 0 -18px 18px; padding: 14px 18px; align-items: flex-start; flex-direction: column; }
  .top.stats-grid { grid-template-columns: 1fr; gap: 14px; }
  .table-toolbar { position: static; grid-template-columns: 1fr; }
  .client-table-head { top: 0; }
  .bulk-toolbar { left: 18px; right: 18px; transform: none; flex-wrap: wrap; }
}

/* Premium JetBrains-inspired dark infrastructure UI */
:root {
  --bg: #1E1F22;
  --panel: #2B2D30;
  --panel-2: #25262B;
  --surface-elevated: #313338;
  --text: #DFE1E5;
  --muted: #9DA0A8;
  --muted-2: #6F737A;
  --line: #3C3F41;
  --accent: #4CC38A;
  --accent-blue: #4A88FF;
  --warning: #E2B714;
  --danger: #E05555;
  --shadow-soft: none;
}
body {
  background: var(--bg);
  color: var(--text);
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
.shell {
  background: var(--bg);
}
.side.app-sidebar {
  border-right: 1px solid var(--line);
  background: #25262B;
}
.brand {
  color: var(--text);
}
.logo-mark {
  background: var(--surface-elevated);
  color: var(--accent);
  border: 1px solid var(--line);
}
.nav button,
.logout-button,
.server-item {
  color: var(--muted);
  background: transparent;
}
.nav button:hover,
.logout-button:hover,
.server-item:hover {
  background: #2B2D30;
  color: var(--text);
}
.nav button.active {
  background: rgba(76,195,138,.12);
  color: var(--accent);
  box-shadow: inset 3px 0 0 var(--accent);
}
.server-block {
  border-top-color: var(--line);
}
.side-label {
  color: var(--muted-2);
}
.mini-badge,
.pill.ok {
  background: rgba(76,195,138,.14);
  color: var(--accent);
  border: 1px solid rgba(76,195,138,.24);
}
.main {
  background: var(--bg);
}
.app-header {
  border-bottom: 1px solid var(--line);
  background: var(--bg);
  backdrop-filter: none;
}
.app-header h1 {
  color: var(--text);
}
.app-header p,
.muted,
.hint {
  color: var(--muted);
}
button,
select,
input,
textarea {
  border-color: var(--line);
  background: var(--surface-elevated);
  color: var(--text);
}
input::placeholder,
textarea::placeholder {
  color: var(--muted-2);
}
button:hover,
select:hover,
input:hover,
textarea:hover {
  border-color: #4B4F52;
}
button:focus-visible,
select:focus-visible,
input:focus-visible,
textarea:focus-visible {
  outline: 2px solid rgba(74,136,255,.42);
  outline-offset: 2px;
}
.primary,
.new-client-button,
.create-cta,
.default-action,
.segmented button.active {
  border: 1px solid rgba(76,195,138,.35);
  background: var(--accent);
  color: #102116;
  font-weight: 750;
}
.primary:hover,
.new-client-button:hover,
.create-cta:hover,
.default-action:hover {
  background: #5DD49A;
  color: #102116;
}
button.danger,
.danger {
  border: 1px solid rgba(224,85,85,.55);
  background: transparent;
  color: var(--danger);
}
button.danger:hover,
.danger:hover {
  background: rgba(224,85,85,.10);
}
.header-actions button,
.header-actions select,
.button-link {
  background: var(--surface-elevated);
  color: var(--text);
  border: 1px solid var(--line);
  box-shadow: none;
}
.panel,
.metric.stat-card {
  border: 1px solid var(--line);
  background: var(--panel);
  box-shadow: none;
}
.panel h2,
.panel-title h2 {
  color: var(--text);
}
.top.stats-grid {
  gap: 16px;
}
.stat-card b {
  color: var(--text);
}
.stat-card small {
  color: var(--muted-2);
}
.stat-icon {
  background: var(--surface-elevated);
  color: var(--accent);
  border: 1px solid var(--line);
}
.clients-layout {
  grid-template-columns: minmax(0, 1fr);
  gap: 16px;
}
.servers-layout {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  gap: 16px;
}
.table-toolbar {
  grid-template-columns: minmax(260px, 1fr) auto auto;
  border-bottom: 1px solid var(--line);
  background: var(--panel);
  backdrop-filter: none;
}
.search-wrap input {
  background: var(--surface-elevated);
  color: var(--text);
}
.filter-tabs {
  border-color: var(--line);
  background: var(--surface-elevated);
}
.filter-tabs button {
  color: var(--muted);
}
.filter-tabs button.active {
  background: #3A3D40;
  color: var(--text);
  box-shadow: none;
}
.client-table {
  background: var(--panel);
}
.client-table-head,
.client-table-row {
  grid-template-columns: 36px minmax(240px, 1.45fr) minmax(126px, .62fr) minmax(118px, .54fr) minmax(178px, .76fr) minmax(204px, auto);
  gap: 12px;
  min-width: 1040px;
}
.client-table-head {
  top: 145px;
  border-bottom: 1px solid var(--line);
  background: var(--panel);
  color: var(--muted-2);
}
.client-table-row {
  min-height: 82px;
  border-bottom: 1px solid rgba(60,63,65,.68);
  background: var(--panel);
}
.client-table-row:hover {
  background: #303236;
}
.client-cell {
  color: var(--text);
}
.main-client {
  gap: 4px;
}
.main-client b {
  color: var(--text);
  line-height: 1.25;
}
.client-comment {
  max-width: 420px;
  overflow: hidden;
  color: #B5B8C0;
  font-size: 12px;
  line-height: 1.35;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.key-line {
  color: var(--muted-2);
}
.key-line code {
  color: var(--muted);
}
.date-cell small {
  color: var(--muted-2);
}
.status-badge.active {
  background: rgba(76,195,138,.13);
  color: var(--accent);
  border: 1px solid rgba(76,195,138,.23);
}
.status-badge.disabled {
  background: rgba(157,160,168,.12);
  color: var(--muted);
  border: 1px solid rgba(157,160,168,.18);
}
.status-badge.expired {
  background: rgba(224,85,85,.12);
  color: #F07979;
  border: 1px solid rgba(224,85,85,.22);
}
.icon-button,
.ghost-icon {
  border: 1px solid var(--line);
  background: var(--surface-elevated);
  color: var(--muted);
}
.ghost-icon {
  border-color: transparent;
  background: transparent;
}
.icon-button:hover,
.ghost-icon:hover {
  border-color: rgba(76,195,138,.34);
  background: rgba(76,195,138,.10);
  color: var(--accent);
}
.row-menu {
  border: 1px solid var(--line);
  background: var(--surface-elevated);
  box-shadow: none;
}
.row-menu button {
  color: var(--text);
}
.row-menu button:hover {
  background: #3A3D40;
}
.row-menu .danger-link {
  color: #F07979;
}
.empty-table {
  color: var(--muted);
}
.row {
  border-color: var(--line);
}
.row:hover {
  background: #303236;
}
.compact-meta {
  color: var(--muted);
}
.notify-action {
  border-color: rgba(226,183,20,.38);
  background: rgba(226,183,20,.10);
  color: #F0CB35;
}
.modal-backdrop {
  background: rgba(12,13,15,.74);
  backdrop-filter: none;
}
.modal {
  border: 1px solid var(--line);
  background: var(--panel);
  color: var(--text);
  box-shadow: none;
}
.modal .panel-title {
  border-bottom: 1px solid var(--line);
  padding-bottom: 12px;
}
.modal-form {
  padding-top: 4px;
}
.progress-log {
  border-color: var(--line);
  background: #202124;
  color: var(--text);
}
.loader {
  border-color: #3C3F41;
  border-top-color: var(--accent);
}
.bulk-toolbar {
  border: 1px solid var(--line);
  background: #25262B;
  color: var(--text);
  box-shadow: none;
}
.bulk-toolbar button {
  border: 1px solid var(--line);
  background: var(--surface-elevated);
  color: var(--text);
}
.bulk-toolbar button.danger {
  border-color: rgba(224,85,85,.55);
  background: transparent;
  color: var(--danger);
}
.chart {
  background: var(--panel-2);
  border-color: var(--line);
}
.table-head,
.table-row {
  border-color: var(--line);
}
.table-row:hover {
  background: #303236;
}
.tooltip:hover::after {
  display: none;
}
.clients-table-card,
.client-table {
  overflow: visible;
}
.client-table-head {
  position: static;
  top: auto;
}
.client-table-row {
  position: relative;
}
.row-menu-wrap {
  position: relative;
  z-index: 60;
}
.row-menu {
  z-index: 120;
}
.hard-reset-box {
  display: grid;
  gap: 10px;
  margin-top: 4px;
  padding-top: 14px;
  border-top: 1px solid var(--line);
}
.hard-reset-box p {
  margin: 0;
  font-size: 12px;
  line-height: 1.45;
}
.config-modal {
  display: grid;
  gap: 18px;
}
.config-modal-head {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 12px;
  align-items: center;
  padding: 2px 0 4px;
}
.config-modal-head b {
  display: block;
  color: var(--text);
  font-size: 18px;
  line-height: 1.2;
}
.config-modal-head p {
  margin: 4px 0 0;
  font-size: 12px;
}
.config-action-icon,
.choice-icon {
  display: grid;
  place-items: center;
  border: 1px solid var(--line);
  background: var(--surface-elevated);
  color: var(--accent);
}
.config-action-icon {
  width: 44px;
  height: 44px;
  border-radius: 14px;
}
.config-section {
  display: grid;
  gap: 10px;
}
.config-section h3 {
  margin: 0;
  color: var(--muted);
  font-size: 12px;
  font-weight: 800;
  letter-spacing: .06em;
  text-transform: uppercase;
}
.upstream-section {
  padding-top: 14px;
  border-top: 1px solid var(--line);
}
.config-choice-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 10px;
}
.upstream-grid {
  grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
}
.config-choice {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 10px;
  align-items: center;
  min-height: 72px;
  padding: 12px;
  border: 1px solid var(--line);
  border-radius: 14px;
  background: var(--surface-elevated);
  color: var(--text);
  text-align: left;
}
.config-choice:hover {
  border-color: rgba(76,195,138,.36);
  background: #36393C;
}
.config-choice.active {
  border-color: rgba(76,195,138,.65);
  background: rgba(76,195,138,.12);
}
.choice-icon {
  width: 36px;
  height: 36px;
  border-radius: 12px;
}
.config-choice b {
  display: block;
  font-size: 14px;
}
.config-choice small {
  display: block;
  margin-top: 3px;
  color: var(--muted-2);
  font-size: 11px;
  font-weight: 650;
}
.config-primary-action {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 10px;
  min-height: 50px;
  margin-top: 4px;
  border-radius: 14px;
  font-size: 15px;
}
.config-primary-action .icon {
  width: 20px;
  height: 20px;
}
.analytics-grid {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  gap: 16px;
}
.analytics-chart-card,
.analytics-table-card {
  min-width: 0;
  padding: 18px;
}
.analytics-chart-card .panel-title,
.analytics-table-card .panel-title {
  align-items: flex-start;
  gap: 16px;
}
.chart-tabs,
.range-tabs {
  display: inline-flex;
  flex-wrap: wrap;
  gap: 6px;
  padding: 4px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: var(--surface-elevated);
}
.chart-tabs button,
.range-tabs button {
  min-height: 34px;
  border: 0;
  background: transparent;
  color: var(--muted);
  font-size: 12px;
  font-weight: 800;
}
.chart-tabs button:hover,
.range-tabs button:hover {
  background: #3A3D40;
  color: var(--text);
}
.chart-tabs button.active,
.range-tabs button.active {
  background: rgba(76,195,138,.14);
  color: var(--accent);
}
.range-tabs {
  width: max-content;
  margin-top: 12px;
}
.chart-wrap {
  position: relative;
  height: 288px;
  overflow: hidden;
  padding-bottom: 4px;
  user-select: none;
}
.chart-scroll {
  height: 100%;
  overflow-x: auto;
  overflow-y: hidden;
  cursor: grab;
  overscroll-behavior: contain;
}
.chart-wrap.dragging .chart-scroll {
  cursor: grabbing;
}
.axis-chart.chart {
  display: block;
  width: auto;
  height: 260px;
  min-height: 0;
  border: 1px solid var(--line);
  border-radius: 14px;
  background: var(--panel-2);
  font-family: Inter, sans-serif;
}
.chart-grid {
  stroke: rgba(157,160,168,.16);
  stroke-width: 1;
}
.chart-axis {
  fill: var(--muted-2);
  font-size: 11px;
  font-weight: 650;
}
.chart-area {
  fill: rgba(76,195,138,.10);
}
.chart-line {
  fill: none;
  stroke: var(--accent);
  stroke-width: 2.4;
  stroke-linecap: round;
  stroke-linejoin: round;
}
.chart-cursor {
  stroke: rgba(74,136,255,.48);
  stroke-width: 1;
  stroke-dasharray: 4 4;
}
.chart-dot {
  fill: var(--accent);
  stroke: var(--panel-2);
  stroke-width: 2;
}
.chart-tooltip {
  position: absolute;
  right: 16px;
  top: 16px;
  z-index: 3;
  display: grid;
  gap: 2px;
  min-width: 132px;
  padding: 10px 12px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: var(--surface-elevated);
  color: var(--text);
}
.chart-tooltip b {
  display: inline-flex;
  align-items: center;
  gap: 7px;
}
.chart-swatch {
  display: inline-block;
  width: 8px;
  height: 8px;
  border-radius: 999px;
}
.chart-tooltip span {
  color: var(--muted);
  font-size: 11px;
}
.analytics-table .table-head,
.analytics-table .table-row {
  grid-template-columns: minmax(220px, 1.2fr) minmax(160px, .7fr) minmax(160px, .7fr);
}
.analytics-table .table-row > span:first-child {
  display: grid;
  gap: 3px;
}
.analytics-table small {
  color: var(--muted);
  font-size: 12px;
}
.tabs {
  display: inline-flex;
  flex-wrap: wrap;
  gap: 6px;
  padding: 5px;
  border: 1px solid var(--line);
  border-radius: 16px;
  background: var(--surface-elevated);
  width: max-content;
  max-width: 100%;
}
.tabs button {
  border-radius: 12px;
  min-height: 34px;
  background: transparent;
}
.tabs button.active {
  border-color: rgba(76,195,138,.45);
  background: rgba(76,195,138,.14);
  color: var(--text);
}
.vpn-bot-grid {
  display: grid;
  grid-template-columns: minmax(180px, .8fr) minmax(240px, 1fr) minmax(240px, 1fr) minmax(140px, .55fr);
  gap: 12px;
  align-items: stretch;
}
@media (max-width: 1180px) {
  .table-toolbar { grid-template-columns: 1fr; }
  .client-table { overflow-x: auto; overflow-y: visible; }
  .client-table-head,
  .client-table-row { min-width: 1040px; }
  .vpn-bot-grid { grid-template-columns: 1fr 1fr; }
}
@media (max-width: 640px) {
  .config-choice-grid,
  .upstream-grid,
  .vpn-bot-grid { grid-template-columns: 1fr; }
  .tabs { width: 100%; }
  .tabs button { flex: 1 1 auto; }
}
DD_WG_CP_OPT_WG_WEB_APP_APP_GLOBALS_CSS_EOF
	mkdir -p "$(dirname "/opt/wg-web/app/app/lib/core.mjs")"
	cat > '/opt/wg-web/app/app/lib/core.mjs' <<'DD_WG_CP_OPT_WG_WEB_APP_APP_LIB_CORE_MJS_EOF'
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
const STATS_DB_FILE = path.join(WEB_DIR, "analytics.sqlite");
const LEGACY_STATS_FILE = path.join(WEB_DIR, "stats.jsonl");
const CLIENT_META_FILE = path.join(WEB_DIR, "clients-meta.json");
const UPSTREAMS_FILE = path.join(WEB_DIR, "upstreams.json");
const DEFAULT_UPSTREAM_FILE = path.join(WEB_DIR, "default-upstream");
const AWG_STATE_FILE = path.join(WEB_DIR, "awg-state.json");
const HEALTH_FILE = path.join(WEB_DIR, "health.json");
const TELEGRAM_FILE = path.join(WEB_DIR, "telegram.json");
const VPN_BOT_FILE = path.join(WEB_DIR, "vpn-bot.json");
const VLESS_FILE = path.join(WEB_DIR, "vless.json");
const TRAFFIC_SHAPER_FILE = path.join(WEB_DIR, "traffic-shaper.json");
const NOTIFY_STATE_FILE = path.join(WEB_DIR, "notify-state.json");
const CERTBOT_LOG_FILE = path.join(WEB_DIR, "certbot.log");
const BOT_DIR = "/opt/dd-awg-bot";
const BOT_CONFIG_DIR = "/etc/dd-awg-bot";
const BOT_CONFIG_FILE = path.join(BOT_CONFIG_DIR, "config.json");
const BOT_SERVICE = "dd-awg-bot.service";
const VLESS_DIR = "/etc/dd-awg-vless";
const VLESS_CONFIG_FILE = path.join(VLESS_DIR, "config.json");
const VLESS_SERVICE = "dd-awg-vless.service";
const VLESS_API_ENDPOINT = "127.0.0.1:10085";
const ROUTING_SCRIPT_FILE = path.join(WEB_DIR, "apply-routing.sh");
const ROUTING_SERVICE = "dd-awg-routing.service";
const WG_INGRESS_IFACE = "wg-in";
const AWG_INGRESS_IFACE = "awg-in";
const VLESS_IFB_IFACE = "vless-ifb";
const TGAPI_STATE_FILE = path.join(WEB_DIR, "tgapi-via-tunnel.env");
const TGAPI_SERVICE_FILE = "/etc/systemd/system/tgapi-via-tunnel.service";
const TGAPI_TIMER = "tgapi-via-tunnel.timer";
const TGAPI_APPLY_BIN = "/usr/local/sbin/tgapi-via-tunnel-apply";
const STATS_HALF_HOUR_MS = 30 * 60 * 1000;
const STATS_HOUR_MS = 60 * 60 * 1000;
const STATS_DAY_MS = 24 * 60 * 60 * 1000;
const STATS_RAW_RETENTION_MS = STATS_DAY_MS;
const STATS_HALF_HOUR_RETENTION_MS = 3 * STATS_DAY_MS;
const STATS_HOUR_RETENTION_MS = 7 * STATS_DAY_MS;
const STATS_CACHE_MS = 15000;
const statsCache = new Map();
const DEFAULT_HEALTH = { intervalSeconds: 60, checks: [{ url: "https://www.cloudflare.com/cdn-cgi/trace", expected: "h=" }] };
const DEFAULT_TRAFFIC_SHAPER = { enabled: true, mbps: 20 };
const DEFAULT_VPN_BOT = { enabled: false, token: "", upstreamId: "" };
const DEFAULT_VLESS = {
  enabled: false,
  publicHost: "",
  sniDomain: "",
  dest: "",
  privateKey: "",
  publicKey: "",
  shortId: "",
  fingerprint: "chrome",
  spiderX: "/",
  transports: {
    realityTcp: { enabled: true, port: 443 },
    xhttpReality: { enabled: false, port: 8433, path: "/dd-awg-xhttp", mode: "auto" }
  }
};
const LEGACY_VLESS_PORTS = {
  realityTcp: { direct: 443, default: 2443, upstreamStart: 3443 },
  xhttpReality: { direct: 8444, default: 9444, upstreamStart: 10444 }
};
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
  await fs.mkdir(VLESS_DIR, { recursive: true });
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

async function ingressAddressPlan() {
  const state = await awgState();
  return state.ingressAddressPlan === "derived-v1" ? "derived-v1" : "legacy-v1";
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

function clientId() {
  return crypto.randomBytes(8).toString("hex");
}

async function ensureClientMetaIds(meta, peers = []) {
  let changed = false;
  for (const peer of peers) {
    if (!meta[peer.name]) { meta[peer.name] = {}; changed = true; }
    if (!meta[peer.name].id) { meta[peer.name].id = clientId(); changed = true; }
    if (meta[peer.name].publicKey !== peer.publicKey) { meta[peer.name].publicKey = peer.publicKey; changed = true; }
  }
  if (changed) await writeClientMeta(meta);
  return meta;
}

function uniqueAccessKey(meta) {
  let key = accessKey();
  const used = new Set(Object.values(meta || {}).map((item) => item?.accessKey).filter(Boolean));
  while (used.has(key)) key = accessKey();
  return key;
}

function normalizeCustomUntil(value) {
  const raw = String(value || "").trim();
  if (!raw) throw new Error("Custom subscription date is required");
  const date = new Date(/^\d{4}-\d{2}-\d{2}$/.test(raw) ? `${raw}T23:59:59.000Z` : raw);
  if (Number.isNaN(date.getTime())) throw new Error("Invalid custom subscription date");
  return date.toISOString();
}

function addSubscription(current, plan, customUntil = "") {
  if (plan === "unlimited") return null;
  if (plan === "custom") return normalizeCustomUntil(customUntil);
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

function normalizeSpeedMbit(value, fallback = 20) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.max(1, Math.min(10000, Math.round(n * 10) / 10));
}

function normalizePersonalSpeedLimit(value = {}) {
  return {
    enabled: Boolean(value.enabled),
    mbps: normalizeSpeedMbit(value.mbps, DEFAULT_TRAFFIC_SHAPER.mbps)
  };
}

function effectiveSpeedLimit(globalSettings, meta, name) {
  const global = { ...DEFAULT_TRAFFIC_SHAPER, ...(globalSettings || {}) };
  const personal = normalizePersonalSpeedLimit(meta[name]?.speedLimit || {});
  if (global.enabled === false) return { enabled: false, mbps: normalizeSpeedMbit(global.mbps, DEFAULT_TRAFFIC_SHAPER.mbps), personal: personal.enabled };
  if (personal.enabled) return { enabled: true, mbps: personal.mbps, personal: true };
  return { enabled: global.enabled !== false, mbps: normalizeSpeedMbit(global.mbps, DEFAULT_TRAFFIC_SHAPER.mbps), personal: false };
}

function clientIsDisabled(peer, meta, name) {
  const sub = clientSubscription(meta, name);
  return Boolean(peer.disabled || meta[name]?.disabled || sub.expired);
}

function activeClientPeersFrom(conf, meta) {
  return peerBlocks(conf).filter((peer) => !clientIsDisabled(peer, meta, peer.name));
}

function activeClientPublicKeys(conf, meta) {
  return new Set(activeClientPeersFrom(conf, meta).map((peer) => peer.publicKey).filter(Boolean));
}

function normalizeClientRoute(input = {}) {
  const value = typeof input === "string" ? { mode: input } : input || {};
  const protocol = value.protocol === "vless" ? "vless" : value.protocol === "awg" ? "awg" : "wg";
  const mode = value.mode === "direct" ? "direct" : value.mode === "upstream" ? "upstream" : "default";
  const upstreamId = mode === "upstream" ? String(value.upstreamId || "") : "";
  if (mode === "upstream" && !upstreamId) throw new Error("Upstream route requires upstreamId");
  return { protocol, mode, upstreamId };
}

function clientRoute(meta, name) {
  return normalizeClientRoute(meta[name]?.route || { protocol: "wg", mode: "default" });
}

async function saveClientRoute(name, route) {
  const client = lookupName(name);
  const meta = await clientMeta();
  if (!meta[client]) throw new Error("Client not found");
  const current = clientRoute(meta, client);
  const next = normalizeClientRoute({ ...current, ...route });
  if (current.protocol === next.protocol && current.mode === next.mode && current.upstreamId === next.upstreamId) return next;
  if (next.mode === "upstream") {
    const upstreams = await routingUpstreams();
    if (!upstreams.some((item) => item.id === next.upstreamId && item.routeReady)) {
      throw new Error("Selected upstream OUT interface is not active");
    }
  }
  meta[client] = { ...meta[client], route: next };
  await writeClientMeta(meta);
  try {
    await applyUnifiedRouting();
  } catch (error) {
    meta[client] = { ...meta[client], route: current };
    await writeClientMeta(meta);
    await applyUnifiedRouting().catch(() => null);
    throw error;
  }
  await applyTrafficShaping().catch((error) => logEvent("traffic-shaper", "error", String(error.message || error)));
  return next;
}

export async function setClientDefaultOut(name, value = {}) {
  return { ok: true, route: await saveClientRoute(name, value) };
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

function quickServiceName(iface, protocol = "awg") {
  return `${protocolTools(protocol).quick}@${iface}.service`;
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

function shellQuote(value) {
  return `'${String(value ?? "").replace(/'/g, "'\\''")}'`;
}

async function serviceActive(service) {
  try {
    await host("systemctl", ["is-active", "--quiet", service], { timeout: 5000 });
    return true;
  } catch {
    return false;
  }
}

async function local(command, args = [], options = {}) {
  const { stdout, stderr } = await execFileAsync(command, args, { timeout: options.timeout || 20000, maxBuffer: 1024 * 1024 * 16 });
  return { stdout, stderr };
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function sqlText(value) {
  return `'${String(value ?? "").replace(/'/g, "''")}'`;
}

function sqlInt(value) {
  const n = Number(value || 0);
  return Number.isFinite(n) ? Math.round(n) : 0;
}

function sqlReal(value) {
  const n = Number(value || 0);
  return Number.isFinite(n) ? n : 0;
}

function sqliteBusy(error) {
  const text = `${error?.message || ""}\n${error?.stderr || ""}`.toLowerCase();
  return text.includes("database is locked") || text.includes("database is busy") || text.includes("sqlite_busy");
}

async function sqliteRun(args, timeout = 20000) {
  await ensureDirs();
  let lastError;
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      return await local("sqlite3", [
        "-cmd", ".timeout 15000",
        "-cmd", "PRAGMA temp_store=MEMORY; PRAGMA cache_size=-16384;",
        ...args
      ], { timeout: Math.max(timeout, 20000) });
    } catch (error) {
      lastError = error;
      if (!sqliteBusy(error) || attempt === 4) throw error;
      await delay(100 * 2 ** attempt);
    }
  }
  throw lastError;
}

async function sqliteExec(sql, timeout = 20000) {
  await sqliteRun([STATS_DB_FILE, sql], timeout);
}

async function sqliteRows(sql, timeout = 20000) {
  const { stdout } = await sqliteRun(["-batch", "-noheader", "-separator", "\t", STATS_DB_FILE, sql], timeout);
  return stdout.trim().split("\n").filter(Boolean).map((line) => line.split("\t"));
}

let statsDbReady = null;

async function initializeStatsDb() {
  await sqliteExec(`
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS traffic_samples (
  ts INTEGER NOT NULL,
  client_id TEXT NOT NULL,
  public_key TEXT NOT NULL,
  mode TEXT NOT NULL,
  rx INTEGER NOT NULL,
  tx INTEGER NOT NULL,
  PRIMARY KEY (ts, client_id, mode)
);
CREATE INDEX IF NOT EXISTS idx_traffic_samples_ts ON traffic_samples(ts);
CREATE INDEX IF NOT EXISTS idx_traffic_samples_client_ts ON traffic_samples(client_id, ts);
CREATE INDEX IF NOT EXISTS idx_traffic_samples_client_mode_ts ON traffic_samples(client_id, mode, ts);
CREATE TABLE IF NOT EXISTS traffic_30m (
  bucket INTEGER NOT NULL,
  client_id TEXT NOT NULL,
  mode TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  PRIMARY KEY (bucket, client_id, mode)
);
CREATE INDEX IF NOT EXISTS idx_traffic_30m_client_bucket ON traffic_30m(client_id, bucket);
CREATE TABLE IF NOT EXISTS traffic_hourly (
  hour INTEGER NOT NULL,
  client_id TEXT NOT NULL,
  mode TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  PRIMARY KEY (hour, client_id, mode)
);
CREATE INDEX IF NOT EXISTS idx_traffic_hourly_client_hour ON traffic_hourly(client_id, hour);
CREATE TABLE IF NOT EXISTS traffic_daily (
  day INTEGER NOT NULL,
  client_id TEXT NOT NULL,
  mode TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  PRIMARY KEY (day, client_id, mode)
);
CREATE INDEX IF NOT EXISTS idx_traffic_daily_day ON traffic_daily(day);
CREATE INDEX IF NOT EXISTS idx_traffic_daily_client_day ON traffic_daily(client_id, day);
CREATE TABLE IF NOT EXISTS traffic_rollup_state (
  client_id TEXT NOT NULL,
  mode TEXT NOT NULL,
  ts INTEGER NOT NULL,
  rx INTEGER NOT NULL,
  tx INTEGER NOT NULL,
  PRIMARY KEY (client_id, mode)
);
CREATE TABLE IF NOT EXISTS system_samples (
  ts INTEGER PRIMARY KEY,
  cpu REAL NOT NULL,
  net_rx INTEGER NOT NULL,
  net_tx INTEGER NOT NULL,
  net_bps REAL NOT NULL DEFAULT 0,
  net_rx_bps REAL NOT NULL DEFAULT 0,
  net_tx_bps REAL NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_system_samples_ts ON system_samples(ts);
CREATE TABLE IF NOT EXISTS system_30m (
  bucket INTEGER PRIMARY KEY,
  cpu_sum REAL NOT NULL,
  net_rx INTEGER NOT NULL,
  net_tx INTEGER NOT NULL,
  net_bps_sum REAL NOT NULL,
  net_rx_bps_sum REAL NOT NULL,
  net_tx_bps_sum REAL NOT NULL,
  sample_count INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS system_hourly (
  hour INTEGER PRIMARY KEY,
  cpu_sum REAL NOT NULL,
  net_rx INTEGER NOT NULL,
  net_tx INTEGER NOT NULL,
  net_bps_sum REAL NOT NULL,
  net_rx_bps_sum REAL NOT NULL,
  net_tx_bps_sum REAL NOT NULL,
  sample_count INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS system_daily (
  day INTEGER PRIMARY KEY,
  cpu_sum REAL NOT NULL,
  net_rx INTEGER NOT NULL,
  net_tx INTEGER NOT NULL,
  net_bps_sum REAL NOT NULL,
  net_rx_bps_sum REAL NOT NULL,
  net_tx_bps_sum REAL NOT NULL,
  sample_count INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  level TEXT NOT NULL,
  scope TEXT NOT NULL,
  message TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_logs_ts ON logs(ts);
`);
  await sqliteExec("ALTER TABLE system_samples ADD COLUMN net_bps REAL NOT NULL DEFAULT 0;").catch(() => null);
  await sqliteExec("ALTER TABLE system_samples ADD COLUMN net_rx_bps REAL NOT NULL DEFAULT 0;").catch(() => null);
  await sqliteExec("ALTER TABLE system_samples ADD COLUMN net_tx_bps REAL NOT NULL DEFAULT 0;").catch(() => null);
}

async function ensureStatsDb() {
  if (!statsDbReady) {
    statsDbReady = initializeStatsDb().catch((error) => {
      statsDbReady = null;
      throw error;
    });
  }
  return statsDbReady;
}

async function logEvent(scope, level, message) {
  try {
    await ensureStatsDb();
    await sqliteExec(`INSERT INTO logs(ts, level, scope, message) VALUES (${Date.now()}, ${sqlText(level)}, ${sqlText(scope)}, ${sqlText(String(message || "").slice(0, 1000))});`);
  } catch {}
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
  const shaper = await trafficShaperSettings();
  const direct = mergeTransferMaps(await transfers(WG_INGRESS_IFACE), await transfers(AWG_INGRESS_IFACE));
  const upstream = {};
  const meta = await ensureClientMetaIds(await clientMeta(), peerBlocks(conf));
  return peerBlocks(conf).map((peer) => ({
    ...peer,
    id: meta[peer.name]?.id || peer.publicKey,
    comment: meta[peer.name]?.comment || "",
    awg: clientAwgParams(meta, peer),
    route: clientRoute(meta, peer.name),
    subscription: clientSubscription(meta, peer.name),
    speedLimit: normalizePersonalSpeedLimit(meta[peer.name]?.speedLimit || {}),
    effectiveSpeedLimit: effectiveSpeedLimit(shaper, meta, peer.name),
    accessKey: meta[peer.name]?.accessKey || "",
    disabled: clientIsDisabled(peer, meta, peer.name),
    direct: clientIsDisabled(peer, meta, peer.name) ? null : direct[peer.publicKey] || null,
    upstream: clientIsDisabled(peer, meta, peer.name) ? null : upstream[peer.publicKey] || null
  }));
}

export async function createClient({ name, dns = "8.8.8.8, 8.8.4.4", comment = "", route = null, protocol = "", mode = "", upstreamId = "", subscription = "1m", customUntil = "" }) {
  await ensureDirs();
  const client = strictName(name);
  let conf = await readText(MAIN_CONF);
  const beforeKeys = activeClientPublicKeys(conf, await clientMeta());
  const beforeVless = await activeVlessClients().catch(() => null);
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
    id: clientId(),
    publicKey,
    comment: commentText(comment),
    disabled: false,
    expiresAt: addSubscription(null, subscription, customUntil),
    accessKey: uniqueAccessKey(meta),
    awg: normalizeAwgParams(awgParamsForOctet(octet)),
    vless: { enabled: true, uuid: crypto.randomUUID() },
    route: normalizeClientRoute(route || { protocol, mode, upstreamId }),
    speedLimit: normalizePersonalSpeedLimit({})
  };
  await writeClientMeta(meta);
  await syncClientPeerRuntime(beforeKeys);
  await syncVlessUsers(beforeVless).catch((error) => logEvent("vless", "error", String(error.message || error)));
  return { name: client };
}

export async function removeClient(name) {
  const client = lookupName(name);
  let conf = await readText(MAIN_CONF);
  const beforeKeys = activeClientPublicKeys(conf, await clientMeta());
  const beforeVless = await activeVlessClients().catch(() => null);
  const block = peerBlocks(conf).find((peer) => peer.name === client);
  if (!block) throw new Error("Client not found");
  conf = conf.replace(peerBlockPattern(client, block.disabled), "");
  await writeMainConfig(conf);
  await fs.rm(path.join(CLIENT_DIR, `${client}.conf`), { force: true });
  const meta = await clientMeta();
  delete meta[client];
  await writeClientMeta(meta);
  await syncClientPeerRuntime(beforeKeys);
  await syncVlessUsers(beforeVless).catch((error) => logEvent("vless", "error", String(error.message || error)));
  return { ok: true };
}

export async function rebuildIngressAddressing() {
  await ensureDirs();
  let conf = await readText(MAIN_CONF);
  const subnet = wg0Subnet(conf);
  const blocks = peerBlocks(conf).sort((a, b) => clientOctet(a) - clientOctet(b));
  let octet = 2;
  const assignments = [];
  for (const block of blocks) {
    if (octet >= 255) throw new Error("WireGuard subnet is full");
    const address = `${subnet}.${octet}`;
    const nextBody = block.body.replace(/^AllowedIPs = .+$/m, `AllowedIPs = ${address}/32`);
    conf = conf.replace(peerBlockPattern(block.name, block.disabled), block.disabled ? disabledPeerText(block.name, nextBody) : activePeerText(block.name, nextBody));
    const clientFile = path.join(CLIENT_DIR, `${block.name}.conf`);
    const clientConf = await readText(clientFile);
    if (clientConf) {
      const nextClientConf = /^Address = .+$/m.test(clientConf)
        ? clientConf.replace(/^Address = .+$/m, `Address = ${address}/24`)
        : clientConf.replace(/^\[Interface\]\n/m, `[Interface]\nAddress = ${address}/24\n`);
      await writeText(clientFile, nextClientConf);
    }
    assignments.push({ name: block.name, address: `${address}/32` });
    octet++;
  }
  await writeMainConfig(conf.trimEnd() + "\n");
  const state = await awgState();
  await writeAwgState({ ...state, ingressAddressPlan: "derived-v1", ingressAddressMigratedAt: new Date().toISOString() });
  await applyUpstreamTunnels();
  return { ok: true, subnet, clients: assignments.length, assignments };
}

export async function updateClient(name, data) {
  const client = lookupName(name);
  const nextName = data.name !== undefined ? strictName(data.name) : client;
  let conf = await readText(MAIN_CONF);
  const beforeKeys = activeClientPublicKeys(conf, await clientMeta());
  const beforeVless = await activeVlessClients().catch(() => null);
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
    id: meta[client]?.id || clientId(),
    publicKey: block.publicKey,
    comment: commentText(data.comment ?? meta[client]?.comment ?? ""),
    awg: normalizeAwgParams(data.awg || meta[client]?.awg || awgParamsForOctet(clientOctet(block)), awgParamsForOctet(clientOctet(block))),
    route: normalizeClientRoute(data.route || meta[client]?.route || { protocol: "wg", mode: "default" }),
    disabled: Boolean(block.disabled || meta[client]?.disabled),
    expiresAt: data.expiresAt !== undefined ? data.expiresAt : meta[client]?.expiresAt,
    accessKey: meta[client]?.accessKey || uniqueAccessKey(meta),
    vless: meta[client]?.vless || { enabled: true, uuid: crypto.randomUUID() },
    speedLimit: normalizePersonalSpeedLimit(meta[client]?.speedLimit || {})
  };
  if (nextName !== client) delete meta[client];
  await writeClientMeta(meta);
  await syncClientPeerRuntime(beforeKeys);
  await syncVlessUsers(beforeVless).catch((error) => logEvent("vless", "error", String(error.message || error)));
  return { ok: true, name: nextName };
}

export async function setClientEnabled(name, enabled) {
  const client = lookupName(name);
  let conf = await readText(MAIN_CONF);
  const beforeKeys = activeClientPublicKeys(conf, await clientMeta());
  const beforeVless = await activeVlessClients().catch(() => null);
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
  await syncClientPeerRuntime(beforeKeys);
  await syncVlessUsers(beforeVless).catch((error) => logEvent("vless", "error", String(error.message || error)));
  return { ok: true, enabled: nextEnabled };
}

export async function setClientSpeedLimit(name, value = {}) {
  const client = lookupName(name);
  const conf = await readText(MAIN_CONF);
  const block = peerBlocks(conf).find((peer) => peer.name === client);
  if (!block) throw new Error("Client not found");
  const meta = await clientMeta();
  meta[client] = { ...meta[client], speedLimit: normalizePersonalSpeedLimit(value) };
  await writeClientMeta(meta);
  await applyTrafficShaping();
  return { ok: true, speedLimit: meta[client].speedLimit };
}

export async function extendClientSubscription(name, plan, customUntil = "") {
  const client = lookupName(name);
  const meta = await clientMeta();
  const beforeKeys = activeClientPublicKeys(await readText(MAIN_CONF), meta);
  const beforeVless = await activeVlessClients().catch(() => null);
  if (!meta[client]) throw new Error("Client not found");
  meta[client] = {
    ...meta[client],
    expiresAt: addSubscription(meta[client]?.expiresAt, plan, customUntil),
    expiredApplied: false,
    accessKey: meta[client]?.accessKey || uniqueAccessKey(meta)
  };
  await writeClientMeta(meta);
  await syncClientPeerRuntime(beforeKeys);
  await syncVlessUsers(beforeVless).catch((error) => logEvent("vless", "error", String(error.message || error)));
  return { ok: true, subscription: clientSubscription(meta, client) };
}

export async function cancelClientSubscription(name) {
  const client = lookupName(name);
  const meta = await clientMeta();
  const beforeKeys = activeClientPublicKeys(await readText(MAIN_CONF), meta);
  const beforeVless = await activeVlessClients().catch(() => null);
  if (!meta[client]) throw new Error("Client not found");
  meta[client] = { ...meta[client], expiresAt: "1970-01-01T00:00:00.000Z", expiredApplied: false, accessKey: meta[client]?.accessKey || uniqueAccessKey(meta) };
  await writeClientMeta(meta);
  await syncClientPeerRuntime(beforeKeys);
  await syncVlessUsers(beforeVless).catch((error) => logEvent("vless", "error", String(error.message || error)));
  return { ok: true, subscription: clientSubscription(meta, client) };
}

export async function enforceSubscriptions() {
  const meta = await clientMeta();
  const beforeKeys = activeClientPublicKeys(await readText(MAIN_CONF), meta);
  const beforeVless = await activeVlessClients().catch(() => null);
  let changed = false;
  for (const [name, value] of Object.entries(meta)) {
    if (subscriptionExpired(value?.expiresAt) && !value.expiredApplied) {
      meta[name] = { ...value, expiredApplied: true };
      changed = true;
    }
  }
  if (changed) {
    await writeClientMeta(meta);
    await syncClientPeerRuntime(beforeKeys);
    await syncVlessUsers(beforeVless).catch((error) => logEvent("vless", "error", String(error.message || error)));
  }
  return { changed };
}

export async function clientConfig(name, mode = "", upstreamId = "", protocol = "", allowDisabled = false, transport = "") {
  if (protocol === "vless") return clientVlessLink(name, mode, upstreamId, transport, allowDisabled);
  const client = lookupName(name);
  const direct = await readText(path.join(CLIENT_DIR, `${client}.conf`));
  if (!direct) throw new Error("Client config not found");
  const conf = await readText(MAIN_CONF);
  const meta = await clientMeta();
  const peer = peerBlocks(conf).find((item) => item.name === client);
  if (!peer) throw new Error("Client not found");
  if (!allowDisabled && clientIsDisabled(peer, meta, client)) throw new Error("Client subscription is expired or disabled");
  const savedRoute = clientRoute(meta, client);
  const requestedProtocol = protocol === "awg" ? "awg" : protocol === "wg" ? "wg" : savedRoute.protocol;
  const effectiveRoute = normalizeClientRoute({ protocol: requestedProtocol, mode: mode || savedRoute.mode, upstreamId: upstreamId || savedRoute.upstreamId });
  if (mode || protocol) await saveClientRoute(client, effectiveRoute);
  const endpoint = await awgClientEndpoint(client, "ingress", 0, effectiveRoute.protocol);
  const awgParams = clientAwgParams(meta, peer);
  const out = direct
    .replace(/^Address = .+$/m, `Address = ${endpoint.clientAddress}`)
    .replace(/^Endpoint = (.+):[0-9]+$/m, `Endpoint = ${wg0Endpoint(conf)}:${endpoint.port}`)
    .replace(/^AllowedIPs = .+$/m, "AllowedIPs = 0.0.0.0/0");
  return effectiveRoute.protocol === "awg" ? withAwgParams(out, awgParams) : stripAwgParams(out);
}

export async function clientQr(name, mode, upstreamId, protocol, allowDisabled = false, transport = "") {
  if (protocol === "vless") return clientVlessQr(name, mode, upstreamId, transport, allowDisabled);
  return QRCode.toDataURL(await clientConfig(name, mode, upstreamId, protocol, allowDisabled), { margin: 1, width: 640 });
}

function mergeVlessTransports(input = {}, fallback = DEFAULT_VLESS.transports) {
  const realityTcp = { ...fallback.realityTcp, ...(input.realityTcp || {}) };
  const xhttpReality = { ...fallback.xhttpReality, ...(input.xhttpReality || {}) };
  return {
    realityTcp: {
      enabled: realityTcp.enabled !== false,
      port: normalizePort(realityTcp.port ?? realityTcp.directPort, DEFAULT_VLESS.transports.realityTcp.port)
    },
    xhttpReality: {
      enabled: Boolean(xhttpReality.enabled),
      port: normalizePort(xhttpReality.port ?? xhttpReality.directPort, DEFAULT_VLESS.transports.xhttpReality.port),
      path: normalizeUrlPath(xhttpReality.path || DEFAULT_VLESS.transports.xhttpReality.path),
      mode: ["auto", "packet-up", "stream-up", "stream-one"].includes(xhttpReality.mode) ? xhttpReality.mode : "auto"
    }
  };
}

function normalizePort(value, fallback) {
  const n = Number(value);
  if (!Number.isInteger(n) || n < 1 || n > 65535) return fallback;
  return n;
}

function normalizeDomain(value) {
  return String(value || "").trim().toLowerCase().replace(/[^a-z0-9.-]/g, "").slice(0, 253);
}

function normalizeHost(value) {
  return String(value || "").trim().replace(/[^0-9a-zA-Z.:\-[\]]/g, "").slice(0, 253);
}

function normalizeUrlPath(value) {
  const raw = String(value || "/").trim().replace(/[?#\s]/g, "");
  return raw.startsWith("/") ? raw.slice(0, 128) || "/" : `/${raw.slice(0, 127)}`;
}

function normalizeShortId(value) {
  const raw = String(value || "").trim().replace(/[^0-9a-fA-F]/g, "").slice(0, 16);
  return raw.length % 2 === 0 ? raw.toLowerCase() : raw.slice(0, -1).toLowerCase();
}

function normalizeVlessSettings(value = {}, fallback = DEFAULT_VLESS) {
  const next = {
    enabled: Boolean(value.enabled),
    publicHost: normalizeHost(value.publicHost ?? fallback.publicHost),
    sniDomain: normalizeDomain(value.sniDomain ?? fallback.sniDomain),
    dest: normalizeHost(value.dest ?? fallback.dest),
    privateKey: String(value.privateKey ?? fallback.privateKey ?? "").trim(),
    publicKey: String(value.publicKey ?? fallback.publicKey ?? "").trim(),
    shortId: normalizeShortId(value.shortId ?? fallback.shortId),
    fingerprint: ["chrome", "firefox", "safari", "ios", "android", "edge", "randomized"].includes(value.fingerprint) ? value.fingerprint : fallback.fingerprint || "chrome",
    spiderX: normalizeUrlPath(value.spiderX ?? fallback.spiderX),
    transports: mergeVlessTransports(value.transports || {}, fallback.transports || DEFAULT_VLESS.transports)
  };
  if (!next.dest && next.sniDomain) next.dest = `${next.sniDomain}:443`;
  return next;
}

async function detectVlessPublicHost() {
  const conf = await readText(MAIN_CONF);
  return normalizeHost(process.env.WG_WEB_PUBLIC_HOST || wg0Endpoint(conf));
}

function validateVlessPorts(settings) {
  const ports = new Map();
  for (const [id, transport] of Object.entries(settings.transports || {})) {
    if (!transport.enabled) continue;
    const port = Number(transport.port);
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`Invalid VLESS port for ${id}`);
    if (ports.has(port)) throw new Error(`VLESS ports overlap: ${id} and ${ports.get(port)}`);
    ports.set(port, id);
  }
}

async function xrayX25519(privateKey = "") {
  const args = privateKey ? ["x25519", "-i", privateKey] : ["x25519"];
  const { stdout, stderr } = await host("xray", args, { timeout: 10000 });
  const text = `${stdout || ""}\n${stderr || ""}`;
  const privateMatch = text.match(/(?:Private\s*key|PrivateKey)\s*[:=]\s*(\S+)/i);
  const publicMatch = text.match(/(?:Public\s*key|PublicKey|Password(?:\s*\(PublicKey\))?)\s*[:=]\s*(\S+)/i);
  const result = {
    privateKey: privateMatch?.[1] || privateKey,
    publicKey: publicMatch?.[1] || ""
  };
  if (!result.privateKey || !result.publicKey) {
    throw new Error("Could not parse xray x25519 output. Check that Xray is installed and supports the x25519 command.");
  }
  return result;
}

async function ensureVlessKeys(settings) {
  let next = { ...settings };
  if (!next.privateKey || !next.publicKey) {
    const keys = await xrayX25519(next.privateKey);
    next.privateKey = next.privateKey || keys.privateKey;
    next.publicKey = keys.publicKey || next.publicKey;
  }
  if (!next.shortId) next.shortId = crypto.randomBytes(4).toString("hex");
  return next;
}

function vlessClient(meta, name) {
  const saved = meta[name]?.vless || {};
  return {
    enabled: saved.enabled !== false,
    uuid: saved.uuid || crypto.randomUUID()
  };
}

async function ensureVlessClientMeta(meta, peers = []) {
  let changed = false;
  for (const peer of peers) {
    if (!meta[peer.name]) { meta[peer.name] = {}; changed = true; }
    if (!meta[peer.name].vless?.uuid) {
      meta[peer.name].vless = { ...meta[peer.name].vless, enabled: meta[peer.name].vless?.enabled !== false, uuid: crypto.randomUUID() };
      changed = true;
    }
  }
  if (changed) await writeClientMeta(meta);
  return meta;
}

function vlessTransportEntries(settings) {
  return Object.entries(settings.transports || {}).filter(([, transport]) => transport.enabled);
}

function vlessPort(transport) {
  return Number(transport.port);
}

function legacyVlessPorts(id, upstreams = []) {
  const legacy = LEGACY_VLESS_PORTS[id];
  if (!legacy) return [];
  return [
    legacy.direct,
    legacy.default,
    ...upstreams.map((_, index) => legacy.upstreamStart + index)
  ];
}

function vlessListeningPorts(settings, upstreams = []) {
  const currentPorts = new Set(vlessTransportEntries(settings).map(([, transport]) => vlessPort(transport)));
  const entries = [];
  for (const [id, transport] of vlessTransportEntries(settings)) {
    entries.push({ id, transport, port: vlessPort(transport), legacy: false });
    for (const port of legacyVlessPorts(id, upstreams)) {
      if (currentPorts.has(port) || entries.some((entry) => entry.port === port)) continue;
      entries.push({ id, transport, port, legacy: true });
    }
  }
  return entries;
}

function vlessRealitySettings(settings) {
  const serverName = settings.sniDomain;
  return {
    show: false,
    dest: settings.dest || `${serverName}:443`,
    xver: 0,
    serverNames: [serverName],
    privateKey: settings.privateKey,
    shortIds: [settings.shortId],
    spiderX: settings.spiderX || "/"
  };
}

function vlessStreamSettings(id, transport, settings) {
  const base = {
    security: "reality",
    realitySettings: vlessRealitySettings(settings)
  };
  if (id === "xhttpReality") {
    return {
      ...base,
      network: "xhttp",
      xhttpSettings: {
        path: transport.path || "/dd-awg-xhttp",
        mode: transport.mode || "auto"
      }
    };
  }
  return {
    ...base,
    network: "tcp",
    tcpSettings: { acceptProxyProtocol: false }
  };
}

function vlessOutbound(client, mark) {
  return {
    tag: `client-${client.slot}`,
    protocol: "freedom",
    streamSettings: { sockopt: { mark } }
  };
}

function vlessSlotEmail(slot) {
  return `slot-${Math.max(1, Number(slot || 1))}@dd-awg`;
}

function vlessRuntimeSlots() {
  return Array.from({ length: 253 }, (_, index) => index + 2);
}

function vlessInboundUser(id, client) {
  return id === "realityTcp"
    ? { id: client.id, email: client.email, flow: "xtls-rprx-vision" }
    : { id: client.id, email: client.email };
}

function vlessInboundTag(entry) {
  const base = entry.id === "xhttpReality" ? "vlessx-in" : "vless-in";
  return entry.legacy ? `${base}-legacy-${entry.port}` : base;
}

function vlessInbound(id, transport, settings, clients, port = vlessPort(transport), legacy = false) {
  return {
    tag: vlessInboundTag({ id, port, legacy }),
    listen: "0.0.0.0",
    port,
    protocol: "vless",
    settings: {
      clients: clients.map((client) => vlessInboundUser(id, client)),
      decryption: "none"
    },
    streamSettings: vlessStreamSettings(id, transport, settings),
    sniffing: {
      enabled: true,
      destOverride: ["http", "tls", "quic"],
      routeOnly: false
    }
  };
}

async function activeVlessClients() {
  const conf = await readText(MAIN_CONF);
  const meta = await ensureVlessClientMeta(await clientMeta(), peerBlocks(conf));
  return activeClientPeersFrom(conf, meta)
    .map((peer) => ({ peer, vless: vlessClient(meta, peer.name) }))
    .filter((item) => item.vless.enabled)
    .map((item) => ({ id: item.vless.uuid, email: vlessSlotEmail(clientOctet(item.peer)), name: item.peer.name, peer: item.peer, slot: clientOctet(item.peer) }));
}

async function applyVlessFirewallPorts(settings, upstreams = []) {
  const ports = vlessListeningPorts(settings, upstreams).map((entry) => entry.port);
  if (!ports.length) return;
  const lines = [
    "set -e",
    "if systemctl is-active --quiet firewalld.service; then"
  ];
  for (const port of ports) lines.push(`  firewall-cmd --add-port=${port}/tcp >/dev/null 2>&1 || true`);
  lines.push("else");
  for (const port of ports) lines.push(`  iptables -w 5 -C INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null || iptables -w 5 -I INPUT -p tcp --dport ${port} -j ACCEPT`);
  lines.push("fi");
  await hostShell(lines.join("\n"), 15000).catch((error) => logEvent("vless", "warn", `Could not open VLESS firewall ports: ${String(error.message || error)}`));
}

async function removeLegacyVlessRouteRules() {
  for (const file of await fs.readdir("/etc/systemd/system").catch(() => [])) {
    if (!/^dd-awg-vless-route-.+\.service$/.test(file)) continue;
    await hostShell(`systemctl disable --now ${shellQuote(file)} >/dev/null 2>&1 || true`, 15000).catch(() => null);
    await fs.rm(`/etc/systemd/system/${file}`, { force: true });
  }
  await hostShell("systemctl daemon-reload >/dev/null 2>&1 || true", 10000).catch(() => null);
}

async function buildVlessConfig(settings) {
  const upstreams = await routingUpstreams();
  const clients = await activeVlessClients();
  const slots = vlessRuntimeSlots();
  const inbounds = vlessListeningPorts(settings, upstreams).map(({ id, transport, port, legacy }) => vlessInbound(id, transport, settings, clients, port, legacy));
  inbounds.unshift({
    tag: "api",
    listen: "127.0.0.1",
    port: Number(VLESS_API_ENDPOINT.split(":").pop()),
    protocol: "dokodemo-door",
    settings: { address: "127.0.0.1" }
  });
  const outbounds = slots.map((slot) => vlessOutbound({ slot }, 0x10000000 + slot));
  const rules = [
    { type: "field", inboundTag: ["api"], outboundTag: "api" },
    ...slots.map((slot) => ({ type: "field", user: [vlessSlotEmail(slot)], outboundTag: `client-${slot}` }))
  ];
  return {
    log: { loglevel: "warning" },
    api: { tag: "api", services: ["HandlerService"] },
    inbounds,
    outbounds,
    routing: {
      domainStrategy: "IPIfNonMatch",
      rules
    }
  };
}

function vlessClientMap(clients = []) {
  return new Map(clients.map((client) => [client.email, client]));
}

function vlessClientChanged(before, after) {
  return !before || !after || before.id !== after.id || before.slot !== after.slot;
}

async function xrayApiAlterInbound(payload) {
  const body = JSON.stringify(payload);
  const methods = ["HandlerService.AlterInbound", "xray.app.proxyman.command.HandlerService.AlterInbound"];
  const serverFlags = [`--server=${VLESS_API_ENDPOINT}`, `-server=${VLESS_API_ENDPOINT}`];
  let lastError;
  for (const serverFlag of serverFlags) {
    for (const method of methods) {
      try {
        await host("xray", ["api", serverFlag, method, body], { timeout: 10000 });
        return;
      } catch (error) {
        lastError = error;
      }
    }
  }
  throw lastError;
}

async function xrayApiAddUser(tag, entryId, client) {
  await xrayApiAlterInbound({
    tag,
    operation: {
      type: "xray.app.proxyman.command.AddUserOperation",
      user: {
        level: 0,
        email: client.email,
        account: {
          type: "xray.proxy.vless.Account",
          id: client.id,
          flow: entryId === "realityTcp" ? "xtls-rprx-vision" : "",
          encryption: "none"
        }
      }
    }
  });
}

async function xrayApiRemoveUser(tag, email) {
  await xrayApiAlterInbound({
    tag,
    operation: {
      type: "xray.app.proxyman.command.RemoveUserOperation",
      email
    }
  });
}

function benignXrayUserError(error) {
  const text = `${error?.message || ""}\n${error?.stderr || ""}\n${error?.stdout || ""}`.toLowerCase();
  return text.includes("not found") || text.includes("no such user") || text.includes("already exists") || text.includes("duplicate");
}

async function syncVlessUsers(beforeClients = null) {
  const settings = await vlessSettings();
  if (!settings.enabled) {
    await applyVlessService();
    return;
  }
  if (!beforeClients) {
    await applyVlessService();
    return;
  }
  if (!(await serviceActive(VLESS_SERVICE))) {
    await applyVlessService();
    return;
  }
  const upstreams = await routingUpstreams();
  await applyVlessFirewallPorts(settings, upstreams);
  await removeLegacyVlessRouteRules();
  await writeJson(VLESS_CONFIG_FILE, await buildVlessConfig(settings));
  const afterClients = await activeVlessClients();
  const before = vlessClientMap(beforeClients);
  const after = vlessClientMap(afterClients);
  const entries = vlessListeningPorts(settings, upstreams);
  try {
    for (const [email, client] of before) {
      if (after.has(email) && !vlessClientChanged(client, after.get(email))) continue;
      for (const entry of entries) {
        await xrayApiRemoveUser(vlessInboundTag(entry), email).catch((error) => {
          if (!benignXrayUserError(error)) throw error;
        });
      }
    }
    for (const [email, client] of after) {
      if (before.has(email) && !vlessClientChanged(before.get(email), client)) continue;
      for (const entry of entries) {
        await xrayApiAddUser(vlessInboundTag(entry), entry.id, client).catch((error) => {
          if (!benignXrayUserError(error)) throw error;
        });
      }
    }
  } catch (error) {
    await logEvent("vless", "warn", `Xray API user sync failed; restarting service: ${String(error.message || error)}`);
    await applyVlessService();
  }
}

export async function applyVlessService() {
  const settings = await vlessSettings();
  if (!settings.enabled) {
    await removeLegacyVlessRouteRules().catch(() => null);
    await hostShell(`systemctl disable --now ${shellQuote(VLESS_SERVICE)} >/dev/null 2>&1 || true`, 15000).catch(() => null);
    return { ok: true, enabled: false };
  }
  if (!settings.sniDomain) throw new Error("VLESS SNI domain is required");
  if (!settings.privateKey || !settings.publicKey) throw new Error("VLESS Reality keys are missing");
  validateVlessPorts(settings);
  const upstreams = await routingUpstreams();
  await applyVlessFirewallPorts(settings, upstreams);
  await removeLegacyVlessRouteRules();
  await writeJson(VLESS_CONFIG_FILE, await buildVlessConfig(settings));
  await hostShell(`systemctl daemon-reload && systemctl enable --now ${shellQuote(VLESS_SERVICE)} && systemctl restart ${shellQuote(VLESS_SERVICE)}`, 30000);
  return { ok: true, enabled: true, serviceActive: await serviceActive(VLESS_SERVICE), ports: vlessListeningPorts(settings, upstreams).length };
}

export async function vlessSettings(nextValue) {
  if (nextValue) {
    const current = normalizeVlessSettings(await readJson(VLESS_FILE, DEFAULT_VLESS));
    let next = normalizeVlessSettings({ ...current, ...nextValue, transports: { ...current.transports, ...(nextValue.transports || {}) } }, current);
    if (!next.publicHost) next.publicHost = await detectVlessPublicHost();
    if (next.enabled) {
      if (!next.sniDomain) throw new Error("VLESS SNI domain is required");
      next = await ensureVlessKeys(next);
    }
    validateVlessPorts(next);
    await writeJson(VLESS_FILE, next);
    await applyVlessService();
    await applyTrafficShaping().catch((error) => logEvent("traffic-shaper", "error", String(error.message || error)));
  }
  const saved = normalizeVlessSettings(await readJson(VLESS_FILE, DEFAULT_VLESS));
  const detectedPublicHost = await detectVlessPublicHost();
  return { ...saved, publicHost: saved.publicHost || detectedPublicHost, detectedPublicHost, serviceActive: await serviceActive(VLESS_SERVICE) };
}

export async function detectVlessHost() {
  return { publicHost: await detectVlessPublicHost() };
}

function normalizeVlessTransportId(value, settings) {
  const requested = String(value || "");
  if (settings.transports?.[requested]?.enabled) return requested;
  return vlessTransportEntries(settings)[0]?.[0] || "realityTcp";
}

export async function clientVlessLink(name, mode = "", upstreamId = "", transportId = "", allowDisabled = false) {
  const client = lookupName(name);
  const conf = await readText(MAIN_CONF);
  const meta = await ensureVlessClientMeta(await clientMeta(), peerBlocks(conf));
  const peer = peerBlocks(conf).find((item) => item.name === client);
  if (!peer) throw new Error("Client not found");
  if (!allowDisabled && clientIsDisabled(peer, meta, client)) throw new Error("Client subscription is expired or disabled");
  const settings = await vlessSettings();
  if (!settings.enabled) throw new Error("VLESS is disabled");
  if (!settings.sniDomain || !settings.publicKey || !settings.shortId) throw new Error("VLESS Reality settings are incomplete");
  const id = normalizeVlessTransportId(transportId, settings);
  const transport = settings.transports[id];
  if (!transport?.enabled) throw new Error("VLESS transport is disabled");
  const savedRoute = clientRoute(meta, client);
  const selectedRoute = normalizeClientRoute({ protocol: "vless", mode: mode || savedRoute.mode, upstreamId: upstreamId || savedRoute.upstreamId });
  if (mode || transportId) await saveClientRoute(client, selectedRoute);
  const host = settings.publicHost || (await telegramSettings()).domain || wg0Endpoint(conf);
  if (!host) throw new Error("VLESS public host is required");
  const params = new URLSearchParams({
    encryption: "none",
    security: "reality",
    sni: settings.sniDomain,
    fp: settings.fingerprint || "chrome",
    pbk: settings.publicKey,
    sid: settings.shortId,
    type: id === "xhttpReality" ? "xhttp" : "tcp"
  });
  if (id === "xhttpReality") {
    params.set("path", transport.path || "/dd-awg-xhttp");
    params.set("mode", transport.mode || "auto");
  } else {
    params.set("flow", "xtls-rprx-vision");
  }
  const label = encodeURIComponent(`${client}-${id}`);
  return `vless://${vlessClient(meta, client).uuid}@${host}:${vlessPort(transport)}?${params.toString()}#${label}`;
}

export async function clientVlessQr(name, mode = "", upstreamId = "", transportId = "", allowDisabled = false) {
  return QRCode.toDataURL(await clientVlessLink(name, mode, upstreamId, transportId, allowDisabled), { margin: 1, width: 640 });
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
  const normalizedProtocol = protocol === "vless" ? "vless" : protocol === "awg" ? "awg" : "wg";
  const normalizedMode = mode === "direct" || mode === "upstream" ? mode : "default";
  const suffix = `${normalizedMode === "default" ? "-default" : normalizedMode === "upstream" ? "-upstream" : ""}-${normalizedProtocol}`;
  return {
    name: client.name,
    filename: `${client.name}${suffix}.${normalizedProtocol === "vless" ? "txt" : "conf"}`,
    content: await clientConfig(client.name, normalizedMode, upstreamId || "", normalizedProtocol)
  };
}

export async function botClientQr(key, mode = "", upstreamId = "", protocol = "") {
  const config = await botClientConfig(key, mode, upstreamId, protocol);
  return { name: config.name, dataUrl: await QRCode.toDataURL(config.content, { margin: 1, width: 640 }) };
}

function cleanTelegramUsername(value) {
  return String(value || "").trim().replace(/^@+/, "").toLowerCase();
}

function normalizeTelegramAdmins(value = {}) {
  const raw = Array.isArray(value.adminUsernames) ? value.adminUsernames : [];
  if (value.adminUsername) raw.push(value.adminUsername);
  return [...new Set(raw.map(cleanTelegramUsername).filter(Boolean))];
}

function normalizeServerName(value) {
  return String(value || "").trim().replace(/[<>]/g, "").slice(0, 64);
}

export async function botAdminInfo(username = "") {
  const settings = await telegramSettings();
  const configured = normalizeTelegramAdmins(settings);
  const current = cleanTelegramUsername(username);
  return { admin: Boolean(current && configured.includes(current)), username: current };
}

export async function botAdminClientConfig(name, mode = "", upstreamId = "", protocol = "") {
  const client = lookupName(name);
  const normalizedProtocol = protocol === "vless" ? "vless" : protocol === "awg" ? "awg" : "wg";
  const normalizedMode = mode === "direct" || mode === "upstream" ? mode : "default";
  const suffix = `${normalizedMode === "default" ? "-default" : normalizedMode === "upstream" ? "-upstream" : ""}-${normalizedProtocol}`;
  return {
    name: client,
    filename: `${client}${suffix}.${normalizedProtocol === "vless" ? "txt" : "conf"}`,
    content: await clientConfig(client, normalizedMode, upstreamId || "", normalizedProtocol, true)
  };
}

export async function botAdminClientQr(name, mode = "", upstreamId = "", protocol = "") {
  const config = await botAdminClientConfig(name, mode, upstreamId, protocol);
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
  if (saved === "direct") return "direct";
  if (saved && items.some((item) => item.id === saved && item.enabled)) return saved;
  await writeText(DEFAULT_UPSTREAM_FILE, "direct");
  return "direct";
}

async function setDefaultUpstream(id) {
  if (id === "direct") {
    await writeText(DEFAULT_UPSTREAM_FILE, "direct");
    return;
  }
  const upstreams = await readJson(UPSTREAMS_FILE, []);
  const upstream = upstreams.find((item) => item.id === id);
  if (!upstream) throw new Error("Upstream tunnel not found");
  if (!upstream.enabled) throw new Error("Cannot set a disabled upstream as default");
  await writeText(DEFAULT_UPSTREAM_FILE, id);
}

export async function routingSettings(nextValue) {
  if (nextValue?.defaultId) {
    let upstreams = await routingUpstreams();
    const previous = await defaultUpstreamId(upstreams);
    const selectedIndex = upstreams.findIndex((item) => item.id === nextValue.defaultId);
    if (selectedIndex >= 0 && upstreams[selectedIndex].enabled && !upstreams[selectedIndex].routeReady) {
      await applyDedicatedUpstream(upstreams[selectedIndex], selectedIndex);
      upstreams = await routingUpstreams();
    }
    if (nextValue.defaultId !== "direct" && !upstreams.some((item) => item.id === nextValue.defaultId && item.routeReady)) {
      throw new Error("Selected upstream OUT interface is not active");
    }
    await setDefaultUpstream(nextValue.defaultId);
    try {
      await applyUnifiedRouting();
    } catch (error) {
      await setDefaultUpstream(previous);
      await applyUnifiedRouting().catch(() => null);
      throw error;
    }
    await applyTrafficShaping().catch((error) => logEvent("traffic-shaper", "error", String(error.message || error)));
  }
  const upstreams = await routingUpstreams();
  const configured = await defaultUpstreamId(upstreams);
  return { defaultId: configured === "direct" || upstreams.some((item) => item.id === configured && item.routeReady) ? configured : "direct", configuredDefaultId: configured };
}

function effectiveClientOut(meta, name, upstreams, routeOverride = null) {
  const route = normalizeClientRoute(routeOverride || meta[name]?.route || { mode: "default" });
  const globalId = upstreams.find((item) => item.isDefault)?.id || "direct";
  let id = route.mode === "direct" ? "direct" : route.mode === "upstream" ? route.upstreamId : globalId;
  let upstream = upstreams.find((item) => item.enabled && item.routeReady !== false && item.id === id);
  if (!upstream && route.mode === "upstream") {
    id = globalId;
    upstream = upstreams.find((item) => item.enabled && item.routeReady !== false && item.id === id);
  }
  return upstream ? { kind: "upstream", upstream, slot: upstreams.findIndex((item) => item.id === upstream.id) + 1 } : { kind: "direct", slot: 0 };
}

function clientTrafficMark(peer) {
  return 0x10000000 + Math.max(1, clientOctet(peer));
}

function routeMarkPrefix(slot) {
  return 0x10000000 + Math.max(0, Number(slot || 0)) * 0x10000;
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

async function routingUpstreams() {
  const upstreams = await listUpstreams();
  return Promise.all(upstreams.map(async (item) => ({
    ...item,
    routeReady: Boolean(item.enabled && await ifaceExists(upstreamIfaces(item).upIface))
  })));
}

export async function createUpstream({ name, config, port = 51821, comment = "" }) {
  await ensureDirs();
  if (!/^\s*\[Interface\]/m.test(config) || !/^\s*\[Peer\]/m.test(config) || !/^\s*Endpoint\s*=/m.test(config)) {
    throw new Error("Uploaded file does not look like a WireGuard/AmneziaWG client config");
  }
  const upstreamProtocol = detectUpstreamProtocol(config);
  await ensureAwgTools();
  const upstreams = (await listUpstreams()).map(({ isDefault, ...item }) => item);
  if (upstreams.length >= 44) throw new Error("A maximum of 44 upstream tunnels is supported");
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
  if (defaultOnly) {
    await routingSettings({ defaultId: data.defaultId });
    return listUpstreams();
  }
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
      meta[name] = { ...value, route: { protocol: normalizeClientRoute(value.route).protocol, mode: "default", upstreamId: "" } };
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

function shiftedSubnet(base, secondOffset = 0, thirdOffset = 0) {
  const parts = String(base || "10.7.0").split(".").map((item) => Number(item));
  const first = Number.isFinite(parts[0]) ? parts[0] : 10;
  const second = Math.min(254, Math.max(0, (Number.isFinite(parts[1]) ? parts[1] : 7) + secondOffset));
  const third = Math.min(254, Math.max(0, (Number.isFinite(parts[2]) ? parts[2] : 0) + thirdOffset));
  return `${first}.${second}.${third}`;
}

async function awgClientEndpoint(name, kind, slot = 0, protocol = "wg") {
  const conf = await readText(MAIN_CONF);
  const peer = peerBlocks(conf).find((item) => item.name === name);
  if (!peer) throw new Error("Client not found");
  const octet = clientOctet(peer);
  if (!octet) throw new Error("Client address not found");
  const ingress = kind === "ingress";
  const direct = kind === "direct";
  const upstream = kind === "upstream";
  const upstreamSlot = Math.max(1, Number(slot || 1));
  if (upstream && upstreamSlot > 44) throw new Error("Too many upstreams for automatic AWG client port allocation");
  const obfuscated = protocol === "awg";
  const port = obfuscated
    ? ingress || direct ? 55000 : upstream ? 57000 + upstreamSlot : 56000
    : ingress || direct ? 52000 : upstream ? 54000 + upstreamSlot : 53000;
  let subnet;
  if (await ingressAddressPlan() === "derived-v1") {
    subnet = shiftedSubnet(wg0Subnet(conf), obfuscated ? 0 : 1, ingress || direct ? 0 : upstream ? upstreamSlot + 1 : 1);
  } else {
    const third = obfuscated
      ? ingress || direct ? 80 : upstream ? 81 + upstreamSlot : 81
      : ingress || direct ? 64 : upstream ? 65 + upstreamSlot : 65;
    subnet = `100.${third}.0`;
  }
  return {
    port,
    serverAddress: `${subnet}.1/24`,
    clientAddress: `${subnet}.${octet}/32`,
    cidr: `${subnet}.0/24`
  };
}

async function clientIngressEndpoints(name, protocol, upstreams = []) {
  const endpoints = [await awgClientEndpoint(name, "ingress", 0, protocol), await awgClientEndpoint(name, "default", 0, protocol)];
  for (const [index, upstream] of upstreams.entries()) endpoints.push(await awgClientEndpoint(name, "upstream", index + 1, protocol));
  const seen = new Set();
  return endpoints.filter((endpoint) => {
    if (seen.has(endpoint.clientAddress)) return false;
    seen.add(endpoint.clientAddress);
    return true;
  });
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
  const upService = await quickServiceName(upIface, upProtocol);
  const inService = await quickServiceName(inIface, inProtocol);
  await writeText(file, `[Unit]\nAfter=network-online.target ${upService} ${inService}\nWants=network-online.target ${upService} ${inService}\n\n[Service]\nType=oneshot\nEnvironment=AWG_ROUTE_ENV=${envFile}\nExecStart=/usr/local/sbin/awg-route-rules start\nExecStop=/usr/local/sbin/awg-route-rules stop\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target\n`, 0o644);
}

function shQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

async function stopTunRules(envFile) {
  await hostShell(`if [ -e ${shQuote(envFile)} ]; then if [ -x /usr/local/sbin/awg-route-rules ]; then AWG_ROUTE_ENV=${shQuote(envFile)} /usr/local/sbin/awg-route-rules stop 2>/dev/null || true; elif [ -x /usr/local/sbin/wg-extra-tun-rules ]; then WG_EXTRA_TUN_ENV=${shQuote(envFile)} /usr/local/sbin/wg-extra-tun-rules stop 2>/dev/null || true; fi; fi`);
}

async function startTunRules(envFile) {
  await hostShell(`if [ -e ${shQuote(envFile)} ] && [ -x /usr/local/sbin/awg-route-rules ]; then AWG_ROUTE_ENV=${shQuote(envFile)} /usr/local/sbin/awg-route-rules start; fi`, 10000);
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
  const legacyInService = await quickServiceName("wg-extra-in");
  const legacyUpService = await quickServiceName("wg-extra-up");
  if (!selected) {
    await hostShell(`systemctl disable --now wg-extra-tun.service ${shQuote(legacyInService)} ${shQuote(legacyUpService)} 2>/dev/null || true`);
    return;
  }
  const names = upstreamIfaces(selected);
  await hostShell(`systemctl disable --now wg-extra-tun.service ${shQuote(legacyInService)} ${shQuote(legacyUpService)} 2>/dev/null || true`);
  await fs.rm(path.join(WG_DIR, "wg-extra-tun.env"), { force: true });
  await fs.rm(path.join(WG_DIR, "wg-extra-in.conf"), { force: true });
  await fs.rm(path.join(WG_DIR, "wg-extra-up.conf"), { force: true });
  await fs.rm(path.join(AWG_DIR, "wg-extra-in.conf"), { force: true });
  await fs.rm(path.join(AWG_DIR, "wg-extra-up.conf"), { force: true });
  await fs.rm("/etc/systemd/system/wg-extra-tun.service", { force: true });
  await assertInterfaceUp(names.upIface, await quickServiceName(names.upIface));
}

async function applyDedicatedUpstream(upstream, index) {
  const names = upstreamIfaces(upstream);
  await ensureAwgTools();
  const upService = await quickServiceName(names.upIface);
  await hostShell(`systemctl disable --now ${shQuote(upService)} 2>/dev/null || true`);
  await writeText(quickConfPath(names.upIface), normalizeUpstreamConfig(await readText(upstream.configPath)));
  await hostShell(`systemctl daemon-reload && systemctl enable --now ${shQuote(upService)}`, 30000);
  await assertInterfaceUp(names.upIface, upService);
}

async function removeDedicatedUpstream(upstream) {
  const names = upstreamIfaces(upstream);
  const upService = await quickServiceName(names.upIface);
  await hostShell(`systemctl disable --now ${shQuote(upService)} 2>/dev/null || true`);
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

async function writeAwgClientDefaultFiles(peers, defaultUpstream, protocol = "wg", stopRules = false) {
  const iface = awgClientIface("", "default", 0, null, protocol);
  const endpoint = await awgClientEndpoint(peers[0].name, "default", 0, protocol);
  const env = path.join(WG_DIR, `${iface}.env`);
  const conf = quickConfPath(iface, "awg");
  const service = `/etc/systemd/system/${iface}.service`;
  if (stopRules) await stopTunRules(env);
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
  return { iface, service };
}

async function writeAwgClientDefault(peers, defaultUpstream, protocol = "wg") {
  const { iface } = await writeAwgClientDefaultFiles(peers, defaultUpstream, protocol, true);
  const quickService = await quickServiceName(iface);
  await hostShell(`systemctl daemon-reload && systemctl restart ${shQuote(quickService)} && systemctl enable ${shQuote(quickService)} && systemctl restart ${shQuote(`${iface}.service`)} && systemctl enable ${shQuote(`${iface}.service`)}`, 30000);
}

async function switchAwgClientDefaultRoute(peers, defaultUpstream, protocol = "wg") {
  const iface = awgClientIface("", "default", 0, null, protocol);
  if (!(await ifaceExists(iface))) {
    await writeAwgClientDefault(peers, defaultUpstream, protocol);
    return;
  }
  const env = path.join(WG_DIR, `${iface}.env`);
  await stopTunRules(env);
  const { service } = await writeAwgClientDefaultFiles(peers, defaultUpstream, protocol, false);
  await hostShell(`systemctl daemon-reload && systemctl enable ${shQuote(path.basename(service))}`, 10000);
  await startTunRules(env);
}

async function writeAwgClientUpstreamFiles(peers, slot, ruleIndex, upstream, protocol = "wg", stopRules = false) {
  const names = upstreamIfaces(upstream);
  const iface = awgClientIface("", "upstream", slot, upstream, protocol);
  const endpoint = await awgClientEndpoint(peers[0].name, "upstream", slot, protocol);
  const env = path.join(WG_DIR, `${iface}.env`);
  const conf = quickConfPath(iface, "awg");
  const service = `/etc/systemd/system/${iface}.service`;
  if (stopRules) await stopTunRules(env);
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
  return { iface, service };
}

async function writeAwgClientUpstream(peers, slot, ruleIndex, upstream, protocol = "wg") {
  const { iface } = await writeAwgClientUpstreamFiles(peers, slot, ruleIndex, upstream, protocol, true);
  const quickService = await quickServiceName(iface);
  await hostShell(`systemctl daemon-reload && systemctl restart ${shQuote(quickService)} && systemctl enable ${shQuote(quickService)} && systemctl restart ${shQuote(`${iface}.service`)} && systemctl enable ${shQuote(`${iface}.service`)}`, 30000);
}

function clientRuntimeTargets(upstreams) {
  const enabled = upstreams.filter((item) => item.enabled);
  const defaultUpstream = upstreams.find((item) => item.enabled && item.isDefault);
  const targets = [];
  for (const protocol of ["wg", "awg"]) {
    targets.push({ iface: awgClientIface("", "direct", 0, null, protocol), kind: "direct", slot: 0, protocol });
    if (defaultUpstream) targets.push({ iface: awgClientIface("", "default", 0, null, protocol), kind: "default", slot: 0, protocol, upstream: defaultUpstream });
    for (const upstream of enabled) {
      const slot = upstreams.findIndex((item) => item.id === upstream.id) + 1;
      targets.push({ iface: awgClientIface("", "upstream", slot, upstream, protocol), kind: "upstream", slot, protocol, upstream });
    }
  }
  return targets;
}

async function ifaceExists(iface) {
  try {
    await host("ip", ["link", "show", iface], { timeout: 5000 });
    return true;
  } catch {
    return false;
  }
}

async function writeClientRuntimeConfigs(peers, upstreams, targets) {
  for (const target of targets) {
    if (target.kind === "direct") {
      await writeAwgClientInConfig(peers, "direct", quickConfPath(target.iface, "awg"), target.protocol === "awg" ? normalizeAwgParams(DEFAULT_AWG_PARAMS) : {}, 0, target.protocol);
    } else if (target.kind === "default") {
      await writeAwgClientDefaultFiles(peers, target.upstream, target.protocol);
    } else {
      const upstreamIndex = upstreams.findIndex((item) => item.id === target.upstream.id);
      await writeAwgClientUpstreamFiles(peers, target.slot, (target.protocol === "awg" ? 400 : 200) + upstreamIndex, target.upstream, target.protocol);
    }
  }
}

async function removeRuntimePeer(iface, publicKey) {
  await host("awg", ["set", iface, "peer", publicKey, "remove"], { timeout: 10000 }).catch(() => null);
}

async function setUnifiedRuntimePeer(iface, protocol, peer, upstreams) {
  const allowedIPs = (await clientIngressEndpoints(peer.name, protocol, upstreams)).map((endpoint) => endpoint.clientAddress).join(",");
  const psk = (peer.body.match(/^PresharedKey = (.+)$/m) || [])[1] || "";
  const args = ["set", iface, "peer", peer.publicKey, "allowed-ips", allowedIPs];
  let pskFile = "";
  try {
    if (psk) {
      pskFile = path.join(WEB_DIR, `.psk-${process.pid}-${crypto.randomBytes(6).toString("hex")}`);
      await fs.writeFile(pskFile, `${psk}\n`, { mode: 0o600 });
      args.splice(4, 0, "preshared-key", pskFile);
    }
    await host("awg", args, { timeout: 10000 });
  } finally {
    if (pskFile) await fs.rm(pskFile, { force: true });
  }
}

async function syncClientPeerRuntime(beforeKeys = null) {
  const upstreams = await listUpstreams();
  const conf = await readText(MAIN_CONF);
  const meta = await clientMeta();
  const peers = activeClientPeersFrom(conf, meta);
  const afterKeys = activeClientPublicKeys(conf, meta);
  const previousKeys = beforeKeys || new Set();
  await ensureAwgTools();
  for (const protocol of ["wg", "awg"]) {
    const result = await writeUnifiedIngressConfig(peers, protocol, upstreams);
    const iface = result.iface;
    if (peers.length && !(await ifaceExists(iface))) {
      await applyAwgClientTunnels(upstreams);
      await applyUnifiedRouting();
      await applyTrafficShaping().catch((error) => logEvent("traffic-shaper", "error", String(error.message || error)));
      return;
    }
    for (const key of previousKeys) {
      if (!afterKeys.has(key)) await removeRuntimePeer(iface, key);
    }
    if (await ifaceExists(iface)) {
      for (const peer of peers) await setUnifiedRuntimePeer(iface, protocol, peer, upstreams);
    }
  }
  await cleanupLegacyIngresses();
  await applyUnifiedRouting();
  await applyTrafficShaping().catch((error) => logEvent("traffic-shaper", "error", String(error.message || error)));
}

async function writeUnifiedIngressConfig(peers, protocol, upstreams) {
  const conf = await readText(MAIN_CONF);
  const privateKey = (conf.match(/^PrivateKey = (.+)$/m) || [])[1] || "";
  const iface = protocol === "awg" ? AWG_INGRESS_IFACE : WG_INGRESS_IFACE;
  const first = peers[0] || peerBlocks(conf)[0];
  if (!first) return { iface, active: false };
  const endpoint = await awgClientEndpoint(first.name, "ingress", 0, protocol);
  let out = `# Generated unified ${protocol.toUpperCase()} ingress\n[Interface]\nAddress = ${endpoint.serverAddress}\nPrivateKey = ${privateKey}\nListenPort = ${endpoint.port}\nTable = off\n`;
  if (protocol === "awg") out += `${awgParamLines(normalizeAwgParams(DEFAULT_AWG_PARAMS))}\n`;
  for (const peer of peers) {
    const allowedIPs = (await clientIngressEndpoints(peer.name, protocol, upstreams)).map((endpoint) => endpoint.clientAddress).join(", ");
    const psk = (peer.body.match(/^PresharedKey = (.+)$/m) || [])[1];
    out += `\n# BEGIN_PEER ${peer.name}\n[Peer]\nPublicKey = ${peer.publicKey}\n`;
    if (psk) out += `PresharedKey = ${psk}\n`;
    out += `AllowedIPs = ${allowedIPs}\n# END_PEER ${peer.name}\n`;
  }
  await writeText(quickConfPath(iface), out);
  return { iface, active: true };
}

async function cleanupLegacyIngresses() {
  const keep = new Set([`${WG_INGRESS_IFACE}.conf`, `${AWG_INGRESS_IFACE}.conf`]);
  const patterns = /^(wg0|awg-direct|awg-default|awg-in-.+|awgo-direct|awgo-default|awgo-.+|ad-.+|au-.+|awg-d-.+|awg-u-.+)\.(conf|env)$/;
  const files = [...new Set([...(await fs.readdir(AWG_DIR).catch(() => [])), ...(await fs.readdir(WG_DIR).catch(() => []))])];
  for (const file of files) {
    if (!patterns.test(file) || keep.has(file)) continue;
    const iface = file.replace(/\.(conf|env)$/, "");
    if (iface === "wg0") {
      await hostShell(`systemctl disable --now ${shQuote(await quickServiceName("wg0"))} 2>/dev/null || true; ip link del wg0 2>/dev/null || true`, 15000).catch(() => null);
      continue;
    }
    await hostShell(`systemctl disable --now ${shQuote(await quickServiceName(iface))} ${shellQuote(iface)}.service 2>/dev/null || true; ip link del ${shellQuote(iface)} 2>/dev/null || true`, 15000).catch(() => null);
    await fs.rm(path.join(AWG_DIR, file), { force: true });
    await fs.rm(path.join(WG_DIR, file), { force: true });
    await fs.rm(`/etc/systemd/system/${iface}.service`, { force: true });
  }
  for (const file of await fs.readdir("/etc/systemd/system").catch(() => [])) {
    if (!/^(awg-direct|awg-default|awg-in-.+|awgo-direct|awgo-default|awgo-.+|ad-.+|au-.+|awg-d-.+|awg-u-.+)\.service$/.test(file)) continue;
    await hostShell(`systemctl disable --now ${shellQuote(file)} 2>/dev/null || true`, 15000).catch(() => null);
    await fs.rm(`/etc/systemd/system/${file}`, { force: true });
  }
  await hostShell("systemctl daemon-reload >/dev/null 2>&1 || true", 10000).catch(() => null);
}

async function applyAwgClientTunnels(upstreams) {
  const conf = await readText(MAIN_CONF);
  const meta = await clientMeta();
  const peers = activeClientPeersFrom(conf, meta);
  await ensureAwgTools();
  for (const protocol of ["wg", "awg"]) {
    const result = await writeUnifiedIngressConfig(peers, protocol, upstreams);
    const quickService = await quickServiceName(result.iface);
    if (result.active) await hostShell(`systemctl restart ${shQuote(quickService)} && systemctl enable ${shQuote(quickService)}`, 30000);
    else await hostShell(`systemctl disable --now ${shQuote(quickService)} 2>/dev/null || true`, 15000).catch(() => null);
  }
  await cleanupLegacyIngresses();
}

async function applyClientRoutingTopology() {
  const conf = await readText(MAIN_CONF);
  const meta = await clientMeta();
  await syncClientPeerRuntime(activeClientPublicKeys(conf, meta));
  return { ok: true };
}

function routingRuleLines(peers, meta, upstreams) {
  const activeOutIfaces = upstreams.filter((item) => item.routeReady).map((item) => upstreamIfaces(item).upIface);
  const lines = [
    "#!/bin/bash",
    "set -euxo pipefail",
    "IPT=$(command -v iptables)",
    "echo 1 > /proc/sys/net/ipv4/ip_forward",
    "echo 1 > /proc/sys/net/ipv4/conf/all/src_valid_mark 2>/dev/null || true",
    `for iface in all default ${WG_INGRESS_IFACE} ${AWG_INGRESS_IFACE} ${activeOutIfaces.join(" ")}; do [[ -e /proc/sys/net/ipv4/conf/$iface/rp_filter ]] && echo 0 > /proc/sys/net/ipv4/conf/$iface/rp_filter || true; done`,
    "for table_chain in 'mangle DD_AWG_PRE PREROUTING' 'mangle DD_AWG_OUT OUTPUT' 'mangle DD_AWG_MSS FORWARD' 'nat DD_AWG_DNAT PREROUTING' 'nat DD_AWG_POST POSTROUTING' 'filter DD_AWG_FWD FORWARD' 'filter DD_AWG_INPUT INPUT'; do",
    "  set -- $table_chain; table=$1; chain=$2; parent=$3",
    "  $IPT -w 5 -t $table -N $chain 2>/dev/null || true",
    "  $IPT -w 5 -t $table -F $chain",
    "  $IPT -w 5 -t $table -C $parent -j $chain 2>/dev/null || $IPT -w 5 -t $table -I $parent 1 -j $chain",
    "done",
    "$IPT -w 5 -t mangle -A DD_AWG_PRE -j CONNMARK --restore-mark",
    "$IPT -w 5 -t mangle -A DD_AWG_OUT -m mark --mark 0x10000000/0xff000000 -j CONNMARK --save-mark",
    "$IPT -w 5 -t nat -A DD_AWG_DNAT -p udp --dport 53000 -j REDIRECT --to-ports 52000",
    "$IPT -w 5 -t nat -A DD_AWG_DNAT -p udp --dport 56000 -j REDIRECT --to-ports 55000",
    "for priority in $(seq 17001 18255); do while ip rule del priority \"$priority\" 2>/dev/null; do :; done; done"
  ];
  for (const [index, upstream] of upstreams.entries()) {
    lines.push(`$IPT -w 5 -t nat -A DD_AWG_DNAT -p udp --dport ${54001 + index} -j REDIRECT --to-ports 52000`);
    lines.push(`$IPT -w 5 -t nat -A DD_AWG_DNAT -p udp --dport ${57001 + index} -j REDIRECT --to-ports 55000`);
    if (!upstream.routeReady) continue;
    const slot = index + 1;
    const prefix = `0x${routeMarkPrefix(slot).toString(16)}`;
    const table = 61000 + slot;
    const upIface = upstreamIfaces(upstream).upIface;
    lines.push(`ip rule add fwmark ${prefix}/0xffff0000 table ${table} priority ${17000 + slot}`);
    lines.push(`ip route replace default dev ${shQuote(upIface)} table ${table}`);
    lines.push(`$IPT -w 5 -t nat -A DD_AWG_POST -m mark --mark ${prefix}/0xffff0000 -o ${shQuote(upIface)} -j MASQUERADE`);
  }
  for (const protocol of ["wg", "awg"]) {
    const iface = protocol === "awg" ? AWG_INGRESS_IFACE : WG_INGRESS_IFACE;
    if (!peers.length) continue;
    lines.push(`$IPT -w 5 -t filter -A DD_AWG_INPUT -p udp --dport ${protocol === "awg" ? 55000 : 52000} -j ACCEPT`);
    lines.push(`$IPT -w 5 -t filter -A DD_AWG_FWD -i ${iface} -j ACCEPT`);
    lines.push(`$IPT -w 5 -t filter -A DD_AWG_FWD -o ${iface} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT`);
    lines.push(`$IPT -w 5 -t mangle -A DD_AWG_MSS -i ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu`);
    lines.push(`$IPT -w 5 -t mangle -A DD_AWG_MSS -o ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu`);
  }
  return { lines };
}

export async function applyUnifiedRouting() {
  const conf = await readText(MAIN_CONF);
  const meta = await clientMeta();
  const peers = activeClientPeersFrom(conf, meta);
  const upstreams = await routingUpstreams();
  const { lines } = routingRuleLines(peers, meta, upstreams);
  if (peers.length) {
    for (const protocol of ["wg", "awg"]) {
      for (const endpoint of await clientIngressEndpoints(peers[0].name, protocol, upstreams)) {
        lines.push(`ip route replace ${endpoint.cidr} dev ${protocol === "awg" ? AWG_INGRESS_IFACE : WG_INGRESS_IFACE}`);
      }
    }
    for (const [index, upstream] of upstreams.entries()) {
      if (!upstream.routeReady) continue;
      const table = 61000 + index + 1;
      for (const protocol of ["wg", "awg"]) {
        for (const endpoint of await clientIngressEndpoints(peers[0].name, protocol, upstreams)) {
          lines.push(`ip route replace ${endpoint.cidr} dev ${protocol === "awg" ? AWG_INGRESS_IFACE : WG_INGRESS_IFACE} table ${table}`);
        }
      }
    }
  }
  for (const peer of peers) {
    const target = effectiveClientOut(meta, peer.name, upstreams);
    const mark = `0x${clientTrafficMark(peer, target, upstreams).toString(16)}`;
    if (target.kind === "upstream" && target.upstream?.routeReady) {
      const slot = upstreams.findIndex((item) => item.id === target.upstream.id) + 1;
      const table = 61000 + slot;
      const upIface = upstreamIfaces(target.upstream).upIface;
      lines.push(`ip rule add fwmark ${mark}/0xffffffff table ${table} priority ${18000 + Math.max(1, clientOctet(peer))}`);
      lines.push(`$IPT -w 5 -t nat -A DD_AWG_POST -m mark --mark ${mark}/0xffffffff -o ${shQuote(upIface)} -j MASQUERADE`);
    }
    for (const protocol of ["wg", "awg"]) {
      for (const endpoint of await clientIngressEndpoints(peer.name, protocol, upstreams)) {
        const ip = tcClientIp(endpoint.clientAddress);
        if (!ip) continue;
        lines.push(`$IPT -w 5 -t mangle -A DD_AWG_PRE -i ${protocol === "awg" ? AWG_INGRESS_IFACE : WG_INGRESS_IFACE} -s ${ip}/32 -j MARK --set-xmark ${mark}/0xffffffff`);
        lines.push(`$IPT -w 5 -t mangle -A DD_AWG_PRE -i ${protocol === "awg" ? AWG_INGRESS_IFACE : WG_INGRESS_IFACE} -s ${ip}/32 -j CONNMARK --save-mark`);
        if (target.kind === "direct") lines.push(`$IPT -w 5 -t nat -A DD_AWG_POST -s ${ip}/32 -m mark --mark ${mark}/0xffffffff -j MASQUERADE`);
      }
    }
  }
  lines.push("ip route flush cache");
  await writeText(ROUTING_SCRIPT_FILE, `${lines.join("\n")}\n`, 0o700);
  try {
    await hostShell(`systemctl daemon-reload && systemctl enable ${shellQuote(ROUTING_SERVICE)} >/dev/null 2>&1 && systemctl restart ${shellQuote(ROUTING_SERVICE)}`, 30000);
  } catch (error) {
    const details = await serviceDiagnostics(ROUTING_SERVICE);
    throw new Error(`Could not apply unified routing. ${details || String(error.message || error)}`);
  }
  return { ok: true, clients: peers.length, upstreams: upstreams.filter((item) => item.enabled).length };
}

async function applyAwgDefaultClientTunnel(upstreams) {
  const conf = await readText(MAIN_CONF);
  const meta = await clientMeta();
  const peers = activeClientPeersFrom(conf, meta);
  const defaultId = await defaultUpstreamId(upstreams);
  const defaultUpstream = upstreams.find((item) => item.enabled && item.id === defaultId);
  if (!peers.length || !defaultUpstream) {
    for (const protocol of ["wg", "awg"]) {
      const iface = awgClientIface("", "default", 0, null, protocol);
      await hostShell(`systemctl disable --now ${shQuote(await quickServiceName(iface))} ${shQuote(`${iface}.service`)} 2>/dev/null || true`);
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

async function applyAwgDefaultClientRouteSwitch(upstreams) {
  const conf = await readText(MAIN_CONF);
  const meta = await clientMeta();
  const peers = activeClientPeersFrom(conf, meta);
  const defaultId = await defaultUpstreamId(upstreams);
  const defaultUpstream = upstreams.find((item) => item.enabled && item.id === defaultId);
  if (!peers.length || !defaultUpstream) {
    await applyAwgDefaultClientTunnel(upstreams);
    return;
  }
  await ensureAwgTools();
  await switchAwgClientDefaultRoute(peers, defaultUpstream, "wg");
  await switchAwgClientDefaultRoute(peers, defaultUpstream, "awg");
}

export async function trafficShaperSettings(nextValue) {
  if (nextValue) {
    await writeJson(TRAFFIC_SHAPER_FILE, {
      enabled: nextValue.enabled !== false,
      mbps: normalizeSpeedMbit(nextValue.mbps, DEFAULT_TRAFFIC_SHAPER.mbps)
    });
  }
  const settings = { ...DEFAULT_TRAFFIC_SHAPER, ...(await readJson(TRAFFIC_SHAPER_FILE, DEFAULT_TRAFFIC_SHAPER)) };
  return { enabled: settings.enabled !== false, mbps: normalizeSpeedMbit(settings.mbps, DEFAULT_TRAFFIC_SHAPER.mbps) };
}

function tcClientIp(cidr) {
  const value = String(cidr || "").replace(/\/\d+$/, "");
  if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(value)) return "";
  return value.split(".").every((part) => Number(part) >= 0 && Number(part) <= 255) ? value : "";
}

function tcRate(value) {
  return `${normalizeSpeedMbit(value, DEFAULT_TRAFFIC_SHAPER.mbps)}mbit`;
}

function tcBurst(value) {
  const mbps = normalizeSpeedMbit(value, DEFAULT_TRAFFIC_SHAPER.mbps);
  return `${Math.max(64, Math.min(8192, Math.round(mbps * 64)))}k`;
}

async function clearTrafficShapingIface(iface) {
  await hostShell(`if command -v tc >/dev/null 2>&1 && ip link show ${shQuote(iface)} >/dev/null 2>&1; then tc qdisc del dev ${shQuote(iface)} root 2>/dev/null || true; tc qdisc del dev ${shQuote(iface)} ingress 2>/dev/null || true; fi`, 10000);
}

async function applyTrafficShapingIface(iface, rules) {
  await clearTrafficShapingIface(iface);
  if (!rules.length) return;
  const lines = [
    "set -e",
    "command -v tc >/dev/null 2>&1",
    `ip link show ${shQuote(iface)} >/dev/null 2>&1`,
    `tc qdisc add dev ${shQuote(iface)} root handle 1: htb default 999`,
    `tc class add dev ${shQuote(iface)} parent 1: classid 1:999 htb rate 10000mbit ceil 10000mbit`,
    `tc qdisc add dev ${shQuote(iface)} handle ffff: ingress`
  ];
  rules.forEach((rule, index) => {
    const classId = index + 10;
    const prio = index + 10;
    const rate = tcRate(rule.mbps);
    const burst = tcBurst(rule.mbps);
    lines.push(`tc class add dev ${shQuote(iface)} parent 1: classid 1:${classId} htb rate ${rate} ceil ${rate}`);
    lines.push(`tc filter add dev ${shQuote(iface)} protocol ip parent 1: prio ${prio} u32 match ip dst ${rule.ip}/32 flowid 1:${classId}`);
    lines.push(`tc filter add dev ${shQuote(iface)} parent ffff: protocol ip prio ${prio} u32 match ip src ${rule.ip}/32 police rate ${rate} burst ${burst} drop flowid :${classId}`);
  });
  await hostShell(lines.join("\n"), 20000);
}

async function publicNetworkIfaces() {
  const { stdout } = await hostShell("ip -o -4 route show to default | awk '{print $5}' | sort -u", 10000).catch(() => ({ stdout: "" }));
  return [...new Set(stdout.trim().split(/\s+/).filter((iface) => /^[0-9A-Za-z_.:-]+$/.test(iface)))];
}

async function applyMarkedEgressShaping(iface, rules) {
  await clearTrafficShapingIface(iface);
  if (!rules.length) return;
  const lines = [
    "set -e",
    `ip link show ${shQuote(iface)} >/dev/null 2>&1`,
    `tc qdisc add dev ${shQuote(iface)} root handle 1: htb default 999`,
    `tc class add dev ${shQuote(iface)} parent 1: classid 1:999 htb rate 10000mbit ceil 10000mbit`,
    `tc qdisc add dev ${shQuote(iface)} parent 1:999 handle 999: fq_codel`
  ];
  rules.forEach((rule, index) => {
    const classId = index + 10;
    const rate = tcRate(rule.mbps);
    lines.push(`tc class add dev ${shQuote(iface)} parent 1: classid 1:${classId} htb rate ${rate} ceil ${rate}`);
    lines.push(`tc qdisc add dev ${shQuote(iface)} parent 1:${classId} handle ${classId}: fq_codel`);
    lines.push(`tc filter add dev ${shQuote(iface)} parent 1: protocol ip prio ${classId} handle ${rule.mark} fw flowid 1:${classId}`);
  });
  await hostShell(lines.join("\n"), 30000);
}

async function applyMarkedTrafficShaping(globalSettings, conf, meta, upstreams) {
  const publicIfaces = await publicNetworkIfaces();
  const inputIfaces = [...new Set([...publicIfaces, ...upstreams.filter((item) => item.routeReady).map((item) => upstreamIfaces(item).upIface)])];
  const rules = [];
  if (globalSettings.enabled !== false) {
    for (const peer of activeClientPeersFrom(conf, meta)) {
      const limit = effectiveSpeedLimit(globalSettings, meta, peer.name);
      if (!limit.enabled) continue;
      const target = effectiveClientOut(meta, peer.name, upstreams);
      rules.push({ mark: clientTrafficMark(peer, target, upstreams), mbps: limit.mbps, target });
    }
  }
  const uploadByIface = new Map(inputIfaces.map((iface) => [iface, []]));
  for (const rule of rules) {
    const ifaces = rule.target.kind === "upstream" ? [upstreamIfaces(rule.target.upstream).upIface] : publicIfaces;
    for (const iface of ifaces) uploadByIface.get(iface)?.push(rule);
  }
  for (const [iface, ifaceRules] of uploadByIface) if (await ifaceExists(iface)) await applyMarkedEgressShaping(iface, ifaceRules);
  const lines = [
    "set -e",
    "modprobe ifb 2>/dev/null || true",
    `ip link show ${VLESS_IFB_IFACE} >/dev/null 2>&1 || ip link add ${VLESS_IFB_IFACE} type ifb`,
    `ip link set ${VLESS_IFB_IFACE} up`,
    `tc qdisc del dev ${VLESS_IFB_IFACE} root 2>/dev/null || true`
  ];
  if (rules.length) {
    lines.push(`tc qdisc add dev ${VLESS_IFB_IFACE} root handle 1: htb default 999`);
    lines.push(`tc class add dev ${VLESS_IFB_IFACE} parent 1: classid 1:999 htb rate 10000mbit ceil 10000mbit`);
    lines.push(`tc qdisc add dev ${VLESS_IFB_IFACE} parent 1:999 handle 999: fq_codel`);
    rules.forEach((rule, index) => {
      const classId = index + 10;
      const rate = tcRate(rule.mbps);
      lines.push(`tc class add dev ${VLESS_IFB_IFACE} parent 1: classid 1:${classId} htb rate ${rate} ceil ${rate}`);
      lines.push(`tc qdisc add dev ${VLESS_IFB_IFACE} parent 1:${classId} handle ${classId}: fq_codel`);
      lines.push(`tc filter add dev ${VLESS_IFB_IFACE} parent 1: protocol ip prio ${classId} handle ${rule.mark} fw flowid 1:${classId}`);
    });
  }
  for (const iface of inputIfaces) {
    lines.push(`tc qdisc add dev ${shQuote(iface)} clsact 2>/dev/null || true`);
    lines.push(`tc filter del dev ${shQuote(iface)} ingress protocol ip pref 47000 2>/dev/null || true`);
    lines.push(`tc filter del dev ${shQuote(iface)} ingress chain 47 2>/dev/null || true`);
    if (!rules.length) continue;
    lines.push(`tc filter add dev ${shQuote(iface)} ingress pref 47000 chain 0 protocol ip flower ct_state -trk action ct pipe action goto chain 47`);
    rules.forEach((rule, index) => {
      lines.push(`tc filter add dev ${shQuote(iface)} ingress pref ${47010 + index} chain 47 protocol ip flower ct_state +trk ct_mark ${rule.mark}/0xffffffff action skbedit mark ${rule.mark} pipe action mirred egress redirect dev ${VLESS_IFB_IFACE}`);
    });
  }
  await hostShell(lines.join("\n"), 30000);
  return { interfaces: inputIfaces.length, rules: rules.length };
}

export async function applyTrafficShaping() {
  const settings = await trafficShaperSettings();
  const conf = await readText(MAIN_CONF);
  const meta = await clientMeta();
  const upstreams = await routingUpstreams();
  const vless = await applyMarkedTrafficShaping(settings, conf, meta, upstreams);
  for (const iface of [WG_INGRESS_IFACE, AWG_INGRESS_IFACE]) if (await ifaceExists(iface)) await clearTrafficShapingIface(iface);
  return { ok: true, enabled: settings.enabled !== false, mbps: normalizeSpeedMbit(settings.mbps, DEFAULT_TRAFFIC_SHAPER.mbps), interfaces: vless.interfaces, rules: vless.rules };
}

export async function applyUpstreamTunnels() {
  const upstreams = await listUpstreams();
  for (const [index, upstream] of upstreams.entries()) {
    if (upstream.enabled) await applyDedicatedUpstream(upstream, index);
    else await removeDedicatedUpstream(upstream);
  }
  const conf = await readText(MAIN_CONF);
  const meta = await clientMeta();
  await syncClientPeerRuntime(activeClientPublicKeys(conf, meta));
  await applyVlessService().catch((error) => logEvent("vless", "error", String(error.message || error)));
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
    const adminUsernames = normalizeTelegramAdmins(nextValue);
    await writeJson(TELEGRAM_FILE, {
      enabled: Boolean(nextValue.enabled),
      token: String(nextValue.token || ""),
      chatId: String(nextValue.chatId || ""),
      notificationIntervalSeconds: Number(nextValue.notificationIntervalSeconds || 300),
      domain: String(nextValue.domain || ""),
      serverName: normalizeServerName(nextValue.serverName),
      adminUsername: adminUsernames[0] || "",
      adminUsernames
    });
  }
  const settings = await readJson(TELEGRAM_FILE, { enabled: false, token: "", chatId: "", notificationIntervalSeconds: 300, domain: "", serverName: "", adminUsername: "", adminUsernames: [] });
  return { ...settings, serverName: normalizeServerName(settings.serverName), adminUsernames: normalizeTelegramAdmins(settings), adminUsername: normalizeTelegramAdmins(settings)[0] || "" };
}

function normalizeVpnBotSettings(value = {}) {
  return {
    enabled: Boolean(value.enabled),
    token: String(value.token || "").trim(),
    upstreamId: String(value.upstreamId || "").trim()
  };
}

async function readExistingVpnBotToken() {
  const saved = await readJson(BOT_CONFIG_FILE, {});
  return String(saved.telegram_token || "");
}

async function ensureVpnBotConfig(settings) {
  await fs.mkdir(BOT_CONFIG_DIR, { recursive: true, mode: 0o700 });
  await fs.mkdir(BOT_DIR, { recursive: true, mode: 0o700 });
  await fs.writeFile(BOT_CONFIG_FILE, JSON.stringify({
    panel_url: "http://127.0.0.1:3000",
    api_token: process.env.BOT_API_TOKEN || "",
    telegram_token: settings.token,
    sessions_file: path.join(BOT_DIR, "sessions.json")
  }, null, 2) + "\n", { mode: 0o600 });
}

async function telegramApiNets() {
  const { stdout } = await hostShell("getent ahostsv4 api.telegram.org 2>/dev/null | awk '{print $1}' | sort -u | sed 's/$/\\/32/' || true", 10000).catch(() => ({ stdout: "" }));
  return [...new Set([
    ...stdout.trim().split(/\s+/).filter(Boolean),
    "149.154.160.0/20",
    "91.108.4.0/22",
    "91.108.8.0/22",
    "91.108.12.0/22",
    "91.108.16.0/22",
    "91.108.56.0/22"
  ])];
}

async function disableTelegramApiRoute() {
  const script = `
set -e
if [[ -s ${shellQuote(TGAPI_STATE_FILE)} ]]; then
  . ${shellQuote(TGAPI_STATE_FILE)}
  for net in \${TGAPI_NETS:-}; do
    if [[ -n "\${TGAPI_IFACE:-}" ]]; then ip route del "$net" dev "$TGAPI_IFACE" 2>/dev/null || true; fi
  done
fi
systemctl disable --now ${shellQuote(TGAPI_TIMER)} tgapi-via-tunnel.service >/dev/null 2>&1 || true
rm -f ${shellQuote(TGAPI_STATE_FILE)} ${shellQuote(TGAPI_SERVICE_FILE)}
systemctl daemon-reload >/dev/null 2>&1 || true`;
  await hostShell(script, 20000).catch(() => null);
}

async function applyTelegramApiRoute(upstreamId) {
  const upstreams = await listUpstreams();
  const upstream = upstreams.find((item) => item.id === upstreamId);
  if (!upstream) throw new Error("Telegram API upstream tunnel not found");
  if (!upstream.enabled) throw new Error("Telegram API upstream tunnel is disabled");
  const iface = upstreamIfaces(upstream).upIface;
  const quickService = await quickServiceName(iface);
  try {
    await host("ip", ["link", "show", iface], { timeout: 5000 });
  } catch {
    await host("systemctl", ["start", quickService], { timeout: 30000 }).catch(() => null);
  }
  try {
    await host("ip", ["link", "show", iface], { timeout: 5000 });
  } catch {
    throw new Error(`${iface} is not up. Check upstream status first.`);
  }
  const nets = await telegramApiNets();
  if (!nets.length) throw new Error("Could not build Telegram API network list");
  if (!fss.existsSync(TGAPI_APPLY_BIN)) throw new Error(`${TGAPI_APPLY_BIN} is missing. Re-run the installer.`);
  await writeText(TGAPI_STATE_FILE, [
    `TGAPI_NAME=${shellQuote(upstream.name)}`,
    `TGAPI_UPSTREAM_ID=${shellQuote(upstream.id)}`,
    `TGAPI_IFACE=${shellQuote(iface)}`,
    `TGAPI_NETS=${shellQuote(nets.join(" "))}`,
    ""
  ].join("\n"));
  await writeText(TGAPI_SERVICE_FILE, `[Unit]
Description=Route Telegram API traffic via selected AWG upstream
After=network-online.target ${quickService}
Wants=network-online.target ${quickService}

[Service]
Type=oneshot
ExecStart=${TGAPI_APPLY_BIN}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
`, 0o644);
  await hostShell(`systemctl daemon-reload && systemctl enable --now ${shellQuote(TGAPI_TIMER)} && systemctl restart tgapi-via-tunnel.service`, 30000);
}

export async function vpnBotSettings(nextValue) {
  if (nextValue) {
    const current = normalizeVpnBotSettings(await readJson(VPN_BOT_FILE, DEFAULT_VPN_BOT));
    const next = normalizeVpnBotSettings({ ...current, ...nextValue });
    if (next.enabled && !next.token) throw new Error("Telegram bot token is required");
    await writeJson(VPN_BOT_FILE, next);
    if (next.enabled) {
      await ensureVpnBotConfig(next);
      await hostShell(`systemctl daemon-reload && systemctl enable --now ${shellQuote(BOT_SERVICE)} && systemctl restart ${shellQuote(BOT_SERVICE)}`, 30000);
      if (next.upstreamId) await applyTelegramApiRoute(next.upstreamId);
      else await disableTelegramApiRoute();
    } else {
      await hostShell(`systemctl disable --now ${shellQuote(BOT_SERVICE)} >/dev/null 2>&1 || true`, 15000).catch(() => null);
      await disableTelegramApiRoute();
    }
  }
  const saved = normalizeVpnBotSettings(await readJson(VPN_BOT_FILE, DEFAULT_VPN_BOT));
  if (!saved.token) saved.token = await readExistingVpnBotToken();
  const routeState = await readText(TGAPI_STATE_FILE);
  const routedUpstreamId = (routeState.match(/^TGAPI_UPSTREAM_ID=(.+)$/m) || [])[1]?.replace(/^'|'$/g, "").replace(/'\\''/g, "'") || "";
  return {
    ...saved,
    upstreamId: saved.upstreamId || routedUpstreamId,
    serviceActive: await serviceActive(BOT_SERVICE),
    telegramApiRouteActive: await serviceActive("tgapi-via-tunnel.service"),
    routedUpstreamId
  };
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
  const service = await quickServiceName(iface);
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
      await logEvent("health", upstream.status === "healthy" ? "info" : "warn", `${upstream.name}: ${before || "unknown"} -> ${upstream.status}${upstream.lastError ? ` (${upstream.lastError})` : ""}`);
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
    await logEvent("certbot", "info", `Certificate issued for ${target}`);
    const settings = await telegramSettings();
    await telegramSettings({ ...settings, domain: target });
    return { ok: true, log };
  } catch (error) {
    const log = `${new Date().toISOString()}\n${String(error.message || error)}\n`;
    await writeText(CERTBOT_LOG_FILE, log, 0o600);
    await logEvent("certbot", "error", `Certificate request failed for ${target}: ${String(error.message || error)}`);
    return { ok: false, log };
  }
}

export async function certbotLog() {
  return { log: await readText(CERTBOT_LOG_FILE) };
}

function peerTextFromBackup(peer = {}) {
  const name = strictName(peer.name);
  const body = String(peer.body || "").trim();
  if (!body || !/^PublicKey = .+$/m.test(body) || !/^AllowedIPs = .+$/m.test(body)) throw new Error(`Invalid peer backup for ${name}`);
  return peer.disabled ? disabledPeerText(name, body) : activePeerText(name, body);
}

function replaceEndpointHost(content, nextHost) {
  const host = String(nextHost || "").trim();
  if (!host) return content;
  return String(content || "").replace(/^Endpoint = (.+):([0-9]+)$/m, `Endpoint = ${host}:$2`);
}

async function backupPayload() {
  const conf = await readText(MAIN_CONF);
  const meta = await clientMeta();
  const peers = peerBlocks(conf).map((peer) => ({ name: peer.name, body: peer.body, disabled: peer.disabled }));
  const files = [];
  for (const peer of peers) files.push({ name: peer.name, content: await readText(path.join(CLIENT_DIR, `${peer.name}.conf`)) });
  const upstreams = (await readJson(UPSTREAMS_FILE, [])).map((item) => ({ ...item, configContent: fss.existsSync(item.configPath || "") ? fss.readFileSync(item.configPath, "utf8") : "" }));
  return {
    kind: "dd-awg-backup",
    version: 1,
    exportedAt: new Date().toISOString(),
    server: { endpoint: wg0Endpoint(conf), listenPort: wg0Port(conf), subnet: wg0Subnet(conf) },
    clients: { peers, meta, files },
    upstreams: { items: upstreams, defaultId: (await readText(DEFAULT_UPSTREAM_FILE)).trim() },
    settings: { health: await healthSettings(), telegram: await telegramSettings(), vpnBot: await vpnBotSettings(), vless: await vlessSettings(), trafficShaper: await trafficShaperSettings() }
  };
}

export async function exportConfig() {
  return backupPayload();
}

export async function analyzeImportConfig(payload = {}) {
  if (payload.kind !== "dd-awg-backup") throw new Error("Unsupported backup file");
  const currentEndpoint = wg0Endpoint(await readText(MAIN_CONF));
  const backupEndpoint = String(payload.server?.endpoint || "");
  const currentClients = new Set(peerBlocks(await readText(MAIN_CONF)).map((peer) => peer.name));
  const currentUpstreams = new Set((await readJson(UPSTREAMS_FILE, [])).flatMap((item) => [item.id, item.name].filter(Boolean)));
  return {
    ok: true,
    backupEndpoint,
    currentEndpoint,
    endpointChanged: Boolean(backupEndpoint && currentEndpoint && backupEndpoint !== currentEndpoint),
    counts: {
      clients: payload.clients?.peers?.length || 0,
      upstreams: payload.upstreams?.items?.length || 0,
      healthChecks: payload.settings?.health?.checks?.length || 0,
      tgAdmins: normalizeTelegramAdmins(payload.settings?.telegram || {}).length,
      trafficShaper: payload.settings?.trafficShaper ? 1 : 0,
      vpnBot: payload.settings?.vpnBot ? 1 : 0,
      vless: payload.settings?.vless ? 1 : 0
    },
    conflicts: {
      clients: (payload.clients?.peers || []).map((peer) => peer.name).filter((name) => currentClients.has(name)),
      upstreams: (payload.upstreams?.items || []).filter((item) => currentUpstreams.has(item.id) || currentUpstreams.has(item.name)).map((item) => item.name || item.id)
    }
  };
}

async function clearClientsConfig() {
  const conf = await readText(MAIN_CONF);
  let next = conf;
  for (const peer of peerBlocks(conf)) next = next.replace(peerBlockPattern(peer.name, peer.disabled), "");
  await writeMainConfig(next.trimEnd() + "\n");
  await writeClientMeta({});
  for (const file of await fs.readdir(CLIENT_DIR).catch(() => [])) if (file.endsWith(".conf")) await fs.rm(path.join(CLIENT_DIR, file), { force: true });
}

async function clearUpstreamsConfig() {
  const upstreams = await readJson(UPSTREAMS_FILE, []);
  for (const item of upstreams) await removeDedicatedUpstream(item).catch(() => null);
  for (const item of upstreams) if (item.configPath) await fs.rm(item.configPath, { force: true });
  await writeJson(UPSTREAMS_FILE, []);
  await writeText(DEFAULT_UPSTREAM_FILE, "");
}

export async function clearConfig({ clients = false, upstreams = false, settings = false } = {}) {
  if (clients) await clearClientsConfig();
  if (upstreams) await clearUpstreamsConfig();
  if (settings) {
    await healthSettings(DEFAULT_HEALTH);
    await telegramSettings({ enabled: false, token: "", chatId: "", notificationIntervalSeconds: 300, domain: "", serverName: "", adminUsernames: [] });
    await vpnBotSettings({ enabled: false, token: "", upstreamId: "" });
    await vlessSettings({ ...DEFAULT_VLESS, enabled: false });
    await trafficShaperSettings(DEFAULT_TRAFFIC_SHAPER);
    await setDefaultUpstream("direct");
  }
  if (clients || upstreams) await applyUpstreamTunnels().catch(() => null);
  else if (settings) {
    await applyUnifiedRouting().catch(() => null);
    await applyVlessService().catch(() => null);
    await applyTrafficShaping().catch(() => null);
  }
  return { ok: true };
}

export async function importConfig(payload = {}, options = {}) {
  if (payload.kind !== "dd-awg-backup") throw new Error("Unsupported backup file");
  const sections = options.sections || {};
  const conflict = options.conflict === "overwrite" ? "overwrite" : "skip";
  const replaceEndpoint = Boolean(options.replaceEndpoint);
  const currentEndpoint = wg0Endpoint(await readText(MAIN_CONF));
  const summary = { clients: { imported: 0, skipped: 0 }, upstreams: { imported: 0, skipped: 0 }, settings: false };
  if (sections.clients) {
    let conf = await readText(MAIN_CONF);
    const meta = await clientMeta();
    const files = new Map((payload.clients?.files || []).map((file) => [file.name, file.content || ""]));
    for (const peer of payload.clients?.peers || []) {
      const name = strictName(peer.name);
      const existing = peerBlocks(conf).find((item) => item.name === name);
      if (existing && conflict === "skip") { summary.clients.skipped++; continue; }
      if (existing) conf = conf.replace(peerBlockPattern(name, existing.disabled), "");
      conf = `${conf.trimEnd()}\n${peerTextFromBackup(peer)}`;
      meta[name] = payload.clients?.meta?.[name] || meta[name] || {};
      let content = files.get(name) || "";
      if (replaceEndpoint) content = replaceEndpointHost(content, currentEndpoint);
      if (content) await writeText(path.join(CLIENT_DIR, `${name}.conf`), content);
      summary.clients.imported++;
    }
    await writeMainConfig(conf.trimEnd() + "\n");
    await writeClientMeta(meta);
  }
  if (sections.upstreams) {
    let upstreams = await readJson(UPSTREAMS_FILE, []);
    for (const item of payload.upstreams?.items || []) {
      const name = strictName(item.name);
      const existingIndex = upstreams.findIndex((upstream) => upstream.id === item.id || upstream.name === name);
      if (existingIndex >= 0 && conflict === "skip") { summary.upstreams.skipped++; continue; }
      if (existingIndex >= 0) {
        await removeDedicatedUpstream(upstreams[existingIndex]).catch(() => null);
        if (upstreams[existingIndex].configPath) await fs.rm(upstreams[existingIndex].configPath, { force: true });
        upstreams.splice(existingIndex, 1);
      }
      const id = String(item.id || crypto.randomBytes(4).toString("hex")).replace(/[^0-9a-zA-Z]/g, "").slice(0, 8) || crypto.randomBytes(4).toString("hex");
      const configPath = path.join(UPSTREAM_DIR, `${id}.conf`);
      await writeText(configPath, normalizeUpstreamConfig(item.configContent || await readText(item.configPath || "")));
      const { isDefault, serverIp, configContent, ...rest } = item;
      upstreams.push({ ...rest, id, name, configPath, enabled: item.enabled !== false, priority: upstreams.length + 1 });
      summary.upstreams.imported++;
    }
    await writeJson(UPSTREAMS_FILE, upstreams);
    if (payload.upstreams?.defaultId === "direct" || upstreams.some((item) => item.id === payload.upstreams?.defaultId && item.enabled !== false)) await writeText(DEFAULT_UPSTREAM_FILE, payload.upstreams.defaultId);
  }
  if (sections.settings) {
    if (payload.settings?.health) await healthSettings(payload.settings.health);
    if (payload.settings?.telegram) await telegramSettings(payload.settings.telegram);
    if (payload.settings?.vpnBot) await vpnBotSettings(payload.settings.vpnBot);
    if (payload.settings?.vless) await vlessSettings(payload.settings.vless);
    if (payload.settings?.trafficShaper) await trafficShaperSettings(payload.settings.trafficShaper);
    summary.settings = true;
  }
  if (sections.clients || sections.upstreams) await applyUpstreamTunnels().catch(() => null);
  else if (sections.settings) await applyTrafficShaping().catch(() => null);
  return { ok: true, summary };
}

let previousCpuSnapshot = null;
let previousNetworkSnapshot = null;

async function readCpuSnapshot() {
  const first = (await fs.readFile("/proc/stat", "utf8")).split("\n")[0] || "";
  const values = first.trim().split(/\s+/).slice(1).map((value) => Number(value || 0));
  const idle = (values[3] || 0) + (values[4] || 0);
  const total = values.reduce((sum, value) => sum + value, 0);
  return { idle, total };
}

async function readNetworkSnapshot() {
  const text = await fs.readFile("/proc/net/dev", "utf8");
  let rx = 0;
  let tx = 0;
  for (const line of text.split("\n").slice(2)) {
    const [ifaceRaw, dataRaw] = line.split(":");
    const iface = String(ifaceRaw || "").trim();
    if (!/^(eth|ens)/.test(iface)) continue;
    const cols = String(dataRaw || "").trim().split(/\s+/).map((value) => Number(value || 0));
    rx += cols[0] || 0;
    tx += cols[8] || 0;
  }
  return { rx, tx };
}

export async function sampleSystemStats() {
  const cpu = await readCpuSnapshot().catch(() => null);
  const net = await readNetworkSnapshot().catch(() => null);
  const now = Date.now();
  let cpuUsage = 0;
  if (cpu && previousCpuSnapshot) {
    const totalDelta = Math.max(0, cpu.total - previousCpuSnapshot.total);
    const idleDelta = Math.max(0, cpu.idle - previousCpuSnapshot.idle);
    cpuUsage = totalDelta > 0 ? Math.max(0, Math.min(100, (1 - idleDelta / totalDelta) * 100)) : 0;
  }
  const netRx = net && previousNetworkSnapshot ? Math.max(0, net.rx - previousNetworkSnapshot.rx) : 0;
  const netTx = net && previousNetworkSnapshot ? Math.max(0, net.tx - previousNetworkSnapshot.tx) : 0;
  const intervalMs = net && previousNetworkSnapshot ? Math.max(1, now - (previousNetworkSnapshot.ts || now)) : 0;
  const netRxBps = intervalMs > 0 ? (netRx * 8) / (intervalMs / 1000) : 0;
  const netTxBps = intervalMs > 0 ? (netTx * 8) / (intervalMs / 1000) : 0;
  const netBps = netRxBps + netTxBps;
  if (cpu) previousCpuSnapshot = cpu;
  if (net) previousNetworkSnapshot = { ...net, ts: now };
  return { ts: now, cpu: cpuUsage, netRx, netTx, netBps, netRxBps, netTxBps };
}

function sustainedCpuPeak(samples = []) {
  const values = samples.map((sample) => Number(sample.cpu || 0)).filter((value) => Number.isFinite(value)).sort((a, b) => b - a);
  if (!values.length) return 0;
  return values[Math.min(values.length - 1, 4)] || 0;
}

function systemMinuteSample(samples = []) {
  if (!samples.length) return { cpu: 0, netRx: 0, netTx: 0, netBps: 0, netRxBps: 0, netTxBps: 0 };
  const netRx = samples.reduce((sum, sample) => sum + Number(sample.netRx || 0), 0);
  const netTx = samples.reduce((sum, sample) => sum + Number(sample.netTx || 0), 0);
  const firstTs = Number(samples[0]?.ts || Date.now());
  const lastTs = Number(samples[samples.length - 1]?.ts || firstTs);
  const durationSeconds = Math.max(1, (lastTs - firstTs + 1000) / 1000);
  return {
    cpu: sustainedCpuPeak(samples),
    netRx,
    netTx,
    netRxBps: (netRx * 8) / durationSeconds,
    netTxBps: (netTx * 8) / durationSeconds,
    netBps: ((netRx + netTx) * 8) / durationSeconds
  };
}

async function migrateLegacyStats(clients = []) {
  await ensureStatsDb();
  const migrated = await sqliteRows("SELECT value FROM meta WHERE key = 'legacy_stats_migrated' LIMIT 1;").catch(() => []);
  if (migrated[0]?.[0] === "1") return;
  const text = await readText(LEGACY_STATS_FILE);
  if (!text.trim()) {
    await sqliteExec("INSERT OR REPLACE INTO meta(key, value) VALUES ('legacy_stats_migrated', '1');");
    return;
  }
  const byPublicKey = new Map(clients.map((client) => [client.publicKey, client]));
  const values = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      const row = JSON.parse(line);
      const current = byPublicKey.get(row.publicKey);
      const id = current?.id || row.name || row.publicKey || "legacy";
      values.push(`(${sqlInt(row.ts)}, ${sqlText(id)}, ${sqlText(row.publicKey || "")}, ${sqlText(row.mode || "legacy")}, ${sqlInt(row.rx)}, ${sqlInt(row.tx)})`);
    } catch {}
  }
  for (let i = 0; i < values.length; i += 300) {
    await sqliteExec(`INSERT OR IGNORE INTO traffic_samples(ts, client_id, public_key, mode, rx, tx) VALUES ${values.slice(i, i + 300).join(",")};`, 60000);
  }
  await sqliteExec("INSERT OR REPLACE INTO meta(key, value) VALUES ('legacy_stats_migrated', '1');");
}

function statsRollupCutoffs(now = Date.now()) {
  return {
    raw: Math.floor((now - STATS_RAW_RETENTION_MS) / STATS_HALF_HOUR_MS) * STATS_HALF_HOUR_MS,
    halfHour: Math.floor((now - STATS_HALF_HOUR_RETENTION_MS) / STATS_HOUR_MS) * STATS_HOUR_MS,
    hour: Math.floor((now - STATS_HOUR_RETENTION_MS) / STATS_DAY_MS) * STATS_DAY_MS
  };
}

export async function compactStats(now = Date.now()) {
  await ensureStatsDb();
  const cutoff = statsRollupCutoffs(now);
  const marker = await sqliteRows("SELECT value FROM meta WHERE key = 'stats_rollup_cutoff' LIMIT 1;").catch(() => []);
  if (Number(marker[0]?.[0] || 0) >= cutoff.raw) return;
  await sqliteExec(`
BEGIN IMMEDIATE;
DROP TABLE IF EXISTS temp.traffic_rollup_batch;
CREATE TEMP TABLE traffic_rollup_batch AS
WITH candidates AS (
  SELECT ts, client_id, mode, rx, tx
  FROM traffic_samples
  WHERE ts < ${cutoff.raw}
),
ordered AS (
  SELECT
    ts,
    client_id,
    mode,
    rx,
    tx,
    LAG(rx) OVER (PARTITION BY client_id, mode ORDER BY ts) AS previous_rx,
    LAG(tx) OVER (PARTITION BY client_id, mode ORDER BY ts) AS previous_tx
  FROM candidates
),
with_state AS (
  SELECT
    ordered.*,
    COALESCE(ordered.previous_rx, state.rx) AS effective_previous_rx,
    COALESCE(ordered.previous_tx, state.tx) AS effective_previous_tx
  FROM ordered
  LEFT JOIN traffic_rollup_state AS state
    ON state.client_id = ordered.client_id AND state.mode = ordered.mode
)
SELECT
  ts,
  (ts / ${STATS_HALF_HOUR_MS}) * ${STATS_HALF_HOUR_MS} AS bucket,
  client_id,
  mode,
  rx,
  tx,
  CASE
    WHEN effective_previous_rx IS NULL OR effective_previous_tx IS NULL THEN 0
    ELSE MAX(0, rx - effective_previous_rx) + MAX(0, tx - effective_previous_tx)
  END AS bytes
FROM with_state;

INSERT INTO traffic_30m(bucket, client_id, mode, bytes)
SELECT bucket, client_id, mode, SUM(bytes)
FROM traffic_rollup_batch
GROUP BY bucket, client_id, mode
ON CONFLICT(bucket, client_id, mode) DO UPDATE SET
  bytes = traffic_30m.bytes + excluded.bytes;

WITH latest AS (
  SELECT
    ts,
    client_id,
    mode,
    rx,
    tx,
    ROW_NUMBER() OVER (PARTITION BY client_id, mode ORDER BY ts DESC) AS recency
  FROM traffic_rollup_batch
)
INSERT INTO traffic_rollup_state(client_id, mode, ts, rx, tx)
SELECT client_id, mode, ts, rx, tx
FROM latest
WHERE recency = 1
ON CONFLICT(client_id, mode) DO UPDATE SET
  ts = excluded.ts,
  rx = excluded.rx,
  tx = excluded.tx;

DELETE FROM traffic_samples WHERE ts < ${cutoff.raw};

INSERT INTO system_30m(bucket, cpu_sum, net_rx, net_tx, net_bps_sum, net_rx_bps_sum, net_tx_bps_sum, sample_count)
SELECT
  (ts / ${STATS_HALF_HOUR_MS}) * ${STATS_HALF_HOUR_MS},
  SUM(cpu),
  SUM(net_rx),
  SUM(net_tx),
  SUM(net_bps),
  SUM(net_rx_bps),
  SUM(net_tx_bps),
  COUNT(*)
FROM system_samples
WHERE ts < ${cutoff.raw}
GROUP BY ts / ${STATS_HALF_HOUR_MS}
ON CONFLICT(bucket) DO UPDATE SET
  cpu_sum = system_30m.cpu_sum + excluded.cpu_sum,
  net_rx = system_30m.net_rx + excluded.net_rx,
  net_tx = system_30m.net_tx + excluded.net_tx,
  net_bps_sum = system_30m.net_bps_sum + excluded.net_bps_sum,
  net_rx_bps_sum = system_30m.net_rx_bps_sum + excluded.net_rx_bps_sum,
  net_tx_bps_sum = system_30m.net_tx_bps_sum + excluded.net_tx_bps_sum,
  sample_count = system_30m.sample_count + excluded.sample_count;

DELETE FROM system_samples WHERE ts < ${cutoff.raw};

INSERT INTO traffic_hourly(hour, client_id, mode, bytes)
SELECT (bucket / ${STATS_HOUR_MS}) * ${STATS_HOUR_MS}, client_id, mode, SUM(bytes)
FROM traffic_30m
WHERE bucket < ${cutoff.halfHour}
GROUP BY bucket / ${STATS_HOUR_MS}, client_id, mode
ON CONFLICT(hour, client_id, mode) DO UPDATE SET
  bytes = traffic_hourly.bytes + excluded.bytes;
DELETE FROM traffic_30m WHERE bucket < ${cutoff.halfHour};

INSERT INTO system_hourly(hour, cpu_sum, net_rx, net_tx, net_bps_sum, net_rx_bps_sum, net_tx_bps_sum, sample_count)
SELECT
  (bucket / ${STATS_HOUR_MS}) * ${STATS_HOUR_MS},
  SUM(cpu_sum),
  SUM(net_rx),
  SUM(net_tx),
  SUM(net_bps_sum),
  SUM(net_rx_bps_sum),
  SUM(net_tx_bps_sum),
  SUM(sample_count)
FROM system_30m
WHERE bucket < ${cutoff.halfHour}
GROUP BY bucket / ${STATS_HOUR_MS}
ON CONFLICT(hour) DO UPDATE SET
  cpu_sum = system_hourly.cpu_sum + excluded.cpu_sum,
  net_rx = system_hourly.net_rx + excluded.net_rx,
  net_tx = system_hourly.net_tx + excluded.net_tx,
  net_bps_sum = system_hourly.net_bps_sum + excluded.net_bps_sum,
  net_rx_bps_sum = system_hourly.net_rx_bps_sum + excluded.net_rx_bps_sum,
  net_tx_bps_sum = system_hourly.net_tx_bps_sum + excluded.net_tx_bps_sum,
  sample_count = system_hourly.sample_count + excluded.sample_count;
DELETE FROM system_30m WHERE bucket < ${cutoff.halfHour};

INSERT INTO traffic_daily(day, client_id, mode, bytes)
SELECT (hour / ${STATS_DAY_MS}) * ${STATS_DAY_MS}, client_id, mode, SUM(bytes)
FROM traffic_hourly
WHERE hour < ${cutoff.hour}
GROUP BY hour / ${STATS_DAY_MS}, client_id, mode
ON CONFLICT(day, client_id, mode) DO UPDATE SET
  bytes = traffic_daily.bytes + excluded.bytes;
DELETE FROM traffic_hourly WHERE hour < ${cutoff.hour};

INSERT INTO system_daily(day, cpu_sum, net_rx, net_tx, net_bps_sum, net_rx_bps_sum, net_tx_bps_sum, sample_count)
SELECT
  (hour / ${STATS_DAY_MS}) * ${STATS_DAY_MS},
  SUM(cpu_sum),
  SUM(net_rx),
  SUM(net_tx),
  SUM(net_bps_sum),
  SUM(net_rx_bps_sum),
  SUM(net_tx_bps_sum),
  SUM(sample_count)
FROM system_hourly
WHERE hour < ${cutoff.hour}
GROUP BY hour / ${STATS_DAY_MS}
ON CONFLICT(day) DO UPDATE SET
  cpu_sum = system_daily.cpu_sum + excluded.cpu_sum,
  net_rx = system_daily.net_rx + excluded.net_rx,
  net_tx = system_daily.net_tx + excluded.net_tx,
  net_bps_sum = system_daily.net_bps_sum + excluded.net_bps_sum,
  net_rx_bps_sum = system_daily.net_rx_bps_sum + excluded.net_rx_bps_sum,
  net_tx_bps_sum = system_daily.net_tx_bps_sum + excluded.net_tx_bps_sum,
  sample_count = system_daily.sample_count + excluded.sample_count;
DELETE FROM system_hourly WHERE hour < ${cutoff.hour};

INSERT OR REPLACE INTO meta(key, value) VALUES ('stats_rollup_cutoff', '${cutoff.raw}');
DROP TABLE traffic_rollup_batch;
COMMIT;
PRAGMA optimize;
`, 120000);
  statsCache.clear();
}

export async function collectStats(systemSamples = []) {
  await ensureStatsDb();
  const clients = await listClients();
  await migrateLegacyStats(clients);
  const now = Date.now();
  const trafficValues = [];
  for (const client of clients) {
    for (const [mode, value] of [["direct", client.direct], ["upstream", client.upstream]]) {
      if (!value) continue;
      trafficValues.push(`(${now}, ${sqlText(client.id || client.publicKey)}, ${sqlText(client.publicKey)}, ${sqlText(mode)}, ${sqlInt(value.rx)}, ${sqlInt(value.tx)})`);
    }
  }
  const system = systemMinuteSample(systemSamples.length ? systemSamples : [await sampleSystemStats()]);
  const statements = [
    "BEGIN IMMEDIATE;",
    `INSERT OR REPLACE INTO system_samples(ts, cpu, net_rx, net_tx, net_bps, net_rx_bps, net_tx_bps) VALUES (${now}, ${sqlReal(system.cpu)}, ${sqlInt(system.netRx)}, ${sqlInt(system.netTx)}, ${sqlReal(system.netBps)}, ${sqlReal(system.netRxBps)}, ${sqlReal(system.netTxBps)});`
  ];
  if (trafficValues.length) {
    statements.push(`INSERT OR REPLACE INTO traffic_samples(ts, client_id, public_key, mode, rx, tx) VALUES ${trafficValues.join(",")};`);
  }
  statements.push("COMMIT;");
  await sqliteExec(statements.join("\n"), 60000);
  statsCache.clear();
  await compactStats(now);
}

function rangeStart(range, scope = "summary") {
  const now = Date.now();
  if (scope === "chart") {
    if (range === "1m") return now - 24 * 60 * 60 * 1000;
    if (range === "10m") return now - 7 * 24 * 60 * 60 * 1000;
    if (range === "30m") return now - 14 * 24 * 60 * 60 * 1000;
    if (range === "1h") return now - 14 * 24 * 60 * 60 * 1000;
    if (range === "1d") return now - 30 * 24 * 60 * 60 * 1000;
    if (range === "hour") return now - 14 * 24 * 60 * 60 * 1000;
    if (range === "day" || range === "month") return now - 30 * 24 * 60 * 60 * 1000;
    return now - 30 * 24 * 60 * 60 * 1000;
  }
  if (range === "hour") return now - 60 * 60 * 1000;
  if (range === "day") return now - 24 * 60 * 60 * 1000;
  if (range === "week") return now - 7 * 24 * 60 * 60 * 1000;
  if (range === "month") return now - 30 * 24 * 60 * 60 * 1000;
  return 0;
}

function bucketSize(range, scope = "summary") {
  if (scope === "chart") {
    if (range === "1m") return 60 * 1000;
    if (range === "10m") return 10 * 60 * 1000;
    if (range === "30m") return 30 * 60 * 1000;
    if (range === "1h") return 60 * 60 * 1000;
    if (range === "1d") return 24 * 60 * 60 * 1000;
    if (range === "hour") return 60 * 60 * 1000;
    if (range === "day") return 24 * 60 * 60 * 1000;
    if (range === "month") return 6 * 60 * 60 * 1000;
    return 6 * 60 * 60 * 1000;
  }
  if (range === "hour") return 60 * 1000;
  if (range === "day") return 5 * 60 * 1000;
  if (range === "week") return 60 * 60 * 1000;
  if (range === "month") return 6 * 60 * 60 * 1000;
  return 24 * 60 * 60 * 1000;
}

function pointList(map, valueKey = "bytes") {
  return [...map.entries()].sort((a, b) => Number(a[0]) - Number(b[0])).map(([ts, value]) => ({ ts: new Date(Number(ts)).toISOString(), [valueKey]: value }));
}

async function computeStats(range = "all", scope = "summary") {
  await ensureStatsDb();
  const start = rangeStart(range, scope);
  const bucket = bucketSize(range, scope);
  const cutoffs = statsRollupCutoffs();
  const rawWhere = start ? `WHERE samples.ts >= ${start}` : "";
  const halfHourWhere = start ? `WHERE bucket >= ${Math.floor(start / STATS_HALF_HOUR_MS) * STATS_HALF_HOUR_MS}` : "";
  const hourWhere = start ? `WHERE hour >= ${Math.floor(start / STATS_HOUR_MS) * STATS_HOUR_MS}` : "";
  const dayWhere = start ? `WHERE day >= ${Math.floor(start / STATS_DAY_MS) * STATS_DAY_MS}` : "";
  const includeRollupBaseline = !start || start < cutoffs.raw;
  const rows = await sqliteRows(`
WITH raw_ordered AS (
  SELECT
    samples.ts,
    samples.client_id,
    samples.mode,
    samples.rx,
    samples.tx,
    LAG(samples.rx) OVER (PARTITION BY samples.client_id, samples.mode ORDER BY samples.ts) AS previous_rx,
    LAG(samples.tx) OVER (PARTITION BY samples.client_id, samples.mode ORDER BY samples.ts) AS previous_tx,
    ROW_NUMBER() OVER (PARTITION BY samples.client_id, samples.mode ORDER BY samples.ts DESC) AS recency,
    state.rx AS rollup_rx,
    state.tx AS rollup_tx
  FROM traffic_samples AS samples
  LEFT JOIN traffic_rollup_state AS state
    ON state.client_id = samples.client_id AND state.mode = samples.mode
  ${rawWhere}
),
raw_deltas AS (
  SELECT
    ts,
    client_id,
    mode,
    recency,
    CASE
      WHEN previous_rx IS NULL AND ${includeRollupBaseline ? 1 : 0} = 1 AND rollup_rx IS NOT NULL
        THEN MAX(0, rx - rollup_rx) + MAX(0, tx - rollup_tx)
      WHEN previous_rx IS NULL OR previous_tx IS NULL THEN 0
      ELSE MAX(0, rx - previous_rx) + MAX(0, tx - previous_tx)
    END AS bytes
  FROM raw_ordered
),
traffic_events AS (
  SELECT day AS ts, client_id, mode, bytes, 0 AS live
  FROM traffic_daily
  ${dayWhere}
  UNION ALL
  SELECT hour, client_id, mode, bytes, 0
  FROM traffic_hourly
  ${hourWhere}
  UNION ALL
  SELECT bucket, client_id, mode, bytes, 0
  FROM traffic_30m
  ${halfHourWhere}
  UNION ALL
  SELECT ts, client_id, mode, bytes, CASE WHEN recency = 1 THEN bytes ELSE 0 END
  FROM raw_deltas
),
system_events AS (
  SELECT
    day AS ts,
    cpu_sum,
    net_rx,
    net_tx,
    net_bps_sum,
    net_rx_bps_sum,
    net_tx_bps_sum,
    sample_count
  FROM system_daily
  ${dayWhere}
  UNION ALL
  SELECT hour, cpu_sum, net_rx, net_tx, net_bps_sum, net_rx_bps_sum, net_tx_bps_sum, sample_count
  FROM system_hourly
  ${hourWhere}
  UNION ALL
  SELECT bucket, cpu_sum, net_rx, net_tx, net_bps_sum, net_rx_bps_sum, net_tx_bps_sum, sample_count
  FROM system_30m
  ${halfHourWhere}
  UNION ALL
  SELECT
    ts,
    cpu,
    net_rx,
    net_tx,
    net_bps,
    net_rx_bps,
    net_tx_bps,
    1
  FROM system_samples AS samples
  ${rawWhere}
)
SELECT 'user', client_id, SUM(bytes), SUM(live), 0, 0, 0, 0, 0
FROM traffic_events
GROUP BY client_id
UNION ALL
SELECT 'bucket', CAST((ts / ${bucket}) * ${bucket} AS TEXT), SUM(bytes), 0, 0, 0, 0, 0, 0
FROM traffic_events
GROUP BY ts / ${bucket}
UNION ALL
SELECT 'system', CAST((ts / ${bucket}) * ${bucket} AS TEXT),
  SUM(cpu_sum) / MAX(1, SUM(sample_count)),
  SUM(net_rx),
  SUM(net_tx),
  SUM(net_bps_sum) / MAX(1, SUM(sample_count)),
  SUM(net_rx_bps_sum) / MAX(1, SUM(sample_count)),
  SUM(net_tx_bps_sum) / MAX(1, SUM(sample_count)),
  0
FROM system_events
GROUP BY ts / ${bucket};
`, 60000);
  const users = {};
  const liveUsers = {};
  const buckets = new Map();
  const systemRows = [];
  for (const [kind, key, first, second, third, fourth, fifth, sixth] of rows) {
    if (kind === "user") {
      users[key] = Number(first || 0);
      liveUsers[key] = Number(second || 0);
    } else if (kind === "bucket") {
      buckets.set(Number(key), Number(first || 0));
    } else if (kind === "system") {
      systemRows.push([key, first, second, third, fourth, fifth, sixth]);
    }
  }
  const cpuBuckets = new Map();
  const networkBuckets = new Map();
  const networkRxBuckets = new Map();
  const networkTxBuckets = new Map();
  const networkBpsBuckets = new Map();
  const networkRxBpsBuckets = new Map();
  const networkTxBpsBuckets = new Map();
  const gigabit = 1000 * 1000 * 1000;
  for (const [tsRaw, cpuRaw, rxRaw, txRaw, bpsRaw, rxBpsRaw, txBpsRaw] of systemRows) {
    const ts = Number(tsRaw);
    const cpu = Number(cpuRaw || 0);
    const rx = Number(rxRaw || 0);
    const tx = Number(txRaw || 0);
    const bps = Number(bpsRaw || 0);
    const rxBps = Number(rxBpsRaw || 0);
    const txBps = Number(txBpsRaw || 0);
    cpuBuckets.set(ts, cpu);
    networkRxBuckets.set(ts, rx);
    networkTxBuckets.set(ts, tx);
    networkBuckets.set(ts, rx + tx);
    networkBpsBuckets.set(ts, bps);
    networkRxBpsBuckets.set(ts, rxBps);
    networkTxBpsBuckets.set(ts, txBps);
  }
  return {
    total: Object.values(users).reduce((sum, value) => sum + value, 0),
    users,
    liveUsers,
    points: pointList(buckets, "bytes"),
    system: {
      cpuPoints: pointList(cpuBuckets, "value"),
      networkPoints: [...networkBuckets.entries()].sort((a, b) => Number(a[0]) - Number(b[0])).map(([ts, bytes]) => ({
        ts: new Date(Number(ts)).toISOString(),
        bytes,
        bps: networkBpsBuckets.get(ts) || 0,
        value: Math.max(0, Math.min(100, ((networkBpsBuckets.get(ts) || 0) / gigabit) * 100)),
        inbound: Math.max(0, Math.min(100, ((networkRxBpsBuckets.get(ts) || 0) / gigabit) * 100)),
        outbound: Math.max(0, Math.min(100, ((networkTxBpsBuckets.get(ts) || 0) / gigabit) * 100)),
        rxBps: networkRxBpsBuckets.get(ts) || 0,
        txBps: networkTxBpsBuckets.get(ts) || 0,
        rx: networkRxBuckets.get(ts) || 0,
        tx: networkTxBuckets.get(ts) || 0
      }))
    },
    db: "sqlite"
  };
}

export async function stats(range = "all", scope = "summary") {
  const key = `${range}:${scope}`;
  const now = Date.now();
  const cached = statsCache.get(key);
  if (cached?.value && cached.expiresAt > now) return cached.value;
  if (cached?.promise) return cached.promise;
  const promise = computeStats(range, scope).then((value) => {
    statsCache.set(key, { value, expiresAt: Date.now() + STATS_CACHE_MS });
    return value;
  }).catch((error) => {
    statsCache.delete(key);
    throw error;
  });
  statsCache.set(key, { promise, expiresAt: 0 });
  return promise;
}
DD_WG_CP_OPT_WG_WEB_APP_APP_LIB_CORE_MJS_EOF
	mkdir -p "$(dirname "/opt/wg-web/app/app/api/[[...path]]/route.js")"
	cat > '/opt/wg-web/app/app/api/[[...path]]/route.js' <<'DD_WG_CP_OPT_WG_WEB_APP_APP_API_PATH_ROUTE_JS_EOF'
import {
  shaPassword,
  signSession,
  verifySession,
  listClients,
  createClient,
  updateClient,
  setClientEnabled,
  setClientSpeedLimit,
  setClientDefaultOut,
  extendClientSubscription,
  cancelClientSubscription,
  removeClient,
  rebuildIngressAddressing,
  clientConfig,
  clientQr,
  botAuthorize,
  botUpstreams,
  botClientConfig,
  botClientQr,
  botAdminInfo,
  botAdminClientConfig,
  botAdminClientQr,
  listUpstreams,
  createUpstream,
  updateUpstreams,
  deleteUpstream,
  routingSettings,
  healthSettings,
  probeHealthService,
  telegramSettings,
  vpnBotSettings,
  vlessSettings,
  detectVlessHost,
  trafficShaperSettings,
  applyTrafficShaping,
  requestCertificate,
  certbotLog,
  exportConfig,
  analyzeImportConfig,
  importConfig,
  clearConfig,
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
    if (path[1] === "admin") {
      const username = url.searchParams.get("username") || "";
      const admin = await botAdminInfo(username);
      if (method === "GET" && path[2] === "me") return json(admin);
      if (!admin.admin) throw new Error("Unauthorized");
      if (method === "GET" && path[2] === "clients" && path[3] && path[4] === "config") {
        const result = await botAdminClientConfig(path[3], url.searchParams.get("mode") || "", url.searchParams.get("upstreamId") || "", url.searchParams.get("protocol") || "");
        return new Response(result.content, {
          headers: {
            "Cache-Control": "no-store",
            "Content-Type": "text/plain; charset=utf-8",
            "Content-Disposition": `attachment; filename="${result.filename}"`
          }
        });
      }
      if (method === "GET" && path[2] === "clients" && path[3] && path[4] === "qr") return json(await botAdminClientQr(path[3], url.searchParams.get("mode") || "", url.searchParams.get("upstreamId") || "", url.searchParams.get("protocol") || ""));
      if (method === "GET" && path[2] === "clients") return json(await listClients());
      if (method === "GET" && path[2] === "upstreams") return json(await listUpstreams());
      if (method === "POST" && path[2] === "clients" && path[3] && path[4] === "subscription" && path[5] === "extend") {
        const body = await req.json();
        return json(await extendClientSubscription(path[3], body.plan, body.customUntil));
      }
      if (method === "POST" && path[2] === "clients" && path[3] && path[4] === "subscription" && path[5] === "cancel") return json(await cancelClientSubscription(path[3]));
      if (method === "POST" && path[2] === "clients") return json(await createClient(await req.json()));
      if (method === "PATCH" && path[2] === "clients" && path[3] && path[4] === "enabled") return json(await setClientEnabled(path[3], (await req.json()).enabled));
      if (method === "PATCH" && path[2] === "clients" && path[3]) return json(await updateClient(path[3], await req.json()));
      if (method === "DELETE" && path[2] === "clients" && path[3]) return json(await removeClient(path[3]));
      return json({ error: "Not found" }, 404);
    }
    return json({ error: "Not found" }, 404);
  }
  await requireAuth(req);
  await enforceSubscriptions().catch(() => null);
  if (method === "GET" && path[0] === "me") return json({ user: process.env.ADMIN_USER || "admin" });
  if (method === "GET" && path[0] === "config" && path[1] === "export") return json(await exportConfig());
  if (method === "POST" && path[0] === "config" && path[1] === "import" && path[2] === "analyze") return json(await analyzeImportConfig(await req.json()));
  if (method === "POST" && path[0] === "config" && path[1] === "import") {
    const body = await req.json();
    return json(await importConfig(body.backup, body.options));
  }
  if (method === "POST" && path[0] === "config" && path[1] === "clear") return json(await clearConfig(await req.json()));
  if (method === "GET" && path[0] === "clients" && path[1] && path[2] === "config") {
    const url = new URL(req.url);
    const mode = url.searchParams.get("mode") || "";
    const requestedProtocol = url.searchParams.get("protocol");
    const protocol = requestedProtocol === "vless" ? "vless" : requestedProtocol === "awg" ? "awg" : "wg";
    const transport = url.searchParams.get("transport") || "";
    const suffix = `${mode === "default" ? "-default" : mode === "upstream" ? "-upstream" : ""}${protocol === "vless" ? `-${transport || "vless"}` : protocol === "awg" ? "-awg" : "-wg"}`;
    return new Response(await clientConfig(path[1], mode, url.searchParams.get("upstreamId") || "", protocol, false, transport), {
      headers: {
        "Cache-Control": "no-store",
        "Content-Type": "text/plain; charset=utf-8",
        "Content-Disposition": `attachment; filename="${path[1]}${suffix}.${protocol === "vless" ? "txt" : "conf"}"`
      }
    });
  }
  if (method === "GET" && path[0] === "clients" && path[1] && path[2] === "qr") {
    const url = new URL(req.url);
    const requestedProtocol = url.searchParams.get("protocol");
    const protocol = requestedProtocol === "vless" ? "vless" : requestedProtocol === "awg" ? "awg" : "wg";
    return json({ dataUrl: await clientQr(path[1], url.searchParams.get("mode") || "", url.searchParams.get("upstreamId") || "", protocol, false, url.searchParams.get("transport") || "") });
  }
  if (method === "GET" && path[0] === "clients") return json(await listClients());
  if (method === "POST" && path[0] === "clients" && path[1] && path[2] === "subscription" && path[3] === "extend") {
    const body = await req.json();
    return json(await extendClientSubscription(path[1], body.plan, body.customUntil));
  }
  if (method === "POST" && path[0] === "clients" && path[1] && path[2] === "subscription" && path[3] === "cancel") return json(await cancelClientSubscription(path[1]));
  if (method === "POST" && path[0] === "clients") return json(await createClient(await req.json()));
  if (method === "PATCH" && path[0] === "clients" && path[1] && path[2] === "enabled") return json(await setClientEnabled(path[1], (await req.json()).enabled));
  if (method === "PATCH" && path[0] === "clients" && path[1] && path[2] === "speed-limit") return json(await setClientSpeedLimit(path[1], await req.json()));
  if (method === "PATCH" && path[0] === "clients" && path[1] && path[2] === "default-out") return json(await setClientDefaultOut(path[1], await req.json()));
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
  if (method === "GET" && path[0] === "settings" && path[1] === "routing") return json(await routingSettings());
  if (method === "POST" && path[0] === "settings" && path[1] === "routing") return json(await routingSettings(await req.json()));
  if (method === "POST" && path[0] === "health-check") return json(await runHealthCheck());
  if (method === "GET" && path[0] === "settings" && path[1] === "health") return json(await healthSettings());
  if (method === "POST" && path[0] === "settings" && path[1] === "health" && path[2] === "probe") return json(await probeHealthService((await req.json()).url));
  if (method === "POST" && path[0] === "settings" && path[1] === "health") return json(await healthSettings(await req.json()));
  if (method === "GET" && path[0] === "settings" && path[1] === "telegram") return json(await telegramSettings());
  if (method === "POST" && path[0] === "settings" && path[1] === "telegram") return json(await telegramSettings(await req.json()));
  if (method === "GET" && path[0] === "settings" && path[1] === "vpn-bot") return json(await vpnBotSettings());
  if (method === "POST" && path[0] === "settings" && path[1] === "vpn-bot") return json(await vpnBotSettings(await req.json()));
  if (method === "GET" && path[0] === "settings" && path[1] === "vless" && path[2] === "detect-ip") return json(await detectVlessHost());
  if (method === "GET" && path[0] === "settings" && path[1] === "vless") return json(await vlessSettings());
  if (method === "POST" && path[0] === "settings" && path[1] === "vless") return json(await vlessSettings(await req.json()));
  if (method === "GET" && path[0] === "settings" && path[1] === "traffic-shaper") return json(await trafficShaperSettings());
  if (method === "POST" && path[0] === "settings" && path[1] === "traffic-shaper") {
    const result = await trafficShaperSettings(await req.json());
    await applyTrafficShaping();
    return json(result);
  }
  if (method === "POST" && path[0] === "settings" && path[1] === "rebuild-ingress-addressing") return json(await rebuildIngressAddressing());
  if (method === "GET" && path[0] === "settings" && path[1] === "certbot") return json(await certbotLog());
  if (method === "POST" && path[0] === "settings" && path[1] === "certbot") return json(await requestCertificate(await req.json()));
  if (method === "GET" && path[0] === "stats") {
    const url = new URL(req.url);
    return json(await stats(url.searchParams.get("range") || "all", url.searchParams.get("scope") || "summary"));
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
DD_WG_CP_OPT_WG_WEB_APP_APP_API_PATH_ROUTE_JS_EOF
	mkdir -p "$(dirname "/opt/wg-web/app/worker.js")"
	cat > '/opt/wg-web/app/worker.js' <<'DD_WG_CP_OPT_WG_WEB_APP_WORKER_JS_EOF'
import { applyUpstreamTunnels, collectStats, compactStats, enforceSubscriptions, healthSettings, runHealthCheck, sampleSystemStats } from "./app/lib/core.mjs";

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function statsLoop() {
  let minuteStartedAt = Date.now();
  let samples = [];
  while (true) {
    try {
      samples.push(await sampleSystemStats());
      if (Date.now() - minuteStartedAt >= 60000) {
        await collectStats(samples);
        samples = [];
        minuteStartedAt = Date.now();
      }
    } catch (error) {
      console.error("stats:", error.message);
    }
    await delay(1000);
  }
}

async function subscriptionsLoop() {
  while (true) {
    try { await enforceSubscriptions(); } catch (error) { console.error("subscriptions:", error.message); }
    await delay(60000);
  }
}

async function healthLoop() {
  while (true) {
    try { await runHealthCheck(); } catch (error) { console.error("health:", error.message); }
    const settings = await healthSettings().catch(() => ({ intervalSeconds: 60 }));
    await delay(Math.max(15, Number(settings.intervalSeconds || 60)) * 1000);
  }
}

async function boot() {
  try { await compactStats(); } catch (error) { console.error("stats compact:", error.message); }
  try { await applyUpstreamTunnels(); } catch (error) { console.error("apply:", error.message); }
  statsLoop();
  subscriptionsLoop();
  healthLoop();
}

boot();
DD_WG_CP_OPT_WG_WEB_APP_WORKER_JS_EOF
	mkdir -p "$(dirname "/opt/wg-web/app/app/page.js")"
	cat > '/opt/wg-web/app/app/page.js' <<'DD_WG_CP_OPT_WG_WEB_APP_APP_PAGE_JS_EOF'
"use client";

import { useEffect, useMemo, useState } from "react";

const namePattern = /^[A-Za-z0-9-]{1,14}$/;
const awgKeys = ["Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4", "I1"];
const dict = {
  en: {
    overview: "Overview", clients: "Clients", upstreams: "Upstreams", settings: "Settings", refresh: "Refresh",
    subtitle: "Production WireGuard/AWG management, routing and traffic analytics.", traffic: "Traffic", active: "Active",
    period: "Period", "1m": "1m", "10m": "10m", "30m": "30m", "1h": "1h", "1d": "1d", hour: "1H", day: "1D", week: "7d", month: "30D", all: "All time", dynamics: "Traffic dynamics",
    topClients: "Top clients", noStats: "Statistics will appear after traffic samples are collected.", name: "Name",
    comment: "Comment", endpoint: "Endpoint", live: "Live RX/TX", newClient: "New client", createClient: "Create client",
    edit: "Edit", save: "Save", delete: "Delete", copy: "Copy", copied: "Copied", download: ".conf",
    newUpstream: "New upstream", upload: "Upload config", makeDefault: "Set default", disable: "Disable", enable: "Enable",
    notifications: "Notifications", down: "Down", recovered: "Recovered", qr: "QR", health: "Health checks",
    addService: "Add service", url: "URL", fetch: "Fetch data", confirm: "Confirm expected data", remove: "Remove",
    interval: "Check interval", telegram: "Telegram", domainCert: "Domain and certificate", domain: "Domain",
    serverName: "Server Name",
    cert: "Get certificate", certLog: "Certificate log", botToken: "Bot token", chatId: "Chat ID", signIn: "Sign in",
    password: "Admin password", healthy: "Healthy", failed: "Down", pending: "Pending", serverIp: "Server IP",
    nameRule: "Use 1-14 characters: English letters, numbers and hyphen only.", lastActive: "Last active", never: "Never",
    subscription: "Subscription", expiresAt: "Valid until", accessKey: "Access key", extendSubscription: "Extend subscription",
    cancelSubscription: "Cancel subscription", unlimited: "Unlimited", expired: "Expired", activeSubscription: "Active",
    choosePeriod: "Choose period", annul: "Annul", custom: "Custom", customUntil: "Valid until date",
    progress: "Operation in progress", exitNow: "Exit now", timedOut: "Operation timed out after 90 seconds",
    preparing: "Preparing request", applying: "Applying changes", refreshingData: "Refreshing data", completed: "Completed",
    updatingRoute: "Updating client route", generatingConfig: "Generating config", generatingQr: "Generating QR code",
    copyingConfig: "Copying config", downloadingConfig: "Downloading config",
    protocol: "Protocol", route: "Route", direct: "DIRECT", defaultRoute: "DEFAULT", generate: "Generate",
    show: "Show", hide: "Hide", ipAddress: "IP", chooseConfig: "Choose config", tgAdmin: "Telegram admin",
    tgAdminHint: "Username without @. These Telegram users will get admin access in the bot.",
    backup: "Backup", exportConfig: "Export JSON", importConfig: "Import JSON", clearConfig: "Clear config",
    importOptions: "Import options", overwrite: "Overwrite conflicts", skip: "Skip conflicts", replaceEndpoint: "Replace client endpoints with this server endpoint",
    clientsSection: "Clients", upstreamsSection: "Upstreams", settingsSection: "Settings", clearWarning: "This will remove selected data. Export a backup first.",
    analytics: "Analytics", routing: "Routing", servers: "Servers", logout: "Logout", searchClients: "Search clients...",
    status: "Status", disabled: "Disabled", selected: "Selected", bulkExtend: "Extend subscription", newClientCta: "New Client",
    ipAddressFull: "IP Address", validUntil: "Valid Until", actions: "Actions", copyConfig: "Copy config", moreActions: "More actions",
    trafficCaption: "Traffic during selected period", clientsCaption: "Total clients", activeCaption: "Currently active", periodCaption: "Reporting window",
    hardResetIps: "Rebuild ingress addressing", hardResetIpsHint: "Migrates all AWG/WG ingress subnets to the new IP plan and rewrites peer addresses. Client devices must be reconfigured.",
    healthCheckEndpoints: "Health check endpoints", expectedResponse: "Expected response", removeEndpoint: "Remove endpoint",
    telegramNotifications: "Telegram Notifications", telegramBotAdmin: "Telegram Bot Admin", domainCertificate: "Domain & Certificate",
    vpnBot: "VPN Bot", telegramApiRoute: "Telegram API route", directTelegramApi: "Direct Telegram API", botService: "Bot service",
    vpnBotHint: "Subscription bot for users. It can route Telegram API traffic through one of your upstream tunnels.",
    notificationsHint: "Operational alerts for upstream health and maintenance events.",
    backupConfiguration: "Backup & Configuration", dangerousActions: "Dangerous Actions", maintenanceActions: "Maintenance actions",
    dangerSettingsHint: "These actions can interrupt users or remove configuration. Use them carefully.",
    controlPlane: "Control plane settings", settingsIntro: "Configure monitoring, Telegram automation, certificates and maintenance from one operational workspace.",
    monitoring: "Monitoring", monitoringHint: "Track upstream availability with lightweight HTTP checks.",
    telegramHint: "Notifications and bot administrator access share the same Telegram integration.",
    domainHint: "Issue and inspect HTTPS certificates for the public admin endpoint.",
    backupHint: "Move configuration between servers or keep a restorable snapshot.",
    trafficShaping: "Traffic shaping", trafficShapingHint: "Per-client kernel-level HTB + fq_codel limits shared across WG, AWG and VLESS.",
    globalSpeedLimit: "Global speed limit", personalSpeedLimit: "Set personal speed limit", speedLimit: "Speed limit",
    speedMbit: "Speed, Mbit/s", shapingEnabled: "Shaping enabled", usePersonalLimit: "Use personal limit",
    effectiveLimit: "Effective limit", globalLimitHint: "Default applies to both input and output for every active client.",
    showQr: "Show QR", downloadConf: "Download .conf", copySettings: "Copy settings", standardRoutes: "Standard routes", upstreamRoutes: "Upstream routes",
    recommended: "Recommended", nativeCompatible: "Native compatible", autoRoute: "Auto route", directServer: "Direct server",
    cpuUsage: "CPU Usage", networkUsage: "Network Usage", trafficUsage: "Traffic Usage", analyticsTable: "Client traffic",
    periodUsage: "Period usage", currentUsage: "Current usage", perMinute: "/min", sqliteStorage: "SQLite analytics storage",
    vless: "VLESS", vlessHint: "Shared Reality ingress ports with per-user routing and traffic shaping.", sniDomain: "SNI domain",
    publicHost: "Public host", detectIp: "Detect IP", realityTcp: "Reality TCP", xhttpReality: "xHTTP Reality", transport: "Transport", realityKeys: "Reality keys",
    port: "Port", individualDefaultOut: "Set individual default out", useGlobalDefault: "Use global default", currentOut: "Current OUT"
  },
  ru: {
    overview: "Обзор", clients: "Клиенты", upstreams: "Upstreams", settings: "Настройки", refresh: "Обновить",
    subtitle: "Панель управления WireGuard/AWG: доступы, маршруты и аналитика трафика.", traffic: "Трафик", active: "Активные",
    period: "Период", "1m": "1м", "10m": "10м", "30m": "30м", "1h": "1ч", "1d": "1д", hour: "1ч", day: "1д", week: "7д", month: "30д", all: "Все время", dynamics: "Динамика трафика",
    topClients: "Топ клиентов", noStats: "Статистика появится после первых замеров трафика.", name: "Имя",
    comment: "Комментарий", endpoint: "Endpoint", live: "Live RX/TX", newClient: "Новый клиент", createClient: "Создать клиента",
    edit: "Редактировать", save: "Сохранить", delete: "Удалить", copy: "Копировать", copied: "Скопировано",
    download: ".conf", newUpstream: "Новый upstream", upload: "Загрузить конфиг", makeDefault: "Сделать default",
    disable: "Отключить", enable: "Включить", notifications: "Уведомления", down: "Падение", recovered: "Восстановление",
    qr: "QR", health: "Проверочные сервисы", addService: "Добавить сервис", url: "URL", fetch: "Получить данные",
    confirm: "Подтвердить ожидаемые данные", remove: "Удалить", interval: "Интервал проверки", telegram: "Telegram",
    domainCert: "Домен и сертификат", domain: "Домен", serverName: "Имя сервера", cert: "Получить сертификат", certLog: "Лог сертификата",
    botToken: "Bot token", chatId: "Chat ID", signIn: "Войти", password: "Пароль администратора", healthy: "Работает",
    failed: "Недоступен", pending: "Ожидает", serverIp: "IP сервера",
	    nameRule: "Используйте 1-14 символов: английские буквы, цифры и дефис.", lastActive: "Последняя активность", never: "Никогда",
	    subscription: "Подписка", expiresAt: "Действует до", accessKey: "Ключ доступа", extendSubscription: "Продлить подписку",
	    cancelSubscription: "Аннулировать подписку", unlimited: "Анлим", expired: "Истекла", activeSubscription: "Активна",
	    choosePeriod: "Выберите срок", annul: "Аннулировать", custom: "CUSTOM", customUntil: "Действует до даты",
	    progress: "Выполняется операция", exitNow: "Выйти сейчас", timedOut: "Операция превысила 90 секунд",
	    preparing: "Подготовка запроса", applying: "Применение изменений", refreshingData: "Обновление данных", completed: "Готово",
	    updatingRoute: "Обновление маршрута клиента", generatingConfig: "Формирование конфига", generatingQr: "Формирование QR-кода",
	    copyingConfig: "Копирование конфига", downloadingConfig: "Скачивание конфига",
	    protocol: "Протокол", route: "Маршрут", direct: "DIRECT", defaultRoute: "DEFAULT", generate: "Сформировать",
	    show: "Показать", hide: "Скрыть", ipAddress: "IP", chooseConfig: "Выбор конфига", tgAdmin: "Telegram админ",
	    tgAdminHint: "Username без @. Эти пользователи Telegram получат админ-доступ в боте.",
	    backup: "Бэкап", exportConfig: "Экспорт JSON", importConfig: "Импорт JSON", clearConfig: "Очистить конфиг",
	    importOptions: "Настройки импорта", overwrite: "Перезаписать конфликты", skip: "Пропустить конфликты", replaceEndpoint: "Заменить endpoint клиентов на endpoint этого сервера",
	    clientsSection: "Клиенты", upstreamsSection: "Upstreams", settingsSection: "Настройки", clearWarning: "Выбранные данные будут удалены. Сначала сделайте экспорт.",
	    analytics: "Аналитика", routing: "Маршруты", servers: "Серверы", logout: "Выйти", searchClients: "Поиск клиентов...",
	    status: "Статус", disabled: "Отключен", selected: "Выбрано", bulkExtend: "Продлить подписку", newClientCta: "Новый клиент",
	    ipAddressFull: "IP адрес", validUntil: "Действует до", actions: "Действия", copyConfig: "Копировать конфиг", moreActions: "Еще действия",
	    trafficCaption: "Трафик за выбранный период", clientsCaption: "Всего клиентов", activeCaption: "Активны сейчас", periodCaption: "Окно статистики",
	    hardResetIps: "Rebuild ingress addressing", hardResetIpsHint: "Мигрирует все AWG/WG ingress подсети на новый IP-план и переписывает peer IP. Клиентские устройства нужно перенастроить.",
	    healthCheckEndpoints: "Health check endpoints", expectedResponse: "Expected response", removeEndpoint: "Remove endpoint",
	    telegramNotifications: "Telegram Notifications", telegramBotAdmin: "Telegram Bot Admin", domainCertificate: "Domain & Certificate",
	    vpnBot: "VPN Bot", telegramApiRoute: "Маршрут Telegram API", directTelegramApi: "Telegram API напрямую", botService: "Сервис бота",
	    vpnBotHint: "Бот подписок для пользователей. Может отправлять трафик Telegram API через один из upstream-туннелей.",
	    notificationsHint: "Операционные уведомления о состоянии upstream и событиях обслуживания.",
	    backupConfiguration: "Backup & Configuration", dangerousActions: "Dangerous Actions", maintenanceActions: "Maintenance actions",
	    dangerSettingsHint: "Эти действия могут отключить пользователей или удалить конфигурацию. Используйте осторожно.",
	    controlPlane: "Control plane settings", settingsIntro: "Настройки мониторинга, Telegram, сертификатов и обслуживания в одном рабочем экране.",
	    monitoring: "Monitoring", monitoringHint: "Проверяйте доступность upstream через легкие HTTP health checks.",
	    telegramHint: "Уведомления и администраторы бота используют одну Telegram-интеграцию.",
	    domainHint: "Выпуск и просмотр HTTPS-сертификата для публичной панели.",
	    backupHint: "Переносите конфигурацию между серверами или храните восстановимый снимок.",
	    trafficShaping: "Traffic shaping", trafficShapingHint: "Персональные kernel-level лимиты HTB + fq_codel, общие для WG, AWG и VLESS.",
	    globalSpeedLimit: "Глобальный лимит скорости", personalSpeedLimit: "Set personal speed limit", speedLimit: "Лимит скорости",
	    speedMbit: "Скорость, Mbit/s", shapingEnabled: "Шейпер включен", usePersonalLimit: "Использовать персональный лимит",
	    effectiveLimit: "Итоговый лимит", globalLimitHint: "По умолчанию применяется на вход и выход для каждого активного клиента.",
	    showQr: "Показать QR", downloadConf: "Скачать .conf", copySettings: "Копировать настройки", standardRoutes: "Стандартные маршруты", upstreamRoutes: "Upstream маршруты",
	    recommended: "Рекомендуется", nativeCompatible: "Совместим с WG", autoRoute: "Автоматический маршрут", directServer: "Прямой сервер",
	    cpuUsage: "CPU Usage", networkUsage: "Network Usage", trafficUsage: "Traffic Usage", analyticsTable: "Трафик клиентов",
	    periodUsage: "Расход за период", currentUsage: "Текущее потребление", perMinute: "/мин", sqliteStorage: "Хранилище аналитики SQLite",
	    vless: "VLESS", vlessHint: "Общие Reality ingress-порты с индивидуальной маршрутизацией и шейпингом.", sniDomain: "SNI домен",
	    publicHost: "Публичный host", detectIp: "Detect IP", realityTcp: "Reality TCP", xhttpReality: "xHTTP Reality", transport: "Транспорт", realityKeys: "Reality ключи",
	    port: "Порт", individualDefaultOut: "Индивидуальный default OUT", useGlobalDefault: "Использовать глобальный default", currentOut: "Текущий OUT"
  }
};
const ranges = { hour: "hour", day: "day", week: "week", month: "month", all: "all" };
const dnsPresets = [["8.8.8.8, 8.8.4.4", "Google"], ["1.1.1.1, 1.0.0.1", "Cloudflare"], ["208.67.222.222, 208.67.220.220", "OpenDNS"], ["9.9.9.9, 149.112.112.112", "Quad9"], ["95.85.95.85, 2.56.220.2", "Gcore"], ["94.140.14.14, 94.140.15.15", "AdGuard"]];
const notifyIntervals = [[60, "1 min"], [300, "5 min"], [900, "15 min"], [3600, "1 h"], [21600, "6 h"], [43200, "12 h"], [86400, "24 h"]];
const planIds = ["7d", "1m", "3m", "6m", "12m", "24m"];
const planLabels = {
  en: { "7d": "7d", "1m": "1 mo", "3m": "3 mo", "6m": "6 mo", "12m": "12 mo", "24m": "24 mo", unlimited: "Unlimited", custom: "Custom" },
  ru: { "7d": "7д", "1m": "1м", "3m": "3м", "6m": "6м", "12m": "12м", "24m": "24м", unlimited: "Анлим", custom: "CUSTOM" }
};
function subscriptionPlans(lang, extras = []) {
  const labels = planLabels[lang] || planLabels.en;
  return [...planIds, ...extras].map((id) => [id, labels[id] || id]);
}

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
function timeLabel(ts) {
  const date = new Date(ts);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleString([], { month: "short", day: "2-digit", hour: "2-digit", minute: "2-digit" });
}
function Chart({ points, empty, formatValue = bytes, valueKey = "bytes", suffix = "", maxValue = null, series = null }) {
  const [hover, setHover] = useState(null);
  const [zoom, setZoom] = useState(1);
  const [drag, setDrag] = useState(null);
  const p = points || [];
  if (!p.length) return <div className="chart axis-chart empty-chart">{empty}</div>;
  const baseWidth = Math.max(720, p.length * 18);
  const width = Math.min(14000, Math.max(720, baseWidth * zoom));
  const height = 260, left = 96, right = 20, top = 18, bottom = 44;
  const innerW = width - left - right;
  const innerH = height - top - bottom;
  const activeSeries = series?.length ? series : [{ key: valueKey, label: "", color: "#4CC38A" }];
  const values = activeSeries.flatMap((item) => p.map((x) => Number(x[item.key] ?? x[valueKey] ?? x.bytes ?? 0)));
  const max = Number(maxValue || 0) > 0 ? Number(maxValue) : Math.max(...values, 1);
  const x = (i) => left + (p.length < 2 ? 0 : i / (p.length - 1) * innerW);
  const y = (value) => top + innerH - (Number(value || 0) / max) * innerH;
  const lineFor = (key) => p.map((point, i) => `${i ? "L" : "M"} ${x(i).toFixed(2)} ${y(point[key] ?? point[valueKey] ?? point.bytes).toFixed(2)}`).join(" ");
  const line = lineFor(activeSeries[0].key);
  const area = `${line} L ${left + innerW} ${top + innerH} L ${left} ${top + innerH} Z`;
  const hoverIndex = hover === null ? p.length - 1 : hover;
  const hoverPoint = p[hoverIndex] || p[p.length - 1];
  const ticks = [0, 0.5, 1].map((ratio) => ({ ratio, value: max * ratio }));
  const labels = [0, Math.floor((p.length - 1) / 2), p.length - 1].filter((item, index, arr) => arr.indexOf(item) === index);
  function zoomChart(event) {
    event.preventDefault();
    const next = Math.max(0.18, Math.min(8, zoom * (event.deltaY > 0 ? 0.86 : 1.16)));
    setZoom(next);
  }
  function startDrag(event) {
    if (event.button !== 0) return;
    setDrag({ x: event.clientX, scrollLeft: event.currentTarget.scrollLeft });
  }
  function moveDrag(event) {
    if (!drag) return;
    event.currentTarget.scrollLeft = drag.scrollLeft - (event.clientX - drag.x);
  }
  return <div className={`chart-wrap ${drag ? "dragging" : ""}`}><div className="chart-scroll" onWheel={zoomChart} onMouseDown={startDrag} onMouseMove={moveDrag} onMouseUp={() => setDrag(null)} onMouseLeave={() => { setHover(null); setDrag(null); }}><svg className="chart axis-chart" viewBox={`0 0 ${width} ${height}`} style={{ width: "100%", minWidth: `${width}px` }} role="img">{ticks.map((tick) => <g key={tick.ratio}><line x1={left} x2={left + innerW} y1={y(tick.value)} y2={y(tick.value)} className="chart-grid" /><text x={left - 10} y={y(tick.value) + 4} textAnchor="end" className="chart-axis">{formatValue(tick.value)}{suffix}</text></g>)}{labels.map((index) => <text key={index} x={x(index)} y={height - 12} textAnchor={index === 0 ? "start" : index === p.length - 1 ? "end" : "middle"} className="chart-axis">{timeLabel(p[index]?.ts)}</text>)}<path d={area} className="chart-area" />{activeSeries.map((item) => <path key={item.key} d={lineFor(item.key)} className="chart-line" style={{ stroke: item.color || "#4CC38A" }} />)}{p.map((point, index) => <rect key={`${point.ts}-${index}`} x={x(index) - Math.max(3, innerW / Math.max(1, p.length) / 2)} y={top} width={Math.max(6, innerW / Math.max(1, p.length))} height={innerH} fill="transparent" onMouseEnter={() => setHover(index)} />)}{hoverPoint && <g><line x1={x(hoverIndex)} x2={x(hoverIndex)} y1={top} y2={top + innerH} className="chart-cursor" />{activeSeries.map((item) => <circle key={item.key} cx={x(hoverIndex)} cy={y(hoverPoint?.[item.key] ?? hoverPoint?.[valueKey] ?? hoverPoint?.bytes)} r="4" className="chart-dot" style={{ fill: item.color || "#4CC38A" }} />)}</g>}</svg></div>{hoverPoint && <div className="chart-tooltip">{activeSeries.map((item) => <b key={item.key}><span className="chart-swatch" style={{ background: item.color || "#4CC38A" }} />{item.label ? `${item.label}: ` : ""}{formatValue(hoverPoint?.[item.key] ?? hoverPoint?.[valueKey] ?? hoverPoint?.bytes)}{suffix}</b>)}<span>{timeLabel(hoverPoint.ts)}</span></div>}</div>;
}
function Modal({ title, children, onClose }) {
  return <div className="modal-backdrop"><div className="modal panel"><div className="panel-title"><h2>{title}</h2><button type="button" onClick={onClose}>x</button></div>{children}</div></div>;
}
function Icon({ name }) {
  const paths = {
    users: "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2 M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8 M22 21v-2a4 4 0 0 0-3-3.87 M16 3.13a4 4 0 0 1 0 7.75",
    chart: "M3 3v18h18 M7 14l4-4 4 4 5-7",
    route: "M6 19a3 3 0 1 1 0-6h12a3 3 0 1 0 0-6H8 M8 7l-3-3 3-3 M16 17l3 3-3 3",
    server: "M4 6h16v5H4z M4 13h16v5H4z M7 8h.01 M7 15h.01",
    gear: "M12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7z M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06A1.65 1.65 0 0 0 15 19.4a1.65 1.65 0 0 0-1 .6 1.65 1.65 0 0 0-.38 1.07V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 8.6 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.6 15a1.65 1.65 0 0 0-.6-1 1.65 1.65 0 0 0-1.07-.38H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 8.6a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.6a1.65 1.65 0 0 0 1-.6 1.65 1.65 0 0 0 .38-1.07V3a2 2 0 1 1 4 0v.09A1.65 1.65 0 0 0 15.4 4.6a1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9c.19.36.38.7.6 1 .32.2.69.31 1.07.32H21a2 2 0 1 1 0 4h-.09A1.65 1.65 0 0 0 19.4 15z",
    refresh: "M21 12a9 9 0 0 1-15.5 6.25L3 16 M3 21v-5h5 M3 12A9 9 0 0 1 18.5 5.75L21 8 M21 3v5h-5",
    plus: "M12 5v14 M5 12h14",
    calendar: "M8 2v4 M16 2v4 M3 10h18 M5 4h14a2 2 0 0 1 2 2v14H3V6a2 2 0 0 1 2-2z",
    transfer: "M7 7h14 M17 3l4 4-4 4 M17 17H3 M7 13l-4 4 4 4",
    qr: "M4 4h6v6H4z M14 4h6v6h-6z M4 14h6v6H4z M14 14h2v2h-2z M18 14h2v6h-4v-2h2z M14 18h2v2h-2z",
    download: "M12 3v12 M7 10l5 5 5-5 M5 21h14",
    copy: "M8 8h11v11H8z M5 16H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h11a1 1 0 0 1 1 1v1",
    edit: "M12 20h9 M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z",
    more: "M12 12h.01 M19 12h.01 M5 12h.01",
    eye: "M1 12s4-7 11-7 11 7 11 7-4 7-11 7S1 12 1 12z M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6",
    logout: "M10 17l5-5-5-5 M15 12H3 M21 3v18"
  };
  return <svg className="icon" viewBox="0 0 24 24" aria-hidden="true"><path d={paths[name] || paths.more} /></svg>;
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
  const [view, setView] = useState("clients");
  const [range, setRange] = useState("all");
  const [chartRange, setChartRange] = useState("1h");
  const [chartTab, setChartTab] = useState("cpu");
  const [clients, setClients] = useState([]);
  const [upstreams, setUpstreams] = useState([]);
  const [routing, setRouting] = useState({ defaultId: "direct" });
  const [stat, setStat] = useState({ total: 0, users: {}, liveUsers: {}, points: [], system: { cpuPoints: [], networkPoints: [] } });
  const [chartStat, setChartStat] = useState({ points: [], system: { cpuPoints: [], networkPoints: [] } });
  const [telegram, setTelegram] = useState({ enabled: false, token: "", chatId: "", notificationIntervalSeconds: 300, domain: "", serverName: "", adminUsername: "" });
  const [vpnBot, setVpnBot] = useState({ enabled: false, token: "", upstreamId: "", serviceActive: false, telegramApiRouteActive: false });
  const [vless, setVless] = useState({ enabled: false, publicHost: "", sniDomain: "", publicKey: "", shortId: "", serviceActive: false, transports: { realityTcp: { enabled: true, port: 443 }, xhttpReality: { enabled: false, port: 8433, path: "/dd-awg-xhttp", mode: "auto" } } });
  const [telegramTab, setTelegramTab] = useState("notifications");
  const [trafficShaper, setTrafficShaper] = useState({ enabled: true, mbps: 20 });
  const [health, setHealth] = useState({ intervalSeconds: 60, checks: [] });
  const [probe, setProbe] = useState({ url: "", data: "" });
  const [certLog, setCertLog] = useState("");
  const [modal, setModal] = useState(null);
  const [target, setTarget] = useState({});
  const [qr, setQr] = useState(null);
  const [error, setError] = useState("");
  const [progress, setProgress] = useState(null);
  const [newSubscription, setNewSubscription] = useState("1m");
  const [revealedKeys, setRevealedKeys] = useState({});
  const [newTgAdmin, setNewTgAdmin] = useState("");
  const [clientSearch, setClientSearch] = useState("");
  const [clientStatusFilter, setClientStatusFilter] = useState("all");
  const [selectedClients, setSelectedClients] = useState({});
  const [openClientMenu, setOpenClientMenu] = useState("");

  function setLanguage(next) { setLang(next); document.cookie = `wg_lang=${next}; Path=/; Max-Age=31536000; SameSite=Lax`; }
  function validateName(value) { if (!namePattern.test(String(value || ""))) { window.alert(t.nameRule); return false; } return true; }
  async function run(fn) { try { setError(""); await fn(); } catch (err) { setError(err.message); window.alert(err.message); } }
  function addProgressLog(text) {
    setProgress((prev) => prev ? { ...prev, logs: [...prev.logs, `${new Date().toLocaleTimeString()} - ${text}`] } : prev);
  }
  async function withProgress(title, steps, fn) {
    const id = globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const stamp = () => new Date().toLocaleTimeString();
    setError("");
    setProgress({ id, title, logs: [`${stamp()} - ${t.preparing}`, ...(steps || []).map((step) => `${stamp()} - ${step}`)], done: false });
    let timer;
    const timeout = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(t.timedOut)), 90000);
    });
    try {
      const result = await Promise.race([(async () => {
        const value = await fn();
        addProgressLog(t.completed);
        return value;
      })(), timeout]);
      setTimeout(() => setProgress((prev) => prev?.id === id ? null : prev), 450);
      return result;
    } catch (err) {
      addProgressLog(`ERROR: ${err.message}`);
      setError(err.message);
      setProgress((prev) => prev?.id === id ? { ...prev, done: true, error: err.message } : prev);
      setTimeout(() => setProgress((prev) => prev?.id === id ? null : prev), 1200);
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }
  async function refresh(check = false) {
    if (check) await api("health-check", { method: "POST" }).catch(() => null);
    const [c, u, r, s, g] = await Promise.all([api("clients"), api("upstreams"), api("settings/routing"), api(`stats?range=${range}`), api(`stats?range=${chartRange}&scope=chart`)]);
    setClients(c); setUpstreams(u); setRouting(r); setStat(s); setChartStat(g);
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
    api("settings/vpn-bot").then(setVpnBot).catch(() => {});
    api("settings/vless").then(setVless).catch(() => {});
    api("settings/traffic-shaper").then(setTrafficShaper).catch(() => {});
    api("settings/certbot").then((r) => setCertLog(r.log || "")).catch(() => {});
    const timer = setInterval(() => refresh(true).catch((e) => setError(e.message)), 60000);
    return () => clearInterval(timer);
  }, [authed, range, chartRange]);
  useEffect(() => {
    if (typeof document === "undefined") return;
    const name = String(telegram.serverName || "").trim();
    document.title = name ? `${name} WG Control Panel` : "DD WG Control Panel";
  }, [telegram.serverName]);

  async function login(e) { e.preventDefault(); await run(async () => { await api("login", { method: "POST", body: JSON.stringify({ password }) }); setAuthed(true); }); }
  async function addClient(e) {
    e.preventDefault(); const formEl = e.currentTarget; const form = new FormData(formEl); const name = form.get("name");
    if (!validateName(name)) return;
    await run(async () => await withProgress(`${t.createClient}: ${name}`, [t.applying, t.refreshingData], async () => {
      await api("clients", { method: "POST", body: JSON.stringify({ name, dns: form.get("dns"), comment: form.get("comment"), subscription: form.get("subscription"), customUntil: form.get("customUntil") }) });
      formEl.reset(); setNewSubscription("1m"); setModal(null); await refreshAfterMutation();
    }));
  }
  async function addUpstream(e) {
    e.preventDefault(); const formEl = e.currentTarget; const form = new FormData(formEl);
    if (!validateName(form.get("name"))) return;
    await run(async () => await withProgress(`${t.upload}: ${form.get("name")}`, [t.applying, t.refreshingData], async () => { await api("upstreams", { method: "POST", body: form }); formEl.reset(); setModal(null); await refreshAfterMutation(); }));
  }
  async function saveEntity() {
    if (!validateName(modal.name)) return;
    await run(async () => {
      await withProgress(`${t.save}: ${modal.name}`, [t.applying, t.refreshingData], async () => {
        if (modal?.type === "client") await api(`clients/${modal.item.name}`, { method: "PATCH", body: JSON.stringify({ name: modal.name, comment: modal.comment, awg: modal.awg }) });
        if (modal?.type === "upstream") await api("upstreams", { method: "PATCH", body: JSON.stringify({ update: { id: modal.item.id, name: modal.name, comment: modal.comment } }) });
        setModal(null); await refresh(true);
      });
    });
  }
  async function saveNotify() { await run(async () => { await api("upstreams", { method: "PATCH", body: JSON.stringify({ notify: { id: modal.item.id, down: modal.down, recovered: modal.recovered } }) }); setModal(null); await refresh(); }); }
  async function probeUrl() { await run(async () => { const result = await api("settings/health/probe", { method: "POST", body: JSON.stringify({ url: probe.url }) }); setProbe({ url: result.url, data: result.expected }); }); }
  function healthChecks() { return Array.isArray(health.checks) ? health.checks : []; }
  async function confirmProbe() { await run(async () => { const next = { ...health, checks: [...healthChecks(), { url: probe.url, expected: probe.data }].slice(0, 10) }; setHealth(next); setProbe({ url: "", data: "" }); setModal(null); await api("settings/health", { method: "POST", body: JSON.stringify(next) }); }); }
  async function removeCheck(index) { await run(async () => { const next = { ...health, checks: healthChecks().filter((_, i) => i !== index) }; setHealth(next); await api("settings/health", { method: "POST", body: JSON.stringify(next) }); }); }
  async function saveTelegram() { await run(async () => { await api("settings/telegram", { method: "POST", body: JSON.stringify(telegram) }); }); }
  async function saveVpnBot() {
    await run(async () => await withProgress(t.vpnBot, [t.applying, t.refreshingData], async () => {
      const next = await api("settings/vpn-bot", { method: "POST", body: JSON.stringify(vpnBot) });
      setVpnBot(next);
      await refresh(true);
    }));
  }
  async function saveVless() {
    await run(async () => await withProgress(t.vless, [t.applying, t.refreshingData], async () => {
      const next = await api("settings/vless", { method: "POST", body: JSON.stringify(vless) });
      setVless(next);
      await refresh(true);
    }));
  }
  async function detectVlessIp() {
    await run(async () => {
      const result = await api("settings/vless/detect-ip");
      setVless((prev) => ({ ...prev, publicHost: result.publicHost || "" }));
    });
  }
  async function saveTrafficShaper() {
    await run(async () => await withProgress(t.trafficShaping, [t.applying, t.refreshingData], async () => {
      const next = await api("settings/traffic-shaper", { method: "POST", body: JSON.stringify(trafficShaper) });
      setTrafficShaper(next);
      await refresh(false);
    }));
  }
  async function savePersonalSpeedLimit() {
    await run(async () => await withProgress(`${t.personalSpeedLimit}: ${modal.item.name}`, [t.applying, t.refreshingData], async () => {
      await api(`clients/${modal.item.name}/speed-limit`, { method: "PATCH", body: JSON.stringify({ enabled: modal.enabled, mbps: modal.mbps }) });
      setModal(null);
      await refresh(false);
    }));
  }
  async function saveIndividualDefaultOut() {
    await run(async () => await withProgress(`${t.individualDefaultOut}: ${modal.item.name}`, [t.applying, t.refreshingData], async () => {
      await api(`clients/${modal.item.name}/default-out`, { method: "PATCH", body: JSON.stringify({ protocol: modal.item.route?.protocol || "wg", mode: modal.mode, upstreamId: modal.upstreamId || "" }) });
      setModal(null);
      await refresh(false);
    }));
  }
  async function setGlobalDefault(defaultId) {
    await run(async () => await withProgress(`${t.makeDefault}: ${defaultId === "direct" ? t.direct : upstreams.find((item) => item.id === defaultId)?.name || defaultId}`, [t.applying, t.refreshingData], async () => {
      const next = await api("settings/routing", { method: "POST", body: JSON.stringify({ defaultId }) });
      setRouting(next);
      await refresh(true);
    }));
  }
  async function getCert() { await run(async () => { const result = await api("settings/certbot", { method: "POST", body: JSON.stringify({ domain: telegram.domain }) }); setCertLog(result.log || ""); await api("settings/telegram", { method: "POST", body: JSON.stringify(telegram) }); }); }
  function tgAdmins() {
    const raw = Array.isArray(telegram.adminUsernames) ? telegram.adminUsernames : typeof telegram.adminUsernames === "string" ? telegram.adminUsernames.split(/[,\s]+/) : [];
    if (telegram.adminUsername) raw.push(telegram.adminUsername);
    return [...new Set(raw.map((item) => String(item || "").trim().replace(/^@+/, "").toLowerCase()).filter(Boolean))];
  }
  async function addTgAdmin() {
    const value = newTgAdmin.trim().replace(/^@+/, "").toLowerCase();
    if (!value) return;
    await run(async () => {
      const next = { ...telegram, adminUsername: telegram.adminUsername || value, adminUsernames: [...new Set([...tgAdmins(), value])] };
      setTelegram(next);
      setNewTgAdmin("");
      await api("settings/telegram", { method: "POST", body: JSON.stringify(next) });
    });
  }
  async function removeTgAdmin(name) {
    await run(async () => {
      const admins = tgAdmins().filter((item) => item !== name);
      const next = { ...telegram, adminUsername: admins[0] || "", adminUsernames: admins };
      setTelegram(next);
      await api("settings/telegram", { method: "POST", body: JSON.stringify(next) });
    });
  }
  async function exportBackup() {
    await run(async () => {
      const data = await api("config/export");
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url; a.download = `dd-awg-backup-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-")}.json`; a.click();
      URL.revokeObjectURL(url);
    });
  }
  async function chooseImportFile(e) {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;
    await run(async () => {
      const backup = JSON.parse(await file.text());
      const analysis = await api("config/import/analyze", { method: "POST", body: JSON.stringify(backup) });
      setModal({ type: "import", backup, analysis, sections: { clients: true, upstreams: true, settings: true }, conflict: "skip", replaceEndpoint: analysis.endpointChanged });
    });
  }
  async function runImport() {
    await run(async () => await withProgress(t.importConfig, [t.applying, t.refreshingData], async () => {
      await api("config/import", { method: "POST", body: JSON.stringify({ backup: modal.backup, options: { sections: modal.sections, conflict: modal.conflict, replaceEndpoint: modal.replaceEndpoint } }) });
      setModal(null); await refreshAfterMutation();
      api("settings/health").then(setHealth).catch(() => {});
      api("settings/telegram").then(setTelegram).catch(() => {});
      api("settings/vless").then(setVless).catch(() => {});
      api("settings/traffic-shaper").then(setTrafficShaper).catch(() => {});
    }));
  }
  async function runClearConfig() {
    if (!window.confirm(t.clearWarning)) return;
    await run(async () => await withProgress(t.clearConfig, [t.applying, t.refreshingData], async () => {
      await api("config/clear", { method: "POST", body: JSON.stringify(modal.sections) });
      setModal(null); await refreshAfterMutation();
      api("settings/health").then(setHealth).catch(() => {});
      api("settings/telegram").then(setTelegram).catch(() => {});
      api("settings/vless").then(setVless).catch(() => {});
      api("settings/traffic-shaper").then(setTrafficShaper).catch(() => {});
    }));
  }
  async function setClientEnabled(client, enabled) { await run(async () => await withProgress(`${enabled ? t.enable : t.disable}: ${client.name}`, [t.applying, t.refreshingData], async () => { await api(`clients/${client.name}/enabled`, { method: "PATCH", body: JSON.stringify({ enabled }) }); await refresh(true); })); }
  async function extendSubscription() {
    if ((modal.plan || "1m") === "custom" && !modal.customUntil) { window.alert(t.customUntil); return; }
    await run(async () => {
      await withProgress(`${t.extendSubscription}: ${modal.item.name}`, [t.applying, t.refreshingData], async () => {
      await api(`clients/${modal.item.name}/subscription/extend`, { method: "POST", body: JSON.stringify({ plan: modal.plan || "1m", customUntil: modal.customUntil || "" }) });
      setModal(null);
      await refreshAfterMutation();
      });
    });
  }
  async function cancelSubscription(client) {
    if (!window.confirm(t.cancelSubscription + "?")) return;
    await run(async () => await withProgress(`${t.cancelSubscription}: ${client.name}`, [t.applying, t.refreshingData], async () => { await api(`clients/${client.name}/subscription/cancel`, { method: "POST" }); await refreshAfterMutation(); }));
  }
  function targetOptions() {
    return [
      { value: "direct", label: "WG DIRECT" },
      { value: "default", label: "WG DEFAULT" },
      ...upstreams.map((u) => ({ value: `upstream:${u.id}`, label: `WG ${u.name}` })),
      { value: "awg-direct", label: "AWG DIRECT" },
      { value: "awg-default", label: "AWG DEFAULT" },
      ...upstreams.map((u) => ({ value: `awg-upstream:${u.id}`, label: `AWG ${u.name}` }))
    ];
  }
  function routeOptions() {
    return [{ mode: "default", upstreamId: "", label: t.defaultRoute }, { mode: "direct", upstreamId: "", label: t.direct }, ...upstreams.map((u) => ({ mode: "upstream", upstreamId: u.id, label: u.name }))];
  }
  function outLabel(route = {}) {
    if (route.mode === "direct") return t.direct;
    if (route.mode === "upstream") return upstreams.find((item) => item.id === route.upstreamId)?.name || route.upstreamId || t.defaultRoute;
    return `${t.defaultRoute} → ${routing.defaultId === "direct" ? t.direct : upstreams.find((item) => item.id === routing.defaultId)?.name || t.direct}`;
  }
  function standardRouteOptions() {
    return [{ mode: "default", upstreamId: "", label: t.defaultRoute }, { mode: "direct", upstreamId: "", label: t.direct }];
  }
  function upstreamRouteOptions() {
    return upstreams.filter((item) => item.enabled).map((u, index) => ({ mode: "upstream", upstreamId: u.id, label: u.name || `UPSTREAM${index + 1}` }));
  }
  function vlessTransports() {
    return [
      { id: "realityTcp", label: t.realityTcp },
      { id: "xhttpReality", label: t.xhttpReality }
    ].filter((item) => vless.transports?.[item.id]?.enabled);
  }
  function updateVlessTransport(id, patch) {
    setVless((prev) => ({ ...prev, transports: { ...(prev.transports || {}), [id]: { ...(prev.transports?.[id] || {}), ...patch } } }));
  }
  function configActionMeta(m = modal) {
    if (m?.action === "qr") return { label: t.showQr, icon: "qr" };
    if (m?.action === "copy") return { label: t.copySettings, icon: "copy" };
    return { label: t.downloadConf, icon: "download" };
  }
  function configModalParams(m = modal) {
    const protocol = m?.protocol || "awg";
    const mode = m?.mode || "default";
    const upstreamId = m?.upstreamId || "";
    const transport = protocol === "vless" ? `&transport=${m?.transport || vlessTransports()[0]?.id || "realityTcp"}` : "";
    return `mode=${mode}&protocol=${protocol}${transport}${mode === "upstream" ? `&upstreamId=${upstreamId}` : ""}`;
  }
  function openConfig(client, action) { const route = client.route || {}; setModal({ type: "config", item: client, action, protocol: route.protocol || "awg", transport: vlessTransports()[0]?.id || "realityTcp", mode: route.mode || "default", upstreamId: route.upstreamId || "" }); }
  async function generateConfig() {
    if (!modal?.item) return;
    const current = { ...modal, item: modal.item };
    const query = configModalParams(current);
    const selectedRoute = { protocol: current.protocol || "awg", mode: current.mode || "default", upstreamId: current.mode === "upstream" ? current.upstreamId || "" : "" };
    await run(async () => await withProgress(`${configActionMeta(current).label}: ${current.item.name}`, [], async () => {
      addProgressLog(t.updatingRoute);
      await api(`clients/${current.item.name}/default-out`, { method: "PATCH", body: JSON.stringify(selectedRoute) });
      setClients((prev) => prev.map((item) => item.name === current.item.name ? { ...item, route: selectedRoute } : item));
      if (current.action === "qr") {
        addProgressLog(t.generatingQr);
        const r = await api(`clients/${current.item.name}/qr?${query}`);
        setQr({ title: current.item.name, dataUrl: r.dataUrl });
        setModal(null);
        return;
      }
      addProgressLog(t.generatingConfig);
      const res = await fetch(`/api/clients/${current.item.name}/config?${query}`, { cache: "no-store" });
      if (!res.ok) throw new Error("Config request failed");
      const content = await res.text();
      if (current.action === "copy") {
        addProgressLog(t.copyingConfig);
        await copyText(content);
        addProgressLog(t.copied);
        setModal(null);
        return;
      }
      addProgressLog(t.downloadingConfig);
      const disposition = res.headers.get("content-disposition") || "";
      const filename = disposition.match(/filename="([^"]+)"/)?.[1] || `${current.item.name}-${current.protocol || "awg"}.${(current.protocol || "awg") === "vless" ? "txt" : "conf"}`;
      const blob = new Blob([content], { type: "text/plain;charset=utf-8" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url; a.download = filename; a.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      setModal(null);
    }));
  }
  async function copyText(text) {
    if (navigator.clipboard?.writeText) {
      try { await navigator.clipboard.writeText(text); return; } catch {}
    }
    const area = document.createElement("textarea");
    area.value = text;
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.select();
    document.execCommand("copy");
    document.body.removeChild(area);
  }
  async function copyAccessKey(client) {
    await copyText(client.accessKey || "");
    window.alert(t.copied);
  }
  async function showQr(client) { openConfig(client, "qr"); }
  async function copyConfig(client, query = configModalParams({ protocol: "awg", mode: "default" })) {
    await run(async () => {
      const res = await fetch(`/api/clients/${client.name}/config?${query}`, { cache: "no-store" });
      if (!res.ok) throw new Error("Config request failed");
      await copyText(await res.text());
      window.alert(t.copied);
    });
  }
  async function logout() {
    await run(async () => { await api("logout", { method: "POST" }); setAuthed(false); });
  }
  function clientState(client) {
    if (client.subscription?.expired) return { key: "expired", label: t.expired };
    if (client.disabled) return { key: "disabled", label: t.disabled };
    return { key: "active", label: t.active };
  }
  function pageTitle() {
    if (view === "dashboard") return t.analytics;
    if (view === "servers") return t.servers;
    if (view === "settings") return t.settings;
    return t.clients;
  }
  function displayClientIp(client) {
    const ip = String(client.allowedIPs || "").match(/([0-9]+)\.[0-9]+\.[0-9]+\.([0-9]+)\/32/);
    return ip ? `${ip[1]}.*.*.${ip[2]}` : client.allowedIPs || "-";
  }
  async function rebuildIngressAddressing() {
    if (!window.confirm(`${t.hardResetIps}?`)) return;
    await run(async () => await withProgress(t.hardResetIps, [t.applying, t.refreshingData], async () => {
      await api("settings/rebuild-ingress-addressing", { method: "POST" });
      await refreshAfterMutation();
    }));
  }
  const filteredClients = useMemo(() => {
    const query = clientSearch.trim().toLowerCase();
    return clients.filter((client) => {
      const state = client.subscription?.expired ? "expired" : client.disabled ? "disabled" : "active";
      const matchesStatus = clientStatusFilter === "all" || state === clientStatusFilter;
      const haystack = `${client.name} ${client.allowedIPs || ""} ${client.comment || ""} ${client.accessKey || ""}`.toLowerCase();
      return matchesStatus && (!query || haystack.includes(query));
    });
  }, [clients, clientSearch, clientStatusFilter]);
  const selectedNames = useMemo(() => Object.entries(selectedClients).filter(([, value]) => value).map(([name]) => name), [selectedClients]);
  const allFilteredSelected = filteredClients.length > 0 && filteredClients.every((client) => selectedClients[client.name]);
  function toggleAllFiltered(checked) {
    setSelectedClients((prev) => {
      const next = { ...prev };
      for (const client of filteredClients) next[client.name] = checked;
      return next;
    });
  }
  function toggleClientSelection(name, checked) {
    setSelectedClients((prev) => ({ ...prev, [name]: checked }));
  }
  async function bulkSetEnabled(enabled) {
    const names = selectedNames;
    if (!names.length) return;
    await run(async () => await withProgress(`${enabled ? t.enable : t.disable}: ${names.length}`, [t.applying, t.refreshingData], async () => {
      for (const name of names) await api(`clients/${name}/enabled`, { method: "PATCH", body: JSON.stringify({ enabled }) });
      setSelectedClients({});
      await refreshAfterMutation();
    }));
  }
  async function bulkDelete() {
    const names = selectedNames;
    if (!names.length || !window.confirm(`${t.delete}: ${names.length}?`)) return;
    await run(async () => await withProgress(`${t.delete}: ${names.length}`, [t.applying, t.refreshingData], async () => {
      for (const name of names) await api(`clients/${name}`, { method: "DELETE" });
      setSelectedClients({});
      await refreshAfterMutation();
    }));
  }
  function openBulkExtend() {
    if (!selectedNames.length) return;
    setModal({ type: "bulk-subscription", names: selectedNames, plan: "1m", customUntil: "" });
  }
  async function extendBulkSubscription() {
    const names = modal?.names || [];
    if (!names.length) return;
    if ((modal.plan || "1m") === "custom" && !modal.customUntil) { window.alert(t.customUntil); return; }
    await run(async () => await withProgress(`${t.extendSubscription}: ${names.length}`, [t.applying, t.refreshingData], async () => {
      for (const name of names) await api(`clients/${name}/subscription/extend`, { method: "POST", body: JSON.stringify({ plan: modal.plan || "1m", customUntil: modal.customUntil || "" }) });
      setModal(null);
      setSelectedClients({});
      await refreshAfterMutation();
    }));
  }
  const active = clients.filter((c) => !c.disabled && (c.direct?.latestHandshake || c.upstream?.latestHandshake)).length;
  const analyticsRows = useMemo(() => clients.map((client) => {
    const key = client.id || client.publicKey || client.name;
    return {
      key,
      name: client.name,
      comment: client.comment || "",
      disabled: client.disabled,
      period: stat.users?.[key] || stat.users?.[client.name] || 0,
      live: stat.liveUsers?.[key] || 0
    };
  }).sort((a, b) => b.period - a.period || a.name.localeCompare(b.name)), [clients, stat.users, stat.liveUsers]);
  const chartOptions = {
    cpu: { label: t.cpuUsage, points: chartStat.system?.cpuPoints || [], valueKey: "value", format: (value) => Number(value || 0).toFixed(1), suffix: "%", maxValue: 100 },
    network: { label: t.networkUsage, points: chartStat.system?.networkPoints || [], valueKey: "rxBps", format: (value) => { const mbit = Number(value || 0) / 1000 / 1000; return mbit >= 100 ? mbit.toFixed(0) : mbit >= 10 ? mbit.toFixed(1) : mbit.toFixed(2); }, suffix: " Mbit/s", series: [{ key: "rxBps", label: "In", color: "#4A88FF" }, { key: "txBps", label: "Out", color: "#4CC38A" }] },
    traffic: { label: t.trafficUsage, points: chartStat.points || [], valueKey: "bytes", format: bytes, suffix: "" }
  };
  const activeChart = chartOptions[chartTab] || chartOptions.traffic;
  const serverName = String(telegram.serverName || "").trim();
  const brandTitle = serverName ? `${serverName} WG Admin` : "WireGuard Admin";

  if (authed === false) return <main className="login"><form className="panel form" onSubmit={login}><h1>DD WG Control Panel</h1><input type="password" placeholder={t.password} value={password} onChange={(e) => setPassword(e.target.value)} /><button className="primary">{t.signIn}</button>{error && <span className="bad">{error}</span>}</form></main>;
  if (!authed) return null;

  return <main className="shell">
    <aside className="side app-sidebar">
      <div className="brand"><span className="logo-mark">WG</span><span>{brandTitle}</span></div>
      <div className="nav">{[["clients", t.clients, "users"], ["dashboard", t.analytics, "chart"], ["servers", t.servers, "server"], ["settings", t.settings, "gear"]].map(([id, label, icon]) => <button key={id} className={view === id ? "active" : ""} onClick={() => setView(id)}><Icon name={icon} />{label}</button>)}</div>
      <div className="server-block"><div className="side-label">{t.servers}</div><button type="button" className="server-item" onClick={() => setView("servers")}><span className="status-dot good" /><span>DIRECT</span>{routing.defaultId === "direct" && <span className="mini-badge">Default</span>}</button>{upstreams.map((u) => <button type="button" className="server-item" key={u.id} onClick={() => setView("servers")} title={`${statusTitle(t, u.status)}${u.serverIp ? ` - ${u.serverIp}` : ""}`}><span className={`status-dot ${dot(u.status)}`} /><span>{u.name}</span>{routing.defaultId === u.id && <span className="mini-badge">Default</span>}</button>)}</div>
      <button type="button" className="logout-button" onClick={logout}><Icon name="logout" />{t.logout}</button>
    </aside>
    <section className="main">
      <header className="app-header"><div><h1>{pageTitle()}</h1><p>{t.subtitle}</p></div><div className="header-actions"><select value={lang} onChange={(e) => setLanguage(e.target.value)}><option value="en">EN</option><option value="ru">RU</option></select><button type="button" onClick={() => refresh(true)}><Icon name="refresh" />{t.refresh}</button></div></header>
      <div className="top stats-grid"><div className="metric stat-card"><div className="stat-icon"><Icon name="transfer" /></div><span className="muted">{t.traffic}</span><b>{bytes(stat.total)}</b><small>{t.trafficCaption}</small></div><div className="metric stat-card"><div className="stat-icon"><Icon name="users" /></div><span className="muted">{t.clients}</span><b>{clients.length}</b><small>{t.clientsCaption}</small></div><div className="metric stat-card"><div className="stat-icon status-only"><span className="status-dot good" /></div><span className="muted">{t.active}</span><b>{active}</b><small>{t.activeCaption}</small></div><div className="metric stat-card"><div className="stat-icon"><Icon name="calendar" /></div><span className="muted">{t.period}</span><select value={range} onChange={(e) => setRange(e.target.value)}>{["day", "week", "month", "all"].map((r) => <option key={r} value={r}>{t[r]}</option>)}</select><small>{t.periodCaption}</small></div></div>
      {error && <p className="bad">{error}</p>}
      {view === "dashboard" && <div className="analytics-grid"><div className="panel analytics-chart-card"><div className="panel-title"><div><h2>{activeChart.label}</h2><span className="muted">{t[chartRange]} · {t.sqliteStorage}</span></div><div className="chart-tabs">{Object.entries(chartOptions).map(([id, item]) => <button type="button" key={id} className={chartTab === id ? "active" : ""} onClick={() => setChartTab(id)}>{item.label}</button>)}</div></div><Chart points={activeChart.points} empty={t.noStats} valueKey={activeChart.valueKey} formatValue={activeChart.format} suffix={activeChart.suffix} maxValue={activeChart.maxValue} series={activeChart.series} /><div className="range-tabs">{["1m", "10m", "30m", "1h", "1d"].map((r) => <button type="button" key={r} className={chartRange === r ? "active" : ""} onClick={() => setChartRange(r)}>{t[r]}</button>)}</div></div><div className="panel analytics-table-card"><div className="panel-title"><h2>{t.analyticsTable}</h2><span className="muted">{t[range]}</span></div><div className="table analytics-table"><div className="table-head"><span>{t.name}</span><span>{t.periodUsage}</span><span>{t.currentUsage}</span></div>{analyticsRows.length ? analyticsRows.map((row) => <div className={`table-row ${row.disabled ? "disabled-row" : ""}`} key={row.key}><span><b>{row.name}</b>{row.comment && <small>{row.comment}</small>}</span><b>{bytes(row.period)}</b><span>{bytes(row.live)} {t.perMinute}</span></div>) : <p className="muted">{t.noStats}</p>}</div></div></div>}
      {view === "clients" && <div className="clients-layout">
        <section className="panel clients-table-card">
          <div className="table-toolbar"><div className="search-wrap"><input value={clientSearch} onChange={(e) => setClientSearch(e.target.value)} placeholder={t.searchClients} /></div><div className="filter-tabs">{["all", "active", "disabled", "expired"].map((status) => <button type="button" key={status} className={clientStatusFilter === status ? "active" : ""} onClick={() => setClientStatusFilter(status)}>{status === "all" ? t.all : status === "active" ? t.active : status === "disabled" ? t.disabled : t.expired}</button>)}</div><button type="button" className="primary new-client-button" onClick={() => setModal({ type: "new-client" })}><Icon name="plus" />{t.newClientCta}</button></div>
          <div className="client-table">
            <div className="client-table-head"><label><input type="checkbox" checked={allFilteredSelected} onChange={(e) => toggleAllFiltered(e.target.checked)} /></label><span>{t.clients}</span><span>{t.ipAddressFull}</span><span>{t.status}</span><span>{t.validUntil}</span><span>{t.actions}</span></div>
            {filteredClients.map((c) => { const state = clientState(c); return <div className={`client-table-row ${state.key}-row`} key={c.name}>
              <label><input type="checkbox" checked={!!selectedClients[c.name]} onChange={(e) => toggleClientSelection(c.name, e.target.checked)} /></label>
              <div className="client-cell main-client"><b>{c.name}</b>{c.comment && <div className="client-comment">{c.comment}</div>}<div className="key-line"><span>{t.accessKey}: </span><code>{revealedKeys[c.name] ? c.accessKey || "-" : "••••••••••••••••"}</code><button type="button" className="ghost-icon" title={revealedKeys[c.name] ? t.hide : t.show} onClick={() => setRevealedKeys({ ...revealedKeys, [c.name]: !revealedKeys[c.name] })}><Icon name="eye" /></button><button type="button" className="ghost-icon" title={t.copy} onClick={() => copyAccessKey(c)}><Icon name="copy" /></button></div></div>
              <div className="client-cell mono">{displayClientIp(c)}</div>
              <div className="client-cell"><span className={`status-badge ${state.key}`}><span className={`status-dot ${state.key === "active" ? "good" : state.key === "expired" ? "danger-dot" : "idle"}`} />{state.label}</span></div>
              <div className="client-cell date-cell"><span>{subscriptionText(c, t, lang).replace(/\s\(.+\)$/, "")}</span><small>{t.lastActive}: {ago(lastHandshake(c), t)}</small></div>
              <div className="client-actions"><button type="button" className="icon-button" title={t.qr} onClick={() => openConfig(c, "qr")} disabled={c.disabled}><Icon name="qr" /></button><button type="button" className="icon-button" title={t.download} onClick={() => openConfig(c, "conf")} disabled={c.disabled}><Icon name="download" /></button><button type="button" className="icon-button" title={t.copyConfig} onClick={() => openConfig(c, "copy")} disabled={c.disabled}><Icon name="copy" /></button><button type="button" className="icon-button" title={t.edit} onClick={() => setModal({ type: "client", item: c, name: c.name, comment: c.comment || "", awg: c.awg || {} })}><Icon name="edit" /></button><div className="row-menu-wrap"><button type="button" className="icon-button" title={t.moreActions} onClick={() => setOpenClientMenu(openClientMenu === c.name ? "" : c.name)}><Icon name="more" /></button>{openClientMenu === c.name && <div className="row-menu"><button type="button" onClick={() => { setOpenClientMenu(""); setModal({ type: "subscription", item: c, plan: "1m", customUntil: "" }); }}>{t.extendSubscription}</button><button type="button" onClick={() => { setOpenClientMenu(""); setModal({ type: "speed-limit", item: c, enabled: c.speedLimit?.enabled || false, mbps: c.speedLimit?.mbps || trafficShaper.mbps || 20 }); }}>{t.personalSpeedLimit}</button><button type="button" onClick={() => { setOpenClientMenu(""); setModal({ type: "default-out", item: c, mode: c.route?.mode || "default", upstreamId: c.route?.upstreamId || "" }); }}>{t.individualDefaultOut}</button><button type="button" onClick={() => { setOpenClientMenu(""); setClientEnabled(c, c.disabled); }}>{c.disabled ? t.enable : t.disable}</button><button type="button" className="danger-link" onClick={() => { setOpenClientMenu(""); cancelSubscription(c); }}>{t.cancelSubscription}</button><button type="button" className="danger-link" onClick={() => { setOpenClientMenu(""); run(async () => await withProgress(`${t.delete}: ${c.name}`, [t.applying, t.refreshingData], async () => { await api(`clients/${c.name}`, { method: "DELETE" }); await refreshAfterMutation(); })); }}>{t.delete}</button></div>}</div></div>
            </div>; })}
            {!filteredClients.length && <div className="empty-table">{t.noStats}</div>}
          </div>
        </section>
        {selectedNames.length > 0 && <div className="bulk-toolbar"><b>{t.selected}: {selectedNames.length}</b><button type="button" onClick={openBulkExtend}>{t.bulkExtend}</button><button type="button" onClick={() => bulkSetEnabled(true)}>{t.enable}</button><button type="button" onClick={() => bulkSetEnabled(false)}>{t.disable}</button><button type="button" className="danger" onClick={bulkDelete}>{t.delete}</button></div>}
      </div>}
      {(view === "upstreams" || view === "servers") && <div className="servers-layout"><div className="panel"><div className="panel-title"><h2>{t.servers}</h2><button type="button" className="primary new-client-button" onClick={() => setModal({ type: "new-upstream" })}><Icon name="plus" />{t.newUpstream}</button></div><div className="row"><div><b>DIRECT</b> {routing.defaultId === "direct" && <span className="pill ok">DEFAULT</span>}<div className="compact-meta"><span className="status-dot good" /> <span className="muted">{t.directServer}</span></div></div><div className="actions">{routing.defaultId !== "direct" && <button className="default-action" onClick={() => setGlobalDefault("direct")}>{t.makeDefault}</button>}</div></div>{upstreams.map((u) => <div className="row" key={u.id}><div><b>{u.name}</b> {routing.defaultId === u.id && <span className="pill ok">DEFAULT</span>}<div className="compact-meta"><span className={`status-dot ${dot(u.status)}`} title={statusTitle(t, u.status)} /> <span className="muted">{t.serverIp}: {u.serverIp || "-"}</span></div><div className="muted">{(u.protocol === "awg" ? "AWG 2.0 · " : "AWG native · ")}{u.comment || u.lastError}</div></div><div className="actions">{routing.defaultId !== u.id && u.enabled && <button className="default-action" onClick={() => setGlobalDefault(u.id)}>{t.makeDefault}</button>}<button onClick={() => setModal({ type: "upstream", item: u, name: u.name, comment: u.comment || "" })}>{t.edit}</button><button className="notify-action" onClick={() => setModal({ type: "notify", item: u, down: u.notify?.down || false, recovered: u.notify?.recovered || false })}>{t.notifications}</button><button onClick={() => run(async () => await withProgress(`${u.enabled ? t.disable : t.enable}: ${u.name}`, [t.applying, t.refreshingData], async () => { await api("upstreams", { method: "PATCH", body: JSON.stringify({ toggle: { id: u.id, enabled: !u.enabled } }) }); await refresh(true); }))}>{u.enabled ? t.disable : t.enable}</button><button className="danger" onClick={() => run(async () => await withProgress(`${t.delete}: ${u.name}`, [t.applying, t.refreshingData], async () => { await api(`upstreams/${u.id}`, { method: "DELETE" }); await refresh(true); }))}>{t.delete}</button></div></div>)}</div></div>}
      {view === "settings" && <div className="settings-studio">
        <div className="settings-overview panel">
          <div><span className="eyebrow">{t.settings}</span><h2>{t.controlPlane}</h2><p>{t.settingsIntro}</p></div>
          <div className="settings-kpis"><div><span>{t.healthCheckEndpoints}</span><b>{healthChecks().length}</b></div><div><span>{t.telegramBotAdmin}</span><b>{tgAdmins().length}</b></div><div><span>{t.telegramNotifications}</span><b>{telegram.enabled ? "On" : "Off"}</b></div><div><span>{t.trafficShaping}</span><b>{trafficShaper.enabled === false ? "Off" : `${trafficShaper.mbps || 20}M`}</b></div><div><span>{t.vless}</span><b>{vless.enabled ? "On" : "Off"}</b></div></div>
        </div>
        <div className="settings-composer">
          <div className="settings-main-column">
            <section className="settings-module panel">
              <div className="module-head"><div className="module-title"><span className="module-icon"><Icon name="chart" /></span><div><h2>{t.monitoring}</h2><p>{t.monitoringHint}</p></div></div><button type="button" className="primary" disabled={healthChecks().length >= 10} onClick={() => { setProbe({ url: "", data: "" }); setModal({ type: "health" }); }}><Icon name="plus" />{t.addService}</button></div>
              <div className="module-toolbar"><label>{t.interval}<select value={health.intervalSeconds || 60} onChange={(e) => run(async () => { const next = { ...health, intervalSeconds: Number(e.target.value) }; setHealth(next); await api("settings/health", { method: "POST", body: JSON.stringify(next) }); })}>{notifyIntervals.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label><div className="module-stat"><span>{t.expectedResponse}</span><b>{bytes(healthChecks().reduce((sum, item) => sum + String(item.expected || "").length, 0))}</b></div></div>
              <div className="settings-table"><div className="settings-table-head"><span>{t.healthCheckEndpoints}</span><span>{t.expectedResponse}</span><span>{t.actions}</span></div>{healthChecks().map((c, i) => <div className="settings-table-row" key={`${c.url}-${i}`}><b>{c.url}</b><span>{bytes((c.expected || "").length)}</span><button type="button" onClick={() => removeCheck(i)}>{t.remove}</button></div>)}{!healthChecks().length && <div className="settings-empty">{t.noStats}</div>}</div>
            </section>
            <section className="settings-module panel">
              <div className="module-head"><div className="module-title"><span className="module-icon"><Icon name="transfer" /></span><div><h2>{t.trafficShaping}</h2><p>{t.trafficShapingHint}</p></div></div><button type="button" className="primary" onClick={saveTrafficShaper}>{t.save}</button></div>
              <div className="shaper-grid"><label className="toggle-card"><input type="checkbox" checked={trafficShaper.enabled !== false} onChange={(e) => setTrafficShaper({ ...trafficShaper, enabled: e.target.checked })} /><span><b>{t.shapingEnabled}</b><small>{t.globalLimitHint}</small></span></label><label>{t.speedMbit}<input type="number" min="1" max="10000" step="1" value={trafficShaper.mbps || 20} onChange={(e) => setTrafficShaper({ ...trafficShaper, mbps: Number(e.target.value) })} /></label><div className="module-stat"><span>{t.globalSpeedLimit}</span><b>{trafficShaper.enabled === false ? "Off" : `${trafficShaper.mbps || 20} Mbit/s`}</b></div></div>
            </section>
            <section className="settings-module panel">
              <div className="module-head"><div className="module-title"><span className="module-icon"><Icon name="route" /></span><div><h2>{t.vless}</h2><p>{t.vlessHint}</p></div></div><button type="button" className="primary" onClick={saveVless}>{t.save}</button></div>
              <div className="vless-grid"><label className="toggle-card"><input type="checkbox" checked={vless.enabled || false} onChange={(e) => setVless({ ...vless, enabled: e.target.checked })} /><span><b>{vless.enabled ? "Enabled" : "Disabled"}</b><small>{vless.serviceActive ? "xray active" : "xray stopped"}</small></span></label><div className="field-with-action"><label>{t.publicHost}<input value={vless.publicHost || ""} onChange={(e) => setVless({ ...vless, publicHost: e.target.value })} placeholder={vless.detectedPublicHost || telegram.domain || "1.2.3.4"} /></label><button type="button" onClick={detectVlessIp}>{t.detectIp}</button></div><label>{t.sniDomain}<input value={vless.sniDomain || ""} onChange={(e) => setVless({ ...vless, sniDomain: e.target.value })} placeholder="www.example.com" /></label><div className="module-stat"><span>{t.realityKeys}</span><b>{vless.publicKey ? "Ready" : "Auto"}</b></div></div>
              <div className="transport-grid">
                {[
                  ["realityTcp", t.realityTcp],
                  ["xhttpReality", t.xhttpReality]
                ].map(([id, label]) => <div className="transport-card" key={id}><label className="toggle-card"><input type="checkbox" checked={vless.transports?.[id]?.enabled || false} onChange={(e) => updateVlessTransport(id, { enabled: e.target.checked })} /><span><b>{label}</b><small>{id === "xhttpReality" ? "xHTTP + Reality" : "TCP + Reality"}</small></span></label><label>{t.port}<input type="number" min="1" max="65535" value={vless.transports?.[id]?.port || ""} onChange={(e) => updateVlessTransport(id, { port: Number(e.target.value) })} /></label>{id === "xhttpReality" && <label>Path<input value={vless.transports?.[id]?.path || "/dd-awg-xhttp"} onChange={(e) => updateVlessTransport(id, { path: e.target.value })} /></label>}</div>)}
              </div>
            </section>
            <section className="settings-module panel">
              <div className="module-head"><div className="module-title"><span className="module-icon"><Icon name="server" /></span><div><h2>Telegram</h2><p>{telegramTab === "notifications" ? t.notificationsHint : t.vpnBotHint}</p></div></div><button type="button" className="primary" onClick={telegramTab === "notifications" ? saveTelegram : saveVpnBot}>{t.save}</button></div>
              <div className="tabs"><button type="button" className={telegramTab === "notifications" ? "active" : ""} onClick={() => setTelegramTab("notifications")}>{t.telegramNotifications}</button><button type="button" className={telegramTab === "vpn-bot" ? "active" : ""} onClick={() => setTelegramTab("vpn-bot")}>{t.vpnBot}</button></div>
              {telegramTab === "notifications" && <div className="telegram-settings-grid"><label className="toggle-card"><input type="checkbox" checked={telegram.enabled || false} onChange={(e) => setTelegram({ ...telegram, enabled: e.target.checked })} /><span><b>{telegram.enabled ? "Enabled" : "Disabled"}</b><small>{t.telegramNotifications}</small></span></label><label>{t.botToken}<input value={telegram.token || ""} onChange={(e) => setTelegram({ ...telegram, token: e.target.value })} /></label><label>{t.chatId}<input value={telegram.chatId || ""} onChange={(e) => setTelegram({ ...telegram, chatId: e.target.value })} /></label><label>{t.interval}<select value={telegram.notificationIntervalSeconds || 300} onChange={(e) => setTelegram({ ...telegram, notificationIntervalSeconds: Number(e.target.value) })}>{notifyIntervals.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label></div>}
              {telegramTab === "vpn-bot" && <div className="vpn-bot-grid"><label className="toggle-card"><input type="checkbox" checked={vpnBot.enabled || false} onChange={(e) => setVpnBot({ ...vpnBot, enabled: e.target.checked })} /><span><b>{vpnBot.enabled ? "Enabled" : "Disabled"}</b><small>{t.botService}: {vpnBot.serviceActive ? "active" : "stopped"}</small></span></label><label>{t.botToken}<input value={vpnBot.token || ""} onChange={(e) => setVpnBot({ ...vpnBot, token: e.target.value })} /></label><label>{t.telegramApiRoute}<select value={vpnBot.upstreamId || ""} onChange={(e) => setVpnBot({ ...vpnBot, upstreamId: e.target.value })}><option value="">{t.directTelegramApi}</option>{upstreams.filter((item) => item.enabled).map((item) => <option key={item.id} value={item.id}>{item.name}{item.isDefault ? " (default)" : ""}</option>)}</select></label><div className="module-stat"><span>{t.telegramApiRoute}</span><b>{vpnBot.telegramApiRouteActive ? "Active" : "Off"}</b></div></div>}
              {telegramTab === "vpn-bot" && <div className="admin-panel"><div><h3>{t.telegramBotAdmin}</h3><p>{t.tgAdminHint}</p></div><div className="admin-chip-list">{tgAdmins().map((name) => <span className="admin-chip" key={name}>@{name}<button type="button" onClick={() => removeTgAdmin(name)}>x</button></span>)}{!tgAdmins().length && <span className="muted">{t.noStats}</span>}</div><div className="inline-add"><input value={newTgAdmin} onChange={(e) => setNewTgAdmin(e.target.value.replace(/^@+/, ""))} placeholder="admin_username" /><button type="button" className="primary" onClick={addTgAdmin}>+</button></div></div>}
            </section>
            <section className="settings-module panel">
              <div className="module-head"><div className="module-title"><span className="module-icon"><Icon name="route" /></span><div><h2>{t.domainCertificate}</h2><p>{t.domainHint}</p></div></div><div className="actions"><button type="button" className="primary" onClick={saveTelegram}>{t.save}</button><button type="button" onClick={getCert}>{t.cert}</button></div></div>
              <div className="domain-grid"><label>{t.serverName}<input value={telegram.serverName || ""} onChange={(e) => setTelegram({ ...telegram, serverName: e.target.value })} placeholder="My Server" /></label><label>{t.domain}<input value={telegram.domain || ""} onChange={(e) => setTelegram({ ...telegram, domain: e.target.value })} placeholder="vpn.example.com" /></label><label className="cert-log-field">{t.certLog}<textarea readOnly value={certLog} /></label></div>
            </section>
          </div>
          <aside className="settings-side-column">
            <section className="settings-module side-module panel">
              <div className="module-title"><span className="module-icon"><Icon name="download" /></span><div><h2>{t.backupConfiguration}</h2><p>{t.backupHint}</p></div></div>
              <button type="button" onClick={exportBackup}>{t.exportConfig}</button>
              <label className="button-link">{t.importConfig}<input type="file" accept=".json,application/json" hidden onChange={chooseImportFile} /></label>
            </section>
            <section className="settings-module side-module danger-module panel">
              <div className="module-title"><span className="module-icon"><Icon name="gear" /></span><div><h2>{t.dangerousActions}</h2><p>{t.dangerSettingsHint}</p></div></div>
              <button type="button" className="danger" onClick={() => setModal({ type: "clear", sections: { clients: false, upstreams: false, settings: false } })}>{t.clearConfig}</button>
              <button type="button" className="danger" onClick={rebuildIngressAddressing}>{t.hardResetIps}</button>
              <p className="muted danger-note">{t.hardResetIpsHint}</p>
            </section>
          </aside>
        </div>
      </div>}
      {modal?.type === "new-client" && <Modal title={t.newClient} onClose={() => setModal(null)}><form className="form modal-form" onSubmit={addClient}><NameInput t={t} /><label>{t.subscription}<select name="subscription" value={newSubscription} onChange={(e) => setNewSubscription(e.target.value)}>{subscriptionPlans(lang, ["custom"]).map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>{newSubscription === "custom" && <label>{t.customUntil}<input name="customUntil" type="date" required /></label>}<label>DNS<select name="dns" defaultValue="8.8.8.8, 8.8.4.4">{dnsPresets.map(([v, l]) => <option key={l} value={v}>{l} - {v}</option>)}</select></label><label>{t.comment}<textarea name="comment" maxLength="300" placeholder="Optional" /></label><button className="primary create-cta">{t.createClient}</button></form></Modal>}
      {modal?.type === "new-upstream" && <Modal title={t.newUpstream} onClose={() => setModal(null)}><form className="form modal-form" onSubmit={addUpstream}><NameInput t={t} /><label>{t.comment}<textarea name="comment" maxLength="300" /></label><input name="file" type="file" accept=".conf" required /><button className="primary create-cta">{t.upload}</button></form></Modal>}
      {(modal?.type === "client" || modal?.type === "upstream") && <Modal title={t.edit} onClose={() => setModal(null)}><div className="form"><NameInput t={t} value={modal.name} onChange={(e) => setModal({ ...modal, name: e.target.value })} /><label>{t.comment}<textarea maxLength="300" value={modal.comment} onChange={(e) => setModal({ ...modal, comment: e.target.value })} /></label>{modal?.type === "client" && <AwgFields value={modal.awg || {}} onChange={(awg) => setModal({ ...modal, awg })} />}<button className="primary" onClick={saveEntity}>{t.save}</button></div></Modal>}
      {modal?.type === "notify" && <Modal title={`${t.notifications}: ${modal.item.name}`} onClose={() => setModal(null)}><div className="form"><label><input type="checkbox" checked={modal.down} onChange={(e) => setModal({ ...modal, down: e.target.checked })} /> {t.down}</label><label><input type="checkbox" checked={modal.recovered} onChange={(e) => setModal({ ...modal, recovered: e.target.checked })} /> {t.recovered}</label><button className="primary" onClick={saveNotify}>{t.save}</button></div></Modal>}
      {modal?.type === "subscription" && <Modal title={`${t.extendSubscription}: ${modal.item.name}`} onClose={() => setModal(null)}><div className="form"><p className="muted">{t.expiresAt}: {subscriptionText(modal.item, t, lang)}</p><label>{t.choosePeriod}<select value={modal.plan || "1m"} onChange={(e) => setModal({ ...modal, plan: e.target.value })}>{subscriptionPlans(lang, ["unlimited", "custom"]).map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>{modal.plan === "custom" && <label>{t.customUntil}<input type="date" value={modal.customUntil || ""} onChange={(e) => setModal({ ...modal, customUntil: e.target.value })} required /></label>}<button className="primary" onClick={extendSubscription}>{t.extendSubscription}</button></div></Modal>}
      {modal?.type === "bulk-subscription" && <Modal title={`${t.extendSubscription}: ${modal.names.length}`} onClose={() => setModal(null)}><div className="form"><label>{t.choosePeriod}<select value={modal.plan || "1m"} onChange={(e) => setModal({ ...modal, plan: e.target.value })}>{subscriptionPlans(lang, ["unlimited", "custom"]).map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>{modal.plan === "custom" && <label>{t.customUntil}<input type="date" value={modal.customUntil || ""} onChange={(e) => setModal({ ...modal, customUntil: e.target.value })} required /></label>}<button className="primary" onClick={extendBulkSubscription}>{t.extendSubscription}</button></div></Modal>}
      {modal?.type === "speed-limit" && <Modal title={`${t.personalSpeedLimit}: ${modal.item.name}`} onClose={() => setModal(null)}><div className="form"><p className="muted">{t.effectiveLimit}: {modal.item.effectiveSpeedLimit?.enabled ? `${modal.item.effectiveSpeedLimit.mbps} Mbit/s` : "Off"}</p><label className="toggle-card"><input type="checkbox" checked={modal.enabled || false} onChange={(e) => setModal({ ...modal, enabled: e.target.checked })} /><span><b>{t.usePersonalLimit}</b><small>{t.globalLimitHint}</small></span></label><label>{t.speedMbit}<input type="number" min="1" max="10000" step="1" value={modal.mbps || 20} onChange={(e) => setModal({ ...modal, mbps: Number(e.target.value) })} disabled={!modal.enabled} /></label><button className="primary" onClick={savePersonalSpeedLimit}>{t.save}</button></div></Modal>}
      {modal?.type === "default-out" && <Modal title={`${t.individualDefaultOut}: ${modal.item.name}`} onClose={() => setModal(null)}><div className="form"><p className="muted">{t.currentOut}: {outLabel(modal.item.route)}</p><label>{t.route}<select value={modal.mode === "upstream" ? `upstream:${modal.upstreamId}` : modal.mode || "default"} onChange={(e) => { const value = e.target.value; setModal({ ...modal, mode: value.startsWith("upstream:") ? "upstream" : value, upstreamId: value.startsWith("upstream:") ? value.slice(9) : "" }); }}><option value="default">{t.useGlobalDefault}</option><option value="direct">{t.direct}</option>{upstreams.filter((item) => item.enabled).map((item) => <option key={item.id} value={`upstream:${item.id}`}>{item.name}</option>)}</select></label><button className="primary" onClick={saveIndividualDefaultOut}>{t.save}</button></div></Modal>}
      {modal?.type === "config" && <Modal title={`${t.chooseConfig}: ${modal.item.name}`} onClose={() => setModal(null)}><div className="config-modal"><div className="config-modal-head"><div className="config-action-icon"><Icon name={configActionMeta().icon} /></div><div><b>{configActionMeta().label}</b><p className="muted">{modal.item.name} · {(modal.protocol || "awg").toUpperCase()}{modal.protocol === "vless" ? `/${modal.transport || vlessTransports()[0]?.id || "realityTcp"}` : ""} · {t.currentOut}: {outLabel({ mode: modal.mode || "default", upstreamId: modal.upstreamId || "" })}</p></div></div><section className="config-section"><h3>{t.protocol}</h3><div className="config-choice-grid protocol-grid"><button type="button" className={`config-choice ${modal.protocol === "awg" ? "active" : ""}`} onClick={() => setModal({ ...modal, protocol: "awg" })}><span className="choice-icon"><Icon name="server" /></span><span><b>AWG</b><small>{t.recommended}</small></span></button><button type="button" className={`config-choice ${modal.protocol === "wg" ? "active" : ""}`} onClick={() => setModal({ ...modal, protocol: "wg" })}><span className="choice-icon"><Icon name="route" /></span><span><b>WG</b><small>{t.nativeCompatible}</small></span></button><button type="button" className={`config-choice ${modal.protocol === "vless" ? "active" : ""}`} onClick={() => setModal({ ...modal, protocol: "vless", transport: modal.transport || vlessTransports()[0]?.id || "realityTcp" })} disabled={!vless.enabled}><span className="choice-icon"><Icon name="transfer" /></span><span><b>VLESS</b><small>{vless.enabled ? "Xray Reality" : "Disabled"}</small></span></button></div></section>{modal.protocol === "vless" && <section className="config-section"><h3>{t.transport}</h3><div className="config-choice-grid">{vlessTransports().map((item) => <button type="button" key={item.id} className={`config-choice ${(modal.transport || vlessTransports()[0]?.id) === item.id ? "active" : ""}`} onClick={() => setModal({ ...modal, transport: item.id })}><span className="choice-icon"><Icon name="server" /></span><span><b>{item.label}</b><small>{item.id === "xhttpReality" ? "xHTTP + Reality" : "TCP + Reality"}</small></span></button>)}</div></section>}<section className="config-section"><h3>{t.standardRoutes}</h3><div className="config-choice-grid">{standardRouteOptions().map((o) => <button type="button" key={`${o.mode}-${o.upstreamId}`} className={`config-choice ${(modal.mode || "default") === o.mode && (modal.upstreamId || "") === o.upstreamId ? "active" : ""}`} onClick={() => setModal({ ...modal, mode: o.mode, upstreamId: o.upstreamId })}><span className="choice-icon"><Icon name={o.mode === "default" ? "transfer" : "route"} /></span><span><b>{o.label}</b><small>{o.mode === "default" ? t.autoRoute : t.directServer}</small></span></button>)}</div></section>{upstreamRouteOptions().length > 0 && <section className="config-section upstream-section"><h3>{t.upstreamRoutes}</h3><div className="config-choice-grid upstream-grid">{upstreamRouteOptions().map((o, index) => <button type="button" key={`${o.mode}-${o.upstreamId}`} className={`config-choice ${(modal.mode || "default") === o.mode && (modal.upstreamId || "") === o.upstreamId ? "active" : ""}`} onClick={() => setModal({ ...modal, mode: o.mode, upstreamId: o.upstreamId })}><span className="choice-icon"><Icon name="server" /></span><span><b>{o.label}</b><small>UPSTREAM {index + 1}</small></span></button>)}</div></section>}<button type="button" className="primary config-primary-action" onClick={generateConfig}><Icon name={configActionMeta().icon} />{configActionMeta().label}</button></div></Modal>}
      {modal?.type === "import" && <Modal title={t.importOptions} onClose={() => setModal(null)}><div className="form"><p className="muted">{t.clientsSection}: {modal.analysis.counts.clients}; {t.upstreamsSection}: {modal.analysis.counts.upstreams}; {t.settingsSection}: {modal.analysis.counts.tgAdmins}</p>{modal.analysis.endpointChanged && <p className="bad">{modal.analysis.backupEndpoint} → {modal.analysis.currentEndpoint}</p>}<label><input type="checkbox" checked={modal.sections.clients} onChange={(e) => setModal({ ...modal, sections: { ...modal.sections, clients: e.target.checked } })} /> {t.clientsSection}</label><label><input type="checkbox" checked={modal.sections.upstreams} onChange={(e) => setModal({ ...modal, sections: { ...modal.sections, upstreams: e.target.checked } })} /> {t.upstreamsSection}</label><label><input type="checkbox" checked={modal.sections.settings} onChange={(e) => setModal({ ...modal, sections: { ...modal.sections, settings: e.target.checked } })} /> {t.settingsSection}</label><label>{t.importOptions}<select value={modal.conflict} onChange={(e) => setModal({ ...modal, conflict: e.target.value })}><option value="skip">{t.skip}</option><option value="overwrite">{t.overwrite}</option></select></label>{modal.analysis.endpointChanged && <label><input type="checkbox" checked={modal.replaceEndpoint} onChange={(e) => setModal({ ...modal, replaceEndpoint: e.target.checked })} /> {t.replaceEndpoint}</label>}<button className="primary" onClick={runImport}>{t.importConfig}</button></div></Modal>}
      {modal?.type === "clear" && <Modal title={t.clearConfig} onClose={() => setModal(null)}><div className="form"><p className="bad">{t.clearWarning}</p><label><input type="checkbox" checked={modal.sections.clients} onChange={(e) => setModal({ ...modal, sections: { ...modal.sections, clients: e.target.checked } })} /> {t.clientsSection}</label><label><input type="checkbox" checked={modal.sections.upstreams} onChange={(e) => setModal({ ...modal, sections: { ...modal.sections, upstreams: e.target.checked } })} /> {t.upstreamsSection}</label><label><input type="checkbox" checked={modal.sections.settings} onChange={(e) => setModal({ ...modal, sections: { ...modal.sections, settings: e.target.checked } })} /> {t.settingsSection}</label><button className="danger" onClick={runClearConfig}>{t.clearConfig}</button></div></Modal>}
      {modal?.type === "health" && <Modal title={t.addService} onClose={() => setModal(null)}><div className="form"><label>{t.url}<input value={probe.url} onChange={(e) => setProbe({ ...probe, url: e.target.value })} placeholder="https://example.com/status" /></label><button type="button" onClick={probeUrl}>{t.fetch}</button>{probe.data && <textarea readOnly value={probe.data} />}{probe.data && <button type="button" className="primary" onClick={confirmProbe}>{t.confirm}</button>}</div></Modal>}
      {qr && <Modal title={qr.title} onClose={() => setQr(null)}><div className="qr"><img src={qr.dataUrl} alt={qr.title} /></div></Modal>}
      {progress && <div className="modal-backdrop hard-block"><div className="modal panel progress-modal"><div className="panel-title"><h2>{progress.title || t.progress}</h2><button type="button" onClick={() => setProgress(null)}>{t.exitNow}</button></div><div className="loader" /><pre className="progress-log">{(progress.logs || []).join("\n")}</pre>{progress.error && <p className="bad">{progress.error}</p>}</div></div>}
    </section>
  </main>;
}
DD_WG_CP_OPT_WG_WEB_APP_APP_PAGE_JS_EOF
	mkdir -p "$(dirname "/opt/dd-awg-bot/bot.py")"
	cat > '/opt/dd-awg-bot/bot.py' <<'DD_WG_CP_OPT_DD_AWG_BOT_BOT_PY_EOF'
#!/usr/bin/env python3
import base64
import html
import json
import os
import re
import socket
import time
import urllib.error
import urllib.parse
import urllib.request

_getaddrinfo = socket.getaddrinfo


def _ipv4_getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
    return _getaddrinfo(host, port, socket.AF_INET, type, proto, flags)


socket.getaddrinfo = _ipv4_getaddrinfo

CONFIG_PATH = "/etc/dd-awg-bot/config.json"

with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
    CONFIG = json.load(fh)

PANEL_URL = CONFIG["panel_url"].rstrip("/")
API_TOKEN = CONFIG["api_token"]
TG_TOKEN = CONFIG["telegram_token"]
SESSIONS_FILE = CONFIG.get("sessions_file", "/opt/dd-awg-bot/sessions.json")
TG_URL = f"https://api.telegram.org/bot{TG_TOKEN}"
UI_VERSION = "menu-v6-admin"
NAME_RE = re.compile(r"^[A-Za-z0-9-]{1,14}$")
PLAN_LABELS = {
    "7d": "7д",
    "1m": "1м",
    "3m": "3м",
    "6m": "6м",
    "12m": "12м",
    "24m": "24м",
    "unlimited": "Анлим",
}


def load_sessions():
    try:
        with open(SESSIONS_FILE, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_sessions(sessions):
    tmp = f"{SESSIONS_FILE}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(sessions, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, SESSIONS_FILE)


def request_json(url, data=None, headers=None, timeout=35, method=None):
    body = None
    final_headers = dict(headers or {})
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        final_headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=final_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            raw = res.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            payload = json.loads(raw)
            raise RuntimeError(payload.get("error") or raw)
        except json.JSONDecodeError:
            raise RuntimeError(raw or str(exc)) from exc


def panel_json(path, params=None, data=None, method=None):
    query = f"?{urllib.parse.urlencode(params or {})}" if params else ""
    return request_json(
        f"{PANEL_URL}/api/{path}{query}",
        data=data,
        headers={"Authorization": f"Bearer {API_TOKEN}"},
        method=method
    )


def panel_text(path, params=None):
    query = f"?{urllib.parse.urlencode(params or {})}" if params else ""
    req = urllib.request.Request(
        f"{PANEL_URL}/api/{path}{query}",
        headers={"Authorization": f"Bearer {API_TOKEN}"}
    )
    try:
        with urllib.request.urlopen(req, timeout=35) as res:
            return res.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            payload = json.loads(raw)
            raise RuntimeError(payload.get("error") or raw)
        except json.JSONDecodeError:
            raise RuntimeError(raw or str(exc)) from exc


def tg(method, payload):
    return request_json(f"{TG_URL}/{method}", data=payload, timeout=60)


def tg_multipart(method, fields, file_field, filename, content, mime):
    boundary = f"----ddawg{int(time.time() * 1000)}"
    parts = []
    for key, value in fields.items():
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{key}\"\r\n\r\n{value}\r\n".encode("utf-8"))
    parts.append(
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"{file_field}\"; filename=\"{filename}\"\r\nContent-Type: {mime}\r\n\r\n".encode("utf-8")
    )
    parts.append(content)
    parts.append(f"\r\n--{boundary}--\r\n".encode("utf-8"))
    req = urllib.request.Request(
        f"{TG_URL}/{method}",
        data=b"".join(parts),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"}
    )
    with urllib.request.urlopen(req, timeout=60) as res:
        return json.loads(res.read().decode("utf-8"))


def keyboard(rows):
    return {
        "keyboard": [[{"text": item} for item in row] for row in rows],
        "resize_keyboard": True,
        "is_persistent": True
    }


def remove_keyboard():
    return {"remove_keyboard": True}


def user_menu():
    return keyboard([
        ["📊 Статус", "🚪 Выйти"],
        ["📷 QR", "📄 .conf"]
    ])


def user_protocol_menu():
    return keyboard([
        ["🛡️ AWG (рекомендуется)"],
        ["🟢 WG"],
        ["⚡ VLESS"],
        ["⬅️ Назад"]
    ])


def admin_menu():
    return keyboard([
        ["👥 Клиенты", "➕ Создать"],
        ["🔍 Найти", "📊 Сводка"],
        ["🚪 Выйти"]
    ])


def client_menu(client):
    toggle = "✅ Enable" if client.get("disabled") else "⛔ Disable"
    return keyboard([
        ["📷 QR", "📄 .conf"],
        ["🔑 Ключ", "✏️ Редактировать"],
        [toggle, "⏳ Подписка"],
        ["🗑 Удалить", "⬅️ Клиенты"],
        ["🏠 Админ меню"]
    ])


def edit_menu():
    return keyboard([
        ["✏️ Имя", "📝 Комментарий"],
        ["⬅️ Клиент", "🏠 Админ меню"]
    ])


def subscription_menu():
    return keyboard([
        ["7д", "1м", "3м"],
        ["6м", "12м", "24м"],
        ["Анлим", "CUSTOM"],
        ["Аннулировать", "⬅️ Клиент"]
    ])


def admin_protocol_menu():
    return keyboard([
        ["🛡️ AWG (рекомендуется)"],
        ["🟢 WG"],
        ["⚡ VLESS"],
        ["⬅️ Клиент"]
    ])


def admin_route_menu(upstreams):
    rows = [["🌐 DEFAULT", "🇷🇺 DIRECT"]]
    if len(upstreams) > 1:
        for item in upstreams:
            rows.append([f"🚇 {item.get('name') or item.get('id')}"])
    rows.append(["⬅️ Клиент"])
    return keyboard(rows)


def clients_menu(clients, page=0):
    page = max(0, int(page or 0))
    per_page = 8
    items = clients[page * per_page:(page + 1) * per_page]
    rows = [[f"👤 {item['name']}"] for item in items]
    nav = []
    if page > 0:
        nav.append("⬅️ Страница")
    if (page + 1) * per_page < len(clients):
        nav.append("➡️ Страница")
    if nav:
        rows.append(nav)
    rows.append(["🏠 Админ меню"])
    return keyboard(rows)


def normalize_session(sessions, chat_id):
    value = sessions.get(chat_id)
    if isinstance(value, str):
        value = {"role": "user", "key": value, "flow": {}, "ui_version": ""}
        sessions[chat_id] = value
    if not isinstance(value, dict):
        value = {"role": "", "flow": {}, "ui_version": ""}
        sessions[chat_id] = value
    if not value.get("role") and value.get("key"):
        value["role"] = "user"
    value.setdefault("flow", {})
    value.setdefault("ui_version", "")
    return value


def set_session(sessions, chat_id, **values):
    session = normalize_session(sessions, chat_id)
    session.update(values)
    session["ui_version"] = UI_VERSION
    save_sessions(sessions)
    return session


def set_flow(sessions, chat_id, **flow):
    session = normalize_session(sessions, chat_id)
    session["flow"] = flow
    session["ui_version"] = UI_VERSION
    save_sessions(sessions)


def clear_flow(sessions, chat_id):
    session = normalize_session(sessions, chat_id)
    session["flow"] = {}
    session["ui_version"] = UI_VERSION
    save_sessions(sessions)


def clean_key(text):
    return re.sub(r"[^A-Z0-9]", "", (text or "").upper())


def username_from(message):
    return ((message.get("from") or {}).get("username") or "").strip().lstrip("@")


def admin_info(username):
    if not username:
        return {"admin": False}
    return panel_json("bot/admin/me", params={"username": username})


def auth_by_key(key):
    return panel_json("bot/auth", data={"key": clean_key(key)})


def client_name_by_key(access_key):
    return auth_by_key(access_key).get("client", {}).get("name") or "client"


def admin_params(session):
    return {"username": session.get("admin_username", "")}


def admin_json(session, path, params=None, data=None, method=None):
    query = dict(params or {})
    query.update(admin_params(session))
    return panel_json(f"bot/admin/{path}", params=query, data=data, method=method)


def admin_text(session, path, params=None):
    query = dict(params or {})
    query.update(admin_params(session))
    return panel_text(f"bot/admin/{path}", params=query)


def clients(session):
    return sorted(admin_json(session, "clients"), key=lambda item: item.get("name", "").lower())


def upstreams(session):
    return [item for item in admin_json(session, "upstreams") if item.get("enabled", True)]


def find_client(session, name):
    target = str(name or "")
    for item in clients(session):
        if item.get("name") == target:
            return item
    raise RuntimeError("Клиент не найден")


def expires_text(client):
    sub = client.get("subscription") or {}
    if sub.get("expiresAt") is None:
        return "Анлим"
    if sub.get("expiresAt"):
        return sub["expiresAt"].replace("T", " ").replace(".000Z", " UTC")
    return "-"


def status_text(client):
    state = "отключен" if client.get("disabled") else "активен"
    return (
        f"Пользователь: <b>{html.escape(client.get('name', '-'))}</b>\n"
        f"Статус: <b>{state}</b>\n"
        f"Подписка до: <b>{html.escape(expires_text(client))}</b>"
    )


def admin_client_text(client):
    state = "отключен" if client.get("disabled") else "активен"
    ip = html.escape(client.get("allowedIPs") or "-")
    comment = html.escape(client.get("comment") or "-")
    return (
        f"👤 <b>{html.escape(client.get('name', '-'))}</b>\n"
        f"IP: <code>{ip}</code>\n"
        f"Статус: <b>{state}</b>\n"
        f"Подписка: <b>{html.escape(expires_text(client))}</b>\n"
        f"Комментарий: {comment}"
    )


def send_message(chat_id, text, reply_markup=None):
    payload = {"chat_id": chat_id, "text": text, "parse_mode": "HTML"}
    if reply_markup:
        payload["reply_markup"] = reply_markup
    tg("sendMessage", payload)


def send_user_menu(chat_id, text):
    send_message(chat_id, text, user_menu())


def send_admin_menu(chat_id, text):
    send_message(chat_id, text, admin_menu())


def send_client_card(chat_id, session, name):
    client = find_client(session, name)
    set_session(session_store, chat_id, selected_client=client["name"], flow={})
    send_message(chat_id, admin_client_text(client), client_menu(client))


def send_config(chat_id, access_key, protocol):
    params = {"key": access_key, "protocol": protocol, "mode": "default", "upstreamId": ""}
    content = panel_text("bot/config", params=params)
    name = client_name_by_key(access_key)
    extension = "txt" if protocol == "vless" else "conf"
    filename = f"{name}-{protocol}.{extension}"
    tg_multipart(
        "sendDocument",
        {"chat_id": str(chat_id), "caption": f"{html.escape(name)} - {protocol.upper()} .{extension}"},
        "document",
        filename,
        content.encode("utf-8"),
        "text/plain; charset=utf-8"
    )


def send_qr(chat_id, access_key, protocol):
    params = {"key": access_key, "protocol": protocol, "mode": "default", "upstreamId": ""}
    name = client_name_by_key(access_key)
    payload = panel_json("bot/qr", params=params)
    data_url = payload.get("dataUrl", "")
    if "," not in data_url:
        raise RuntimeError("QR не получен")
    tg_multipart(
        "sendPhoto",
        {"chat_id": str(chat_id), "caption": f"{html.escape(name)} - {protocol.upper()}"},
        "photo",
        "qr.png",
        base64.b64decode(data_url.split(",", 1)[1]),
        "image/png"
    )


def send_admin_config(chat_id, session, name, protocol, mode="default", upstream_id=""):
    content = admin_text(session, f"clients/{urllib.parse.quote(name)}/config", params={"protocol": protocol, "mode": mode, "upstreamId": upstream_id})
    extension = "txt" if protocol == "vless" else "conf"
    tg_multipart(
        "sendDocument",
        {"chat_id": str(chat_id), "caption": f"{html.escape(name)} {protocol.upper()} {mode.upper()} .{extension}"},
        "document",
        f"{name}-{mode}-{protocol}.{extension}",
        content.encode("utf-8"),
        "text/plain; charset=utf-8"
    )


def send_admin_qr(chat_id, session, name, protocol, mode="default", upstream_id=""):
    payload = admin_json(session, f"clients/{urllib.parse.quote(name)}/qr", params={"protocol": protocol, "mode": mode, "upstreamId": upstream_id})
    data_url = payload.get("dataUrl", "")
    if "," not in data_url:
        raise RuntimeError("QR не получен")
    tg_multipart(
        "sendPhoto",
        {"chat_id": str(chat_id), "caption": f"{html.escape(name)} {protocol.upper()} {mode.upper()} QR"},
        "photo",
        "qr.png",
        base64.b64decode(data_url.split(",", 1)[1]),
        "image/png"
    )


def plan_from_text(text):
    mapping = {"7д": "7d", "1м": "1m", "3м": "3m", "6м": "6m", "12м": "12m", "24м": "24m", "Анлим": "unlimited"}
    return mapping.get(text)


def protocol_from_text(text):
    if text == "🛡️ AWG (рекомендуется)":
        return "awg"
    if text == "🛡️ AWG":
        return "awg"
    if text == "🟢 WG":
        return "wg"
    if text == "⚡ VLESS":
        return "vless"
    return ""


def legacy_action(text):
    match = re.match(r"^(QR|CONF) (WG|AWG|VLESS)(?: .*)?$", text or "")
    if not match:
        return "", ""
    kind, protocol = match.groups()
    return kind, protocol.lower()


def handle_admin_flow(chat_id, text, sessions, session, flow):
    step = flow.get("step")
    if text == "⬅️ Клиент" and session.get("selected_client"):
        clear_flow(sessions, chat_id)
        send_client_card(chat_id, session, session.get("selected_client"))
        return True
    if step == "create_name":
        if not NAME_RE.match(text):
            send_message(chat_id, "Имя: 1-14 символов, английские буквы, цифры и дефис.")
            return True
        set_flow(sessions, chat_id, step="create_plan", name=text)
        send_message(chat_id, f"Клиент <b>{html.escape(text)}</b>. Выберите срок подписки.", subscription_menu())
        return True
    if step == "create_plan":
        if text == "CUSTOM":
            set_flow(sessions, chat_id, step="create_custom", name=flow["name"])
            send_message(chat_id, "Введите дату в формате YYYY-MM-DD.")
            return True
        plan = plan_from_text(text)
        if not plan:
            send_message(chat_id, "Выберите срок подписки.", subscription_menu())
            return True
        admin_json(session, "clients", data={"name": flow["name"], "subscription": plan}, method="POST")
        send_client_card(chat_id, session, flow["name"])
        return True
    if step == "create_custom":
        if not re.match(r"^\d{4}-\d{2}-\d{2}$", text):
            send_message(chat_id, "Введите дату в формате YYYY-MM-DD.")
            return True
        admin_json(session, "clients", data={"name": flow["name"], "subscription": "custom", "customUntil": text}, method="POST")
        send_client_card(chat_id, session, flow["name"])
        return True
    if step == "search":
        items = [item for item in clients(session) if text.lower() in item.get("name", "").lower()]
        if not items:
            clear_flow(sessions, chat_id)
            send_admin_menu(chat_id, "Ничего не найдено.")
            return True
        if len(items) == 1:
            send_client_card(chat_id, session, items[0]["name"])
            return True
        clear_flow(sessions, chat_id)
        send_message(chat_id, f"Найдено: {len(items)}", clients_menu(items, 0))
        return True
    if step == "edit_name":
        old_name = session.get("selected_client")
        if not NAME_RE.match(text):
            send_message(chat_id, "Имя: 1-14 символов, английские буквы, цифры и дефис.")
            return True
        admin_json(session, f"clients/{urllib.parse.quote(old_name)}", data={"name": text}, method="PATCH")
        send_client_card(chat_id, session, text)
        return True
    if step == "edit_comment":
        name = session.get("selected_client")
        admin_json(session, f"clients/{urllib.parse.quote(name)}", data={"comment": "" if text == "-" else text[:300]}, method="PATCH")
        send_client_card(chat_id, session, name)
        return True
    if step == "custom_sub":
        name = session.get("selected_client")
        if not re.match(r"^\d{4}-\d{2}-\d{2}$", text):
            send_message(chat_id, "Введите дату в формате YYYY-MM-DD.")
            return True
        admin_json(session, f"clients/{urllib.parse.quote(name)}/subscription/extend", data={"plan": "custom", "customUntil": text}, method="POST")
        send_client_card(chat_id, session, name)
        return True
    if step == "admin_file_protocol":
        protocol = protocol_from_text(text)
        name = session.get("selected_client")
        if not protocol:
            send_message(chat_id, "Выберите протокол.", admin_protocol_menu())
            return True
        set_flow(sessions, chat_id, step="admin_file_route", kind=flow.get("kind"), protocol=protocol)
        send_message(chat_id, "Выберите маршрут.", admin_route_menu(upstreams(session)))
        return True
    if step == "admin_file_route":
        name = session.get("selected_client")
        protocol = flow.get("protocol") or "awg"
        mode, upstream_id = "default", ""
        if text == "🇷🇺 DIRECT":
            mode = "direct"
        elif text == "🌐 DEFAULT":
            mode = "default"
        elif text.startswith("🚇 "):
            upstream_name = text.replace("🚇 ", "", 1).strip()
            upstream = next((item for item in upstreams(session) if item.get("name") == upstream_name), None)
            if not upstream:
                send_message(chat_id, "Upstream не найден. Выберите маршрут.", admin_route_menu(upstreams(session)))
                return True
            mode, upstream_id = "upstream", upstream["id"]
        else:
            send_message(chat_id, "Выберите маршрут.", admin_route_menu(upstreams(session)))
            return True
        clear_flow(sessions, chat_id)
        if flow.get("kind") == "QR":
            send_admin_qr(chat_id, session, name, protocol, mode, upstream_id)
        else:
            send_admin_config(chat_id, session, name, protocol, mode, upstream_id)
        send_client_card(chat_id, session, name)
        return True
    if step == "delete_confirm":
        name = session.get("selected_client")
        if text == "✅ Да удалить":
            admin_json(session, f"clients/{urllib.parse.quote(name)}", method="DELETE")
            clear_flow(sessions, chat_id)
            send_admin_menu(chat_id, f"Клиент <b>{html.escape(name)}</b> удален.")
            return True
        send_client_card(chat_id, session, name)
        return True
    return False


def handle_admin(chat_id, text, sessions, session):
    flow = session.get("flow") or {}
    if flow and handle_admin_flow(chat_id, text, sessions, session, flow):
        return

    if text in ("🏠 Админ меню", "⬅️ Назад"):
        clear_flow(sessions, chat_id)
        send_admin_menu(chat_id, "Админ меню.")
        return
    if text == "👥 Клиенты":
        set_session(sessions, chat_id, client_page=0, flow={})
        items = clients(session)
        send_message(chat_id, f"Клиенты: {len(items)}", clients_menu(items, 0))
        return
    if text == "➡️ Страница":
        page = int(session.get("client_page") or 0) + 1
        set_session(sessions, chat_id, client_page=page)
        items = clients(session)
        send_message(chat_id, f"Клиенты: {len(items)}", clients_menu(items, page))
        return
    if text == "⬅️ Страница":
        page = max(0, int(session.get("client_page") or 0) - 1)
        set_session(sessions, chat_id, client_page=page)
        items = clients(session)
        send_message(chat_id, f"Клиенты: {len(items)}", clients_menu(items, page))
        return
    if text.startswith("👤 "):
        send_client_card(chat_id, session, text.replace("👤 ", "", 1).strip())
        return
    if text == "➕ Создать":
        set_flow(sessions, chat_id, step="create_name")
        send_message(chat_id, "Введите имя нового клиента.")
        return
    if text == "🔍 Найти":
        set_flow(sessions, chat_id, step="search")
        send_message(chat_id, "Введите часть имени клиента.")
        return
    if text == "📊 Сводка":
        items = clients(session)
        active = len([item for item in items if not item.get("disabled")])
        send_admin_menu(chat_id, f"Всего клиентов: <b>{len(items)}</b>\nАктивных: <b>{active}</b>\nОтключенных: <b>{len(items) - active}</b>")
        return

    name = session.get("selected_client")
    if not name:
        send_admin_menu(chat_id, "Выберите действие.")
        return

    if text == "⬅️ Клиенты":
        items = clients(session)
        send_message(chat_id, f"Клиенты: {len(items)}", clients_menu(items, int(session.get("client_page") or 0)))
        return
    if text == "⬅️ Клиент":
        send_client_card(chat_id, session, name)
        return
    if text in ("📷 QR", "📄 .conf"):
        set_flow(sessions, chat_id, step="admin_file_protocol", kind="QR" if text == "📷 QR" else "CONF")
        send_message(chat_id, "Выберите протокол.", admin_protocol_menu())
        return
    if text == "🔑 Ключ":
        client = find_client(session, name)
        send_message(chat_id, f"Access key для <b>{html.escape(name)}</b>:\n<code>{html.escape(client.get('accessKey') or '-')}</code>", client_menu(client))
        return
    if text == "✏️ Редактировать":
        send_message(chat_id, "Что редактируем?", edit_menu())
        return
    if text == "✏️ Имя":
        set_flow(sessions, chat_id, step="edit_name")
        send_message(chat_id, "Введите новое имя.")
        return
    if text == "📝 Комментарий":
        set_flow(sessions, chat_id, step="edit_comment")
        send_message(chat_id, "Введите новый комментарий. Для очистки отправьте '-' .")
        return
    if text in ("⛔ Disable", "✅ Enable"):
        client = find_client(session, name)
        admin_json(session, f"clients/{urllib.parse.quote(name)}/enabled", data={"enabled": bool(client.get("disabled"))}, method="PATCH")
        send_client_card(chat_id, session, name)
        return
    if text == "⏳ Подписка":
        send_message(chat_id, "Выберите действие с подпиской.", subscription_menu())
        return
    plan = plan_from_text(text)
    if plan:
        admin_json(session, f"clients/{urllib.parse.quote(name)}/subscription/extend", data={"plan": plan}, method="POST")
        send_client_card(chat_id, session, name)
        return
    if text == "CUSTOM":
        set_flow(sessions, chat_id, step="custom_sub")
        send_message(chat_id, "Введите дату в формате YYYY-MM-DD.")
        return
    if text == "Аннулировать":
        admin_json(session, f"clients/{urllib.parse.quote(name)}/subscription/cancel", method="POST")
        send_client_card(chat_id, session, name)
        return
    if text == "🗑 Удалить":
        set_flow(sessions, chat_id, step="delete_confirm")
        send_message(chat_id, f"Удалить <b>{html.escape(name)}</b>?", keyboard([["✅ Да удалить"], ["⬅️ Клиент"]]))
        return


def handle_user(chat_id, text, sessions, session):
    access_key = session.get("key", "")
    flow = session.get("flow") or {}

    if text in ("📊 Статус", "Статус"):
        result = auth_by_key(access_key)
        clear_flow(sessions, chat_id)
        send_user_menu(chat_id, status_text(result["client"]))
        return
    if text == "⬅️ Назад":
        clear_flow(sessions, chat_id)
        send_user_menu(chat_id, "Главное меню.")
        return
    if text == "📷 QR":
        set_flow(sessions, chat_id, kind="QR")
        send_message(chat_id, "Выберите протокол. Маршрут: DEFAULT/AUTO.", user_protocol_menu())
        return
    if text == "📄 .conf":
        set_flow(sessions, chat_id, kind="CONF")
        send_message(chat_id, "Выберите протокол. Маршрут: DEFAULT/AUTO.", user_protocol_menu())
        return
    legacy_kind, legacy_protocol = legacy_action(text)
    if legacy_kind:
        clear_flow(sessions, chat_id)
        if legacy_kind == "QR":
            send_qr(chat_id, access_key, legacy_protocol)
        else:
            send_config(chat_id, access_key, legacy_protocol)
        send_user_menu(chat_id, "Готово.")
        return
    protocol = protocol_from_text(text)
    if protocol and flow.get("kind"):
        kind = flow["kind"]
        clear_flow(sessions, chat_id)
        if kind == "QR":
            send_qr(chat_id, access_key, protocol)
        else:
            send_config(chat_id, access_key, protocol)
        send_user_menu(chat_id, "Готово.")
        return
    if text in ("🌐 AUTO", "🇷🇺 Россия") or text.startswith("🚇 "):
        clear_flow(sessions, chat_id)
        send_user_menu(chat_id, "Маршрут теперь выбирается автоматически: DEFAULT/AUTO.")
        return
    if flow.get("kind"):
        send_message(chat_id, "Выберите протокол.", user_protocol_menu())


def handle_message(message, sessions):
    global session_store
    session_store = sessions
    chat_id = str(message["chat"]["id"])
    text = (message.get("text") or "").strip()
    if not text:
        return

    username = username_from(message)
    is_admin = bool(admin_info(username).get("admin")) if username else False

    if text == "/start":
        if is_admin:
            set_session(sessions, chat_id, role="admin", admin_username=username, flow={})
            send_admin_menu(chat_id, f"Админ режим: <b>@{html.escape(username)}</b>")
            return
        if chat_id in sessions and normalize_session(sessions, chat_id).get("role") == "user":
            session = normalize_session(sessions, chat_id)
            result = auth_by_key(session.get("key", ""))
            clear_flow(sessions, chat_id)
            send_user_menu(chat_id, status_text(result["client"]))
        else:
            sessions.pop(chat_id, None)
            save_sessions(sessions)
            send_message(chat_id, "Введите ваш 16-значный ключ доступа.", remove_keyboard())
        return

    if text in ("🚪 Выйти", "Logout"):
        sessions.pop(chat_id, None)
        save_sessions(sessions)
        send_message(chat_id, "Вы вышли. Отправьте /start для входа.", remove_keyboard())
        return

    if chat_id not in sessions:
        if is_admin:
            set_session(sessions, chat_id, role="admin", admin_username=username, flow={})
            send_admin_menu(chat_id, f"Админ режим: <b>@{html.escape(username)}</b>")
            return
        key = clean_key(text)
        if not re.match(r"^[A-Z0-9]{16}$", key):
            return
        result = auth_by_key(key)
        set_session(sessions, chat_id, role="user", key=key, flow={})
        send_user_menu(chat_id, status_text(result["client"]))
        return

    session = normalize_session(sessions, chat_id)
    if session.get("role") == "admin":
        if not is_admin:
            sessions.pop(chat_id, None)
            save_sessions(sessions)
            send_message(chat_id, "Админ-доступ больше не подтвержден.", remove_keyboard())
            return
        session["admin_username"] = username
        handle_admin(chat_id, text, sessions, session)
        return

    handle_user(chat_id, text, sessions, session)


def main():
    offset = 0
    while True:
        try:
            updates = request_json(f"{TG_URL}/getUpdates?timeout=45&offset={offset}", timeout=60).get("result", [])
            sessions = load_sessions()
            for update in updates:
                offset = max(offset, update["update_id"] + 1)
                if "message" not in update:
                    continue
                try:
                    handle_message(update["message"], sessions)
                except Exception as exc:
                    chat_id = update["message"]["chat"]["id"]
                    send_message(chat_id, f"Ошибка: {html.escape(str(exc))}")
        except Exception as exc:
            print(f"polling error: {exc}", flush=True)
            time.sleep(5)


if __name__ == "__main__":
    session_store = {}
    main()
DD_WG_CP_OPT_DD_AWG_BOT_BOT_PY_EOF
	chmod 700 /opt/dd-awg-bot/bot.py
	mkdir -p "$(dirname "/etc/systemd/system/dd-awg-bot.service")"
	cat > '/etc/systemd/system/dd-awg-bot.service' <<'DD_WG_CP_ETC_SYSTEMD_SYSTEM_DD_AWG_BOT_SERVICE_EOF'
[Unit]
Description=DD AWG Telegram subscription bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/dd-awg-bot/bot.py
Restart=always
RestartSec=5
WorkingDirectory=/opt/dd-awg-bot

[Install]
WantedBy=multi-user.target
DD_WG_CP_ETC_SYSTEMD_SYSTEM_DD_AWG_BOT_SERVICE_EOF
	mkdir -p "$(dirname "/etc/systemd/system/dd-awg-vless.service")"
	cat > '/etc/systemd/system/dd-awg-vless.service' <<'DD_WG_CP_ETC_SYSTEMD_SYSTEM_DD_AWG_VLESS_SERVICE_EOF'
[Unit]
Description=DD AWG VLESS ingress service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /etc/dd-awg-vless/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
DD_WG_CP_ETC_SYSTEMD_SYSTEM_DD_AWG_VLESS_SERVICE_EOF
	mkdir -p "$(dirname "/etc/systemd/system/dd-awg-routing.service")"
	cat > '/etc/systemd/system/dd-awg-routing.service' <<'DD_WG_CP_ETC_SYSTEMD_SYSTEM_DD_AWG_ROUTING_SERVICE_EOF'
[Unit]
Description=DD AWG unified client routing
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/wireguard/wg-web/apply-routing.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
DD_WG_CP_ETC_SYSTEMD_SYSTEM_DD_AWG_ROUTING_SERVICE_EOF
	rm -f /usr/local/sbin/dd-awg-vless-rules
	for legacy_vless_service in /etc/systemd/system/dd-awg-vless-route-*.service; do
		[[ -e "$legacy_vless_service" ]] || continue
		systemctl disable --now "$(basename "$legacy_vless_service")" 2>/dev/null || true
		rm -f "$legacy_vless_service"
	done
	rm -f /etc/wireguard/wg-web/vless-*.env
	mkdir -p "$(dirname "/usr/local/sbin/tgapi-via-tunnel-apply")"
	cat > '/usr/local/sbin/tgapi-via-tunnel-apply' <<'DD_WG_CP_USR_LOCAL_SBIN_TGAPI_VIA_TUNNEL_APPLY_EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/etc/wireguard/wg-web/tgapi-via-tunnel.env"
[[ -s "$STATE_FILE" ]] || exit 0
source "$STATE_FILE"

if [[ -z "${TGAPI_IFACE:-}" || -z "${TGAPI_NETS:-}" ]]; then
	echo "TGAPI_IFACE or TGAPI_NETS is empty in $STATE_FILE"
	exit 1
fi

for _ in $(seq 1 30); do
	if ip link show "$TGAPI_IFACE" >/dev/null 2>&1; then
		break
	fi
	sleep 1
done

if ! ip link show "$TGAPI_IFACE" >/dev/null 2>&1; then
	echo "$TGAPI_IFACE does not exist"
	exit 1
fi

for net in $TGAPI_NETS; do
	ip route replace "$net" dev "$TGAPI_IFACE" scope link
done
DD_WG_CP_USR_LOCAL_SBIN_TGAPI_VIA_TUNNEL_APPLY_EOF
	chmod 700 /usr/local/sbin/tgapi-via-tunnel-apply
	mkdir -p "$(dirname "/etc/systemd/system/tgapi-via-tunnel.timer")"
	cat > '/etc/systemd/system/tgapi-via-tunnel.timer' <<'DD_WG_CP_ETC_SYSTEMD_SYSTEM_TGAPI_VIA_TUNNEL_TIMER_EOF'
[Unit]
Description=Refresh Telegram API routes via selected AWG upstream

[Timer]
OnBootSec=30s
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
DD_WG_CP_ETC_SYSTEMD_SYSTEM_TGAPI_VIA_TUNNEL_TIMER_EOF
	systemctl daemon-reload
	if [[ -s /etc/dd-awg-bot/config.json ]]; then
		systemctl enable --now dd-awg-bot.service
	else
		systemctl disable --now dd-awg-bot.service 2>/dev/null || true
	fi
	if [[ -s /etc/wireguard/wg-web/tgapi-via-tunnel.env ]]; then
		systemctl enable --now tgapi-via-tunnel.timer
	else
		systemctl disable --now tgapi-via-tunnel.timer tgapi-via-tunnel.service 2>/dev/null || true
	fi
	if [[ -s /etc/dd-awg-vless/config.json ]]; then
		systemctl enable --now dd-awg-vless.service
	else
		systemctl disable --now dd-awg-vless.service 2>/dev/null || true
	fi

	cleanup_web_manager_networks
	write_extra_rules_script
	systemctl enable --now docker.service
	docker compose -f /opt/wg-web/docker-compose.yml up -d --build

	echo
	echo "WireGuard web management panel is ready."
	echo "URL: https://$wg_web_host:8443"
	echo "Login: admin"
	if [[ "${wg_web_password_changed:-0}" -eq 1 ]]; then
		echo "Password: $wg_web_password"
	else
		echo "Password: existing password was preserved"
	fi
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
	prepare_web_panel_password
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
				systemctl disable --now dd-awg-bot.service dd-awg-vless.service dd-awg-routing.service tgapi-via-tunnel.timer tgapi-via-tunnel.service 2>/dev/null || true
				for service in /etc/systemd/system/dd-awg-vless-route-*.service; do
					[[ -e "$service" ]] || continue
					systemctl disable --now "$(basename "$service")" 2>/dev/null || true
					rm -f "$service"
				done
				rm -rf /opt/dd-awg-bot /etc/dd-awg-bot /etc/dd-awg-vless
				rm -f /etc/systemd/system/dd-awg-bot.service /etc/systemd/system/dd-awg-vless.service /etc/systemd/system/dd-awg-routing.service /etc/systemd/system/tgapi-via-tunnel.service /etc/systemd/system/tgapi-via-tunnel.timer /usr/local/sbin/tgapi-via-tunnel-apply /usr/local/sbin/dd-awg-vless-rules
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
