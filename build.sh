#!/bin/bash
set -euo pipefail

# ========== ПОЛЬЗОВАТЕЛЬСКИЕ НАСТРОЙКИ ==========
RELEASE="${RELEASE:-noble}"
ARCH="${ARCH:-amd64}"
MIRROR="${MIRROR:-http://archive.ubuntu.com/ubuntu}"
WORKDIR="${WORKDIR:-$(pwd)/rescuebuild}"
IMAGENAME="${IMAGENAME:-RescueOS-${RELEASE}-$(date +%Y%m%d-%H%M).iso}"

# Каталог самого скрипта — нужен для авто-поиска локальных исходников драйверов
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CUSTOM_FILES_DIR="$(pwd)/export"
# Путь к каталогу с дополнительными deb-пакетами (относительно текущей папки скрипта)
CUSTOM_DEB_DIR="$(pwd)/distr"

HOSTNAME="rescuebox"
USERNAME="unknown"
USER_PASS="unknown"
ROOT_PASS="unknown"

# Сеть: статика (несколько IP на одном интерфейсе) или dhcp; по умолчанию dhcp
NETWORK_MODE="${NETWORK_MODE:-dhcp}"   # "static" или "dhcp"
STATIC_IPS=(
  "192.168.137.110/24"
  "192.168.0.110/24"
  "192.168.1.110/24"
  "10.222.255.110/24"
)
STATIC_GATEWAY="192.168.137.1"
STATIC_DNS="8.8.8.8 8.8.4.4"

# DHCP-сервер (dnsmasq) для подсети 192.168.137.0/24, запуск вручную
INSTALL_DHCP_SERVER="yes"      # "yes" - установить dnsmasq
DHCP_SUBNET="192.168.137.0"
DHCP_NETMASK="255.255.255.0"
DHCP_RANGE="192.168.137.50,192.168.137.150"
DHCP_GATEWAY="192.168.137.1"
DHCP_DNS="8.8.8.8"

SQUASHFS_COMP="${SQUASHFS_COMP:-xz}"
SQUASHFS_BLOCK_SIZE="${SQUASHFS_BLOCK_SIZE:-1M}"
ISO_COMPRESSION="${ISO_COMPRESSION:-xz}"
BUILD_THREADS="${BUILD_THREADS:-$(nproc)}"

EXTRA_SYSTEM_PACKAGES=(
   "openvpn"
  "aria2" "netcat-openbsd" "socat" "far2l"
  "python3" "python3-pip" "smartmontools"
  "openssh-server" "sqlite3" "jq"
  "ntfs-3g" "exfatprogs" "dosfstools"
  "testdisk" "gddrescue" "partclone" "clonezilla"
  "btop" "tmux" "screen" "mc" "nmap"
"tcpdump" "wireshark-common" "iftop" "iperf3" "network-manager" "bash-completion" "aircrack-ng" "hcxdumptool" "hcxtools"
  # USB-over-IP (usbip): в Ubuntu ПАКЕТА С ИМЕНЕМ "usbip" НЕ СУЩЕСТВУЕТ.
  #   /usr/bin/usbip, /usr/bin/usbipd (обёртки)      -> linux-tools-common
  #   /usr/lib/linux-tools/<версия>/usbip (бинарник) -> linux-tools-generic
  #   модули ядра vhci-hcd, usbip-core, usbip-host   -> linux-modules-extra-* (зависимость linux-image-generic)
  "linux-tools-common" "linux-tools-generic"
  "ipmitool" "freeipmi" "whiptail"
  "libusb-1.0-0" "libc6"
  "wpasupplicant" "wireless-tools" "gdisk" "usbutils"
  )

# Список имён deb-файлов, которые нужно установить
CUSTOM_DEB_PACKAGES=(
  "libfptr10_10.10.8.0_amd64_uem.deb"
)

EXTRA_PIP_PACKAGES=(
  "requests" "paramiko" "psutil" "pyshtrih"
)
if [[ "$INSTALL_DHCP_SERVER" == "yes" ]]; then
  EXTRA_SYSTEM_PACKAGES+=("dnsmasq")
fi

# ===== WiFi: сторонний драйвер rtl8192eu (Realtek 8192EU, USB) =====
# Рецепт "dkms + отключить встроенный rtl8xxxu" выполняется автоматически
# во время сборки: модуль собирается в chroot и попадает в filesystem.squashfs.
RTL8192EU_ENABLE="${RTL8192EU_ENABLE:-yes}"
RTL8192EU_REPO="${RTL8192EU_REPO:-https://github.com/clnhub/rtl8192eu-linux.git}"
RTL8192EU_REF="${RTL8192EU_REF:-5.11.2.3}"                  # ветка/тег/коммит
RTL8192EU_DKMS_NAME="rtl8192eu"                             # PACKAGE_NAME из dkms.conf
RTL8192EU_DKMS_VER="1.0"                                    # PACKAGE_VERSION из dkms.conf
RTL8192EU_MONITOR_MODE="${RTL8192EU_MONITOR_MODE:-yes}"     # CONFIG_WIFI_MONITOR=y (airmon-ng)
RTL8192EU_BLACKLIST="rtl8xxxu"                              # встроенный драйвер-конкурент
RTL8192EU_PURGE_BUILD_TOOLS="${RTL8192EU_PURGE_BUILD_TOOLS:-yes}"  # убрать gcc после сборки
RTL8192EU_REQUIRED="${RTL8192EU_REQUIRED:-yes}"             # yes = падать, если не собралось
RTL8192EU_SRC_LOCAL="${RTL8192EU_SRC_LOCAL:-}"              # локальная копия исходников (offline)
RTL8192EU_SRC_HOST="${RTL8192EU_SRC_HOST:-$SCRIPT_DIR/.rtl8192eu-src}"  # кэш исходников (рядом со скриптом!)
RTL8192EU_SRC_NAME="rtl8192eu-src"                          # каталог исходников внутри chroot
RTL8192EU_MODULE_NAME="8192eu"                              # BUILT_MODULE_NAME из dkms.conf
# Папки, в которых автоматически ищутся уже скачанные исходники
# (когда GitHub недоступен — достаточно распаковать туда архив драйвера)
RTL8192EU_SRC_CANDIDATES=(
  "rtl8192eu" "rtl8192eu-linux" "rtl8192eu-linux-driver" "rtl8192eu-5.11.2.3"
)
# ==================================================================
# ===============================================

CHROOTDIR="$WORKDIR/chroot"
ISODIR="$WORKDIR/iso"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export DEBCONF_NONINTERACTIVE_SEEN=true
export DEBCONF_NOWARNINGS=yes

MOZILLA_KEY_URL="https://packages.mozilla.org/apt/repo-signing-key.gpg"
MOZILLA_REPO_LINE="deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main"
MOZILLA_KEY_FINGERPRINT="35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"

REQUIRED_PACKAGES=(
  debootstrap xorriso syslinux-utils squashfs-tools grub-pc-bin grub-efi-amd64-bin mtools aria2 git
)

DEBOOTSTRAP_ESSENTIAL=(
  "apt" "dpkg" "gpg" "gnupg" "ca-certificates" "coreutils" "bash" "util-linux" "locales" "wget"
)

SYSTEM_PACKAGES=(
  "sudo" "wget" "curl" "netbase" "net-tools" "iproute2" "iputils-ping"
  "grub-pc" "os-prober" "parted" "fdisk" "e2fsprogs"
  "keyboard-configuration" "console-setup" "locales" "debconf"
  "bind9-utils" "cpio" "cron" "dmidecode" "dosfstools" "ed" "file" "ftp"
  "hdparm" "logrotate" "lshw" "lsof" "man-db" "media-types" "nftables"
  "pciutils" "psmisc" "rsync" "strace" "time" "usbutils" "xz-utils" "zstd"
  "nano" "xxd" "bash-completion" "apt-file" "command-not-found" "less"
  "ntfs-3g" "exfatprogs" "dosfstools"
)

# ВНИМАНИЕ: live-стек ТОЛЬКО casper (Ubuntu). Debian-пакеты live-boot/live-config/
# live-tools ставить НЕЛЬЗЯ: они подменяют update-initramfs и вешают свои initramfs-хуки
# рядом с casper — при загрузке с "boot=casper" это ломает поиск live-носителя.
LIVE_SYSTEM_PACKAGES=(
  "linux-image-generic" "linux-headers-generic"
  "casper" "initramfs-tools" "initramfs-tools-bin" "initramfs-tools-core"
  "systemd" "systemd-sysv" "libpam-systemd" "udev" "uuid-runtime"
  "grub-common" "grub-pc-bin" "grub-efi-amd64-bin"
  "busybox-initramfs" "cryptsetup-initramfs"
  "pciutils" "usbutils" "lshw" "hwdata" "dmidecode"
  "systemd-resolved" "net-tools" "iproute2"
  # Wi-Fi 8192EU: dkms + компилятор собирают внешний модуль, iw/rfkill нужны airmon-ng/airo
  "dkms" "build-essential" "bc" "iw" "rfkill"
  # Plymouth: графическая заставка загрузки (работает в initramfs, без X11;
  # plymouth-themes содержит script-плагин, plymouth-label — текст/шрифты)
  "plymouth" "plymouth-themes" "plymouth-label"
  # Роутер: NAT (iptables) + DHCP/DNS-раздача в проводную сеть
  "iptables"
)

SYSTEM_PACKAGES+=("${EXTRA_SYSTEM_PACKAGES[@]}")
LIVE_SYSTEM_PACKAGES+=("${EXTRA_SYSTEM_PACKAGES[@]}")

BLOCKED_CANONICAL_PACKAGES=(
  "snapd" "snapd-login-service" "gnome-software-plugin-snap"
  "ubuntu-pro-client" "ubuntu-advantage-tools" "apport" "apport-symptoms"
  "whoopsie" "popularity-contest" "landscape-client"
)

# ========== ФУНКЦИИ ==========
log()   { echo -e "[\e[1;34m$(date '+%H:%M:%S')\e[0m] $1"; }
warn()  { echo -e "[\e[1;33mWARN\e[0m] $1" >&2; }
err()   { echo -e "[\e[1;31mERROR\e[0m] $1" >&2; }
success(){ echo -e "[\e[1;32mSUCCESS\e[0m] $1"; }

replace_multiline() {
    local file="$1"
    local placeholder="$2"
    local content="$3"

    # Безопасная (awk-версия) замена строки-маркера на многострочный блок.
    # Прежняя perl-версия (s|\Q$ph\E|\Q$content\E|s) портила содержимое:
    # в replacement \Q\E не даёт литеральности — спецсимволы получали
    # лишние бэкслэши, а "\n" не превращались в переводы строк, из-за чего
    # /etc/systemd/network/20-wired.network становился нерабочим.
    # Маркеры в шаблоне стоят на отдельных строках — используем replace_line_block.
    replace_line_block "$@"
}

# Чтение значения из dkms.conf: read_dkms_var <file> PACKAGE_NAME
read_dkms_var() {
    local file="$1" var="$2" val=""
    val="$(grep -m1 "^${var}=" "$file" 2>/dev/null | cut -d'"' -f2 || true)"
    printf '%s\n' "$val"
}

# Авто-поиск уже скачанных исходников драйвера rtl8192eu.
# Нужен, когда GitHub недоступен: достаточно распаковать архив драйвера
# в папку rtl8192eu/ рядом со скриптом (или указать RTL8192EU_SRC_LOCAL).
# Печатает путь к каталогу, содержащему dkms.conf (пусто, если не найдено).
resolve_wifi_source() {
    local candidates=() c found
    if [[ -n "$RTL8192EU_SRC_LOCAL" ]]; then
        candidates+=("$RTL8192EU_SRC_LOCAL")
    fi
    for c in "${RTL8192EU_SRC_CANDIDATES[@]}"; do
        candidates+=("$(pwd)/$c" "$SCRIPT_DIR/$c")
    done
    for c in "${candidates[@]}"; do
        [[ -d "$c" ]] || continue
        if [[ -f "$c/dkms.conf" ]]; then printf '%s\n' "$c"; return 0; fi
        # Архив с GitHub распаковывается во вложенную папку (rtl8192eu-linux-5.11.2.3/)
        found="$(find "$c" -maxdepth 2 -name 'dkms.conf' 2>/dev/null | head -1)"
        if [[ -n "$found" ]]; then dirname "$found"; return 0; fi
    done
    printf '\n'
}

# Замена строки-маркера на многострочный блок.
# В отличие от replace_multiline безопасна для текста с |, $, \ и кавычками
# (perl-версия использует | как разделитель и ломается на пайпах).
replace_line_block() {
    local file="$1"
    local marker="$2"
    local content="$3"
    local blockfile
    blockfile="$(mktemp)"
    printf '%s\n' "$content" > "$blockfile"
    awk -v marker="$marker" -v bf="$blockfile" '
        $0 == marker { while ((getline line < bf) > 0) print line; next }
        { print }
    ' "$file" > "$file.replaced" && mv "$file.replaced" "$file"
    rm -f "$blockfile"
}

cleanup() {
  if [[ "${CLEANUP_RUNNING:-}" == "1" ]]; then return; fi
  CLEANUP_RUNNING=1
  log "Starting cleanup..."
  if [[ -n "${CHROOTDIR:-}" && -d "$CHROOTDIR" ]]; then
    for mp in dev/pts proc sys run dev; do
      mountpoint -q "$CHROOTDIR/$mp" 2>/dev/null && sudo umount -l "$CHROOTDIR/$mp" || true
    done
  fi
  if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" && "$WORKDIR" != "/" && "$WORKDIR" != "$HOME" ]]; then
    if [[ "${PRESERVE_WORKDIR:-}" != "1" ]]; then
      sudo rm -rf "$WORKDIR"
    else
      log "Preserving workdir: $WORKDIR"
    fi
  fi
}

handle_error() {
  local line_no=$1
  local exit_code=$2
  err "Script failed at line $line_no with exit code $exit_code"
  if [[ -f "$CHROOTDIR/tmp/chroot.log" ]]; then
    tail -20 "$CHROOTDIR/tmp/chroot.log"
  fi
}
trap 'handle_error $LINENO $?' ERR
trap cleanup EXIT INT TERM

create_apt_config() {
  sudo mkdir -p /etc/apt/apt.conf.d/
  sudo tee /etc/apt/apt.conf.d/99no-warnings >/dev/null <<EOF
APT::Get::Assume-Yes "true";
APT::Get::Fix-Broken "true";
DPkg::Options "--force-confold";
DPkg::Options "--force-confdef";
DPkg::Options "--force-overwrite";
Dpkg::Use-Pty "0";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF
}

check_dependencies() {
  log "Checking build dependencies..."
  local missing=()
  for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then missing+=("$pkg"); fi
  done
  if [[ ${#missing[@]} -ne 0 ]]; then
    log "Installing missing packages: ${missing[*]}"
    create_apt_config
    sudo apt-get -qq update
    sudo apt-get -qq install -y "${missing[@]}"
  fi
  local opt_missing=()
  for pkg in aria2 pigz pbzip2; do
    if ! dpkg -s "$pkg" &>/dev/null; then opt_missing+=("$pkg"); fi
  done
  if [[ ${#opt_missing[@]} -ne 0 ]]; then
    log "Optional packages: ${opt_missing[*]}"
    read -p "Install optional packages? [y/N]: " -n 1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then sudo apt-get -qq install -y "${opt_missing[@]}"; fi
  fi
}

detect_timezone() {
  local tz=""
  if command -v timedatectl >/dev/null; then
    tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")
  fi
  if [[ -z "$tz" && -L /etc/localtime ]]; then
    tz=$(readlink /etc/localtime | sed 's|^.*/zoneinfo/||')
  fi
  if [[ -z "$tz" && -f /etc/timezone ]]; then
    tz=$(cat /etc/timezone)
  fi
  if [[ -n "$tz" && -f "/usr/share/zoneinfo/$tz" ]]; then echo "$tz"; else echo "UTC"; fi
}

validate_packages() {
  log "Validating package availability..."
  local temp_sources="/tmp/sources.list.$$"
  cat > "$temp_sources" <<EOF
deb $MIRROR $RELEASE main restricted universe multiverse
deb $MIRROR $RELEASE-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $RELEASE-security main restricted universe multiverse
EOF
  for pkg in "linux-image-generic" "live-boot" "casper"; do
    if ! apt-cache --option Dir::Etc::SourceList="$temp_sources" search "^$pkg\$" >/dev/null 2>&1; then
      warn "Package $pkg might not be available for $RELEASE"
    fi
  done
  rm -f "$temp_sources"
}

run_debootstrap() {
  local include_list=$(IFS=,; echo "${DEBOOTSTRAP_ESSENTIAL[*]}")
  local exclude_list=$(IFS=,; echo "${BLOCKED_CANONICAL_PACKAGES[*]}")
  log "Running debootstrap (minbase) with includes: $include_list"
  local opts="--arch=$ARCH --variant=minbase --include=$include_list --exclude=$exclude_list"
  if command -v aria2c >/dev/null; then
    export DEBOOTSTRAP_DOWNLOAD_OPTS="--continue --max-connection-per-server=5 --max-concurrent-downloads=5"
  fi
  sudo debootstrap $opts $RELEASE "$CHROOTDIR" "$MIRROR"
}

# ========== MAIN ==========
main() {
  local start_time=$(date +%s)
  if [[ $EUID -eq 0 ]]; then err "Do not run as root"; exit 1; fi
  if ! sudo -n true 2>/dev/null; then sudo true; fi

  local host_timezone=$(detect_timezone)
  log "Timezone: $host_timezone"
  check_dependencies
  validate_packages

  log "Creating directories: $WORKDIR"
  sudo mkdir -p "$CHROOTDIR" "$ISODIR"
  run_debootstrap

  # Настройка chroot
  log "Configuring chroot environment..."
  [[ -f "$CHROOTDIR/etc/resolv.conf" ]] && sudo cp "$CHROOTDIR/etc/resolv.conf" "$CHROOTDIR/etc/resolv.conf.orig"
  sudo cp /etc/resolv.conf "$CHROOTDIR/etc/"
  for dir in dev dev/pts proc sys run; do
    if ! mountpoint -q "$CHROOTDIR/$dir" 2>/dev/null; then
      sudo mkdir -p "$CHROOTDIR/$dir"
      sudo mount --bind "/$dir" "$CHROOTDIR/$dir"
    fi
  done

  local system_packages_str=$(IFS=' '; echo "${SYSTEM_PACKAGES[*]}")
  local live_packages_str=$(IFS=' '; echo "${LIVE_SYSTEM_PACKAGES[*]}")
  local blocked_space=$(printf "%s" "${BLOCKED_CANONICAL_PACKAGES[*]}")
  local apt_pinning_rules=""
  for pkg in "${BLOCKED_CANONICAL_PACKAGES[@]}"; do
    apt_pinning_rules+="Package: $pkg"$'\n'"Pin: release *"$'\n'"Pin-Priority: -1"$'\n\n'
  done

  # Создаём APT pinning для блокировки нежелательных пакетов
  log "Generating APT pinning rules for blocked packages..."
  sudo mkdir -p "$CHROOTDIR/etc/apt/preferences.d"
  for pkg in "${BLOCKED_CANONICAL_PACKAGES[@]}"; do
      printf "Package: %s\nPin: release *\nPin-Priority: -1\n\n" "$pkg" | sudo tee -a "$CHROOTDIR/etc/apt/preferences.d/no-canonical" >/dev/null
  done

  # ===== WiFi: исходники драйвера rtl8192eu =====
  local wifi_driver_block=""
  if [[ "$RTL8192EU_ENABLE" == "yes" ]]; then
    local wifi_local_src="" wifi_src_origin=""
    wifi_local_src="$(resolve_wifi_source)"
    if [[ -n "$wifi_local_src" ]]; then
      # Локальная копия имеет приоритет: работает без интернета и всегда свежая
      log "WiFi driver: найдены локальные исходники: $wifi_local_src"
      rm -rf "$RTL8192EU_SRC_HOST"
      cp -r "$wifi_local_src" "$RTL8192EU_SRC_HOST"
      wifi_src_origin="локальная копия $wifi_local_src"
    elif [[ -f "$RTL8192EU_SRC_HOST/dkms.conf" ]]; then
      log "WiFi driver: использую кэш исходников $RTL8192EU_SRC_HOST"
      wifi_src_origin="кэш сборки $RTL8192EU_SRC_HOST"
    else
      log "WiFi driver: скачиваю $RTL8192EU_REPO ($RTL8192EU_REF)..."
      rm -rf "$RTL8192EU_SRC_HOST"
      if ! git clone --depth 1 --branch "$RTL8192EU_REF" "$RTL8192EU_REPO" "$RTL8192EU_SRC_HOST"; then
        err "Не удалось скачать драйвер rtl8192eu: $RTL8192EU_REPO ($RTL8192EU_REF)"
        err ""
        err "Как исправить (любой из вариантов):"
        err "  1) Скачайте архив драйвера на другой машине и распакуйте рядом со скриптом:"
        err "       ${SCRIPT_DIR}/rtl8192eu/"
        err "     Внутри обязательно должен быть файл dkms.conf."
        err "     Ссылка: ${RTL8192EU_REPO%.git}  (ветка ${RTL8192EU_REF}, Code -> Download ZIP)"
        err "  2) Или укажите путь к уже скачанным исходникам явно:"
        err "       RTL8192EU_SRC_LOCAL=/путь/к/rtl8192eu ./build.sh"
        err "  3) Или соберите образ без этого драйвера:"
        err "       RTL8192EU_ENABLE=no ./build.sh"
        exit 1
      fi
      wifi_src_origin="git clone $RTL8192EU_REPO ($RTL8192EU_REF)"
    fi

    if [[ ! -f "$RTL8192EU_SRC_HOST/dkms.conf" ]]; then
      err "В $RTL8192EU_SRC_HOST нет dkms.conf — это не исходники драйвера rtl8192eu"
      err "Распакуйте в ${SCRIPT_DIR}/rtl8192eu/ корень архива драйвера (там, где dkms.conf и Makefile)."
      exit 1
    fi

    # Имена/версию берём из dkms.conf — сборка не развалится на другом форке драйвера
    local dkms_name dkms_ver dkms_mod
    dkms_name="$(read_dkms_var "$RTL8192EU_SRC_HOST/dkms.conf" PACKAGE_NAME)"
    dkms_ver="$(read_dkms_var "$RTL8192EU_SRC_HOST/dkms.conf" PACKAGE_VERSION)"
    dkms_mod="$(read_dkms_var "$RTL8192EU_SRC_HOST/dkms.conf" 'BUILT_MODULE_NAME\[0\]')"
    if [[ -n "$dkms_name" ]]; then RTL8192EU_DKMS_NAME="$dkms_name"; fi
    if [[ -n "$dkms_ver" ]];  then RTL8192EU_DKMS_VER="$dkms_ver"; fi
    if [[ -n "$dkms_mod" ]];  then RTL8192EU_MODULE_NAME="$dkms_mod"; fi

    log "  источник: $wifi_src_origin"
    log "  dkms: $RTL8192EU_DKMS_NAME/$RTL8192EU_DKMS_VER, модуль: $RTL8192EU_MODULE_NAME.ko"
    log "  source commit: $(git -C "$RTL8192EU_SRC_HOST" rev-parse --short HEAD 2>/dev/null || echo 'нет git (распакованный архив)')"

    # Режим монитора/инъекций — нужен airmon-ng/airodump-ng (есть в образе)
    if [[ "$RTL8192EU_MONITOR_MODE" == "yes" ]]; then
      sed -i 's/^CONFIG_WIFI_MONITOR[[:space:]]*=[[:space:]]*n/CONFIG_WIFI_MONITOR = y/' "$RTL8192EU_SRC_HOST/Makefile"
      if grep -q '^CONFIG_WIFI_MONITOR[[:space:]]*=[[:space:]]*y' "$RTL8192EU_SRC_HOST/Makefile"; then
        success "CONFIG_WIFI_MONITOR=y (режим монитора включён)"
      else
        warn "Не удалось включить CONFIG_WIFI_MONITOR в Makefile драйвера"
      fi
    fi

    sudo rm -rf "$CHROOTDIR/usr/src/$RTL8192EU_SRC_NAME"
    sudo mkdir -p "$CHROOTDIR/usr/src/$RTL8192EU_SRC_NAME"
    sudo cp -a "$RTL8192EU_SRC_HOST/." "$CHROOTDIR/usr/src/$RTL8192EU_SRC_NAME/"
    sudo rm -rf "$CHROOTDIR/usr/src/$RTL8192EU_SRC_NAME/.git"

    # Блок, который выполнится ВНУТРИ chroot (подставляется в WIFI_DRIVER_PLACEHOLDER)
    wifi_driver_block=$(cat <<'WIFIEOF'
# ===== WiFi: сборка стороннего драйвера rtl8192eu (DKMS) =====
if [ -d /usr/src/WIFI_SRC_DIR_PLACEHOLDER ]; then
  echo "=== Building third-party WiFi driver rtl8192eu (DKMS) ==="
  # ВАЖНО: uname -r внутри chroot указывает на ядро СБОРОЧНОЙ машины,
  # поэтому версии ядер берём из /lib/modules и передаём в dkms через -k.
  KERNELS="$(ls -1 /lib/modules | sort -V)"
  echo "Kernels in image: $(echo $KERNELS)"
  apt-get -qq install -y --no-install-recommends dkms build-essential bc
  for KVER in $KERNELS; do
    # без headers этого ядра модуль не собрать — не валим скрипт, сообщаем явно
    apt-get -qq install -y --no-install-recommends linux-headers-"$KVER" \
      || echo "WARNING: не удалось поставить linux-headers-$KVER — ядро будет пропущено"
  done
  # Идемпотентность: если модуль уже был зарегистрирован — снимаем регистрацию
  dkms remove -m WIFI_DKMS_NAME_PLACEHOLDER -v WIFI_DKMS_VER_PLACEHOLDER --all >/dev/null 2>&1 || true
  mkdir -p /usr/src/WIFI_DKMS_NAME_PLACEHOLDER-WIFI_DKMS_VER_PLACEHOLDER
  cp -a /usr/src/WIFI_SRC_DIR_PLACEHOLDER/. /usr/src/WIFI_DKMS_NAME_PLACEHOLDER-WIFI_DKMS_VER_PLACEHOLDER/
  # .git в дереве DKMS не нужен — не тащим его в образ
  rm -rf /usr/src/WIFI_DKMS_NAME_PLACEHOLDER-WIFI_DKMS_VER_PLACEHOLDER/.git
  if ! dkms add -m WIFI_DKMS_NAME_PLACEHOLDER -v WIFI_DKMS_VER_PLACEHOLDER; then
    echo "ERROR: dkms add не удался для WIFI_DKMS_NAME_PLACEHOLDER/WIFI_DKMS_VER_PLACEHOLDER"
    rm -rf /usr/src/WIFI_DKMS_NAME_PLACEHOLDER-WIFI_DKMS_VER_PLACEHOLDER
    tail -20 /var/lib/dkms/WIFI_DKMS_NAME_PLACEHOLDER/WIFI_DKMS_VER_PLACEHOLDER/build/make.log 2>/dev/null || true
    if [ "WIFI_REQUIRED_PLACEHOLDER" = "yes" ]; then exit 1; fi
  fi
  WIFI_OK=1
  for KVER in $KERNELS; do
    if ! dkms install -m WIFI_DKMS_NAME_PLACEHOLDER -v WIFI_DKMS_VER_PLACEHOLDER -k "$KVER"; then
      WIFI_OK=0
      echo "ERROR: dkms не смог собрать WIFI_DKMS_NAME_PLACEHOLDER для ядра $KVER"
      tail -40 /var/lib/dkms/WIFI_DKMS_NAME_PLACEHOLDER/WIFI_DKMS_VER_PLACEHOLDER/build/make.log 2>/dev/null || true
    fi
    depmod -a "$KVER" || true
    # Контроль: модуль должен быть собран ИМЕННО для этого ядра.
    # (в Makefile есть KVER := $(shell uname -r), но значение из командной строки
    #  dkms.conf (KVER=${kernelver}) переопределяет его — проверяем результат)
    KO="$(find /lib/modules/"$KVER" -name 'WIFI_MODULE_PLACEHOLDER.ko' 2>/dev/null | head -1)"
    if [ -n "$KO" ]; then
      VM="$(modinfo -F vermagic "$KO" 2>/dev/null | awk '{print $1}')"
      if [ "$VM" = "$KVER" ]; then
        echo "OK: WIFI_MODULE_PLACEHOLDER.ko собран для $KVER ($KO)"
      else
        echo "WARNING: vermagic модуля ($VM) не совпадает с ядром ($KVER)!"
      fi
    fi
  done
  if [ "$WIFI_OK" = "1" ]; then
    echo "OK: модуль WIFI_MODULE_PLACEHOLDER собран для всех ядер образа"
  else
    echo "WARNING: сборка драйвера 8192eu завершилась с ошибкой"
    if [ "WIFI_REQUIRED_PLACEHOLDER" = "yes" ]; then
      echo "FATAL: RTL8192EU_REQUIRED=yes — прерываю сборку образа"
      exit 1
    fi
  fi
  rm -rf /usr/src/WIFI_SRC_DIR_PLACEHOLDER
  # Встроенный драйвер ядра rtl8xxxu претендует на те же USB-ID — отключаем его
  cat > /etc/modprobe.d/WIFI_BLACKLIST_PLACEHOLDER-blacklist.conf <<'MODBLEOF'
blacklist WIFI_BLACKLIST_PLACEHOLDER
install WIFI_BLACKLIST_PLACEHOLDER /bin/false
MODBLEOF
  # Хелпер: перезапуск драйвера без перезагрузки системы
  cat > /usr/local/bin/wifi-rtl8192eu <<'WIFIHELP'
#!/bin/bash
# Перезапуск стороннего драйвера WIFI_MODULE_PLACEHOLDER (Realtek 8192EU)
modprobe -r WIFI_BLACKLIST_PLACEHOLDER 2>/dev/null || true
modprobe -r WIFI_MODULE_PLACEHOLDER 2>/dev/null || true
modprobe WIFI_MODULE_PLACEHOLDER
echo "--- lsmod ---"
lsmod | grep -E 'WIFI_MODULE_PLACEHOLDER|WIFI_BLACKLIST_PLACEHOLDER' || echo "модуль WIFI_MODULE_PLACEHOLDER не загрузился"
echo "--- карта ---"
lshw -c network 2>/dev/null | grep -E 'driver=|Wireless interface' || true
WIFIHELP
  chmod +x /usr/local/bin/wifi-rtl8192eu
  if [ "WIFI_PURGE_PLACEHOLDER" = "yes" ]; then
    echo "Removing build tools (RTL8192EU_PURGE_BUILD_TOOLS=yes)..."
    apt-get -qq purge -y build-essential gcc g++ cpp || true
  fi
  echo "=== WiFi driver step completed ==="
fi
WIFIEOF
)
    wifi_driver_block="${wifi_driver_block//WIFI_MODULE_PLACEHOLDER/$RTL8192EU_MODULE_NAME}"
    wifi_driver_block="${wifi_driver_block//WIFI_SRC_DIR_PLACEHOLDER/$RTL8192EU_SRC_NAME}"
    wifi_driver_block="${wifi_driver_block//WIFI_DKMS_NAME_PLACEHOLDER/$RTL8192EU_DKMS_NAME}"
    wifi_driver_block="${wifi_driver_block//WIFI_DKMS_VER_PLACEHOLDER/$RTL8192EU_DKMS_VER}"
    wifi_driver_block="${wifi_driver_block//WIFI_BLACKLIST_PLACEHOLDER/$RTL8192EU_BLACKLIST}"
    wifi_driver_block="${wifi_driver_block//WIFI_REQUIRED_PLACEHOLDER/$RTL8192EU_REQUIRED}"
    wifi_driver_block="${wifi_driver_block//WIFI_PURGE_PLACEHOLDER/$RTL8192EU_PURGE_BUILD_TOOLS}"
  else
    log "WiFi driver rtl8192eu disabled (RTL8192EU_ENABLE=no)"
  fi

  # Генерация NetworkManager keyfile. Один сетевой стек: NetworkManager + systemd-resolved.
  local nm_connection=""
  if [[ "$NETWORK_MODE" == "static" ]]; then
    local idx=1
    nm_connection=$'[connection]
id=Rescue-Network
type=ethernet
autoconnect=true

[ipv4]
method=manual
'
    for ip in "${STATIC_IPS[@]}"; do
      nm_connection+="address${idx}=$ip
"
      ((idx++))
    done
    nm_connection+=$'\n# Ethernet по умолчанию НЕ является шлюзом (never-default):\n# Wi-Fi остаётся WAN. Если нужен провод как WAN — задайте gateway вручную:\n# nmcli con mod Rescue-Network ipv4.never-default no ipv4.gateway '$STATIC_GATEWAY$'\nnever-default=true\n'
    nm_connection+="dns=$STATIC_DNS;
"
    nm_connection+=$'

[ipv6]
method=disabled
'
  else
    nm_connection=$'[connection]
id=Rescue-Network
type=ethernet
autoconnect=true
multi-connect=3

[ipv4]
method=auto

[ipv6]
method=auto
'
  fi

  # Конфиг для dnsmasq (если включён)
  local dnsmasq_config=""
  if [[ "$INSTALL_DHCP_SERVER" == "yes" ]]; then
      dnsmasq_config=$(cat <<EOF
bind-dynamic
dhcp-range=$DHCP_RANGE
dhcp-option=3,$DHCP_GATEWAY
dhcp-option=6,$DHCP_DNS
dhcp-option=1,$DHCP_NETMASK
EOF
  )
  fi

  # ===== Plymouth: тема загрузки RescueOS (вставляется в chroot-скрипт) =====
  local plymouth_block="$(cat <<'PLYBLOCK'
# ===== Plymouth: кастомная тема RescueOS =====
echo "Installing custom Plymouth theme..."
mkdir -p /usr/share/plymouth/themes/rescueos

cat > /usr/share/plymouth/themes/rescueos/rescueos.plymouth <<'PLYEOF'
[Plymouth Theme]
Name=RescueOS
Description=RescueOS animated boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/rescueos
ScriptFile=/usr/share/plymouth/themes/rescueos/rescueos.script
PLYEOF

cat > /usr/share/plymouth/themes/rescueos/rescueos.script <<'SCRIPTPLY'
# ============================================================
#  RescueOS Plymouth theme - animated boot splash
# ============================================================

# --- Фон: тёмный градиент ---
Window.SetBackgroundTopColor(0.04, 0.05, 0.09);
Window.SetBackgroundBottomColor(0.00, 0.00, 0.02);

cx = Window.GetWidth()  / 2;
cy = Window.GetHeight() / 2;

# --- Заголовок с лёгким зелёным свечением ---
title = Image.Text("RESCUE OS", 0.25, 0.95, 0.55);
title_sprite = Sprite(title);
title_sprite.SetX(cx - title.GetWidth()  / 2);
title_sprite.SetY(cy - 60);

subtitle = Image.Text("Recovery Environment", 0.55, 0.60, 0.70);
sub_sprite = Sprite(subtitle);
sub_sprite.SetX(cx - subtitle.GetWidth() / 2);
sub_sprite.SetY(cy - 60 + title.GetHeight() + 6);

status = Image.Text("Загрузка системы...", 0.7, 0.7, 0.75);
status_sprite = Sprite(status);
status_sprite.SetX(cx - status.GetWidth() / 2);
status_sprite.SetY(cy + 110);

# --- Пять пульсирующих точек под заголовком (без массивов) ---
r = 0.15; g = 0.85; b = 0.45;

d0 = Image.Text("●", r, g, b); s0 = Sprite(d0);
d1 = Image.Text("●", r, g, b); s1 = Sprite(d1);
d2 = Image.Text("●", r, g, b); s2 = Sprite(d2);
d3 = Image.Text("●", r, g, b); s3 = Sprite(d3);
d4 = Image.Text("●", r, g, b); s4 = Sprite(d4);

s0.SetX(cx - 60 - 8); s0.SetY(cy + 60);
s1.SetX(cx - 30 - 8); s1.SetY(cy + 60);
s2.SetX(cx -  8);     s2.SetY(cy + 60);
s3.SetX(cx + 30 - 8); s3.SetY(cy + 60);
s4.SetX(cx + 60 - 8); s4.SetY(cy + 60);

s0.SetOpacity(0.15); s1.SetOpacity(0.15); s2.SetOpacity(0.15);
s3.SetOpacity(0.15); s4.SetOpacity(0.15);

# --- Анимация "бегущая волна" ---
tick = 0;
step = 0;

fun animate() {
    tick = tick + 1;
    if (tick >= 12) {
        tick = 0;
        step = step + 1;
        if (step > 7) { step = 0; }
    }

    # Волна: каждая точка вспыхивает по очереди, потом все гаснут
    if (step == 0) { s0.SetOpacity(1.0); s1.SetOpacity(0.15); s2.SetOpacity(0.15); s3.SetOpacity(0.15); s4.SetOpacity(0.15); }
    if (step == 1) { s0.SetOpacity(0.4); s1.SetOpacity(1.0);  s2.SetOpacity(0.15); s3.SetOpacity(0.15); s4.SetOpacity(0.15); }
    if (step == 2) { s0.SetOpacity(0.15); s1.SetOpacity(0.4); s2.SetOpacity(1.0);  s3.SetOpacity(0.15); s4.SetOpacity(0.15); }
    if (step == 3) { s0.SetOpacity(0.15); s1.SetOpacity(0.15); s2.SetOpacity(0.4); s3.SetOpacity(1.0);  s4.SetOpacity(0.15); }
    if (step == 4) { s0.SetOpacity(0.15); s1.SetOpacity(0.15); s2.SetOpacity(0.15); s3.SetOpacity(0.4); s4.SetOpacity(1.0);  }
    if (step == 5) { s0.SetOpacity(1.0); s1.SetOpacity(0.15); s2.SetOpacity(0.15); s3.SetOpacity(0.15); s4.SetOpacity(0.15); }
    if (step == 6) { s0.SetOpacity(1.0); s1.SetOpacity(1.0);  s2.SetOpacity(1.0);  s3.SetOpacity(1.0);  s4.SetOpacity(1.0);  }
    if (step == 7) { s0.SetOpacity(0.5); s1.SetOpacity(0.5);  s2.SetOpacity(0.5);  s3.SetOpacity(0.5);  s4.SetOpacity(0.5);  }
}

Plymouth.SetRefreshFunction(animate);
SCRIPTPLY

chmod 644 /usr/share/plymouth/themes/rescueos/rescueos.plymouth
chmod 644 /usr/share/plymouth/themes/rescueos/rescueos.script

# Активируем тему как дефолтную
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    plymouth-set-default-theme rescueos || true
fi

# Меньше текста на консоли поверх заставки
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3"/' /etc/default/grub 2>/dev/null || true
# ===== /Plymouth =====
PLYBLOCK
)"

  # ===== Роутер: NAT wlan->eth + DHCP/DNS (вставляется в chroot-скрипт) =====
  local router_block="$(cat <<'ROUTERBLOCK'
# ===== Роутер RescueOS: интернет по WiFi -> раздача в проводную сеть (IPv4) =====
echo "Installing RescueOS router helper..."
systemctl disable --now dnsmasq 2>/dev/null || true   # системный dnsmasq не используем

mkdir -p /usr/local/bin

cat > /usr/local/bin/router <<'ROUTER_SH'
#!/bin/bash
# RescueOS router: WAN = WiFi (default route), LAN = провод.
# NAT (MASQUERADE) + DHCP/DNS через dnsmasq. Только IPv4.
LAN_SUBNET="192.168.137.0/24"
LAN_IP="192.168.137.110"
DHCP_RANGE="192.168.137.50,192.168.137.150,12h"
CONF="/run/rescue-dnsmasq.conf"
PID="/run/rescue-dnsmasq.pid"
LOG="/var/log/rescue-router.log"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

find_wan() {  # беспроводной интерфейс с default-маршрутом
  local if_
  for if_ in $(ip -4 route show default 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | sort -u); do
    [ -d "/sys/class/net/$if_/wireless" ] && { echo "$if_"; return 0; }
  done
  return 1
}

find_lan() {  # проводной интерфейс, на котором назначен LAN_IP
  local if_
  for if_ in $(ls /sys/class/net 2>/dev/null | grep -vE '^(lo|wlan|wlp|ww|docker|virbr|veth|tap|tun)'); do
    [ -d "/sys/class/net/$if_/wireless" ] && continue
    ip -4 addr show dev "$if_" 2>/dev/null | grep -q "$LAN_IP" && { echo "$if_"; return 0; }
  done
  return 1
}

wait_up() {  # ждём до 3 минут: wifi-интернет + провод с LAN_IP
  local i=0
  while [ "$i" -lt 90 ]; do
    if find_wan >/dev/null && find_lan >/dev/null; then return 0; fi
    sleep 2; i=$((i+2))
  done
  return 1
}

start() {
  if ! wait_up; then
    log "router не запущен: нет WiFi-интернета и/или проводного LAN с $LAN_IP"
    exit 0
  fi
  local wan lan
  wan=$(find_wan); lan=$(find_lan)
  sysctl -qw net.ipv4.ip_forward=1
  iptables -t nat -C POSTROUTING -s "$LAN_SUBNET" -o "$wan" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$LAN_SUBNET" -o "$wan" -j MASQUERADE
  iptables -C FORWARD -i "$lan" -o "$wan" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$lan" -o "$wan" -j ACCEPT
  iptables -C FORWARD -i "$wan" -o "$lan" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$wan" -o "$lan" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  cat > "$CONF" <<CONF
interface=$lan
bind-interfaces
except-interface=lo
dhcp-authoritative
dhcp-range=$DHCP_RANGE
dhcp-option=3,$LAN_IP
dhcp-option=6,$LAN_IP
dhcp-option=1,255.255.255.0
server=8.8.8.8
CONF
  dnsmasq --conf-file="$CONF" --pid-file="$PID"
  log "router UP: WAN=$wan LAN=$lan ($LAN_IP) DHCP=$DHCP_RANGE"
}

stop() {
  if [ -f "$PID" ]; then kill "$(cat "$PID")" 2>/dev/null || true; fi
  rm -f "$PID" "$CONF"
  iptables -t nat -S POSTROUTING 2>/dev/null | grep MASQUERADE | sed 's/^-A //' | \
    while read -r r; do iptables -t nat -D $r 2>/dev/null || true; done
  iptables -S FORWARD 2>/dev/null | grep conntrack | sed 's/^-A //' | \
    while read -r r; do iptables -D $r 2>/dev/null || true; done
  iptables -S FORWARD 2>/dev/null | grep -F "-o $(find_wan 2>/dev/null)" | sed 's/^-A //' | \
    while read -r r; do iptables -D $r 2>/dev/null || true; done
  sysctl -qw net.ipv4.ip_forward=0
  log "router stopped"
}

status() {
  if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
    echo "router: АКТИВЕН  WAN=$(find_wan || echo '?')  LAN=$(find_lan || echo '?')  DHCP=$DHCP_RANGE"
    iptables -t nat -S POSTROUTING 2>/dev/null | grep MASQUERADE || true
  else
    echo "router: не активен"
    echo "hint: sudo router start   (включается вручную: NAT+DHCP WiFi->провод)"
  fi
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  *) echo "usage: router {start|stop|restart|status}"; exit 1 ;;
esac
ROUTER_SH
chmod 755 /usr/local/bin/router

cat > /etc/systemd/system/rescue-router.service <<'UNIT'
[Unit]
Description=RescueOS router (NAT + DHCP/DNS over WiFi uplink, IPv4)
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/router start
ExecStop=/usr/local/bin/router stop
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT
systemctl disable rescue-router.service 2>/dev/null || true  # режим роутера включается вручную: sudo router start
echo "Router helper installed (sudo router status)"
# ===== /Роутер =====
ROUTERBLOCK
)"

  local config_script="/tmp/configure_chroot_$$.sh"
  cat > "$config_script" <<'SCRIPT_EOF'
#!/bin/bash
set -e
exec > >(tee /tmp/chroot.log) 2>&1

export LANG=C.UTF-8 LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none
export DEBCONF_NONINTERACTIVE_SEEN=true DEBCONF_NOWARNINGS=yes

echo "=== System Configuration ==="; date

# hostname, locale
echo "HOSTNAME_PLACEHOLDER" > /etc/hostname
echo "ru_RU.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=ru_RU.UTF-8 LANGUAGE=ru_RU LC_ALL=ru_RU.UTF-8

# timezone
ln -sfn "/usr/share/zoneinfo/TIMEZONE_PLACEHOLDER" /etc/localtime
echo "TIMEZONE_PLACEHOLDER" > /etc/timezone

# hosts
cat > /etc/hosts <<HOSTS
127.0.0.1      localhost
127.0.1.1      HOSTNAME_PLACEHOLDER
::1            localhost ip6-localhost ip6-loopback
ff02::1        ip6-allnodes
ff02::2        ip6-allrouters
HOSTS

# apt sources
cat > /etc/apt/sources.list <<LIST
deb MIRROR_PLACEHOLDER RELEASE_PLACEHOLDER main restricted universe multiverse
deb MIRROR_PLACEHOLDER RELEASE_PLACEHOLDER-updates main restricted universe multiverse
deb MIRROR_PLACEHOLDER RELEASE_PLACEHOLDER-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu RELEASE_PLACEHOLDER-security main restricted universe multiverse
LIST
sed -i '/^deb cdrom:/d' /etc/apt/sources.list

# apt config
mkdir -p /etc/apt/apt.conf.d/
cat > /etc/apt/apt.conf.d/99no-recommends <<EOF
APT::Acquire::Retries "3";
APT::Acquire::http::Timeout "10";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "en";
APT::Get::Assume-Yes "true";
DPkg::Options "--force-confold";
DPkg::Options "--force-confdef";
DPkg::Options "--force-overwrite";
Dpkg::Use-Pty "0";
EOF

# mozilla repo
install -d -m 0755 /etc/apt/keyrings
wget -q MOZILLA_KEY_URL_PLACEHOLDER -O- | tee /etc/apt/keyrings/packages.mozilla.org.asc > /dev/null
echo "MOZILLA_REPO_LINE_PLACEHOLDER" | tee -a /etc/apt/sources.list.d/mozilla.list > /dev/null
cat > /etc/apt/preferences.d/mozilla <<EOF
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF

apt-get -qq update

# purge blocked packages
for pkg in BLOCKED_SPACE_PLACEHOLDER; do
  if dpkg -s "$pkg" &>/dev/null; then
    apt-get -qq purge -y --allow-remove-essential "$pkg" || true
  fi
done
apt-get -qq update || true
apt-get -qq autoremove -y || true

# install packages
echo "Installing system packages..."
apt-get -qq install -y SYSTEM_PACKAGES_PLACEHOLDER
echo "Installing live system packages..."
apt-get -qq install -y LIVE_PACKAGES_PLACEHOLDER

# now setup console font (after console-setup is installed)
# Кириллица в TTY: дефолтный Fixed16 глифов кириллицы не содержит (квадратики).
# Terminus + CHARMAP=UTF-8 -> console-setup применит вариант CyrSlav-Terminus16.
cat > /etc/default/console-setup <<CONSOLESETUP
CHARMAP="UTF-8"
FONTFACE="Terminus"
FONT="Terminus16"
CONSOLESETUP
if command -v setupcon >/dev/null; then
  setupcon --save || true
fi

# python packages
if command -v pip3 >/dev/null; then
  echo "Installing Python packages..."
  pip3 install --no-cache-dir --break-system-packages PIP_PACKAGES_PLACEHOLDER || echo "WARNING: pip install failed"
fi

# Установка локальных deb-пакетов (скопированных из хоста)
if [ -d /tmp/custom_debs ]; then
  echo "Installing custom deb packages..."
  for deb in /tmp/custom_debs/*.deb; do
    if [ -f "$deb" ]; then
      echo "  - $(basename "$deb")"
      # Пытаемся установить пакет
      dpkg -i "$deb" || {
        echo "Failed to install $(basename "$deb"), attempting to fix dependencies..."
        apt-get install -f -y
        dpkg -i "$deb" || {
          echo "ERROR: Could not install $(basename "$deb") even after fixing dependencies."
          exit 1
        }
      }
    fi
  done
  # Удаляем временную папку с deb-файлами
  rm -rf /tmp/custom_debs
fi

# ===== Plymouth: кастомная тема RescueOS (до update-initramfs на хосте) =====
PLYMOUTH_PLACEHOLDER

# ===== Роутер: NAT wlan->eth + DHCP/DNS (только IPv4) =====
ROUTER_PLACEHOLDER

# kernel check
if ! ls /boot/vmlinuz-* >/dev/null 2>&1; then
  echo "ERROR: Kernel not installed"
  exit 1
fi

# users
for user in USERNAME_PLACEHOLDER; do
  if ! id "$user" &>/dev/null; then
    adduser --disabled-password --gecos "" "$user"
    echo "$user:USER_PASS_PLACEHOLDER" | chpasswd
    usermod -aG sudo "$user"
  fi
done
echo "root:ROOT_PASS_PLACEHOLDER" | chpasswd

# Настройка клавиатуры (русская + английская, Alt+Shift)
cat > /etc/default/keyboard <<KB
XKBMODEL="pc105"
XKBLAYOUT="us,ru"
XKBVARIANT=","
XKBOPTIONS="grp:alt_shift_toggle"
BACKSPACE="guess"
KB
setupcon --save
systemctl enable keyboard-setup 2>/dev/null || true

# network configuration — NetworkManager only
mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/Rescue-Network.nmconnection <<NMCONNECTION
NM_CONNECTION_PLACEHOLDER
NMCONNECTION
chmod 600 /etc/NetworkManager/system-connections/Rescue-Network.nmconnection
rm -f /etc/systemd/network/20-wired.network
systemctl disable iwd systemd-networkd 2>/dev/null || true
systemctl enable NetworkManager systemd-resolved 2>/dev/null || true
# Ubuntu-специфика: /usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf
# делает все проводные интерфейсы unmanaged. Пустой файл в /etc с тем же именем
# перебивает его — иначе ens*/eth* никогда не получат DHCP от NetworkManager.
mkdir -p /etc/NetworkManager/conf.d
touch /etc/NetworkManager/conf.d/10-globally-managed-devices.conf
rm -f /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# optional: dnsmasq config (if installed)
if [ -f /etc/dnsmasq.conf ] && [ -n "INSTALL_DHCP_SERVER_PLACEHOLDER" ]; then
  cat > /etc/dnsmasq.d/rescue-dhcp.conf <<DNSMASQ
DNSMASQ_CONFIG_PLACEHOLDER
DNSMASQ
  systemctl disable dnsmasq 2>/dev/null || true  # не запускаем автоматически
fi

# Настройка wireshark
if dpkg -l wireshark-common >/dev/null 2>&1; then
    echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
    dpkg-reconfigure -f noninteractive wireshark-common
    usermod -aG wireshark USERNAME_PLACEHOLDER
fi

# Добавляем вызов в .bashrc
echo '
# RescueOS configurator
alias config="bash $HOME/.config/settings.sh"
alias vpn-connect="sudo openvpn --config /etc/openvpn/work.ovpn"
alias vpn-stop="sudo pkill openvpn"
alias setup="sudo /usr/local/bin/setup"
alias ll="ls -alF"
alias la="ls -A"
alias l="ls -CF"

# История команд
export HISTFILE="$HOME/.bash_history"
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoreboth:erasedups
shopt -s histappend
' >> /home/USERNAME_PLACEHOLDER/.bashrc

# История для root
echo '
export HISTFILE="/root/.bash_history"
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoreboth:erasedups
shopt -s histappend
' >> /root/.bashrc

# Создаём файлы истории
touch /home/USERNAME_PLACEHOLDER/.bash_history
chown USERNAME_PLACEHOLDER:USERNAME_PLACEHOLDER /home/USERNAME_PLACEHOLDER/.bash_history
touch /root/.bash_history

# Пополним историю командами из help.sh
cat > /home/USERNAME_PLACEHOLDER/.bash_history <<'HIST_EOF'
# ============================================================
#  RESCUEOS ШПАРГАЛКА — это .bash_history: стрелка вверх и Ctrl+R работают
#  Разделы: QUICK / SYSTEM / NETWORK / NM / ROUTER / STORAGE / LVM-RAID /
#           MOUNT / RECOVERY / TOOLS / PROC-LOGS / EFI / SSH / SERIAL /
#           SETUP / DOCKER / IPMI / USB / WIFI / VPN / FILES / REPORT /
#           RECIPES / DAR
# ============================================================

# ============ QUICK: срез состояния ============
rescue-ui                          # меню: сеть / диски+SMART / диагностика / VPN
ip -br addr                        # интерфейсы и адреса кратко
ip -br link
ip route
ping -c 4 8.8.8.8
resolvectl query ya.ru
lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS,MODEL,SERIAL
systemctl --failed
journalctl -p err -b
dmesg -T | tail -100

# ============ SYSTEM: ОС / CPU / RAM / PCI / USB ============
uname -a
uname -r
cat /etc/os-release
hostnamectl
lscpu
lsmem
free -h
vmstat 1
lspci -nnk
lsusb
lsusb -t
lsmod
systemd-analyze
systemd-analyze blame

# ============ NETWORK: срез состояния сети ============
ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}(/\d+)?'
ip -6 route
ip neigh
ip neigh flush all
ip route show
resolvectl status
resolvectl dns eth0 8.8.8.8
ping -c 4 ya.ru
ping -c 4 192.168.137.1
tracepath 8.8.8.8
mtr -rw 8.8.8.8
ss -lntup
ss -antp
dig ya.ru
curl -I https://ya.ru
curl -4 ifconfig.me
iw dev
iw dev wlan0 link
iw dev wlan0 station dump
nmtui

# ============ NM: NetworkManager (главный сетевой менеджер) ============
nmcli general status
nmcli device status
nmcli connection show
nmcli device show
nmcli device wifi list
nmcli device wifi rescan
nmcli device connect eth0
nmcli device disconnect eth0
nmcli connection modify "Rescue-Network" ipv4.method auto && nmcli connection up "Rescue-Network"
nmcli connection modify "Rescue-Network" ipv4.addresses 192.168.1.110/24 ipv4.gateway 192.168.1.1 ipv4.dns "8.8.8.8 8.8.4.4" ipv4.method manual && nmcli connection up "Rescue-Network"
sudo ip addr add 192.168.100.10/24 dev eth0
sudo ip addr del 192.168.100.10/24 dev eth0
sudo ip route add default via 192.168.100.1
sudo ip link set eth0 up
journalctl -u NetworkManager -b

# ============ ROUTER: раздача интернета WiFi -> провод (NAT+DHCP, IPv4) ============
sudo router status
sudo router start                  # ждёт до 3 мин: WiFi-интернет + провод с 192.168.137.110
sudo router restart
sudo router stop
cat /var/lib/misc/dnsmasq.leases   # выданные DHCP-адреса
tail -50 /var/log/rescue-router.log
# ============ STORAGE: диски / SMART / NVMe ============
lsblk -f
ls -l /dev/disk/by-id/
blkid
sudo fdisk -l
sudo parted -l
sudo smartctl -x /dev/sdX
sudo smartctl -H /dev/sda
sudo smartctl -a /dev/sda
sudo smartctl -A /dev/sda | grep -Ei 'temp|temperature'
sudo smartctl -t short /dev/sda
sudo smartctl -t long /dev/sda
sudo smartctl -l selftest /dev/sda
dmesg -T | grep -Ei 'I/O error|error|fail|ata|nvme'
sudo nvme list
sudo nvme smart-log /dev/nvme0
sudo nvme error-log /dev/nvme0

# ============ LVM / RAID ============
sudo pvs
sudo vgs
sudo lvs -a -o +devices
sudo vgscan
sudo vgchange -ay
cat /proc/mdstat
sudo mdadm --detail --scan
sudo mdadm --detail /dev/md0
sudo mdadm --examine /dev/sda1
zpool status
zfs list

# ============ MOUNT / FS (первый вариант — только чтение) ============
sudo mkdir -p /mnt/windows
sudo mount -o ro /dev/sda1 /mnt/windows
sudo mount -t ntfs3 -o ro /dev/sdX1 /mnt/windows
sudo mount -t ntfs-3g /dev/sdX1 /mnt/windows -o uid=1000,gid=1000,umask=022
sudo mount -t exfat /dev/sdX2 /mnt/windows
sudo mount -t vfat /dev/sdX3 /mnt/windows
sudo ntfsfix -n /dev/sda1
sudo fsck.ext4 -fn /dev/sda1
findmnt /mnt/windows
sudo lsof +D /mnt/windows
sudo fuser -vm /mnt/windows
sudo umount /mnt/windows

# ============ RECOVERY: клонирование умирающих дисков ============
# ВАЖНО: SOURCE и DESTINATION перепутать нельзя!
# Перед запуском: lsblk -e7 -o NAME,SIZE,MODEL,SERIAL
sudo ddrescue -f -n /dev/sda /mnt/recovery/disk.img /mnt/recovery/disk.log   # 1-й проход: только хорошие области
sudo ddrescue -f -r3 /dev/sda /mnt/recovery/disk.img /mnt/recovery/disk.log  # 2-й проход: дочитать плохие
sudo ddrescue -f /dev/sda /mnt/recovery/disk.img /mnt/recovery/disk.log      # продолжить прерванное
sudo fdisk -l /mnt/recovery/disk.img
sudo losetup -Pf --show /mnt/recovery/disk.img
sudo partclone.ext4 -d -c -s /dev/sda1 -o /mnt/recovery/sda1.img
mount_img

# ============ TOOLS: сеть/трафик/файлы ============
mc
far2l
nmap -sn 192.168.1.0/24
nmap -sV 192.168.1.1
nc -zv 192.168.1.1 22
socat - TCP:192.168.1.1:80
iperf3 -s
iperf3 -c 192.168.1.100
iftop
tcpdump -i eth0
aria2c -x 16 -s 16 <URL>
sqlite3 /path/to/db "SELECT * FROM table;"
jq '.key' file.json
# ============ PROC-LOGS: процессы и журналы ============
dmesg -w
journalctl -f
journalctl -b                       # текущая загрузка
journalctl -b -1                    # предыдущая загрузка
journalctl -k -b                    # только ядро
journalctl -p warning -b
journalctl -u ssh -b
journalctl -u NetworkManager -b
journalctl --since "1 hour ago"
ps auxf
ps -eo pid,ppid,%cpu,%mem,stat,comm --sort=-%cpu | head -20
ps -eo pid,ppid,%mem,%cpu,stat,comm --sort=-%mem | head -20
sudo lsof -nP
sudo lsof -i
htop
btop
systemctl status <service>

# ============ EFI / GRUB ============
sudo efibootmgr -v
sudo mount /dev/sda1 /mnt && find /mnt/EFI -maxdepth 3 -type f && sudo umount /mnt
sudo grub-install --version
sudo update-grub

# ============ SSH ============
systemctl status ssh
sudo systemctl restart ssh
ss -lntp | grep ':22'
sudo sshd -t
ssh -vvv user@192.168.1.10
scp file user@192.168.1.10:/tmp/
rsync -avP /source/ user@192.168.1.10:/dest/
who
w
last

# ============ SERIAL: консоль ============
ls -l /dev/ttyUSB* /dev/ttyACM*
sudo screen /dev/ttyUSB0 115200
sudo minicom -D /dev/ttyUSB0 -b 115200
stty -F /dev/ttyUSB0 -a
dmesg -T | grep -Ei 'ttyUSB|ttyACM|serial'

# ============ SETUP: утилиты образа ============
setup
sudo setup
wifi-rtl8192eu                      # перезапуск Wi-Fi-драйвера 8192eu
install-ubuntu ~/ubuntu-24.04.1-desktop-amd64.iso
sudo dd if=~/ubuntu.iso of=/dev/sdX bs=4M status=progress conv=fsync
aria2c -x 16 -s 16 https://releases.ubuntu.com/24.04/ubuntu-24.04.1-desktop-amd64.iso

# ============ DOCKER / PYTHON ============
docker ps
docker images
docker run -d --name container_name image_name
docker logs -f container_name
docker exec -it container_name bash
docker compose up -d
docker compose down
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
# ============ IPMI (локально и удалённо) ============
sudo ipmitool sensor
sudo ipmitool sensor list
sudo ipmitool sdr
sudo ipmitool sensor | grep -Ei 'temp|fan|volt'
sudo ipmitool power status
sudo ipmitool power on
sudo ipmitool power off
sudo ipmitool power cycle
sudo ipmitool power reset
sudo ipmitool mc info
sudo ipmitool mc guid
sudo ipmitool lan print 1           # обнаружение BMC-сети
sudo ipmitool lan set 1 ipsrc static
sudo ipmitool lan set 1 ipaddr <IP>
sudo ipmitool lan set 1 netmask <МАСКА>
sudo ipmitool lan set 1 defgw ipaddr <ШЛЮЗ>
sudo ipmitool lan set 1 ipsrc dhcp
sudo ipmitool user list 1
sudo ipmitool user set name <ID> <имя>
sudo ipmitool user set password <ID> <пароль>
sudo ipmitool user priv <ID> <уровень> 1   # уровни: 2=user, 3=operator, 4=admin
sudo ipmitool user enable <ID>
sudo ipmitool sel info
sudo ipmitool sel elist
sudo ipmitool sel clear
sudo ipmitool sol activate
sudo ipmitool sol deactivate
sudo ipmitool chassis status
sudo ipmitool chassis identify <сек>
# удалённо (с рабочей машины):
sudo ipmitool -I lanplus -H <BMC-IP> -U <USER> -P <ПАРОЛЬ> mc info
sudo ipmitool -I lanplus -H <BMC-IP> -U <USER> -P <ПАРОЛЬ> chassis status
sudo ipmitool -I lanplus -H <BMC-IP> -U <USER> -P <ПАРОЛЬ> sensor

# ============ USB / USBIP ============
lsusb
lsusb -t
usbip list -r <IP>
sudo usbip attach -r <IP> -b 3-4
usbip port
sudo usbip detach -p 0
sudo modprobe usbip-host vhci-hcd

# ============ WIFI: iw / монитор / перехват / hashcat ============
iw dev
sudo iw dev wlan0 scan | grep -E "SSID|signal|freq"
sudo iw dev wlan0 connect <SSID> key 0:s:<пароль>
sudo iw dev wlan0 disconnect
sudo iw dev wlan0 set power_save off
sudo airmon-ng check kill
sudo airmon-ng start wlan0
iw dev wlan0mon info
sudo airodump-ng wlan0mon
sudo airodump-ng --bssid XX:XX:XX:XX:XX:XX --channel X --write capture wlan0mon
sudo aireplay-ng --deauth 0 -a BSSID -c CLIENT wlan0mon
hcxpcapngtool -o hash.h22000 capture-*.pcapng
hcxhashtool -o hash.h22000 --input=capture.hc22000
hashcat -m 22000 hash.h22000 /usr/share/wordlists/rockyou.txt --session=rescue_wpa
hashcat --show hash.h22000
sudo airmon-ng stop wlan0mon
sudo ./bettercap

# ============ VPN (OpenVPN) ============
sudo openvpn --config /etc/openvpn/work.ovpn
sudo openvpn --config /etc/openvpn/work.conf
sudo systemctl status openvpn* 2>/dev/null || true
sudo ip addr show | grep tun

# ============ FILES: поиск и место ============
find /etc -type f -iname '*network*'
find /etc -type f -iname '*.conf'
grep -Rni "192.168.1.1" /etc 2>/dev/null
grep -Rni "ERROR" /var/log 2>/dev/null
du -xhd1 / 2>/dev/null | sort -h
df -hT
df -ih

# ============ REPORT: собрать отчёт и скинуть на флешку ============
mkdir -p /mnt/recovery/rescue-report && cd /mnt/recovery/rescue-report
uname -a > uname.txt
ip addr > ip-addr.txt
ip route > ip-route.txt
lsblk -f > lsblk.txt
lspci -nnk > lspci.txt
lsusb > lsusb.txt
sudo smartctl -x /dev/sda > smart-sda.txt 2>&1
journalctl -b > journal.txt
dmesg -T > dmesg.txt
tar -C /mnt/recovery -czf rescue-report-$(date +%Y%m%d-%H%M%S).tar.gz rescue-report

# ============ QUICK RECIPES: готовые рецепты ============
# 1. Узнать, какой диск какой:
lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
# 2. Проверить диск перед восстановлением:
sudo smartctl -x /dev/sdX; dmesg -T | grep -Ei 'error|fail|I/O|ata|nvme'
# 3. Клонировать умирающий диск:
sudo ddrescue -f -n /dev/sdX /mnt/recovery/disk.img /mnt/recovery/disk.log
sudo ddrescue -f -r3 /dev/sdX /mnt/recovery/disk.img /mnt/recovery/disk.log
# 4. Быстро проверить сеть:
ip -br addr; ip route; ping -c 4 8.8.8.8; resolvectl query ya.ru
# 5. Найти причину проблем с сетью:
nmcli device status; journalctl -u NetworkManager -b
# 6. Найти ошибки загрузки:
systemctl --failed; journalctl -p err -b
# 7. Полный отчёт: см. раздел REPORT выше

# ============ DAR: восстановление из образа ============
restore-img /mnt/img/fs
cd /mnt/img
md5sum -c fs.1.dar.md5 fs.2.dar.md5 fs.3.dar.md5 fs.4.dar.md5
dar -x fs -R /mnt/restore
dar -x fs -R /mnt/restore -i путь/к/файлу
dar -c backup /path/to/dir -z9
dar -c backup -s 2G -z9 /path/to/dir
dar -l fs
dar -t fs
HIST_EOF
chown USERNAME_PLACEHOLDER:USERNAME_PLACEHOLDER /home/USERNAME_PLACEHOLDER/.bash_history

# Пополним историю root
cp /home/USERNAME_PLACEHOLDER/.bash_history /root/.bash_history
chown root:root /root/.bash_history

# autologin
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<AUTO
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin USERNAME_PLACEHOLDER --noclear %I \$TERM
AUTO

# Приветственное сообщение (русский)
cat > /etc/profile.d/welcome.sh <<'WELCOME'
#!/bin/bash
# Страховка: применяем консольный шрифт с кириллицей при логине
setupcon >/dev/null 2>&1 || true
G="\033[1;32m"; Y="\033[1;33m"; D="\033[0m"
echo -e "${G}============================================================${D}"
echo -e "${G}  RescueOS — аварийная станция${D}"
echo -e "${G}============================================================${D}"
echo "Пользователь: USERNAME_PLACEHOLDER / USER_PASS_PLACEHOLDER   root: ROOT_PASS_PLACEHOLDER"
echo "Режим сети: NETWORK_MODE_PLACEHOLDER   Часовой пояс: $(cat /etc/timezone 2>/dev/null)"
echo -e "IPv4:"
ip -4 -br addr show 2>/dev/null | grep -v '^lo' | sed 's/^/  /'
echo ""
echo -e "${Y}Главное:${D}"
echo "  rescue-ui          меню: сеть / диски+SMART / диагностика / VPN / IPMI / reboot"
echo "  setup              конфигурация (sudo setup — от root)"
echo "  .bash_history      шпаргалка: стрелка вверх / Ctrl+R (QUICK/NETWORK/STORAGE/IPMI...)"
echo ""
echo -e "${Y}Сеть:${D}"
echo "  nmcli device wifi list | nmcli device wifi connect <SSID> password <пароль>"
echo "  nmtui              интерактивная настройка сети"
echo "  sudo router status  роутер WiFi->провод (NAT+DHCP, IPv4): start|restart|stop"
echo ""
echo -e "${Y}Диски / диагностика:${D}"
echo "  lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL"
echo "  sudo smartctl -x /dev/sdX"
echo ""
echo -e "${Y}IPMI:${D}"
echo "  sudo ipmitool sensor | power status|on|off | sel elist | lan print 1"
echo ""
echo -e "${Y}Монтирование Windows / VPN:${D}"
echo "  sudo mkdir -p /mnt/windows && sudo mount -t ntfs3 -o ro /dev/sdX1 /mnt/windows"
echo "  sudo openvpn --config /etc/openvpn/work.ovpn"
echo ""
WELCOME
chmod +x /etc/profile.d/welcome.sh

WIFI_DRIVER_PLACEHOLDER

# ===== Rescue UI: whiptail menu =====
cat > /usr/local/bin/rescue-ui <<'RESCUEUI'
#!/bin/bash
set -u
pause(){ whiptail --msgbox "$1" 18 100; }
show_net(){ pause "$(nmcli device status 2>&1)\n\n$(nmcli connection show --active 2>&1)\n\n$(ip -4 addr show)\n\n$(ip route show)"; }
set_dhcp(){ nmcli con mod Rescue-Network ipv4.method auto ipv6.method auto 2>/dev/null||true; nmcli con down Rescue-Network 2>/dev/null||true; nmcli con up Rescue-Network 2>/dev/null||true; }
set_static(){ nmcli con mod Rescue-Network ipv4.method manual ipv4.addresses "192.168.137.110/24,192.168.0.110/24,192.168.1.110/24,10.222.255.110/24" ipv4.never-default yes ipv4.dns "8.8.8.8,8.8.4.4" ipv6.method disabled 2>/dev/null||true; nmcli con down Rescue-Network 2>/dev/null||true; nmcli con up Rescue-Network 2>/dev/null||true; }
network_menu(){ while true; do c=$(whiptail --menu "Сеть" 18 100 6 "1" "Статус" "2" "DHCP" "3" "Статика Rescue" "4" "Добавить временный IPv4" "5" "Маршруты/DNS" "0" "Назад" 3>&1 1>&2 2>&3)||return; case "$c" in 1)show_net;;2)set_dhcp;;3)set_static;;4) ipx=$(whiptail --inputbox "IPv4/prefix:" 10 80 3>&1 1>&2 2>&3)||continue; dev=$(nmcli -t -f DEVICE,TYPE dev status|awk -F: '$2=="ethernet"&&$1!=""{print $1;exit}'); if [[ "$ipx" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]&&[[ -n "$dev" ]]; then ip addr add "$ipx" dev "$dev" 2>/dev/null&&pause "Добавлено $ipx на $dev"||pause "Не удалось добавить адрес."; else pause "Некорректный адрес или Ethernet-интерфейс не найден."; fi;;5) pause "$(nmcli general status 2>&1)\n\n$(ip route show)\n\n$(resolvectl status 2>&1)";;0)return;;esac;done; }
disk_menu(){ while true; do c=$(whiptail --menu "Диски" 16 100 6 "1" "lsblk -f" "2" "SMART" "3" "Монтировать RO (безопасно)" "4" "Монтировать RW" "5" "fdisk/parted" "0" "Назад" 3>&1 1>&2 2>&3)||return; case "$c" in 1)pause "$(lsblk -f 2>&1)";;2)d=$(whiptail --inputbox "Диск:" 10 70 /dev/sda 3>&1 1>&2 2>&3)||continue;pause "$(smartctl -a "$d" 2>&1)";;3|4)d=$(whiptail --inputbox "Раздел:" 10 70 3>&1 1>&2 2>&3)||continue;mkdir -p /mnt/windows;opts="";[ "$c" = 3 ]&&opts="-o ro";mount $opts "$d" /mnt/windows 2>&1&&pause "Смонтировано в /mnt/windows$([ "$c" = 3 ] && echo " (read-only)")"||pause "Ошибка монтирования.";;5)pause "$(fdisk -l 2>&1)\n\n$(parted -l 2>&1)";;0)return;;esac;done; }
diagnostics(){ r=$(mktemp /tmp/rescue-diag.XXXXXX); { echo "=== RescueOS diagnostics ==="; date; uname -a; lshw -short 2>&1||true; lspci -nn 2>&1||true; lsusb 2>&1||true; nmcli device status 2>&1||true; ip -4 addr show; ip route show; resolvectl status 2>&1||true; lsblk -f 2>&1; }>$r;whiptail --textbox "$r" 32 115;rm -f "$r"; }
while true; do c=$(whiptail --title "RESCUE OS" --menu "Экстренное рабочее окружение" 20 100 9 "1" "Сеть / NetworkManager" "2" "Диски / SMART / Mount" "3" "Диагностика" "4" "VPN / nmtui" "5" "IPMI" "6" "Терминал" "7" "Перезагрузка" "8" "Выключение" "0" "Выход" 3>&1 1>&2 2>&3)||exit 0;case "$c" in 1)network_menu;;2)disk_menu;;3)diagnostics;;4)nmtui;;5)pause "$(ipmitool sensor 2>&1||true)\n\n$(ipmitool chassis status 2>&1||true)";;6)exec bash;;7)systemctl reboot;;8)systemctl poweroff;;0)exit 0;;esac;done
RESCUEUI
chmod 755 /usr/local/bin/rescue-ui

# cleanup
mkdir -p /root/var/crash
apt-get -qq clean
apt-get -qq autoremove -y
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
rm -rf /var/cache/apt/* /var/lib/apt/lists/* /tmp/* /var/tmp/*
rm -rf /root/.cache /home/*/.cache 2>/dev/null || true
[[ -f /etc/resolv.conf.orig ]] && mv /etc/resolv.conf.orig /etc/resolv.conf

echo "=== Configuration completed ==="
date
SCRIPT_EOF

  # подстановки
  sed -i "s|HOSTNAME_PLACEHOLDER|$HOSTNAME|g" "$config_script"
  sed -i "s|TIMEZONE_PLACEHOLDER|$host_timezone|g" "$config_script"
  sed -i "s|MIRROR_PLACEHOLDER|$MIRROR|g" "$config_script"
  sed -i "s|RELEASE_PLACEHOLDER|$RELEASE|g" "$config_script"
  sed -i "s|SYSTEM_PACKAGES_PLACEHOLDER|$system_packages_str|g" "$config_script"
  sed -i "s|LIVE_PACKAGES_PLACEHOLDER|$live_packages_str|g" "$config_script"
  sed -i "s|BLOCKED_SPACE_PLACEHOLDER|$blocked_space|g" "$config_script"
  sed -i "s|MOZILLA_KEY_URL_PLACEHOLDER|$MOZILLA_KEY_URL|g" "$config_script"
  sed -i "s|MOZILLA_REPO_LINE_PLACEHOLDER|$MOZILLA_REPO_LINE|g" "$config_script"
  sed -i "s|USERNAME_PLACEHOLDER|$USERNAME|g" "$config_script"
  sed -i "s|USER_PASS_PLACEHOLDER|$USER_PASS|g" "$config_script"
  sed -i "s|ROOT_PASS_PLACEHOLDER|$ROOT_PASS|g" "$config_script"
  sed -i "s|NETWORK_MODE_PLACEHOLDER|$NETWORK_MODE|g" "$config_script"
  sed -i "s|INSTALL_DHCP_SERVER_PLACEHOLDER|$INSTALL_DHCP_SERVER|g" "$config_script"

  replace_multiline "$config_script" \
    "BLOCKED_RULES_PLACEHOLDER" \
    "$apt_pinning_rules"

  replace_line_block "$config_script" \
    "NM_CONNECTION_PLACEHOLDER" \
    "$nm_connection"

  replace_multiline "$config_script" \
    "DNSMASQ_CONFIG_PLACEHOLDER" \
    "$dnsmasq_config"

  replace_line_block "$config_script" \
    "WIFI_DRIVER_PLACEHOLDER" \
    "$wifi_driver_block"

  replace_line_block "$config_script" \
    "PLYMOUTH_PLACEHOLDER" \
    "$plymouth_block"

  replace_line_block "$config_script" \
    "ROUTER_PLACEHOLDER" \
    "$router_block"
    
  pip_packages_str=$(IFS=' '; echo "${EXTRA_PIP_PACKAGES[*]}")
  sed -i "s|PIP_PACKAGES_PLACEHOLDER|$pip_packages_str|g" "$config_script"

  if [[ -d "$CUSTOM_DEB_DIR" ]] && [[ ${#CUSTOM_DEB_PACKAGES[@]} -gt 0 ]]; then
    log "Copying custom deb packages to chroot..."
    sudo mkdir -p "$CHROOTDIR/tmp/custom_debs"
    for deb in "${CUSTOM_DEB_PACKAGES[@]}"; do
      if [[ -f "$CUSTOM_DEB_DIR/$deb" ]]; then
        sudo cp "$CUSTOM_DEB_DIR/$deb" "$CHROOTDIR/tmp/custom_debs/"
        log "  - $deb"
      else
        err "Custom deb not found: $CUSTOM_DEB_DIR/$deb"
        exit 1
      fi
    done
  fi

  chmod +x "$config_script"
  log "Running chroot configuration..."
  sudo cp "$config_script" "$CHROOTDIR/tmp/configure_system.sh"
  sudo chmod +x "$CHROOTDIR/tmp/configure_system.sh"
  if ! sudo chroot "$CHROOTDIR" /tmp/configure_system.sh; then
    err "Chroot configuration failed"
    tail -20 "$CHROOTDIR/tmp/chroot.log" 2>/dev/null || true
    rm -f "$config_script"
    exit 1
  fi
  rm -f "$config_script"

  # ===== Проверка: драйвер Wi-Fi 8192eu реально в образе =====
  if [[ "$RTL8192EU_ENABLE" == "yes" ]]; then
    local ko_path=$(sudo find "$CHROOTDIR/lib/modules" -name "${RTL8192EU_MODULE_NAME}.ko*" 2>/dev/null | head -1)
    if [[ -n "$ko_path" ]]; then
      success "Драйвер ${RTL8192EU_MODULE_NAME}.ko в образе: ${ko_path#$CHROOTDIR}"
    else
      err "${RTL8192EU_MODULE_NAME}.ko НЕ найден в образе — Wi-Fi на 8192EU работать не будет"
      exit 1
    fi
    if sudo test -f "$CHROOTDIR/etc/modprobe.d/${RTL8192EU_BLACKLIST}-blacklist.conf"; then
      success "Встроенный драйвер ${RTL8192EU_BLACKLIST} отключён (blacklist)"
    else
      warn "Не найден /etc/modprobe.d/${RTL8192EU_BLACKLIST}-blacklist.conf"
    fi
  fi

  CUSTOM_FILES_DIR="${CUSTOM_FILES_DIR:-$HOME/my_custom_files}"
  if [[ -d "$CUSTOM_FILES_DIR" ]]; then
      log "Copying custom files from $CUSTOM_FILES_DIR to /home/$USERNAME in chroot..."
      sudo mkdir -p "$CHROOTDIR/home/$USERNAME"
      sudo cp -r "$CUSTOM_FILES_DIR"/* "$CHROOTDIR/home/$USERNAME/"
      sudo chown -R "$USERNAME:$USERNAME" "$CHROOTDIR/home/$USERNAME"
      success "Custom files copied to /home/$USERNAME"
  else
      warn "Custom files directory $CUSTOM_FILES_DIR not found, skipping"
  fi


  # Копирование VPN-ключей
  if [[ -d "$CUSTOM_FILES_DIR/vpn_key" ]]; then
      log "Copying VPN keys to /etc/openvpn/ in chroot..."
      sudo mkdir -p "$CHROOTDIR/etc/openvpn"
      sudo cp -r "$CUSTOM_FILES_DIR/vpn_key/"* "$CHROOTDIR/etc/openvpn/"
      sudo chmod 600 "$CHROOTDIR/etc/openvpn/work.key" "$CHROOTDIR/etc/openvpn/ta.key" 2>/dev/null || true
      sudo chmod 644 "$CHROOTDIR/etc/openvpn/ca.crt" "$CHROOTDIR/etc/openvpn/work.crt" 2>/dev/null || true
      sudo chown -R root:root "$CHROOTDIR/etc/openvpn" 2>/dev/null || true
      success "VPN keys copied to /etc/openvpn/"
  # Копирование setup-скрипта
  if [[ -f "$CUSTOM_FILES_DIR/setup" ]]; then
      log "Installing admin setup script..."
      sudo cp "$CUSTOM_FILES_DIR/setup" "$CHROOTDIR/usr/local/bin/setup"
      sudo chmod +x "$CHROOTDIR/usr/local/bin/setup"
      success "Setup script installed to /usr/local/bin/setup"
  fi
  fi
  log "Updating initramfs..."
  sudo chroot "$CHROOTDIR" update-initramfs -u -k all

  log "Preparing boot files..."
  sudo mkdir -p "$ISODIR/casper"
  local kernel_files=($(sudo find "$CHROOTDIR/boot" -name "vmlinuz-*" -type f))
  if [[ ${#kernel_files[@]} -eq 0 ]]; then err "No kernel found"; exit 1; fi
  local kernel_version=$(basename "${kernel_files[0]}" | sed 's/vmlinuz-//')
  sudo cp "$CHROOTDIR/boot/vmlinuz-$kernel_version" "$ISODIR/casper/vmlinuz"
  sudo cp "$CHROOTDIR/boot/initrd.img-$kernel_version" "$ISODIR/casper/initrd.img"

  # размонтирование
  log "Unmounting for squashfs..."
  for mp in dev/pts proc sys run dev; do
    mountpoint -q "$CHROOTDIR/$mp" 2>/dev/null && sudo umount -l "$CHROOTDIR/$mp" || true
  done

  log "Creating squashfs (this may take a while)..."
  local squashfs_opts="-comp $SQUASHFS_COMP -b $SQUASHFS_BLOCK_SIZE -processors $BUILD_THREADS"
  sudo mksquashfs "$CHROOTDIR" "$ISODIR/casper/filesystem.squashfs" -e boot $squashfs_opts -no-progress

  # проверка блокируемых пакетов
  log "Checking for blocked packages in squashfs..."
  local found=()
  for pkg in "${BLOCKED_CANONICAL_PACKAGES[@]}"; do
    if sudo unsquashfs -l "$ISODIR/casper/filesystem.squashfs" 2>/dev/null | grep -q -E "/var/lib/dpkg/info/${pkg}\..*|/usr/bin/${pkg}"; then
      found+=("$pkg")
    fi
  done
  if [[ ${#found[@]} -eq 0 ]]; then success "No blocked packages found."; else warn "Blocked packages found: ${found[*]}"; fi

  # метаданные
  local fs_size=$(sudo du -sb "$CHROOTDIR" | cut -f1)
  echo "$fs_size" | sudo tee "$ISODIR/casper/filesystem.size" >/dev/null
  sudo mkdir -p "$ISODIR/.disk"
  echo "RescueOS Live - Built $(date)" | sudo tee "$ISODIR/.disk/info" >/dev/null
  echo "$(date -u +%Y%m%d-%H%M)" | sudo tee "$ISODIR/.disk/casper-uuid" >/dev/null

  sudo chroot "$CHROOTDIR" dpkg-query -W --showformat='${Package} ${Version}\n' | sudo tee "$ISODIR/casper/filesystem.manifest" >/dev/null
  sudo cp "$ISODIR/casper/filesystem.manifest" "$ISODIR/casper/filesystem.manifest-desktop"
  echo -e "live-boot\nlive-boot-initramfs-tools\ncasper\nlupin-casper" | sudo tee "$ISODIR/casper/filesystem.manifest-remove" >/dev/null

  # GRUB
  sudo mkdir -p "$ISODIR/boot/grub"
  cat <<GRUBCFG | sudo tee "$ISODIR/boot/grub/grub.cfg" >/dev/null
set timeout=10
set default=0

menuentry "Start RescueOS" {
    linux /casper/vmlinuz boot=casper splash quiet vt.global_cursor_default=0 username=$USERNAME hostname=$HOSTNAME
    initrd /casper/initrd.img
}

menuentry "Start RescueOS (Debug)" {
    linux /casper/vmlinuz boot=casper debug username=$USERNAME hostname=$HOSTNAME
    initrd /casper/initrd.img
}
GRUBCFG

  (cd "$ISODIR" && find . -type f ! -name "md5sum.txt" -print0 | sudo xargs -0 md5sum | sudo tee md5sum.txt >/dev/null)

  # создание ISO
  log "Creating ISO image: $IMAGENAME"
  local avail=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
  if [[ $avail -lt 2 ]]; then err "Need at least 2GB free"; exit 1; fi
  if sudo grub-mkrescue -o "$IMAGENAME" "$ISODIR" --compress="$ISO_COMPRESSION" -- -volid RESCUEOS 2>/dev/null; then
    log "ISO created with grub-mkrescue"
  elif sudo xorriso -as mkisofs -r -V "RESCUEOS" -cache-inodes -J -l -o "$IMAGENAME" "$ISODIR" 2>/dev/null; then
    log "ISO created with xorriso"
  else
    err "ISO creation failed"
    exit 1
  fi
  sudo chown "$USER:$USER" "$IMAGENAME"
  chmod 644 "$IMAGENAME"

  local end_time=$(date +%s)
  local build_time=$((end_time - start_time))
  local iso_path=$(realpath "$IMAGENAME")
  local iso_size=$(du -h "$IMAGENAME" | cut -f1)
  
  success "ISO built successfully: $iso_path ($iso_size)"
  echo "Build time: $((build_time/60))m $((build_time%60))s"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi