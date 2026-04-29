#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="Linux IP Changer"
BACKUP_BASE="/root/ip-changer-backup-$(date +%Y%m%d-%H%M%S)"

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNUNG]${NC} $1"; }
error() { echo -e "${RED}[FEHLER]${NC} $1"; }

tty_read() {
  local prompt="$1"
  local var_name="$2"

  if [[ -r /dev/tty ]]; then
    read -rp "$prompt" "$var_name" < /dev/tty
  else
    error "Keine interaktive Eingabe möglich."
    error "Bitte Script nicht mit curl | bash starten."
    error "Nutze z.B.: sudo bash <(curl -fsSL URL)"
    exit 1
  fi
}

print_header() {
  clear || true
  echo -e "${BLUE}=================================================${NC}"
  echo -e "${BLUE} ${SCRIPT_NAME}${NC}"
  echo -e "${BLUE}=================================================${NC}"
  echo
  echo "Beispiel:"
  echo "  IP-Adresse: 192.168.10.25"
  echo "  CIDR:       wird automatisch vorgeschlagen"
  echo "  Gateway:    wird automatisch vorgeschlagen"
  echo "  DNS:        wird automatisch vorgeschlagen"
  echo
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    error "Bitte als root ausführen."
    exit 1
  fi
}

detect_network_stack() {
  if command -v netplan >/dev/null 2>&1 && [[ -d /etc/netplan ]]; then
    echo "netplan"
  elif [[ -f /etc/network/interfaces ]]; then
    echo "ifupdown"
  else
    echo "unknown"
  fi
}

validate_ipv4() {
  local ip="$1"

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  IFS='.' read -r a b c d <<< "$ip"

  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

validate_cidr() {
  local cidr="$1"
  [[ "$cidr" =~ ^[0-9]+$ ]] || return 1
  (( cidr >= 1 && cidr <= 32 ))
}

ip_to_int() {
  local ip="$1"
  local a b c d
  IFS='.' read -r a b c d <<< "$ip"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ip() {
  local int="$1"
  echo "$(( (int >> 24) & 255 )).$(( (int >> 16) & 255 )).$(( (int >> 8) & 255 )).$(( int & 255 ))"
}

cidr_to_mask_int() {
  local cidr="$1"

  if (( cidr == 0 )); then
    echo 0
  else
    echo $(( 0xFFFFFFFF << (32 - cidr) & 0xFFFFFFFF ))
  fi
}

cidr_to_netmask() {
  local cidr="$1"
  int_to_ip "$(cidr_to_mask_int "$cidr")"
}

calculate_network_info() {
  local ip="$1"
  local cidr="$2"

  local ip_int mask_int network_int broadcast_int first_host last_host

  ip_int="$(ip_to_int "$ip")"
  mask_int="$(cidr_to_mask_int "$cidr")"
  network_int=$(( ip_int & mask_int ))
  broadcast_int=$(( network_int | (~mask_int & 0xFFFFFFFF) ))

  if (( cidr >= 31 )); then
    first_host="$network_int"
    last_host="$broadcast_int"
  else
    first_host=$(( network_int + 1 ))
    last_host=$(( broadcast_int - 1 ))
  fi

  echo "Netzwerk:       $(int_to_ip "$network_int")/$cidr"
  echo "Subnetzmaske:   $(int_to_ip "$mask_int")"
  echo "Erste Host-IP:  $(int_to_ip "$first_host")"
  echo "Letzte Host-IP: $(int_to_ip "$last_host")"
  echo "Broadcast:      $(int_to_ip "$broadcast_int")"
}

gateway_in_same_subnet() {
  local ip="$1"
  local gateway="$2"
  local cidr="$3"

  local ip_int gw_int mask_int

  ip_int="$(ip_to_int "$ip")"
  gw_int="$(ip_to_int "$gateway")"
  mask_int="$(cidr_to_mask_int "$cidr")"

  [[ $(( ip_int & mask_int )) -eq $(( gw_int & mask_int )) ]]
}

ask_ipv4() {
  local prompt="$1"
  local value=""

  while true; do
    tty_read "$prompt" value

    if validate_ipv4 "$value"; then
      echo "$value"
      return
    fi

    error "Ungültige IPv4-Adresse: $value"
  done
}

ask_cidr_with_default() {
  local default_cidr="$1"
  local value=""

  while true; do
    if [[ -n "$default_cidr" ]]; then
      tty_read "CIDR eingeben [${default_cidr}]: " value
      value="${value:-$default_cidr}"
    else
      tty_read "CIDR eingeben, z.B. 24: " value
    fi

    if validate_cidr "$value"; then
      echo "$value"
      return
    fi

    error "Ungültiger CIDR-Wert. Erlaubt ist 1 bis 32."
  done
}

ask_gateway_with_default() {
  local default_gateway="$1"
  local value=""

  while true; do
    if [[ -n "$default_gateway" ]]; then
      tty_read "Gateway eingeben [${default_gateway}]: " value
      value="${value:-$default_gateway}"
    else
      tty_read "Gateway eingeben, z.B. 192.168.10.1: " value
    fi

    if validate_ipv4 "$value"; then
      echo "$value"
      return
    fi

    error "Ungültiges Gateway: $value"
  done
}

ask_dns_with_default() {
  local default_dns="$1"
  local input=""
  local valid dns

  while true; do
    if [[ -n "$default_dns" ]]; then
      tty_read "DNS-Server kommagetrennt eingeben [${default_dns}]: " input
      input="${input:-$default_dns}"
    else
      tty_read "DNS-Server kommagetrennt eingeben, z.B. 9.9.9.9,8.8.8.8: " input
    fi

    valid=1
    IFS=',' read -ra dns_servers <<< "$input"

    for dns in "${dns_servers[@]}"; do
      dns="$(echo "$dns" | xargs)"

      if ! validate_ipv4 "$dns"; then
        error "Ungültiger DNS-Server: $dns"
        valid=0
      fi
    done

    if [[ "$valid" -eq 1 ]]; then
      echo "$input"
      return
    fi
  done
}

select_interface() {
  mapfile -t interfaces < <(
    ip -o link show |
      awk -F': ' '{print $2}' |
      sed 's/@.*//' |
      grep -v '^lo$'
  )

  if [[ "${#interfaces[@]}" -eq 0 ]]; then
    error "Keine Netzwerkinterfaces gefunden."
    exit 1
  fi

  echo "Verfügbare Netzwerkinterfaces:"
  echo

  for i in "${!interfaces[@]}"; do
    local iface="${interfaces[$i]}"
    local current_ip

    current_ip="$(ip -4 -o addr show "$iface" | awk '{print $4}' | paste -sd ', ' -)"
    [[ -z "$current_ip" ]] && current_ip="keine IPv4"

    echo "  [$((i + 1))] $iface ($current_ip)"
  done

  echo

  local choice=""

  while true; do
    tty_read "Interface auswählen [1-${#interfaces[@]}]: " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#interfaces[@]} )); then
      echo "${interfaces[$((choice - 1))]}"
      return
    fi

    error "Ungültige Auswahl."
  done
}

detect_current_cidr() {
  local iface="$1"

  ip -4 -o addr show "$iface" |
    awk '{print $4}' |
    head -n1 |
    cut -d'/' -f2
}

detect_gateway() {
  ip route | awk '/default/ {print $3; exit}'
}

detect_dns() {
  local dns_list=""

  if [[ -f /etc/resolv.conf ]]; then
    dns_list="$(
      awk '/^nameserver/ {print $2}' /etc/resolv.conf |
        grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' |
        paste -sd ',' -
    )"
  fi

  if [[ -z "$dns_list" || "$dns_list" == "127.0.0.53" ]]; then
    dns_list="9.9.9.9,8.8.8.8"
  fi

  echo "$dns_list"
}

show_current_config() {
  local iface="$1"

  echo
  echo -e "${BLUE}Aktuelle Konfiguration für $iface:${NC}"
  echo "----------------------------------------"
  ip -4 addr show "$iface" || true
  echo
  ip route || true
  echo "----------------------------------------"
}

backup_file() {
  local file="$1"

  if [[ -e "$file" ]]; then
    mkdir -p "$BACKUP_BASE"
    cp -a "$file" "$BACKUP_BASE/"
    success "Backup erstellt: $BACKUP_BASE/$(basename "$file")"
  fi
}

write_resolv_conf() {
  local dns_input="$1"

  info "Setze DNS in /etc/resolv.conf..."

  if systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
    systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
  fi

  backup_file "/etc/resolv.conf"
  rm -f /etc/resolv.conf

  {
    echo "# Generated by Linux IP Changer"
    IFS=',' read -ra dns_servers <<< "$dns_input"

    for dns in "${dns_servers[@]}"; do
      dns="$(echo "$dns" | xargs)"
      echo "nameserver ${dns}"
    done
  } > /etc/resolv.conf

  chmod 644 /etc/resolv.conf

  success "/etc/resolv.conf wurde gesetzt."
}

disable_cloud_init_networking() {
  local cloud_file="/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"

  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    info "Deaktiviere Cloud-Init Netzwerkverwaltung..."

    mkdir -p "$BACKUP_BASE/cloud"
    [[ -f "$cloud_file" ]] && cp -a "$cloud_file" "$BACKUP_BASE/cloud/"

    cat > "$cloud_file" <<EOF
network: {config: disabled}
EOF

    success "Cloud-Init Netzwerkverwaltung deaktiviert."
  fi
}

configure_netplan() {
  local iface="$1"
  local ipaddr="$2"
  local cidr="$3"
  local gateway="$4"
  local dns_input="$5"

  local netplan_dir="/etc/netplan"
  local netplan_file="${netplan_dir}/99-static-${iface}.yaml"
  local dns_yaml=""
  local dns

  mkdir -p "$BACKUP_BASE/netplan"

  if compgen -G "${netplan_dir}/*.yaml" >/dev/null; then
    cp -a "${netplan_dir}"/*.yaml "$BACKUP_BASE/netplan/"
    success "Netplan-Backup erstellt: $BACKUP_BASE/netplan/"
  fi

  shopt -s nullglob
  for file in "${netplan_dir}"/*.yaml; do
    mv "$file" "${file}.disabled"
    info "Alte Netplan-Datei deaktiviert: $file"
  done
  shopt -u nullglob

  IFS=',' read -ra dns_servers <<< "$dns_input"

  for dns in "${dns_servers[@]}"; do
    dns="$(echo "$dns" | xargs)"
    dns_yaml+="          - ${dns}"$'\n'
  done

  info "Schreibe Netplan-Konfiguration: $netplan_file"

  cat > "$netplan_file" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${iface}:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${ipaddr}/${cidr}
      routes:
        - to: default
          via: ${gateway}
      nameservers:
        addresses:
${dns_yaml}
EOF

  chmod 600 "$netplan_file"

  netplan generate
  netplan apply

  success "Netplan-Konfiguration wurde angewendet."
}

configure_ifupdown() {
  local iface="$1"
  local ipaddr="$2"
  local cidr="$3"
  local gateway="$4"
  local dns_input="$5"

  local interfaces_file="/etc/network/interfaces"
  local netmask
  local dns_space=""

  netmask="$(cidr_to_netmask "$cidr")"

  IFS=',' read -ra dns_servers <<< "$dns_input"
  for dns in "${dns_servers[@]}"; do
    dns="$(echo "$dns" | xargs)"
    dns_space+="${dns} "
  done

  backup_file "$interfaces_file"

  info "Schreibe ifupdown-Konfiguration: $interfaces_file"

  cat > "$interfaces_file" <<EOF
# Generated by Linux IP Changer

auto lo
iface lo inet loopback

auto ${iface}
iface ${iface} inet static
    address ${ipaddr}
    netmask ${netmask}
    gateway ${gateway}
    dns-nameservers ${dns_space}
EOF

  ip -4 addr flush dev "$iface" || true
  ip addr add "${ipaddr}/${cidr}" dev "$iface" || true
  ip route replace default via "$gateway" dev "$iface" || true

  if systemctl list-unit-files networking.service >/dev/null 2>&1; then
    systemctl restart networking || true
  else
    ifdown "$iface" || true
    ifup "$iface" || true
  fi

  success "ifupdown-Konfiguration wurde gesetzt."
}

test_connectivity() {
  local gateway="$1"

  echo
  echo -e "${BLUE}Verbindungstest:${NC}"
  echo "----------------------------------------"

  if ping -c 2 -W 2 "$gateway" >/dev/null 2>&1; then
    success "Gateway erreichbar: $gateway"
  else
    warn "Gateway nicht erreichbar: $gateway"
  fi

  if ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1; then
    success "Internet per IP erreichbar: 8.8.8.8"
  else
    warn "Internet per IP nicht erreichbar."
  fi

  if ping -c 2 -W 2 google.de >/dev/null 2>&1; then
    success "DNS funktioniert: google.de"
  else
    warn "DNS-Test fehlgeschlagen."
  fi

  echo "----------------------------------------"
}

main() {
  print_header
  require_root

  local stack iface ipaddr cidr gateway dns_input detected_gateway detected_cidr detected_dns confirm force

  stack="$(detect_network_stack)"

  case "$stack" in
    netplan)
      success "Netzwerk-Stack erkannt: Netplan"
      ;;
    ifupdown)
      success "Netzwerk-Stack erkannt: ifupdown (/etc/network/interfaces)"
      ;;
    *)
      error "Kein unterstützter Netzwerk-Stack erkannt."
      error "Unterstützt: Netplan, ifupdown"
      exit 1
      ;;
  esac

  echo

  iface="$(select_interface)"
  show_current_config "$iface"

  detected_cidr="$(detect_current_cidr "$iface")"
  detected_gateway="$(detect_gateway)"
  detected_dns="$(detect_dns)"

  ipaddr="$(ask_ipv4 "Gewünschte statische IP-Adresse eingeben, z.B. 192.168.10.25: ")"
  cidr="$(ask_cidr_with_default "$detected_cidr")"
  gateway="$(ask_gateway_with_default "$detected_gateway")"

  echo
  echo -e "${BLUE}Subnetz-Rechner:${NC}"
  echo "----------------------------------------"
  calculate_network_info "$ipaddr" "$cidr"
  echo "Gateway:        $gateway"
  echo "----------------------------------------"

  if gateway_in_same_subnet "$ipaddr" "$gateway" "$cidr"; then
    success "Gateway liegt im gleichen Subnetz."
  else
    error "Gateway liegt NICHT im gleichen Subnetz."
    echo
    echo "Diese Kombination ist wahrscheinlich falsch:"
    echo "  IP:      ${ipaddr}/${cidr}"
    echo "  Gateway: ${gateway}"
    echo
    tty_read "Trotzdem fortfahren? [j/N]: " force

    if [[ ! "$force" =~ ^[jJ]$ ]]; then
      warn "Abgebrochen."
      exit 0
    fi
  fi

  dns_input="$(ask_dns_with_default "$detected_dns")"

  echo
  echo -e "${BLUE}Geplante Konfiguration:${NC}"
  echo "----------------------------------------"
  echo "Stack:      $stack"
  echo "Interface:  $iface"
  echo "IP-Adresse: ${ipaddr}/${cidr}"
  echo "Netmask:    $(cidr_to_netmask "$cidr")"
  echo "Gateway:    $gateway"
  echo "DNS:        $dns_input"
  echo "Backup:     $BACKUP_BASE"
  echo "----------------------------------------"
  echo

  tty_read "Konfiguration schreiben und anwenden? [j/N]: " confirm

  if [[ ! "$confirm" =~ ^[jJ]$ ]]; then
    warn "Abgebrochen."
    exit 0
  fi

  disable_cloud_init_networking
  write_resolv_conf "$dns_input"

  case "$stack" in
    netplan)
      configure_netplan "$iface" "$ipaddr" "$cidr" "$gateway" "$dns_input"
      ;;
    ifupdown)
      configure_ifupdown "$iface" "$ipaddr" "$cidr" "$gateway" "$dns_input"
      ;;
  esac

  write_resolv_conf "$dns_input"

  echo
  success "Fertig. Die Netzwerkkonfiguration wurde gesetzt."
  echo

  echo "Aktuelle IPv4-Konfiguration:"
  ip -4 addr show "$iface"
  echo

  echo "Aktuelle Route:"
  ip route
  echo

  echo "Aktuelle DNS-Konfiguration:"
  cat /etc/resolv.conf
  echo

  test_connectivity "$gateway"
}

main "$@"
