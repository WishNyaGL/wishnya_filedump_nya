import time
import re
import requests
from bs4 import BeautifulSoup
from colorama import init, Fore, Style

# Инициализация библиотеки для цветного вывода (актуально для Windows)
init(autoreset=True)

# ==================== НАСТРОЙКИ СKРИПТА ====================
URL = "https://euronews.com/"  # Адрес целевого сайта (как пример)
INTERVAL = 5                 # Интервал проверки в секундах

# Искомое слово или регулярное выражение (регистр не важен)
TARGET_WORD = "telegram"

# Радиус захвата: сколько слов брать СЛЕВА и СПРАВА от найденного слова
WORDS_RADIUS = 5

# Исключения: если эта точная строка есть в сыром HTML-коде, проверка пропускается
EXCLUDE_PHRASES = [
    "Технические работы",
    "Доступ ограничен"
]
# ===========================================================

def clean_html(html_content):
    """Очищает HTML от тегов, скриптов и стилей, возвращая чистый текст."""
    soup = BeautifulSoup(html_content, 'html.parser')
    for script in soup(["script", "style"]):
        script.decompose()
    return soup.get_text(separator=' ')

def find_context(text, target, radius):
    """Ищет слово и вырезает контекст вокруг него."""
    # Разбиваем текст на слова. Набор цифр без пробелов (\d+) считается как слово.
    # Этот паттерн делит текст по пробельным символам, сохраняя слова и числа.
    words = text.split()

    # Приводим к нижнему регистру для поиска без учета регистра
    target_lower = target.lower()
    words_lower = [w.lower() for w in words]

    results = []

    # Ищем все вхождения
    for idx, word in enumerate(words_lower):
        if target_lower in word: # Частичное или полное совпадение в слове
            # Определяем границы радиуса
            start = max(0, idx - radius)
            end = min(len(words), idx + radius + 1)

            # Собираем контекст из оригинального массива слов (чтобы сохранить регистр)
            context = " ".join(words[start:end])
            results.append(context)

    return results

def monitor():
    print(f"Запуск мониторинга {URL} с интервалом {INTERVAL} сек...")
    print(f"Ищем слово: '{TARGET_WORD}' с радиусом в {WORDS_RADIUS} слов.\n")

    iteration = 0
    while True:
        iteration += 1
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")

        try:
            # Запрос к сайту с таймаутом, чтобы скрипт не завис
            response = requests.get(URL, timeout=10)
            html_raw = response.text

            # Проверка на исключения в коде сайта
            has_exception = False
            for phrase in EXCLUDE_PHRASES:
                if phrase in html_raw:
                    print(f"[{timestamp}] Итерация {iteration}: {Fore.YELLOW}ПРОПУЩЕНО (Найдено исключение: '{phrase}'){Style.RESET_ALL}")
                    has_exception = True
                    break

            if has_exception:
                time.sleep(INTERVAL)
                continue

            # Извлекаем чистый текст
            clean_text = clean_html(html_raw)

            # Ищем совпадения
            matches = find_context(clean_text, TARGET_WORD, WORDS_RADIUS)

            if matches:
                print(f"[{timestamp}] Итерация {iteration}: {Fore.GREEN}НАЙДЕНО!{Style.RESET_ALL}")
                for i, match in enumerate(matches, 1):
                    print(f"   -> Совпадение {i}: ... {match} ...")
            else:
                print(f"[{timestamp}] Итерация {iteration}: {Fore.RED}ПУСТО{Style.RESET_ALL}")

        except requests.exceptions.RequestException as e:
            print(f"[{timestamp}] Итерация {iteration}: {Fore.RED}Ошибка запроса ({e}){Style.RESET_ALL}")

        time.sleep(INTERVAL)

if __name__ == "__main__":
    try:
        monitor()
    except KeyboardInterrupt:
        print(f"\n{Fore.YELLOW}Мониторинг остановлен пользователем.{Style.RESET_ALL}")
