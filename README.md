# AI-CICADA 🤖

Local AI Chat with JWT Authentication, SQLite Database, and Web Interface.

[![Version](https://img.shields.io/badge/version-5.1.0-blue.svg)](https://github.com/yourusername/ai-cicada)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

## Features ✨

- 🔐 **JWT Authentication** - Secure API with JSON Web Tokens
- 💾 **SQLite Database** - Local data storage with fallback
- 🌐 **Web Interface** - Modern responsive UI
- 🤖 **AI Integration** - Ollama and llama.cpp support
- 🛠️ **Tools Support** - Web search, calculator, memory
- 🐳 **Docker Ready** - Full containerization
- 📊 **Systemd Service** - Auto-start on Linux
- 🔍 **Resource Check** - Validates RAM/CPU before install

## Quick Start 🚀

### Option 1: Native Installation

```bash
# Download and install
./cicada-ai.sh install

# Start services
./cicada-ai.sh start
```

### Option 2: Docker (Recommended)

```bash
# Setup Docker environment
./cicada-ai.sh docker

# Start containers
./cicada-ai.sh docker-start
```

### Option 3: Docker Compose

```bash
cd ~/.ai-cicada/docker
docker-compose up -d
```

## CLI Commands 📟

```bash
./cicada-ai.sh install          # Full installation
./cicada-ai.sh start            # Start services
./cicada-ai.sh stop             # Stop services
./cicada-ai.sh restart          # Restart services
./cicada-ai.sh status           # Check status
./cicada-ai.sh remove           # Uninstall
./cicada-ai.sh systemd          # Setup auto-start
./cicada-ai.sh doctor           # Diagnose issues
./cicada-ai.sh docker           # Docker setup
./cicada-ai.sh docker-start     # Start containers
./cicada-ai.sh docker-stop      # Stop containers
./cicada-ai.sh docker-logs      # View Docker logs
```

## System Requirements 📋

| Model Size | RAM Required | Disk Space |
|------------|--------------|------------|
| 0.5B       | 2 GB         | 1 GB       |
| 3B         | 4 GB         | 4 GB       |
| 7B         | 8 GB         | 8 GB       |
| 13B        | 16 GB        | 15 GB      |
| 70B        | 64 GB        | 70 GB      |

## Access 🔗

- **Web Chat**: http://localhost:3000
- **Ollama API**: http://localhost:11434

## Project Structure 📁

```
ai-cicada/
├── cicada-ai.sh          # Main installer script
├── Dockerfile            # Docker image
├── docker-compose.yml    # Docker orchestration
├── entrypoint.sh         # Docker entrypoint
├── nginx.conf            # Nginx reverse proxy config
├── server.js             # Node.js backend (generated)
├── index.html            # Web frontend (generated)
├── package.json          # NPM dependencies
└── data/
    ├── cicada.db         # SQLite database
    └── .install_state    # Installation state
```

## Environment Variables 🔧

| Variable      | Default                  | Description          |
|---------------|--------------------------|----------------------|
| `AI_MODEL`    | qwen2.5-coder:3b         | Default AI model     |
| `JWT_SECRET`    | auto-generated           | JWT signing secret   |
| `PORT`          | 3000                     | Web server port      |
| `DB_PATH`       | /data/cicada.db          | Database location    |
| `OLLAMA_HOST`   | http://ollama:11434      | Ollama endpoint      |

## Security 🔒

- JWT tokens with 7-day expiry
- Password hashing with bcrypt-like algorithm
- Input sanitization (no eval)
- Rate limiting support (via Nginx)

## Docker Services 🐳

| Service  | Image                    | Port  | Description        |
|----------|--------------------------|-------|--------------------|
| ollama   | ollama/ollama:latest     | 11434 | AI backend         |
| web      | ai-cicada (built)        | 3000  | Web interface      |
| nginx    | nginx:alpine             | 80/443| Reverse proxy      |

## Troubleshooting 🔧

```bash
# Check system health
./cicada-ai.sh doctor

# View logs
./cicada-ai.sh logs

# Check port usage
./cicada-ai.sh status

# Reset everything
./cicada-ai.sh remove
./cicada-ai.sh install
```

## Supported Platforms 💻

- ✅ Ubuntu/Debian
- ✅ Fedora
- ✅ Arch Linux
- ✅ Alpine Linux (Home Assistant)
- ✅ WSL (Windows)
- ✅ Termux (Android)
- ✅ macOS (partial)

## Contributing 🤝

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing`)
5. Open a Pull Request

## License 📄

MIT License - see [LICENSE](LICENSE) file for details.

## Credits 🙏

- [Ollama](https://ollama.ai/) - AI backend
- [llama.cpp](https://github.com/ggerganov/llama.cpp) - Alternative backend
- [better-sqlite3](https://github.com/WiseLibs/better-sqlite3) - SQLite driver
- [jsonwebtoken](https://github.com/auth0/node-jsonwebtoken) - JWT library

---

Made with ❤️ for the privacy-conscious AI enthusiast.
