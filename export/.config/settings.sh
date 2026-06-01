#!/bin/bash

# ===================== ФУНКЦИИ ДЛЯ СЕТИ =====================
get_interface() {
    local iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(e|eth)' | head -n1)
    if [[ -z "$iface" ]]; then
        whiptail --msgbox "Не найден проводной сетевой интерфейс (e* или eth*)." 10 50
        return 1
    fi
    echo "$iface"
}

configure_network() {
    local iface=$(get_interface)
    [[ -z "$iface" ]] && return

    local ip_addr=$(whiptail --inputbox "Введите IP-адрес с маской (например 192.168.1.100/24):" 10 60 "" 3>&1 1>&2 2>&3)
    [[ -z "$ip_addr" ]] && { whiptail --msgbox "IP не введён." 10 40; return; }

    local gateway=$(whiptail --inputbox "Введите IP шлюза (например 192.168.1.1):" 10 60 "" 3>&1 1>&2 2>&3)
    [[ -z "$gateway" ]] && { whiptail --msgbox "Шлюз не введён." 10 40; return; }

    local dns=$(whiptail --inputbox "Введите DNS-сервер(ы) через пробел (например 8.8.8.8 8.8.4.4):" 10 60 "8.8.8.8" 3>&1 1>&2 2>&3)

    sudo ip addr add "$ip_addr" dev "$iface" 2>/dev/null || whiptail --msgbox "Не удалось добавить IP. Возможно, он уже существует." 10 50
    sudo ip link set "$iface" up
    sudo ip route add default via "$gateway" 2>/dev/null || whiptail --msgbox "Не удалось добавить маршрут. Возможно, уже существует." 10 50

    sudo mkdir -p /etc/systemd/network
    cat <<EOF | sudo tee /etc/systemd/network/20-wired.network > /dev/null
[Match]
Name=$iface

[Network]
Address=$ip_addr
Gateway=$gateway
DNS=$dns
EOF
    sudo systemctl restart systemd-networkd
    whiptail --msgbox "Сеть настроена:\nИнтерфейс: $iface\nIP: $ip_addr\nШлюз: $gateway\nDNS: $dns" 12 60
}

manage_dhcp() {
    if systemctl is-active --quiet dnsmasq; then
        if whiptail --title "DHCP-сервер" --yesno "DHCP-сервер (dnsmasq) сейчас ЗАПУЩЕН.\nОстановить его?" 10 50; then
            sudo systemctl stop dnsmasq
            sudo systemctl disable dnsmasq 2>/dev/null
            whiptail --msgbox "DHCP-сервер остановлен." 10 40
        fi
    else
        if whiptail --title "DHCP-сервер" --yesno "DHCP-сервер (dnsmasq) сейчас ОСТАНОВЛЕН.\nЗапустить его?" 10 50; then
            if [[ ! -f /etc/dnsmasq.d/rescue-dhcp.conf ]]; then
                whiptail --msgbox "Конфигурационный файл /etc/dnsmasq.d/rescue-dhcp.conf не найден." 10 60
                return
            fi
            sudo systemctl start dnsmasq
            sudo systemctl enable dnsmasq 2>/dev/null
            whiptail --msgbox "DHCP-сервер запущен." 10 40
        fi
    fi
}

# ===================== ФУНКЦИИ IPMI =====================
ipmi_users() {
    local users_list=$(sudo ipmitool user list 1 2>/dev/null)
    if [[ -z "$users_list" ]]; then
        whiptail --msgbox "Не удалось получить список пользователей IPMI.\nПроверьте, что ipmitool установлен и доступен." 10 60
        return
    fi
    whiptail --title "Пользователи IPMI (канал 1)" --msgbox "$users_list" 20 70

    local user_id=$(whiptail --inputbox "Введите ID пользователя для смены пароля (или оставьте пустым для выхода):" 10 60 "" 3>&1 1>&2 2>&3)
    if [[ -n "$user_id" ]]; then
        local new_pass=$(whiptail --passwordbox "Введите новый пароль для пользователя ID $user_id:" 10 60 "" 3>&1 1>&2 2>&3)
        if [[ -n "$new_pass" ]]; then
            sudo ipmitool user set password "$user_id" "$new_pass"
            whiptail --msgbox "Пароль для пользователя ID $user_id изменён." 10 40
        else
            whiptail --msgbox "Пароль не введён, операция отменена." 10 40
        fi
    fi
}

ipmi_sensors() {
    local sensors=$(sudo ipmitool sensor 2>/dev/null)
    if [[ -z "$sensors" ]]; then
        whiptail --msgbox "Не удалось получить данные сенсоров IPMI." 10 50
        return
    fi
    whiptail --title "Сенсоры IPMI" --msgbox "$sensors" 25 80
}

ipmi_power() {
    local power_status=$(sudo ipmitool power status 2>/dev/null | grep -i "Chassis Power" || echo "Unknown")
    local choice=$(whiptail --title "Управление питанием" --menu \
        "Текущее состояние: $power_status\nВыберите действие:" 15 55 4 \
        "1" "Включить" \
        "2" "Выключить (мягкое)" \
        "3" "Перезагрузить" \
        "4" "Выключить принудительно (power off)" \
        "5" "Назад" 3>&1 1>&2 2>&3)

    case $choice in
        1) sudo ipmitool power on ;;
        2) sudo ipmitool power soft ;;
        3) sudo ipmitool power reset ;;
        4) sudo ipmitool power off ;;
        5) return ;;
        *) return ;;
    esac
    whiptail --msgbox "Команда отправлена." 10 50
}

ipmi_network_config() {
    local channel=$(whiptail --inputbox "Введите номер канала IPMI (обычно 1):" 10 60 "1" 3>&1 1>&2 2>&3)
    [[ -z "$channel" ]] && return

    local current_mode=$(sudo ipmitool lan print "$channel" 2>/dev/null | grep "IP Address Source" | awk -F': ' '{print $2}')
    local current_ip=$(sudo ipmitool lan print "$channel" 2>/dev/null | grep "IP Address" | grep -v "Source" | awk -F': ' '{print $2}')

    local mode_choice=$(whiptail --title "Настройка IPMI сети (канал $channel)" --menu \
        "Текущий режим: ${current_mode:-неизвестно}\nТекущий IP: ${current_ip:-неизвестно}\n\nВыберите действие:" 15 60 3 \
        "1" "DHCP (автоматически)" \
        "2" "Статический IP" \
        "3" "Назад" 3>&1 1>&2 2>&3)

    case $mode_choice in
        1)
            sudo ipmitool lan set "$channel" ipsrc dhcp
            whiptail --msgbox "IPMI переключён в режим DHCP." 10 60
            ;;
        2)
            local ip_addr=$(whiptail --inputbox "Введите IP-адрес для BMC (например 192.168.1.50):" 10 60 "" 3>&1 1>&2 2>&3)
            [[ -z "$ip_addr" ]] && { whiptail --msgbox "IP не введён." 10 40; return; }
            local netmask=$(whiptail --inputbox "Введите маску подсети (например 255.255.255.0):" 10 60 "255.255.255.0" 3>&1 1>&2 2>&3)
            [[ -z "$netmask" ]] && return
            local gateway=$(whiptail --inputbox "Введите шлюз по умолчанию:" 10 60 "" 3>&1 1>&2 2>&3)
            [[ -z "$gateway" ]] && return

            sudo ipmitool lan set "$channel" ipsrc static
            sudo ipmitool lan set "$channel" ipaddr "$ip_addr"
            sudo ipmitool lan set "$channel" netmask "$netmask"
            sudo ipmitool lan set "$channel" defgw ipaddr "$gateway"
            whiptail --msgbox "Статический IP для BMC настроен:\nIP: $ip_addr\nМаска: $netmask\nШлюз: $gateway" 12 60
            ;;
        3) return ;;
    esac
}

# ===================== ПОДМЕНЮ =====================
submenu_network() {
    while true; do
        CHOICE=$(whiptail --title "Сетевые настройки" --menu \
            "Выберите действие:" 15 55 3 \
            "1" "Настройка статического IP и шлюза" \
            "2" "Запустить / остановить DHCP-сервер (dnsmasq)" \
            "3" "Назад" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1) configure_network ;;
            2) manage_dhcp ;;
            3) break ;;
            *) break ;;
        esac
    done
}

submenu_ipmi() {
    while true; do
        CHOICE=$(whiptail --title "IPMI / iDRAC настройки" --menu \
            "Выберите действие:" 18 60 5 \
            "1" "Пользователи (список и смена пароля)" \
            "2" "Сенсоры (статусы, температуры, напряжения)" \
            "3" "Управление питанием (вкл/выкл/перезагрузка)" \
            "4" "Настройка сети IPMI (статический IP / DHCP)" \
            "5" "Назад" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1) ipmi_users ;;
            2) ipmi_sensors ;;
            3) ipmi_power ;;
            4) ipmi_network_config ;;
            5) break ;;
            *) break ;;
        esac
    done
}

# ===================== ГЛАВНОЕ МЕНЮ =====================
while true; do
    MAIN=$(whiptail --title "RescueOS — Панель управления" --menu \
        "Выберите раздел:" 15 55 3 \
        "1" "Сетевые настройки" \
        "2" "Настройка IPMI / iDRAC" \
        "3" "Выход" 3>&1 1>&2 2>&3)

    case $MAIN in
        1) submenu_network ;;
        2) submenu_ipmi ;;
        3) break ;;
        *) break ;;
    esac
done