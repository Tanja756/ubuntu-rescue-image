# 1. Создаём правильный конфиг
sudo tee /etc/default/keyboard > /dev/null <<EOF
XKBMODEL="pc105"
XKBLAYOUT="us,ru"
XKBVARIANT=","
XKBOPTIONS="grp:alt_shift_toggle"
BACKSPACE="guess"
EOF

# 2. Применяем в текущей консоли (без перезагрузки)
sudo setupcon

# 3. Перезапускаем сервис keyboard-setup (на всякий случай)
sudo systemctl restart keyboard-setup 2>/dev/null || sudo service keyboard-setup restart