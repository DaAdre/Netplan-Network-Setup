# Netplan Static IP Setup

Ein interaktives Bash-Script zur schnellen Umstellung eines Linux-Servers von DHCP auf eine statische IPv4-Konfiguration unter Verwendung von Netplan.

## ✨ Features

- Interaktive Auswahl des Netzwerkinterfaces
- Validierung von IP, CIDR, Gateway und DNS
- Integrierter Subnetz-Rechner (Anzeige von Netzwerk, Broadcast etc.)
- Prüfung, ob Gateway im gleichen Subnetz liegt
- Automatisches Backup bestehender Netplan-Konfigurationen
- Deaktivierung alter Netplan-Dateien
- Optionale Deaktivierung von Cloud-Init Netzwerk-Konfiguration
- Setzt Netplan-Konfiguration automatisch
- Setzt zusätzlich `/etc/resolv.conf` für funktionierendes DNS
- Deaktiviert optional `systemd-resolved`
- Entfernt alte IP-Adressen und setzt neue direkt
- Automatischer Verbindungstest (Gateway, Internet, DNS)

## 🚀 Verwendung

### Direkt ausführen (empfohlen)

```bash
curl -fsSL https://raw.githubusercontent.com/DaAdre/Netplan-Network-Setup/refs/heads/main/netplan-static-ip.sh | sudo bash
