#!/bin/bash
set -euo pipefail

RED='\e[1;31m'; GREEN='\e[1;32m'; YELLOW='\e[1;33m'; CYAN='\e[1;36m'; NC='\e[0m'

DATA_LABEL="rescue-data"
MOUNT_POINT="/mnt/img"
MIN_SIZE=$((5 * 1024**3 / 512))   # 5 ГБ в секторах по 512

CDROM_DEV=$(findmnt -n -o SOURCE /cdrom 2>/dev/null || true)
if [[ -z "$CDROM_DEV" ]]; then
    echo -e "${RED}Не найден /cdrom. Загрузка не с USB?${NC}"
    exit 1
fi

ROOT_PKNAME=$(lsblk -ndo PKNAME "$CDROM_DEV" 2>/dev/null || true)
if [[ "$ROOT_PKNAME" == loop* || -z "$ROOT_PKNAME" ]]; then
    echo -e "${YELLOW}Загрузка с ISO — DATA-раздел не требуется.${NC}"
    exit 0
fi
DISK="/dev/$ROOT_PKNAME"

echo -e "${YELLOW}Загрузочный диск:${NC}"
lsblk -d -o NAME,SIZE,TYPE,MODEL "$DISK"
echo ""

DATA_PART=$(blkid -L "$DATA_LABEL" 2>/dev/null || true)
if [[ -n "$DATA_PART" ]]; then
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        echo -e "${GREEN}Раздел $DATA_LABEL уже смонтирован в $MOUNT_POINT${NC}"
    else
        mkdir -p "$MOUNT_POINT"
        mount "$DATA_PART" "$MOUNT_POINT"
        echo -e "${GREEN}Раздел $DATA_LABEL смонтирован в $MOUNT_POINT${NC}"
        echo -e "${YELLOW}Доступно:${NC} $(df -h "$MOUNT_POINT" | awk 'NR==2 {print $4}')"
    fi
    exit 0
fi

FREE_BLOCKS=$(parted -s "$DISK" unit s print free 2>/dev/null | \
    awk '/Free Space/ {split($2,a,":"); split(a[2],b,"s"); print b[1]}' | tail -1)

if [[ -z "$FREE_BLOCKS" || $FREE_BLOCKS -lt $MIN_SIZE ]]; then
    echo -e "${RED}Недостаточно свободного места (минимум 5 ГБ).${NC}"
    exit 1
fi

echo -e "${YELLOW}Свободно:${NC} $((FREE_BLOCKS * 512 / 1024**3)) ГБ"

echo -e "${CYAN}Создаю раздел $DATA_LABEL...${NC}"
parted -s "$DISK" mkpart primary ext4 100%FREE
udevadm settle

NEW_NUM=$(parted -m "$DISK" unit s print 2>/dev/null | awk -F: '/^[0-9]+/ {n=$1} END {print n}')
if [[ "$ROOT_PKNAME" =~ [0-9]$ ]]; then
    PART_PREFIX="${ROOT_PKNAME}p"
else
    PART_PREFIX="$ROOT_PKNAME"
fi
NEW_PART="/dev/${PART_PREFIX}${NEW_NUM}"

if [[ ! -b "$NEW_PART" ]]; then
    echo -e "${RED}Не удалось определить новый раздел.${NC}"
    exit 1
fi

echo -e "${CYAN}Форматирую $NEW_PART (ext4)...${NC}"
mkfs.ext4 -L "$DATA_LABEL" "$NEW_PART"

echo ""
echo -e "${GREEN}===========================================${NC}"
echo -e "${GREEN}  Раздел $NEW_PART ($DATA_LABEL) создан.${NC}"
echo -e "${GREEN}  Перезагрузитесь, чтобы смонтировать его.${NC}"
echo -e "${GREEN}  После reboot запустите mount_img снова.${NC}"
echo -e "${GREEN}===========================================${NC}"
