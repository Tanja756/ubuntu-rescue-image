import pyshtrih
import time
from datetime import datetime

def get_kkt_info(port=None, baudrate=115200):
    """
    Подключается к ККТ, запрашивает статус, время и данные ОФД.
    Если порт не указан, выполняет автопоиск.
    """
    kkt = None
    try:
        # --- 1. АВТОПОИСК (Если порт не указан) ---
        if port is None:
            print("Выполняется автопоиск ККТ...")
            found_devices = []

            def discovery_callback(found_port, found_baudrate):
                print(f"  Найдено устройство: порт {found_port}, скорость {found_baudrate}")
                found_devices.append((found_port, found_baudrate))

            pyshtrih.discovery(discovery_callback)

            if not found_devices:
                raise Exception("Устройства не найдены. Проверьте подключение ККТ и повторите попытку.")
            
            # Берем первое найденное устройство для примера
            port, baudrate = found_devices[0]
            print(f"\nДля работы выбрано устройство на порту {port}.")

        # --- 2. ПОДКЛЮЧЕНИЕ К ККТ ---
        print(f"\nПодключение к {port}...")
        kkt = pyshtrih.device.KKT(port, baudrate)
        kkt.connect()
        print(f"Подключено. Модель: {kkt.model()}")

        # --- 3. ЗАПРОС СОСТОЯНИЯ (0x11) ---
        print("\n--- Запрос состояния ФР ---")
        state = kkt.full_state()
        print(f"Статус ФР: {state}")

        # --- 4. ПОЛУЧЕНИЕ ВРЕМЕНИ НА ККТ ---
        print("\n--- Время на ККТ ---")
        # Используем метод 'get_current_time', если он есть (рекомендую проверить)
        # или команду 0x1F для чтения системной таблицы.
        if hasattr(kkt, 'get_current_time'):
            kkt_time = kkt.get_current_time()
            print(kkt_time.strftime("%Y-%m-%d %H:%M:%S"))
        else:
            # Альтернативный способ, если прямого метода нет:
            # Читаем системную таблицу (номер 0, поле 0).
            # ВНИМАНИЕ! Ответ может иметь разный формат на разных моделях.
            # Это лишь демонстрация возможного подхода.
            try:
                sys_data = kkt.read_table(0, 0)
                if len(sys_data) >= 6:
                    # Предполагаемый формат: ГГ, ММ, ДД, ЧЧ, ММ, СС
                    year, month, day, hour, minute, second = sys_data[:6]
                    # Корректируем год, если он получен как смещение от 2000
                    if year < 100:
                        year += 2000
                    dt = datetime(year, month, day, hour, minute, second)
                    print(dt.strftime("%Y-%m-%d %H:%M:%S"))
                else:
                    print("Не удалось распарсить время. Недостаточно данных.")
            except Exception as e:
                print(f"Не удалось прочитать время: {e}")

        # --- 5. СТАТУС ОБМЕНА С ОФД (0xFF39) ---
        print("\n--- Статус информационного обмена с ОФД ---")
        try:
            # В большинстве версий pyshtrih эта команда есть, название может отличаться
            if hasattr(kkt, 'get_exchange_status'):
                ofd_status = kkt.get_exchange_status()
                print(f"Статус: {ofd_status}")
            else:
                # Низкоуровневый вызов, если метод отсутствует
                response = kkt.command(0xFF39)
                print(f"Ответ ККТ (HEX): {response.hex()}")
        except Exception as e:
            print(f"Ошибка получения статуса ОФД: {e}")

        # --- 6. НЕОТПРАВЛЕННЫЕ ДОКУМЕНТЫ (0xFF3F) ---
        print("\n--- Количество неотправленных документов в ОФД ---")
        try:
            if hasattr(kkt, 'get_unsent_fd_count'):
                unsent = kkt.get_unsent_fd_count()
                print(f"Неотправленных документов: {unsent}")
            else:
                response = kkt.command(0xFF3F)
                # Предполагаем, что ответ — это 4-байтовое целое число
                count = int.from_bytes(response, byteorder='little', signed=False)
                print(f"Неотправленных документов: {count}")
        except Exception as e:
            print(f"Ошибка получения количества документов: {e}")

    except Exception as e:
        print(f"\n!!! КРИТИЧЕСКАЯ ОШИБКА: {e}")
    finally:
        if kkt:
            kkt.disconnect()
            print("\nСоединение с ККТ закрыто.")


if __name__ == '__main__':
    # Вариант 1: Автоматический поиск устройства
    get_kkt_info()

    # Вариант 2: Ручное указание порта (Если автопоиск не сработал)
    # get_kkt_info(port='COM3')  # Для Windows
    # get_kkt_info(port='/dev/ttyUSB0')  # Для Linux