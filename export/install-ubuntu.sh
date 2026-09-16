#!/bin/bash
set -euo pipefail

RED='\e[1;31m'; GREEN='\e[1;32m'; YELLOW='\e[1;33m'; CYAN='\e[1;36m'; NC='\e[0m'

if [[ $# -lt 1 ]]; then
  echo -e "${YELLOW}Usage:${NC} install-ubuntu <путь-к-ubuntu.iso>"
  echo ""
  echo "  Ищет ISO в указанном пути и записывает на выбранный диск."
  echo "  Пример: install-ubuntu ~/ubuntu-24.04.1-desktop-amd64.iso"
  exit 1
fi

ISO="$1"

if [[ ! -f "$ISO" ]]; then
  echo -e "${RED}Файл не найден:${NC} $ISO"
  exit 1
fi

ISO_SIZE=$(du -h "$ISO" | cut -f1)
echo -e "${CYAN}ISO:${NC} $ISO ($ISO_SIZE)"
echo ""

echo -e "${YELLOW}Доступные диски:${NC}"
echo "------------------------------------------------------------"
lsblk -d -o NAME,SIZE,TYPE,RO,MODEL | grep -v loop
echo "------------------------------------------------------------"
echo ""

read -p "Введите целевой диск (например, sda): " DISK
DEVICE="/dev/$DISK"

if [[ ! -b "$DEVICE" ]]; then
  echo -e "${RED}Блочное устройство $DEVICE не найдено.${NC}"
  exit 1
fi

echo ""
echo -e "${YELLOW}ВНИМАНИЕ:${NC} Все данные на ${RED}$DEVICE${NC} будут уничтожены!"
echo -e "  Устройство: $(lsblk -d -o MODEL "$DEVICE" | tail -1)"
echo -e "  Размер:     $(lsblk -d -o SIZE "$DEVICE" | tail -1)"
echo ""

read -p "Продолжить? Введите yes: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo -e "${YELLOW}Отменено.${NC}"
  exit 1
fi

echo ""
echo -e "${CYAN}Запись ISO на $DEVICE...${NC}"
sudo dd if="$ISO" of="$DEVICE" bs=4M status=progress conv=fsync

echo ""
echo -e "${GREEN}Готово!${NC}"
echo -e "Теперь можно загрузиться с $DEVICE."
echo ""
echo -e "Если система не загружается, попробуйте:="
echo "  sudo dd if=$ISO of=$DEVICE bs=4M status=progress conv=fsync oflag=direct"
