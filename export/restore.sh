#!/bin/bash
set -euo pipefail

RED='\e[1;31m'; GREEN='\e[1;32m'; YELLOW='\e[1;33m'; CYAN='\e[1;36m'; NC='\e[0m'

usage() {
  echo -e "${YELLOW}Usage:${NC} restore-img <путь-к-архиву/образу>"
  echo ""
  echo "  Поддерживаемые форматы:"
  echo "    *.1.dar, *.2.dar, …  — многотомный DAR-архив (указывается путь без .N.dar)"
  echo "    *.img, *.iso, *.raw   — сырой образ диска (dd)"
  echo ""
  echo "  Примеры:"
  echo "    restore-img /mnt/img/fs                 # dar-архив fs.1.dar, fs.2.dar..."
  echo "    restore-img /mnt/img/system.img         # dd-образ"
  echo "    restore-img /mnt/img/ubuntu.iso         # dd-образ iso"
  exit 1
}

detect_archive_type() {
  local path="$1"

  if [[ -f "${path}.1.dar" ]]; then
    echo "dar"
    return
  fi
  if [[ -f "${path}.dar" ]]; then
    echo "dar"
    return
  fi
  for ext in img iso raw; do
    if [[ -f "${path}" ]] && [[ "${path,,}" == *".${ext}" ]]; then
      echo "raw"
      return
    fi
  done
  if [[ -f "${path}.1.dar" ]] || [[ -f "${path}.dar" ]]; then
    echo "dar"
    return
  fi

  echo "unknown"
}

list_disks() {
  echo -e "${YELLOW}Доступные диски:${NC}"
  echo "------------------------------------------------------------"
  lsblk -d -o NAME,SIZE,TYPE,RO,MODEL | grep -v loop
  echo "------------------------------------------------------------"
}

select_disk() {
  local dev
  read -p "Введите целевой диск (например, sdb): " dev
  DEVICE="/dev/$dev"

  if [[ ! -b "$DEVICE" ]]; then
    echo -e "${RED}Блочное устройство $DEVICE не найдено.${NC}"
    exit 1
  fi

  echo ""
  echo -e "${YELLOW}ВНИМАНИЕ:${NC} Все данные на ${RED}$DEVICE${NC} будут уничтожены!"
  echo -e "  Устройство: $(lsblk -d -o MODEL "$DEVICE" 2>/dev/null | tail -1)"
  echo -e "  Размер:     $(lsblk -d -o SIZE "$DEVICE" 2>/dev/null | tail -1)"
  echo ""

  local confirm
  read -p "Продолжить? Введите yes: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo -e "${YELLOW}Отменено.${NC}"
    exit 1
  fi
}

select_partition_scheme() {
  echo ""
  echo -e "${YELLOW}Выберите схему разметки:${NC}"
  echo "  1 — Один раздел ext4 (весь диск)"
  echo "  2 — Один раздел btrfs (весь диск)"
  echo "  3 — /boot ext4 + корень btrfs"
  echo "  4 — Использовать существующие разделы (без разметки)"
  echo "  5 — Пропустить разметку (диск уже готов)"
  echo ""
  read -p "Ваш выбор [1-5]: " scheme_choice
  echo ""
}

partition_and_format() {
  local dev="$1"
  local scheme="$2"

  case "$scheme" in
    1)
      echo -e "${CYAN}Создаю один раздел ext4 на весь диск...${NC}"
      sudo parted -s "$dev" mklabel gpt
      sudo parted -s "$dev" mkpart primary ext4 0% 100%
      sudo parted -s "$dev" set 1 boot on
      sleep 1
      PART="${dev}1"
      echo -e "${CYAN}Форматирую $PART в ext4...${NC}"
      sudo mkfs.ext4 -F "$PART"
      ;;
    2)
      echo -e "${CYAN}Создаю один раздел btrfs на весь диск...${NC}"
      sudo parted -s "$dev" mklabel gpt
      sudo parted -s "$dev" mkpart primary btrfs 0% 100%
      sudo parted -s "$dev" set 1 boot on
      sleep 1
      PART="${dev}1"
      echo -e "${CYAN}Форматирую $PART в btrfs...${NC}"
      sudo mkfs.btrfs -f "$PART"
      ;;
    3)
      echo -e "${CYAN}Создаю /boot ext4 + корень btrfs...${NC}"
      sudo parted -s "$dev" mklabel gpt
      sudo parted -s "$dev" mkpart primary ext4 1MiB 1GiB
      sudo parted -s "$dev" set 1 boot on
      sudo parted -s "$dev" mkpart primary btrfs 1GiB 100%
      sleep 1
      PART_BOOT="${dev}1"
      PART_ROOT="${dev}2"
      echo -e "${CYAN}Форматирую $PART_BOOT в ext4...${NC}"
      sudo mkfs.ext4 -F "$PART_BOOT"
      echo -e "${CYAN}Форматирую $PART_ROOT в btrfs...${NC}"
      sudo mkfs.btrfs -f "$PART_ROOT"
      ;;
    4|5)
      echo -e "${CYAN}Пропускаю разметку.${NC}"
      return
      ;;
    *)
      echo -e "${RED}Неверный выбор.${NC}"
      exit 1
      ;;
  esac
}

mount_partitions() {
  local dev="$1"
  local scheme="$2"
  local mnt="$3"

  sudo mkdir -p "$mnt"

  case "$scheme" in
    1|2)
      PART="${dev}1"
      echo -e "${CYAN}Монтирую $PART в $mnt...${NC}"
      sudo mount "$PART" "$mnt"
      ;;
    3)
      PART_BOOT="${dev}1"
      PART_ROOT="${dev}2"
      echo -e "${CYAN}Монтирую $PART_ROOT в $mnt...${NC}"
      sudo mount "$PART_ROOT" "$mnt"
      sudo mkdir -p "$mnt/boot"
      echo -e "${CYAN}Монтирую $PART_BOOT в $mnt/boot...${NC}"
      sudo mount "$PART_BOOT" "$mnt/boot"
      ;;
    4)
      # Использовать существующие разделы — нужно смонтировать их вручную или авто
      echo -e "${CYAN}Монтирую все доступные разделы $dev...${NC}"
      local parts=($(lsblk -n -o NAME "$dev" | tail -n +2))
      local first=1
      for p in "${parts[@]}"; do
        local fstype=$(lsblk -n -o FSTYPE "/dev/$p" 2>/dev/null)
        [[ -z "$fstype" ]] && continue
        local label=$(lsblk -n -o LABEL "/dev/$p" 2>/dev/null | head -1)
        if [[ "$first" -eq 1 ]]; then
          sudo mount "/dev/$p" "$mnt"
          first=0
        else
          sudo mkdir -p "$mnt/boot"
          sudo mount "/dev/$p" "$mnt/boot"
        fi
      done
      if [[ "$first" -eq 1 ]]; then
        echo -e "${RED}Не удалось смонтировать ни одного раздела.${NC}"
        exit 1
      fi
      ;;
    5)
      echo -e "${CYAN}Пропускаю монтирование (диск используется напрямую).${NC}"
      ;;
  esac
}

umount_all() {
  local mnt="$1"

  if mountpoint -q "$mnt/boot" 2>/dev/null; then
    sudo umount "$mnt/boot" || true
  fi
  if mountpoint -q "$mnt" 2>/dev/null; then
    sudo umount "$mnt" || true
  fi
  sudo rm -rf "$mnt"
}

install_grub_if_needed() {
  local dev="$1"
  local mnt="$2"
  local scheme="$3"

  if [[ "$scheme" == "5" ]]; then
    return
  fi

  if [[ -d "$mnt/boot/grub" ]] || [[ -d "$mnt/boot/grub2" ]]; then
    echo ""
    local grub_choice
    read -p "Обнаружен /boot с GRUB. Установить GRUB на $dev? [y/N]: " grub_choice
    if [[ "$grub_choice" =~ ^[Yy]$ ]]; then
      echo -e "${CYAN}Устанавливаю GRUB на $dev...${NC}"
      sudo mount --bind /dev "$mnt/dev" 2>/dev/null || true
      sudo mount --bind /proc "$mnt/proc" 2>/dev/null || true
      sudo mount --bind /sys "$mnt/sys" 2>/dev/null || true
      sudo chroot "$mnt" grub-install "$dev" 2>/dev/null || \
        sudo grub-install --root-directory="$mnt" "$dev"
      sudo umount "$mnt/dev" 2>/dev/null || true
      sudo umount "$mnt/proc" 2>/dev/null || true
      sudo umount "$mnt/sys" 2>/dev/null || true
      echo -e "${GREEN}GRUB установлен.${NC}"
    fi
  fi
}

restore_dar() {
  local archive_path="$1"
  local mnt="$2"

  echo -e "${CYAN}Восстанавливаю DAR-архив в $mnt...${NC}"

  if [[ -f "${archive_path}.1.dar" ]]; then
    sudo dar -x "$archive_path" -R "$mnt" -w
  elif [[ -f "${archive_path}.dar" ]]; then
    sudo dar -x "$archive_path" -R "$mnt" -w
  else
    echo -e "${RED}DAR-архив не найден: ${archive_path}.1.dar или ${archive_path}.dar${NC}"
    exit 1
  fi

  echo -e "${GREEN}DAR-архив восстановлен в $mnt${NC}"
}

restore_raw() {
  local image_path="$1"
  local dev="$2"

  echo -e "${CYAN}Записываю образ на $dev...${NC}"
  sudo dd if="$image_path" of="$dev" bs=4M status=progress conv=fsync
  echo -e "${GREEN}Образ записан на $dev${NC}"
}

# ===== MAIN =====
main() {
  if [[ $# -lt 1 ]]; then
    usage
  fi

  local SRC="$1"

  if [[ ! -e "$SRC" ]] && [[ ! -f "${SRC}.1.dar" ]] && [[ ! -f "${SRC}.dar" ]]; then
    echo -e "${RED}Архив/образ не найден: $SRC${NC}"
    exit 1
  fi

  local TYPE
  TYPE=$(detect_archive_type "$SRC")

  if [[ "$TYPE" == "unknown" ]]; then
    echo -e "${RED}Не удалось определить тип архива/образа: $SRC${NC}"
    echo "  Поддерживается: .1.dar/.dar (DAR), .img/.iso/.raw (dd)"
    exit 1
  fi

  local IMG_SIZE
  if [[ "$TYPE" == "raw" ]]; then
    IMG_SIZE=$(du -h "$SRC" | cut -f1)
  else
    local first_vol
    if [[ -f "${SRC}.1.dar" ]]; then
      first_vol="${SRC}.1.dar"
    else
      first_vol="${SRC}.dar"
    fi
    IMG_SIZE=$(du -h "$first_vol" | cut -f1)
  fi

  echo -e "${CYAN}Источник:${NC} $SRC ($IMG_SIZE, тип: $TYPE)"
  echo ""

  list_disks
  echo ""
  select_disk

  if [[ "$TYPE" == "raw" ]]; then
    restore_raw "$SRC" "$DEVICE"
    echo -e "${GREEN}Готово!${NC}"
    exit 0
  fi

  # DAR restore
  echo ""
  echo -e "${CYAN}Режим восстановления DAR-архива${NC}"
  echo "  Архив будет развёрнут на выбранный диск."
  echo "  Диск будет размечен, отформатирован, и файлы из архива будут восстановлены."
  echo ""

  select_partition_scheme

  local MNT=$(mktemp -d)

  partition_and_format "$DEVICE" "$scheme_choice"
  mount_partitions "$DEVICE" "$scheme_choice" "$MNT"
  restore_dar "$SRC" "$MNT"
  install_grub_if_needed "$DEVICE" "$MNT" "$scheme_choice"
  umount_all "$MNT"

  echo ""
  echo -e "${GREEN}Готово! Диск $DEVICE готов к загрузке.${NC}"
  echo -e "  Можно загрузиться с этого диска или проверить результат:"
  echo -e "    sudo lsblk $DEVICE"
}

main "$@"
