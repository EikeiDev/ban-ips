#!/bin/bash

set -e

IP_LIST_URL="https://raw.githubusercontent.com/KotaruProject/ban-ips/main/ip_ranges.txt"
JAIL_NAME="manual-block"
IPSET_NAME="f2b-$JAIL_NAME"
ACTION_NAME="iptables-ipset-cidr"
ACTION_FILE="/etc/fail2ban/action.d/$ACTION_NAME.conf"
LOG_FILE="/var/log/manual-block.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

echo "🔍 Проверка: установлен ли Fail2Ban..."
if ! command -v fail2ban-server >/dev/null 2>&1; then
  sudo apt update >> "$LOG_FILE" 2>&1
  sudo apt install -y fail2ban ipset iptables-persistent >> "$LOG_FILE" 2>&1
  log "✅ Установлены необходимые пакеты."
fi

echo "⚙️ Проверка unit-файла fail2ban на наличие '-xf'..."
UNIT_FILE="/usr/lib/systemd/system/fail2ban.service"
if grep -q '\-xf' "$UNIT_FILE"; then
  sudo sed -i 's/\/fail2ban-server -xf start/\/fail2ban-server start/' "$UNIT_FILE"
  sudo systemctl daemon-reexec >> "$LOG_FILE" 2>&1
  sudo systemctl daemon-reload >> "$LOG_FILE" 2>&1
  log "⚠️ Удалён параметр -xf из unit-файла Fail2Ban."
fi

echo "🔄 Перезапускаю Fail2Ban..."
sudo systemctl restart fail2ban >> "$LOG_FILE" 2>&1
sleep 2
log "✅ Fail2Ban успешно запущен."

echo "📁 Создаю кастомный action '$ACTION_NAME'..."
sudo tee "$ACTION_FILE" > /dev/null <<EOF
[Definition]
actionstart = ipset create $IPSET_NAME hash:net timeout 0 -exist
actionstop = ipset flush $IPSET_NAME
actionban = ipset add $IPSET_NAME <ip> -exist
actionunban = ipset del $IPSET_NAME <ip> -exist

[Init]
name = $JAIL_NAME
EOF
log "✅ Action '$ACTION_NAME' создан."

echo "📁 Создаю jail '$JAIL_NAME'..."
sudo tee "/etc/fail2ban/jail.d/$JAIL_NAME.conf" > /dev/null <<EOF
[$JAIL_NAME]
enabled = true
filter = $JAIL_NAME
action = $ACTION_NAME
bantime = -1
findtime = 1h
maxretry = 1
EOF
log "✅ Jail '$JAIL_NAME' создан."

echo "📁 Создаю фильтр '$JAIL_NAME' (заглушка)..."
sudo tee "/etc/fail2ban/filter.d/$JAIL_NAME.conf" > /dev/null <<EOF
[Definition]
failregex = ^ban: <HOST>\$
EOF
log "✅ Фильтр '$JAIL_NAME' создан."

echo "📁 Создаю пустой лог-файл..."
sudo touch /var/log/empty.log
sudo chmod 644 /var/log/empty.log

echo "🔁 Перезапускаю Fail2Ban с новым jail..."
sudo systemctl restart fail2ban >> "$LOG_FILE" 2>&1
sleep 2

log "⬇️ Загружаю список IP и применяю через fail2ban-client..."
curl -fsSL "$IP_LIST_URL" | grep -vE '^\s*#|^\s*$' | while read -r CIDR; do
  {
    sudo fail2ban-client set $JAIL_NAME banip "$CIDR"
  } >> "$LOG_FILE" 2>&1 || log "⚠️ Проблема с баном $CIDR"
done

if ! sudo iptables -S | grep -q "match-set $IPSET_NAME"; then
  sudo iptables -I INPUT -m set --match-set $IPSET_NAME src -j REJECT --reject-with icmp-port-unreachable
  log "✅ Правило iptables для ipset '$IPSET_NAME' добавлено."
else
  log "ℹ️ Правило iptables уже существует."
fi

echo "✅ Готово. Подробности: $LOG_FILE"
