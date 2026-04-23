# AI-CICADA 🤖

Локальный ИИ-чат с JWT-аутентификацией, базой данных SQLite и веб-интерфейсом.

> **Автор:** [Cicada3301](https://github.com/Cicada3301)

[![Version](https://img.shields.io/badge/version-5.1.0-blue.svg)](https://github.com/Cicada3301/ai-cicada)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

## Возможности ✨

- 🔐 **JWT-аутентификация** — безопасный API с JSON Web Tokens
- 💾 **База данных SQLite** — локальное хранение данных с резервным режимом
- 🌐 **Веб-интерфейс** — современный адаптивный UI
- 🤖 **Интеграция с ИИ** — поддержка Ollama и llama.cpp
- 🛠️ **Поддержка инструментов** — веб-поиск, калькулятор, память
- 🐳 **Docker-готовность** — полная контейнеризация
- 📊 **Systemd-сервис** — автозапуск на Linux
- 🔍 **Проверка ресурсов** — проверка ОЗУ/ЦПУ перед установкой

## Быстрый старт 🚀

### Вариант 1: Нативная установка

```bash
# Скачать и установить
./cicada-ai.sh install

# Запустить сервисы
./cicada-ai.sh start
```

### Вариант 2: Docker (рекомендуется)

```bash
# Настройка окружения Docker
./cicada-ai.sh docker

# Запуск контейнеров
./cicada-ai.sh docker-start
```

### Вариант 3: Docker Compose

```bash
cd ~/.ai-cicada/docker
docker-compose up -d
```

## Команды CLI 📟

```bash
./cicada-ai.sh install          # Полная установка
./cicada-ai.sh start            # Запустить сервисы
./cicada-ai.sh stop             # Остановить сервисы
./cicada-ai.sh restart          # Перезапустить сервисы
./cicada-ai.sh status           # Проверить статус
./cicada-ai.sh remove           # Удалить (деинсталляция)
./cicada-ai.sh systemd          # Настроить автозапуск
./cicada-ai.sh doctor           # Диагностика проблем
./cicada-ai.sh docker           # Настройка Docker
./cicada-ai.sh docker-start     # Запустить контейнеры
./cicada-ai.sh docker-stop      # Остановить контейнеры
./cicada-ai.sh docker-logs      # Просмотр логов Docker
```

## Системные требования 📋

| Размер модели | Требуемое ОЗУ | Место на диске |
|---------------|---------------|----------------|
| 0.5B          | 2 ГБ          | 1 ГБ           |
| 3B            | 4 ГБ          | 4 ГБ           |
| 7B            | 8 ГБ          | 8 ГБ           |
| 13B           | 16 ГБ         | 15 ГБ          |
| 70B           | 64 ГБ         | 70 ГБ          |

## Доступ 🔗

- **Веб-чат**: http://localhost:3000
- **Ollama API**: http://localhost:11434

## Структура проекта 📁

```
ai-cicada/
├── cicada-ai.sh          # Основной скрипт установщика
├── Dockerfile            # Docker-образ
├── docker-compose.yml    # Оркестрация Docker
├── entrypoint.sh         # Точка входа Docker
├── nginx.conf            # Конфигурация обратного прокси Nginx
├── server.js             # Бэкенд на Node.js (генерируется)
├── index.html            # Веб-фронтенд (генерируется)
├── package.json          # Зависимости NPM
└── data/
    ├── cicada.db         # База данных SQLite
    └── .install_state    # Состояние установки
```

## Переменные окружения 🔧

| Переменная      | По умолчанию             | Описание                  |
|-----------------|--------------------------|---------------------------|
| `AI_MODEL`      | qwen2.5-coder:3b         | Модель ИИ по умолчанию    |
| `JWT_SECRET`    | генерируется авто        | Секрет подписи JWT        |
| `PORT`          | 3000                     | Порт веб-сервера          |
| `DB_PATH`       | /data/cicada.db          | Расположение базы данных  |
| `OLLAMA_HOST`   | http://ollama:11434      | Эндпоинт Ollama           |

## Безопасность 🔒

- JWT-токены с истечением срока 7 дней
- Хеширование паролей с bcrypt-подобным алгоритмом
- Санитизация входных данных (без eval)
- Поддержка ограничения частоты запросов (через Nginx)

## Docker-сервисы 🐳

| Сервис   | Образ                    | Порт   | Описание           |
|----------|--------------------------|--------|--------------------|
| ollama   | ollama/ollama:latest     | 11434  | ИИ-бэкенд          |
| web      | ai-cicada (собранный)    | 3000   | Веб-интерфейс      |
| nginx    | nginx:alpine             | 80/443 | Обратный прокси    |

## Устранение неполадок 🔧

```bash
# Проверка состояния системы
./cicada-ai.sh doctor

# Просмотр логов
./cicada-ai.sh logs

# Проверка занятых портов
./cicada-ai.sh status

# Полный сброс
./cicada-ai.sh remove
./cicada-ai.sh install
```

## Поддерживаемые платформы 💻

- ✅ Ubuntu/Debian
- ✅ Fedora
- ✅ Arch Linux
- ✅ Alpine Linux (Home Assistant)
- ✅ WSL (Windows)
- ✅ Termux (Android)
- ✅ macOS (частичная поддержка)

## Участие в разработке 🤝

1. Сделайте форк репозитория
2. Создайте ветку для своей функции (`git checkout -b feature/amazing`)
3. Зафиксируйте изменения (`git commit -m 'Add amazing feature'`)
4. Отправьте ветку (`git push origin feature/amazing`)
5. Откройте Pull Request

## Лицензия 📄

Лицензия MIT — подробности в файле [LICENSE](LICENSE).

## Благодарности 🙏

- [Ollama](https://ollama.ai/) — ИИ-бэкенд
- [llama.cpp](https://github.com/ggerganov/llama.cpp) — альтернативный бэкенд
- [better-sqlite3](https://github.com/WiseLibs/better-sqlite3) — драйвер SQLite
- [jsonwebtoken](https://github.com/auth0/node-jsonwebtoken) — библиотека JWT

---

Создано с ❤️ автором **[Cicada3301](https://github.com/Cicada3301)** — для тех, кто ценит приватность в мире ИИ.
