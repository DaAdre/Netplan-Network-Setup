#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="Netplan Static IP Setup"
NETPLAN_DIR="/etc/netplan"
BACKUP_DIR="${NETPLAN_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
CLOUD_INIT_DISABLE_FILE="/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNUNG]${NC} $1"; }
error() { echo -e "${RED}[FEHLER]${NC} $1"; }

print_header() {
  clear || true
  echo -e "${BLUE}=================================================${NC}"
  echo -e "${BLUE} ${SCRIPT_NAME}${NC}"
  echo -e "${BLUE}=================================================${NC}"
  echo
  echo "Beispiel:"
  echo "  IP-Adresse: 10.22.38.11"
  echo "  CIDR:       18"
  echo "  Gateway:    10.22.0.1"
  echo "  DNS:        9.9.9.9,8.8.8.8"
  echo
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    error "Bitte als root ausführen."
    echo
    echo "Beispiel:"
    echo "  curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/netplan-static-ip.sh | sudo bash"
    exit 1
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
    read -rp "$prompt" value

    if validate_ipv4 "$value"; then
      echo "$value"
      return
    fi

    error "Ungültige IPv4-Adresse: $value" >&2
  done
}

ask_cidr() {
  local value=""

  while true; do
    read -rp "CIDR eingeben, z.B. 18 oder 24: " value

    if validate_cidr "$value"; then
      echo "$value"
      return
    fi

    error "Ungültiger CIDR-Wert. Erlaubt ist 1 bis 32." >&2
  done
}

ask_dns() {
  local input=""
  local valid dns

  while true; do
    read -rp "DNS-Server kommagetrennt eingeben, z.B. 9.9.9.9,8.8.8.8: " input

    valid=1
    IFS=',' read -ra dns_servers <<< "$input"

    for dns in "${dns_servers[@]}"; do
      dns="$(echo "$dns" | xargs)"

      if ! validate_ipv4 "$dns"; then
        error "Ungültiger DNS-Server: $dns" >&2
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
    error "Keine Netzwerkinterfaces gefunden." >&2
    exit 1
  fi

  echo "Verfügbare Netzwerkinterfaces:" >&2
  echo >&2

  for i in "${!interfaces[@]}"; do
    local iface="${interfaces[$i]}"
    local current_ip

    current_ip="$(ip -4 -o addr show "$iface" | awk '{print $4}' | paste -sd ', ' -)"
    [[ -z "$current_ip" ]] && current_ip="keine IPv4"

    echo "  [$((i + 1))] $iface ($current_ip)" >&2
  done

  echo >&2

  local choice=""

  while true; do
    read -rp "Interface auswählen [1-${#interfaces[@]}]: " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#interfaces[@]} )); then
      echo "${interfaces[$((choice - 1))]}"
      return
    fi

    error "Ungültige Auswahl." >&2
  done
}

detect_gateway() {
  ip route | awk '/default/ {print $3; exit}'
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

backup_netplan() {
  info "Erstelle Backup der bestehenden Netplan-Konfigurationen..."

  mkdir -p "$BACKUP_DIR"

  if compgen -G "${NETPLAN_DIR}/*.yaml" >/dev/null; then
    cp "${NETPLAN_DIR}"/*.yaml "$BACKUP_DIR"/
    success "Backup erstellt: $BACKUP_DIR"
  else
    warn "Keine bestehenden YAML-Dateien in ${NETPLAN_DIR} gefunden."
  fi
}

disable_existing_netplan_files() {
  info "Deaktiviere bestehende Netplan-Dateien..."

  shopt -s nullglob

  for file in "${NETPLAN_DIR}"/*.yaml; do
    mv "$file" "${file}.disabled"
    info "Deaktiviert: $file"
  done

  shopt -u nullglob
}

disable_cloud_init_networking() {
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    info "Deaktiviere Cloud-Init Netzwerkverwaltung..."

    cat > "$CLOUD_INIT_DISABLE_FILE" <<EOF
network: {config: disabled}
EOF

    success "Cloud-Init Netzwerkverwaltung deaktiviert."
  fi
}

write_netplan_config() {
  local iface="$1"
  local ipaddr="$2"
  local cidr="$3"
  local gateway="$4"
  local dns_input="$5"
  local netplan_file="${NETPLAN_DIR}/99-static-${iface}.yaml"

  local dns_yaml=""
  local dns

  IFS=',' read -ra dns_servers <<< "$dns_input"

  for dns in "${dns_servers[@]}"; do
    dns="$(echo "$dns" | xargs)"
    dns_yaml+="          - ${dns}"$'\n'
  done

  info "Schreibe neue Netplan-Konfiguration: $netplan_file"

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

  success "Netplan-Datei erstellt: $netplan_file"
}

write_resolv_conf() {
  local dns_input="$1"

  info "Setze DNS zusätzlich direkt in /etc/resolv.conf..."

  if systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
    systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
    success "systemd-resolved wurde deaktiviert."
  fi

  rm -f /etc/resolv.conf

  {
    echo "# Generated by Netplan Static IP Setup"
    IFS=',' read -ra dns_servers <<< "$dns_input"

    for dns in "${dns_servers[@]}"; do
      dns="$(echo "$dns" | xargs)"
      echo "nameserver ${dns}"
    done
  } > /etc/resolv.conf

  chmod 644 /etc/resolv.conf

  success "/etc/resolv.conf wurde gesetzt."
}

flush_old_addresses() {
  local iface="$1"
  local ipaddr="$2"
  local cidr="$3"

  warn "Entferne vorhandene IPv4-Adressen von $iface..."
  ip -4 addr flush dev "$iface" || true

  info "Setze neue IPv4-Adresse sofort manuell..."
  ip addr add "${ipaddr}/${cidr}" dev "$iface" || true

  success "IPv4-Adresse wurde direkt gesetzt."
}

apply_netplan() {
  info "Prüfe Netplan-Konfiguration..."
  netplan generate

  success "Netplan-Konfiguration ist gültig."

  info "Wende Netplan-Konfiguration an..."
  netplan apply

  if systemctl is-active --quiet systemd-networkd; then
    info "Starte systemd-networkd neu..."
    systemctl restart systemd-networkd
  fi

  success "Netplan wurde angewendet."
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

  local iface ipaddr cidr gateway dns_input detected_gateway

  iface="$(select_interface)"

  show_current_config "$iface"

  ipaddr="$(ask_ipv4 "Gewünschte statische IP-Adresse eingeben, z.B. 10.22.38.11: ")"
  cidr="$(ask_cidr)"

  detected_gateway="$(detect_gateway)"

  if [[ -n "$detected_gateway" ]]; then
    read -rp "Gateway eingeben [${detected_gateway}]: " gateway
    gateway="${gateway:-$detected_gateway}"
  else
    gateway="$(ask_ipv4 "Gateway eingeben, z.B. 10.22.0.1: ")"
  fi

  if ! validate_ipv4 "$gateway"; then
    error "Ungültiges Gateway: $gateway"
    exit 1
  fi

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
    echo "Beispiel:"
    echo "  Bei IP 10.22.38.11 und Gateway 10.22.0.1 ist meistens /18 korrekt."
    echo "  Bei /25 müsste das Gateway z.B. 10.22.38.1 sein."
    echo
    read -rp "Trotzdem fortfahren? [j/N]: " force

    if [[ ! "$force" =~ ^[jJ]$ ]]; then
      warn "Abgebrochen."
      exit 0
    fi
  fi

  dns_input="$(ask_dns)"

  echo
  echo -e "${BLUE}Geplante Konfiguration:${NC}"
  echo "----------------------------------------"
  echo "Interface:  $iface"
  echo "IP-Adresse: ${ipaddr}/${cidr}"
  echo "Gateway:    $gateway"
  echo "DNS:        $dns_input"
  echo "----------------------------------------"
  echo

  read -rp "Konfiguration schreiben und anwenden? [j/N]: " confirm

  if [[ ! "$confirm" =~ ^[jJ]$ ]]; then
    warn "Abgebrochen."
    exit 0
  fi

  backup_netplan
  disable_existing_netplan_files
  disable_cloud_init_networking
  write_netplan_config "$iface" "$ipaddr" "$cidr" "$gateway" "$dns_input"
  write_resolv_conf "$dns_input"
  flush_old_addresses "$iface" "$ipaddr" "$cidr"
  apply_netplan
  write_resolv_conf "$dns_input"

  echo
  success "Fertig. Die Netzwerkkonfiguration wurde angewendet."
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
