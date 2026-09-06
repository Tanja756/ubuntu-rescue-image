#!/bin/bash
set -euo pipefail

# ========== ПОЛЬЗОВАТЕЛЬСКИЕ НАСТРОЙКИ ==========
RELEASE="${RELEASE:-noble}"
ARCH="${ARCH:-amd64}"
MIRROR="${MIRROR:-http://archive.ubuntu.com/ubuntu}"
WORKDIR="${WORKDIR:-$(pwd)/rescuebuild}"
IMAGENAME="${IMAGENAME:-RescueOS-${RELEASE}-$(date +%Y%m%d-%H%M).iso}"

CUSTOM_FILES_DIR="$(pwd)/export"
# Путь к каталогу с дополнительными deb-пакетами (относительно текущей папки скрипта)
CUSTOM_DEB_DIR="$(pwd)/distr"

HOSTNAME="rescuebox"
USERNAME="unknown"
USER_PASS="unknown"
ROOT_PASS="unknown"

# Сеть: статика, два IP на одном интерфейсе (пример eth0)
NETWORK_MODE="static"          # "static" или "dhcp"
STATIC_IPS=(
  "192.168.137.110/24"
  "192.168.0.110/24"
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
  debootstrap xorriso syslinux-utils squashfs-tools grub-pc-bin grub-efi-amd64-bin mtools aria2
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

LIVE_SYSTEM_PACKAGES=(
  "linux-image-generic" "linux-headers-generic"
  "live-boot" "live-boot-initramfs-tools" "casper" "initramfs-tools"
  "systemd" "systemd-sysv" "libpam-systemd" "udev" "uuid-runtime"
  "grub-common" "grub-pc-bin" "grub-efi-amd64-bin"
  "overlayroot" "busybox-initramfs" "cryptsetup-initramfs"
  "pciutils" "usbutils" "lshw" "hwdata" "dmidecode"
  "live-tools" "live-config" "live-config-systemd"
  "iwd" "systemd-resolved" "net-tools" "iproute2"
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

    perl -0777 -i -pe \
        "s|\Q$placeholder\E|\Q$content\E|s" \
        "$file"
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
    apt_pinning_rules+="Package: $pkg\nPin: release *\nPin-Priority: -1\n\n"
  done

  # Создаём APT pinning для блокировки нежелательных пакетов
  log "Generating APT pinning rules for blocked packages..."
  sudo mkdir -p "$CHROOTDIR/etc/apt/preferences.d"
  for pkg in "${BLOCKED_CANONICAL_PACKAGES[@]}"; do
      printf "Package: %s\nPin: release *\nPin-Priority: -1\n\n" "$pkg" | sudo tee -a "$CHROOTDIR/etc/apt/preferences.d/no-canonical" >/dev/null
  done

  # Генерация network config для статики с двумя IP
  local network_config=""
    if [[ "$NETWORK_MODE" == "static" ]]; then
      network_config="[Match]\nName=e*\n\n[Network]\n"
    for ip in "${STATIC_IPS[@]}"; do
      network_config+="Address=$ip\n"
    done
    network_config+="Gateway=$STATIC_GATEWAY\nDNS=$STATIC_DNS\n"
  else
    network_config="[Match]\nName=en*\n\n[Network]\nDHCP=yes\n"
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
if command -v setupcon >/dev/null; then
  echo "FONT=cyr-sun16" >> /etc/default/console-setup
  setupcon --save
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

# network configuration
cat > /etc/systemd/network/20-wired.network <<NET
NETWORK_CONFIG_PLACEHOLDER
NET
systemctl enable iwd systemd-networkd systemd-resolved
systemctl enable NetworkManager 2>/dev/null || true
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
# Wi-Fi (iw)
iw dev
iw dev wlan0 info
iw dev wlan0 link
iwconfig wlan0
sudo iw dev wlan0 scan
sudo iw dev wlan0 scan | grep SSID
sudo iw dev wlan0 scan | grep -E "SSID|signal|freq"
sudo iw dev wlan0 connect <SSID>
sudo iw dev wlan0 connect <SSID> key 0:s:<пароль>
sudo iw dev wlan0 connect <SSID> p2p-client
sudo iw dev wlan0 disconnect
sudo iw dev wlan0 set power_save on
sudo iw dev wlan0 set power_save off
sudo iw dev wlan0 set type monitor
sudo iw dev wlan0 set type managed
sudo iw dev wlan0 scan | grep SSID
sudo iw dev wlan0 connect MyWiFi key 0:s:12345678
sudo iw dev wlan0 link
# Сеть
ip addr show
ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}(/\d+)?'
sudo ip addr add 192.168.100.10/24 dev eth0
sudo ip addr del 192.168.100.10/24 dev eth0
sudo ip route add default via 192.168.100.1
sudo ip route add 10.0.0.0/8 via 192.168.1.1
ip route show
resolvectl status
resolvectl dns eth0 8.8.8.8
ping 8.8.8.8
ping -c 4 ya.ru
traceroute ya.ru
mtr ya.ru
sudo dhclient eth0
sudo dhclient -r eth0
sudo dhclient -v eth0
sudo ip addr add 192.168.1.100/24 dev eth0
sudo ip link set eth0 up
sudo ip route add default via 192.168.1.1
# DHCP-сервер
sudo dnsmasq -C /etc/dnsmasq.d/rescue-dhcp.conf --no-daemon
sudo dnsmasq -C /etc/dnsmasq.d/rescue-dhcp.conf
sudo pkill dnsmasq
cat /var/lib/misc/dnsmasq.leases
sudo ip addr add 192.168.137.110/24 dev eth0
# IPMI
sudo ipmitool sensor
sudo ipmitool sensor list
sudo ipmitool sdr
sudo ipmitool power status
sudo ipmitool power on
sudo ipmitool power off
sudo ipmitool power cycle
sudo ipmitool power reset
sudo ipmitool mc info
sudo ipmitool mc guid
sudo ipmitool user list 1
sudo ipmitool user set name <ID> <имя>
sudo ipmitool user set password <ID> <пароль>
sudo ipmitool user priv <ID> <уровень> 1
sudo ipmitool user enable <ID>
sudo ipmitool user disable <ID>
sudo ipmitool lan print 1
sudo ipmitool lan set 1 ipsrc static
sudo ipmitool lan set 1 ipaddr <IP>
sudo ipmitool lan set 1 netmask <МАСКА>
sudo ipmitool lan set 1 defgw ipaddr <ШЛЮЗ>
sudo ipmitool lan set 1 ipsrc dhcp
sudo ipmitool sel list
sudo ipmitool sel clear
sudo ipmitool sol activate
sudo ipmitool sol deactivate
sudo ipmitool chassis status
sudo ipmitool chassis identify <сек>
# Монтирование
lsblk -f
lsblk
fdisk -l
blkid
sudo mkdir -p /mnt/windows
sudo mount -t ntfs3 /dev/sdX1 /mnt/windows
sudo mount -t ntfs-3g /dev/sdX1 /mnt/windows
sudo mount -t exfat /dev/sdX2 /mnt/windows
sudo mount -t vfat /dev/sdX3 /mnt/windows
sudo umount /mnt/windows
sudo mount -t ntfs-3g /dev/sdX1 /mnt/windows -o uid=1000,gid=1000,umask=022
sudo smartctl -a /dev/sda
sudo smartctl -H /dev/sda
sudo smartctl -t short /dev/sda
sudo smartctl -t long /dev/sda
sudo smartctl -l selftest /dev/sda
# Полезные команды
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
dmesg -w
journalctl -f
htop
btop
aria2c -x 16 -s 16 <URL>
mount_img
sudo parted -l
sudo fdisk -l
sudo ddrescue -d /dev/sda /dev/sdb log
sudo partclone.ext4 -d /dev/sda1 -o img
sqlite3 /path/to/db "SELECT * FROM table;"
cat file.json | jq .
jq '.key' file.json
# USB
usb_dev
# VPN
sudo openvpn --config /etc/openvpn/work.ovpn
sudo openvpn --config /etc/openvpn/work.conf
sudo systemctl status openvpn* 2>/dev/null || true
sudo ip addr show | grep tun
# Setup
setup
sudo setup
# Установка Ubuntu
install-ubuntu ~/ubuntu-24.04.1-desktop-amd64.iso
sudo dd if=~/ubuntu.iso of=/dev/sdX bs=4M status=progress conv=fsync
aria2c -x 16 -s 16 https://releases.ubuntu.com/24.04/ubuntu-24.04.1-desktop-amd64.iso
sudo apt install -y aircrack-ng
# DAR
restore-img /mnt/img/fs
restore-img /mnt/img/system.img
restore-img /mnt/img/ubuntu.iso
cd /mnt/img
md5sum -c fs.1.dar.md5 fs.2.dar.md5 fs.3.dar.md5 fs.4.dar.md5
dar -x fs -R /mnt/restore
dar -x fs -R /mnt/restore -i путь/к/файлу
dar -c backup /path/to/dir -z9
dar -c backup -s 2G -z9 /path/to/dir
dar -l fs
dar -t fs
dar --help
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
cat > /etc/profile.d/welcome.sh <<WELCOME
#!/bin/bash
echo -e "\\e[1;32mДобро пожаловать в RescueOS\\e[0m"
echo -e "Пользователь: USERNAME_PLACEHOLDER / USER_PASS_PLACEHOLDER, root: ROOT_PASS_PLACEHOLDER"
echo -e "Режим сети: NETWORK_MODE_PLACEHOLDER"
echo -e "Текущие IP-адреса (IPv4):"
ip -4 addr show | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){3}(/\\d+)?' | while read ip; do
    echo "  \$ip"
done
if [ -f /usr/sbin/dnsmasq ]; then
  echo -e "DHCP-сервер готов (запуск вручную): sudo dnsmasq -C /etc/dnsmasq.d/rescue-dhcp.conf"
fi
echo -e "Часовой пояс: \\\$(cat /etc/timezone)"
echo ""
echo -e "\\e[1;33mДобавление дополнительного IP-адреса (пример):\\e[0m"
echo "  sudo ip addr add 192.168.100.10/24 dev eth0"
echo -e "\\e[1;33mДобавление маршрута до роутера (пример):\\e[0m"
echo "  sudo ip route add default via 192.168.100.1"
echo ""
# IPMI: пользователи и пароли
echo -e "\\e[1;33mУправление сервером по IPMI:\\e[0m"
echo "  # Просмотр датчиков (локально): sudo ipmitool sensor"
echo "  # Управление питанием: sudo ipmitool power status|on|off|cycle|reset"
echo -e "\\e[1;33mУправление пользователями IPMI:\\e[0m"
echo "  # Список пользователей: sudo ipmitool user list 1"
echo "  # Смена пароля (ID обычно 1 или 2): sudo ipmitool user set password <ID> <пароль>"
echo "  # Создать нового пользователя:"
echo "    sudo ipmitool user set name <ID> <имя>"
echo "    sudo ipmitool user set password <ID> <пароль>"
echo "    sudo ipmitool user priv <ID> <уровень> 1   # уровни: 2 (user), 3 (operator), 4 (admin)"
echo "    sudo ipmitool user enable <ID>"
echo ""

# IPMI: настройка сети (только если BMC в режиме static)
if ipmitool lan print 1 | grep -q "IP Address Source.*Static"; then
  echo -e "\\e[1;33mНастройка сети BMC (статический IP):\\e[0m"
  echo "  # Проверить текущие параметры: sudo ipmitool lan print 1"
  echo "  # Задать статический IP:"
  echo "    sudo ipmitool lan set 1 ipaddr <IP>"
  echo "    sudo ipmitool lan set 1 netmask <МАСКА>"
  echo "    sudo ipmitool lan set 1 defgw ipaddr <ШЛЮЗ>"
  echo "  # Переключить в DHCP: sudo ipmitool lan set 1 ipsrc dhcp"
  echo ""
fi
echo -e "\\e[1;33mМонтирование Windows-разделов (NTFS/exFAT/FAT):\\e[0m"
echo "  # Создать точку монтирования:"
echo "  sudo mkdir -p /mnt/windows"
echo "  # Примонтировать NTFS-раздел (например, /dev/sda1):"
echo "  sudo mount -t ntfs3 /dev/sda1 /mnt/windows   # ntfs3 (встроенный драйвер ядра) или"
echo "  sudo mount -t ntfs-3g /dev/sda1 /mnt/windows # ntfs-3g (userspace)"
echo "  # Для exFAT:"
echo "  sudo mount -t exfat /dev/sda2 /mnt/windows"
echo "  # Для FAT32:"
echo "  sudo mount -t vfat /dev/sda3 /mnt/windows"
echo "  # Узнать список разделов: lsblk -f"
echo ""
echo -e "\\e[1;33mКонфигурация в интерактивномрежиме:\\e[0m"
echo "  config"
echo ""
echo -e "\\e[1;33mVPN (OpenVPN):\\e[0m"
echo "  sudo openvpn --config /etc/openvpn/work.ovpn"
echo "  sudo openvpn --config /etc/openvpn/work.conf"
echo -e "\\e[1;33mКонфиги VPN:\\e[0m"
echo "  /etc/openvpn/work.ovpn (self-contained)"
echo "  /etc/openvpn/work.conf (с отдельными файлами)"
echo "  /etc/openvpn/ca.crt, /etc/openvpn/work.crt, /etc/openvpn/work.key, /etc/openvpn/ta.key"
echo ""
echo ""
echo -e "\\e[1;33mАдминистрирование:\\e[0m"
echo "  setup — конфигурация сети, IPMI, диски, диагностика"
echo "  sudo setup — запуск от root"
echo ""
WELCOME
chmod +x /etc/profile.d/welcome.sh

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

  replace_multiline "$config_script" \
    "NETWORK_CONFIG_PLACEHOLDER" \
    "$network_config"

  replace_multiline "$config_script" \
    "DNSMASQ_CONFIG_PLACEHOLDER" \
    "$dnsmasq_config"
    
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
    linux /casper/vmlinuz boot=casper quiet splash username=$USERNAME hostname=$HOSTNAME
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