#!/bin/bash

set -e

LOG_FILE="$HOME/ollama_install.log"
CHAT_DIR="$HOME/.ai-cicada"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Check if port is in use
check_port() {
    local port=$1
    if command -v lsof >/dev/null 2>&1 && lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
        return 0
    elif command -v netstat >/dev/null 2>&1 && netstat -tuln 2>/dev/null | grep -q ":$port "; then
        return 0
    elif command -v ss >/dev/null 2>&1 && ss -tuln 2>/dev/null | grep -q ":$port "; then
        return 0
    elif [ -f /proc/net/tcp ] && awk '\$2 ~ /:'"$(printf '%04X' $port)"'/ {exit 0}' /proc/net/tcp 2>/dev/null; then
        return 0
    fi
    return 1
}

kill_port() {
    local port=$1
    local pids
    pids=$(lsof -ti :$port 2>/dev/null || netstat -tulpn 2>/dev/null | grep ":$port " | awk '{print $7}' | cut -d'/' -f1 | grep -E '^[0-9]+$' || ss -tulpn 2>/dev/null | grep ":$port " | grep -oP 'pid=\K[0-9]+')
    if [ -n "$pids" ]; then
        echo "$pids" | xargs kill -9 2>/dev/null || true
        sleep 1
    fi
}

# State management for tracking installed components
STATE_FILE="$CHAT_DIR/.install_state"
SCRIPT_VERSION="5.1.0"

init_state() {
    mkdir -p "$CHAT_DIR"
    if [ ! -f "$STATE_FILE" ]; then
        echo "{}" > "$STATE_FILE"
    fi
}

get_state() {
    local key=$1
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE" | grep -oP '"'$key'":\s*"\K[^"]+' 2>/dev/null || echo ""
    fi
}

set_state() {
    local key=$1
    local value=$2
    init_state
    local tmp_file="${STATE_FILE}.tmp"
    if [ -s "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" != "{}" ]; then
        # Update existing key
        if grep -q "\"$key\":" "$STATE_FILE"; then
            sed 's/"'$key'": "[^"]*"/"'$key'": "'$value'"/' "$STATE_FILE" > "$tmp_file"
        else
            # Add new key
            sed 's/}$/, "'$key'": "'$value'"}/' "$STATE_FILE" > "$tmp_file"
        fi
    else
        # Create new state
        echo "{ \"$key\": \"$value\" }" > "$tmp_file"
    fi
    mv "$tmp_file" "$STATE_FILE"
}

# Download verification with checksum and size check
verify_download() {
    local file=$1
    local min_size=${2:-1000}  # minimum size in bytes (default 1KB)
    
    if [ ! -f "$file" ]; then
        printf "${RED}Download failed: file not found %s${NC}\n" "$file"
        return 1
    fi
    
    local size
    size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
    if [ "$size" -lt "$min_size" ]; then
        printf "${RED}Download incomplete: %s is only %s bytes${NC}\n" "$file" "$size"
        rm -f "$file"
        return 1
    fi
    
    # Check if file looks like HTML error page (common issue)
    if head -1 "$file" | grep -qi "^<!DOCTYPE\|^<html\|^<HTML"; then
        printf "${RED}Download failed: received HTML error page instead of file${NC}\n"
        rm -f "$file"
        return 1
    fi
    
    return 0
}

# Process lock to prevent duplicate runs
LOCK_FILE="/tmp/ai-cicada-install.lock"
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local old_pid
        old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            printf "${RED}Another installation is already running (PID: %s)${NC}\n" "$old_pid"
            return 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
    return 0
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# Lifecycle commands
lifecycle_start() {
    printf "${BLUE}Starting AI-CICADA services...${NC}\n"
    
    # Start Ollama if not running
    if ! pgrep -x "ollama" > /dev/null 2>&1; then
        printf "${YELLOW}Starting Ollama...${NC}\n"
        ollama serve >> "$LOG_FILE" 2>&1 &
        sleep 3
    fi
    
    # Check port 3000
    if check_port 3000; then
        printf "${YELLOW}Port 3000 busy, killing old process...${NC}\n"
        kill_port 3000
        sleep 1
    fi
    
    local CHAT_HOST
    CHAT_HOST=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    printf "${GREEN}Web chat: http://%s:3000${NC}\n" "$CHAT_HOST"
    printf "${YELLOW}Press Ctrl+C to stop${NC}\n"
    
    AI_MODEL="$MODEL" node "$CHAT_DIR/server.js"
}

lifecycle_stop() {
    printf "${BLUE}Stopping AI-CICADA services...${NC}\n"
    
    local killed=0
    
    # Stop node server
    local node_pids
    node_pids=$(pgrep -f "node.*server.js" 2>/dev/null)
    if [ -n "$node_pids" ]; then
        echo "$node_pids" | xargs kill -9 2>/dev/null || true
        killed=$((killed + 1))
    fi
    
    # Stop llama-server
    if pgrep -f "llama-server" > /dev/null 2>&1; then
        pkill -f "llama-server" 2>/dev/null || true
        killed=$((killed + 1))
    fi
    
    # Kill processes on ports
    kill_port 3000
    kill_port 8080
    
    if [ $killed -gt 0 ]; then
        printf "${GREEN}Services stopped${NC}\n"
    else
        printf "${YELLOW}No running services found${NC}\n"
    fi
}

lifecycle_status() {
    printf "${CYAN}AI-CICADA Status:${NC}\n"
    printf "  Script version: %s\n" "$SCRIPT_VERSION"
    printf "  Install dir: %s\n" "$CHAT_DIR"
    
    # Check state
    local install_date
    install_date=$(get_state "install_date")
    if [ -n "$install_date" ]; then
        printf "  Installed: %s\n" "$install_date"
    fi
    
    # Check Ollama
    if pgrep -x "ollama" > /dev/null 2>&1; then
        printf "  Ollama: ${GREEN}running${NC}\n"
    else
        printf "  Ollama: ${RED}stopped${NC}\n"
    fi
    
    # Check web server
    if pgrep -f "node.*server.js" > /dev/null 2>&1; then
        local pid
        pid=$(pgrep -f "node.*server.js" | head -1)
        printf "  Web server: ${GREEN}running (PID: %s)${NC}\n" "$pid"
    else
        printf "  Web server: ${RED}stopped${NC}\n"
    fi
    
    # Check llama-server
    if pgrep -f "llama-server" > /dev/null 2>&1; then
        printf "  llama.cpp: ${GREEN}running${NC}\n"
    else
        printf "  llama.cpp: ${RED}stopped${NC}\n"
    fi
    
    # Check ports
    if check_port 3000; then
        printf "  Port 3000: ${YELLOW}in use${NC}\n"
    else
        printf "  Port 3000: ${GREEN}available${NC}\n"
    fi
    
    if check_port 11434; then
        printf "  Port 11434: ${YELLOW}in use (Ollama)${NC}\n"
    else
        printf "  Port 11434: ${RED}available${NC}\n"
    fi
}

lifecycle_restart() {
    lifecycle_stop
    sleep 2
    lifecycle_start
}

# Resource checking before installation
check_resources() {
    local model=$1
    printf "${BLUE}Checking system resources...${NC}\n"
    
    # Get available RAM in MB
    local ram_mb=0
    if [ -f /proc/meminfo ]; then
        ram_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
        if [ "$ram_mb" -eq 0 ]; then
            ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
        fi
    elif command -v free >/dev/null 2>&1; then
        ram_mb=$(free -m | awk '/^Mem:/{print $7}' 2>/dev/null || echo 0)
    elif command -v vm_stat >/dev/null 2>&1; then
        # macOS fallback
        ram_mb=$(vm_stat | awk '/free/ {gsub(/[^0-9]/, ""); print int($1/1024)}' 2>/dev/null || echo 0)
    fi
    
    # Get available disk space in GB
    local disk_gb=0
    disk_gb=$(df -BG "$CHAT_DIR" 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print int($4)}' || df -h "$HOME" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/[A-Za-z]//g')
    [ -z "$disk_gb" ] && disk_gb=0
    
    # CPU cores
    local cpu_cores=1
    cpu_cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
    
    printf "  RAM: %d MB available\n" "$ram_mb"
    printf "  Disk: %s GB available\n" "$disk_gb"
    printf "  CPU: %d cores\n" "$cpu_cores"
    
    # Model requirements (approximate)
    local min_ram=4096  # 4GB default
    local model_size_gb=0
    
    case "$model" in
        *0.5b*)  min_ram=2048;  model_size_gb=1 ;;
        *1.5b*)  min_ram=3072;  model_size_gb=2 ;;
        *3b*)    min_ram=4096;  model_size_gb=4 ;;
        *7b*)    min_ram=8192;  model_size_gb=8 ;;
        *8b*)    min_ram=8192;  model_size_gb=8 ;;
        *13b*)   min_ram=16384; model_size_gb=15 ;;
        *70b*)   min_ram=65536; model_size_gb=70 ;;
        llama3.2:3b) min_ram=4096; model_size_gb=4 ;;
        phi3:mini) min_ram=4096; model_size_gb=4 ;;
        mistral:7b) min_ram=8192; model_size_gb=8 ;;
        qwen2.5-coder:3b) min_ram=4096; model_size_gb=4 ;;
        *) min_ram=4096; model_size_gb=4 ;;
    esac
    
    local warnings=0
    
    # Check RAM
    if [ "$ram_mb" -lt "$min_ram" ]; then
        printf "${YELLOW}WARNING: Insufficient RAM for %s${NC}\n" "$model"
        printf "${YELLOW}  Required: %d MB, Available: %d MB${NC}\n" "$min_ram" "$ram_mb"
        printf "${YELLOW}  Model may run slowly or crash${NC}\n"
        warnings=$((warnings + 1))
    else
        printf "${GREEN}  RAM: OK for %s${NC}\n" "$model"
    fi
    
    # Check disk space (model + buffer)
    local required_disk=$((model_size_gb + 2))
    if [ "$disk_gb" -lt "$required_disk" ]; then
        printf "${YELLOW}WARNING: Low disk space${NC}\n"
        printf "${YELLOW}  Required: ~%d GB, Available: %s GB${NC}\n" "$required_disk" "$disk_gb"
        warnings=$((warnings + 1))
    else
        printf "${GREEN}  Disk: OK${NC}\n"
    fi
    
    # Check CPU (warning only)
    if [ "$cpu_cores" -lt 2 ]; then
        printf "${YELLOW}WARNING: Only %d CPU core detected${NC}\n" "$cpu_cores"
        printf "${YELLOW}  Inference will be slow${NC}\n"
        warnings=$((warnings + 1))
    fi
    
    if [ $warnings -gt 0 ]; then
        printf "${YELLOW}\nContinue anyway? [y/N]: ${NC}"
        read -r confirm </dev/tty
        case "$confirm" in
            [Yy]*) return 0 ;;
            *) printf "${RED}Aborted by user${NC}\n"; return 1 ;;
        esac
    fi
    
    return 0
}

# Systemd integration
setup_systemd() {
    if [ "$ENV_TYPE" = "termux" ] || [ "$ENV_TYPE" = "homeassistant" ] || [ "$ENV_TYPE" = "wsl-ha" ]; then
        printf "${YELLOW}Systemd not available on this platform${NC}\n"
        return 1
    fi
    
    if ! command -v systemctl >/dev/null 2>&1; then
        printf "${YELLOW}systemctl not available${NC}\n"
        return 1
    fi
    
    printf "${BLUE}Setting up systemd service...${NC}\n"
    
    # Create systemd service for AI-CICADA
    local service_file="/etc/systemd/system/ai-cicada.service"
    
    # Check if we can write to systemd
    if [ ! -w /etc/systemd/system ]; then
        printf "${YELLOW}Need sudo to create systemd service${NC}\n"
        printf "${YELLOW}Run: sudo systemctl enable --now ai-cicada${NC}\n"
        return 1
    fi
    
    cat > "$service_file" << EOF
[Unit]
Description=AI-CICADA Web Chat
After=network.target ollama.service
Wants=ollama.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$CHAT_DIR
Environment=AI_MODEL=$MODEL
Environment=NODE_ENV=production
Environment=JWT_SECRET=$(openssl rand -hex 32 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | head -c 64)
ExecStart=/usr/bin/node $CHAT_DIR/server.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable ai-cicada.service
    
    printf "${GREEN}Systemd service created: ai-cicada.service${NC}\n"
    printf "${GREEN}  Start: sudo systemctl start ai-cicada${NC}\n"
    printf "${GREEN}  Stop:  sudo systemctl stop ai-cicada${NC}\n"
    printf "${GREEN}  Logs:  sudo journalctl -u ai-cicada -f${NC}\n"
    
    # Also create service for Ollama if not exists
    if [ ! -f /etc/systemd/system/ollama.service ]; then
        printf "${YELLOW}Consider installing Ollama systemd service:${NC}\n"
        printf "${YELLOW}  sudo systemctl enable --now ollama${NC}\n"
    fi
    
    return 0
}

# Full CLI command dispatcher
cicada_cli() {
    local cmd="${1:-help}"
    shift || true
    
    case "$cmd" in
        install)
            printf "${CYAN}AI-CICADA Installer v%s${NC}\n" "$SCRIPT_VERSION"
            cicada_do_install
            ;;
        start)
            lifecycle_start
            ;;
        stop)
            lifecycle_stop
            ;;
        restart)
            lifecycle_restart
            ;;
        status)
            lifecycle_status
            ;;
        remove|uninstall)
            cicada_do_remove
            ;;
        systemd)
            setup_systemd
            ;;
        logs)
            cicada_logs
            ;;
        doctor)
            cicada_doctor
            ;;
        docker)
            cicada_docker_setup
            ;;
        docker-start)
            cicada_docker_start
            ;;
        docker-stop)
            cicada_docker_stop
            ;;
        docker-logs)
            cicada_docker_logs
            ;;
        help|--help|-h|*)
            cat << 'HELPEOF'
AI-CICADA - Local AI Chat with JWT Auth

Usage: ./33.sh <command> [options]

Commands:
  install          Run full installation (interactive)
  start            Start web server and dependencies
  stop             Stop all AI-CICADA services
  restart          Restart services
  status           Show service status and health
  remove           Uninstall AI-CICADA
  systemd          Setup systemd service (auto-start)
  logs             View service logs
  doctor           Diagnose common issues
  docker           Setup Docker environment
  docker-start     Start Docker containers
  docker-stop      Stop Docker containers
  docker-logs      View Docker logs
  help             Show this help

Examples:
  ./33.sh install              # First time setup (native)
  ./33.sh docker               # Setup Docker files
  ./33.sh docker-start         # Start with Docker
  ./33.sh start                # Start native services

Docker:
  docker-compose up -d         # Start all services
  docker-compose logs -f web     # View web logs
  docker-compose pull            # Update images

Files:
  Install dir: ~/.ai-cicada/
  Database:    ~/.ai-cicada/cicada.db
  Logs:        ~/ollama_install.log
  State:       ~/.ai-cicada/.install_state
HELPEOF
            ;;
    esac
}

# Actual installation logic (extracted from main)
cicada_do_install() {
    # Check resources first
    if ! check_resources "${1:-qwen2.5-coder:3b}"; then
        printf "${RED}Installation aborted${NC}\n"
        return 1
    fi
    
    # Acquire lock
    if ! acquire_lock; then
        exit 1
    fi
    
    # Cleanup on exit
    trap 'release_lock; exit' INT TERM EXIT
    
    echo "===== AI-CICADA INSTALL $(date) =====" > "$LOG_FILE"
    detect_env
    init_state
    
    # Check if already installed
    local prev_install
    prev_install=$(get_state "script_version")
    if [ -n "$prev_install" ]; then
        printf "${YELLOW}Previous installation detected (version: %s)${NC}\n" "$prev_install"
        printf "${YELLOW}This will update/overwrite existing files${NC}\n"
        printf "${YELLOW}Press any key to continue or Ctrl+C to cancel...${NC}\n"
        read -r -n1 </dev/tty || true
        printf "\n"
    fi
    
    show_logo
    select_backend
    update_system; clear
    install_nodejs; printf "\n"
    install_sqlite_tools; printf "\n"

    if [ "$BACKEND" = "llamacpp" ]; then
        select_llama_model
        install_llama; printf "\n"
        download_llama_model; printf "\n"
        install_npm_deps; printf "\n"
        create_web_chat; printf "\n"
        setup_alias; printf "\n"
        show_ha_tips
        final_screen
        clear
        center_text "${YELLOW}What to launch now?${NC}"
        printf "\n"
        draw_box "1) Browser chat (web via llama.cpp)" "2) Exit"
        printf "\n${YELLOW}Choice: ${NC}"
        read -r ch </dev/tty
        case $ch in
            1) launch_llamacpp ;;
            *) printf "${GREEN}Done! Run 'web' anytime after starting llama-server.${NC}\n" ;;
        esac
    else
        select_model
        install_ollama; printf "\n"
        start_ollama_service
        install_model; clear
        install_npm_deps; printf "\n"
        create_web_chat; printf "\n"
        setup_alias; printf "\n"
        show_ha_tips
        final_screen
        launch_choice
    fi
    
    # Save installation state
    set_state "script_version" "$SCRIPT_VERSION"
    set_state "install_date" "$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"
    set_state "platform" "$ENV_TYPE"
    set_state "backend" "$BACKEND"
    set_state "model" "$MODEL"
    
    # Release lock
    release_lock
    trap - INT TERM EXIT
    
    printf "${GREEN}\nInstallation complete!${NC}\n"
    printf "${GREEN}Run 'cicada start' or './33.sh start' to begin${NC}\n"
}

# Uninstall function
cicada_do_remove() {
    printf "${YELLOW}This will remove AI-CICADA and all data!${NC}\n"
    printf "${YELLOW}Database at %s will be DELETED${NC}\n" "$CHAT_DIR"
    printf "${YELLOW}Are you sure? [yes/no]: ${NC}"
    read -r confirm
    if [ "$confirm" != "yes" ]; then
        printf "${GREEN}Aborted${NC}\n"
        return 0
    fi
    
    printf "${BLUE}Stopping services...${NC}\n"
    lifecycle_stop
    pkill -f "ollama" 2>/dev/null || true
    
    printf "${BLUE}Removing files...${NC}\n"
    rm -rf "$CHAT_DIR"
    rm -f /tmp/ai-cicada-install.lock
    
    # Remove from shell rc
    local SHELLRC="$HOME/.bashrc"
    if [ -f "$HOME/.bashrc" ]; then
        sed -i '/# AI-CICADA/,/# END AI-CICADA/d' "$SHELLRC" 2>/dev/null || true
    fi
    
    # Remove systemd service if exists
    if [ -f /etc/systemd/system/ai-cicada.service ]; then
        systemctl stop ai-cicada 2>/dev/null || true
        systemctl disable ai-cicada 2>/dev/null || true
        rm -f /etc/systemd/system/ai-cicada.service
        systemctl daemon-reload 2>/dev/null || true
    fi
    
    printf "${GREEN}AI-CICADA removed${NC}\n"
}

# View logs
cicada_logs() {
    printf "${CYAN}Recent logs:${NC}\n"
    if [ -f "$LOG_FILE" ]; then
        tail -50 "$LOG_FILE"
    fi
    
    # Try journalctl if available
    if command -v journalctl >/dev/null 2>&1 && systemctl is-active ai-cicada >/dev/null 2>&1; then
        printf "${CYAN}\nSystemd service logs:${NC}\n"
        journalctl -u ai-cicada -n 20 --no-pager 2>/dev/null || true
    fi
}

# Diagnostic function
cicada_doctor() {
    printf "${CYAN}AI-CICADA Diagnostics${NC}\n\n"
    
    local issues=0
    
    # Check 1: Node.js
    printf "1. Node.js... "
    if command -v node >/dev/null 2>&1; then
        printf "${GREEN}%s${NC}\n" "$(node --version)"
    else
        printf "${RED}NOT FOUND${NC}\n"
        issues=$((issues + 1))
    fi
    
    # Check 2: Ollama
    printf "2. Ollama... "
    if command -v ollama >/dev/null 2>&1; then
        printf "${GREEN}installed${NC}"
        if pgrep -x "ollama" >/dev/null 2>&1; then
            printf " ${GREEN}(running)${NC}\n"
        else
            printf " ${YELLOW}(stopped)${NC}\n"
        fi
    else
        printf "${RED}NOT FOUND${NC}\n"
        issues=$((issues + 1))
    fi
    
    # Check 3: Dependencies
    printf "3. Dependencies... "
    if [ -d "$CHAT_DIR/node_modules/better-sqlite3" ]; then
        printf "${GREEN}OK${NC}\n"
    else
        printf "${YELLOW}incomplete (will use fallback)${NC}\n"
    fi
    
    # Check 4: Database
    printf "4. Database... "
    if [ -f "$CHAT_DIR/cicada.db" ]; then
        local size
        size=$(stat -f%z "$CHAT_DIR/cicada.db" 2>/dev/null || stat -c%s "$CHAT_DIR/cicada.db" 2>/dev/null || echo 0)
        printf "${GREEN}exists (%s bytes)${NC}\n" "$size"
    else
        printf "${YELLOW}not created yet${NC}\n"
    fi
    
    # Check 5: Ports
    printf "5. Port 3000... "
    if check_port 3000; then
        printf "${YELLOW}in use${NC}\n"
        issues=$((issues + 1))
    else
        printf "${GREEN}available${NC}\n"
    fi
    
    printf "6. Port 11434... "
    if check_port 11434; then
        printf "${GREEN}Ollama listening${NC}\n"
    else
        printf "${YELLOW}not in use${NC}\n"
    fi
    
    # Check 6: Systemd
    printf "7. Systemd service... "
    if [ -f /etc/systemd/system/ai-cicada.service ]; then
        if systemctl is-enabled ai-cicada >/dev/null 2>&1; then
            printf "${GREEN}enabled${NC}\n"
        else
            printf "${YELLOW}created but not enabled${NC}\n"
        fi
    else
        printf "${YELLOW}not set up${NC}\n"
    fi
    
    printf "\n"
    if [ $issues -eq 0 ]; then
        printf "${GREEN}All checks passed!${NC}\n"
    else
        printf "${YELLOW}%d issue(s) found${NC}\n" "$issues"
        printf "${YELLOW}Run './33.sh install' to fix${NC}\n"
    fi
}

# Docker management functions
cicada_docker_setup() {
    printf "${CYAN}Setting up AI-CICADA Docker environment...${NC}\n"
    
    # Check if Docker is installed
    if ! command -v docker >/dev/null 2>&1; then
        printf "${RED}Docker not found. Please install Docker first:${NC}\n"
        printf "  curl -fsSL https://get.docker.com | sh\n"
        return 1
    fi
    
    if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
        printf "${RED}Docker Compose not found. Please install it:${NC}\n"
        printf "  https://docs.docker.com/compose/install/\n"
        return 1
    fi
    
    # Create Docker directory
    local DOCKER_DIR="$CHAT_DIR/docker"
    mkdir -p "$DOCKER_DIR"
    
    # Create Dockerfile
    cat > "$DOCKER_DIR/Dockerfile" << 'DOCKEREOF'
# AI-CICADA Docker Image
FROM node:18-slim AS base

RUN apt-get update && apt-get install -y \
    python3 make g++ curl ca-certificates sqlite3 procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json ./
RUN npm install && npm cache clean --force

FROM node:18-slim AS production
RUN apt-get update && apt-get install -y sqlite3 curl ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -r cicada && useradd -r -g cicada cicada
WORKDIR /app

COPY --from=base /app/node_modules ./node_modules
COPY --from=base /app/package.json ./
COPY server.js ./
COPY index.html ./
COPY entrypoint.sh ./
RUN chmod +x entrypoint.sh

RUN mkdir -p /data && chown -R cicada:cicada /data /app

ENV NODE_ENV=production
ENV PORT=3000
ENV DB_PATH=/data/cicada.db
ENV OLLAMA_HOST=http://ollama:11434

EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3000/api/health || exit 1

USER cicada
VOLUME ["/data"]
ENTRYPOINT ["./entrypoint.sh"]
CMD ["start"]
DOCKEREOF

    # Create docker-compose.yml
    cat > "$DOCKER_DIR/docker-compose.yml" << 'COMPOSEOF'
version: '3.8'

services:
  ollama:
    image: ollama/ollama:latest
    container_name: ai-cicada-ollama
    volumes:
      - ollama-data:/root/.ollama
    ports:
      - "11434:11434"
    environment:
      - OLLAMA_ORIGINS=*
      - OLLAMA_HOST=0.0.0.0
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:11434/api/tags"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  web:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: ai-cicada-web
    ports:
      - "3000:3000"
    environment:
      - NODE_ENV=production
      - PORT=3000
      - DB_PATH=/data/cicada.db
      - OLLAMA_HOST=http://ollama:11434
      - AI_MODEL=${AI_MODEL:-qwen2.5-coder:3b}
      - JWT_SECRET=${JWT_SECRET:-}
    volumes:
      - cicada-data:/data
    depends_on:
      ollama:
        condition: service_healthy
    restart: unless-stopped
    networks:
      - ai-cicada-network

volumes:
  ollama-data:
  cicada-data:

networks:
  ai-cicada-network:
    driver: bridge
COMPOSEOF

    # Create entrypoint.sh
    cat > "$DOCKER_DIR/entrypoint.sh" << 'ENTRYEOF'
#!/bin/bash
set -e

DATA_DIR="${DATA_DIR:-/data}"
DB_PATH="${DB_PATH:-$DATA_DIR/cicada.db}"
PORT="${PORT:-3000}"
OLLAMA_HOST="${OLLAMA_HOST:-http://ollama:11434}"
AI_MODEL="${AI_MODEL:-qwen2.5-coder:3b}"

if [ -z "$JWT_SECRET" ] || [ "$JWT_SECRET" = "auto-generate" ]; then
    JWT_SECRET=$(head -c 32 /dev/urandom | xxd -p -c 64 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | head -c 64)
    export JWT_SECRET
fi

wait_for_ollama() {
    echo "Waiting for Ollama at $OLLAMA_HOST..."
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if curl -s "$OLLAMA_HOST/api/tags" > /dev/null 2>&1; then
            echo "Ollama is ready!"
            return 0
        fi
        attempt=$((attempt + 1))
        echo "Attempt $attempt/$max_attempts - waiting 5s..."
        sleep 5
    done
    echo "Ollama failed to start"
    return 1
}

pull_model() {
    echo "Checking model: $AI_MODEL"
    if curl -s "$OLLAMA_HOST/api/tags" | grep -q "$AI_MODEL"; then
        echo "Model already available"
        return 0
    fi
    echo "Pulling model $AI_MODEL..."
    curl -X POST "$OLLAMA_HOST/api/pull" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$AI_MODEL\"}" \
        --silent --show-error || true
    local attempts=0
    while [ $attempts -lt 60 ]; do
        if curl -s "$OLLAMA_HOST/api/tags" | grep -q "$AI_MODEL"; then
            echo "Model ready!"
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 10
    done
    echo "Model pull timeout"
    return 1
}

init_database() {
    mkdir -p "$DATA_DIR"
    if [ ! -f "$DB_PATH" ]; then
        echo "Initializing database..."
        sqlite3 "$DB_PATH" << 'SQL'
CREATE TABLE IF NOT EXISTS users (username TEXT PRIMARY KEY, password_hash TEXT NOT NULL, created_at INTEGER DEFAULT (strftime('%s', 'now')), total_msgs INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS chats (id TEXT PRIMARY KEY, username TEXT NOT NULL, title TEXT, created_at INTEGER DEFAULT (strftime('%s', 'now')));
CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, chat_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, created_at INTEGER DEFAULT (strftime('%s', 'now')));
CREATE TABLE IF NOT EXISTS memory (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, category TEXT DEFAULT 'general', created_at INTEGER DEFAULT (strftime('%s', 'now')), UNIQUE(username, key));
SQL
        echo "Database initialized"
    fi
}

case "${1:-start}" in
    start)
        wait_for_ollama
        pull_model
        init_database
        echo "Starting AI-CICADA server..."
        echo "  Port: $PORT"
        echo "  Model: $AI_MODEL"
        echo "  Ollama: $OLLAMA_HOST"
        exec node server.js
        ;;
    wait)
        wait_for_ollama
        pull_model
        echo "Ready!"
        ;;
    init)
        init_database
        echo "Database initialized"
        ;;
    shell|bash|sh)
        exec /bin/bash
        ;;
    *)
        exec "$@"
        ;;
esac
ENTRYEOF

    chmod +x "$DOCKER_DIR/entrypoint.sh"
    
    # Create .env file
    cat > "$DOCKER_DIR/.env" << 'ENVEOF'
# AI-CICADA Docker Configuration
AI_MODEL=qwen2.5-coder:3b
JWT_SECRET=auto-generate
ENVEOF

    # Create helper script
    cat > "$DOCKER_DIR/start.sh" << 'STARTEOF'
#!/bin/bash
# AI-CICADA Docker Start Script

cd "$(dirname "$0")"

# Check if already running
if docker-compose ps | grep -q "ai-cicada"; then
    echo "AI-CICADA is already running"
    echo "Run: docker-compose logs -f web"
    exit 0
fi

# Build and start
echo "Building and starting AI-CICADA..."
docker-compose up --build -d

echo ""
echo "Waiting for services to be ready..."
sleep 5

# Check status
if docker-compose ps | grep -q "Up"; then
    echo ""
    echo "✓ AI-CICADA is running!"
    echo "  Web: http://localhost:3000"
    echo "  Ollama: http://localhost:11434"
    echo ""
    echo "Commands:"
    echo "  docker-compose logs -f web    # View logs"
    echo "  docker-compose stop           # Stop"
    echo "  docker-compose restart        # Restart"
else
    echo "✗ Failed to start. Check logs:"
    echo "  docker-compose logs"
fi
STARTEOF

    chmod +x "$DOCKER_DIR/start.sh"
    
    # Create README
    cat > "$DOCKER_DIR/README.md" << 'READMEEOF'
# AI-CICADA Docker Setup

## Quick Start

```bash
# Start everything
./start.sh

# Or with docker-compose
docker-compose up -d
```

## Access

- Web Interface: http://localhost:3000
- Ollama API: http://localhost:11434

## Commands

```bash
# View logs
docker-compose logs -f web
docker-compose logs -f ollama

# Stop
docker-compose stop

# Restart
docker-compose restart

# Update
docker-compose pull
docker-compose up -d

# Remove all data (careful!)
docker-compose down -v
```

## Configuration

Edit `.env` file to change:
- `AI_MODEL` - default AI model
- `JWT_SECRET` - authentication secret

## Volumes

Data is persisted in Docker volumes:
- `ollama-data` - AI models
- `cicada-data` - database and config

## Troubleshooting

```bash
# Check status
docker-compose ps

# Restart web only
docker-compose restart web

# Shell into container
docker-compose exec web sh
```
READMEEOF

    printf "${GREEN}Docker environment created in %s${NC}\n" "$DOCKER_DIR"
    printf "${GREEN}\nFiles created:${NC}\n"
    printf "  - Dockerfile\n"
    printf "  - docker-compose.yml\n"
    printf "  - entrypoint.sh\n"
    printf "  - .env\n"
    printf "  - start.sh\n"
    printf "  - README.md\n"
    
    printf "${CYAN}\nTo start:${NC}\n"
    printf "  cd %s\n" "$DOCKER_DIR"
    printf "  ./start.sh\n"
    printf "  # or: docker-compose up -d\n"
}

cicada_docker_start() {
    local DOCKER_DIR="$CHAT_DIR/docker"
    
    if [ ! -f "$DOCKER_DIR/docker-compose.yml" ]; then
        printf "${YELLOW}Docker environment not found. Setting up...${NC}\n"
        cicada_docker_setup
    fi
    
    cd "$DOCKER_DIR"
    printf "${BLUE}Starting AI-CICADA Docker containers...${NC}\n"
    docker-compose up --build -d
    
    printf "${YELLOW}Waiting for services...${NC}\n"
    sleep 10
    
    if docker-compose ps | grep -q "Up"; then
        printf "${GREEN}✓ AI-CICADA is running!${NC}\n"
        printf "  Web: http://localhost:3000\n"
        printf "  Ollama: http://localhost:11434\n"
    else
        printf "${RED}✗ Failed to start${NC}\n"
        docker-compose logs
    fi
}

cicada_docker_stop() {
    local DOCKER_DIR="$CHAT_DIR/docker"
    
    if [ ! -f "$DOCKER_DIR/docker-compose.yml" ]; then
        printf "${RED}Docker environment not found${NC}\n"
        return 1
    fi
    
    cd "$DOCKER_DIR"
    printf "${BLUE}Stopping AI-CICADA Docker containers...${NC}\n"
    docker-compose stop
    printf "${GREEN}Stopped${NC}\n"
}

cicada_docker_logs() {
    local DOCKER_DIR="$CHAT_DIR/docker"
    
    if [ ! -f "$DOCKER_DIR/docker-compose.yml" ]; then
        printf "${RED}Docker environment not found${NC}\n"
        return 1
    fi
    
    cd "$DOCKER_DIR"
    local service="${1:-web}"
    docker-compose logs -f "$service"
}

detect_wsl() {
    # Check for WSL using multiple methods
    if [ -f /proc/sys/kernel/osrelease ] && grep -qi "microsoft\|wsl" /proc/sys/kernel/osrelease 2>/dev/null; then
        return 0
    fi
    if [ -f /proc/version ] && grep -qi "microsoft\|wsl" /proc/version 2>/dev/null; then
        return 0
    fi
    if [ -n "$WSL_DISTRO_NAME" ] || [ -n "$WSLENV" ]; then
        return 0
    fi
    return 1
}

detect_env() {
    # WSL check first (can also have apt)
    if detect_wsl; then
        ENV_TYPE="wsl"
        PKG_MANAGER="apt"
        SUDO="sudo"
        if [ -f /etc/hassio_supervisor ] || [ -d /config/custom_components ] 2>/dev/null; then
            # WSL with Home Assistant
            ENV_TYPE="wsl-ha"
            PKG_MANAGER="apk"
            SUDO=""
            CHAT_DIR="/config/.ai-cicada"
            LOG_FILE="/config/ai-cicada-install.log"
        fi
    elif [ -f /etc/hassio_supervisor ] || [ -f /etc/homeassistant ] || \
       [ -d /config/custom_components ] || \
       grep -qi "homeassistant\|hassio\|hassos" /proc/version 2>/dev/null || \
       grep -qi "homeassistant" /etc/os-release 2>/dev/null; then
        ENV_TYPE="homeassistant"
        PKG_MANAGER="apk"
        SUDO=""
        CHAT_DIR="/config/.ai-cicada"
        LOG_FILE="/config/ai-cicada-install.log"
    elif [ -n "$TERMUX_VERSION" ] || [ -d "/data/data/com.termux" ]; then
        ENV_TYPE="termux"
        PKG_MANAGER="pkg"
        SUDO=""
    elif command -v apt >/dev/null 2>&1; then
        ENV_TYPE="debian"
        PKG_MANAGER="apt"
        SUDO="sudo"
    elif command -v dnf >/dev/null 2>&1; then
        ENV_TYPE="fedora"
        PKG_MANAGER="dnf"
        SUDO="sudo"
    elif command -v pacman >/dev/null 2>&1; then
        ENV_TYPE="arch"
        PKG_MANAGER="pacman"
        SUDO="sudo"
    elif command -v apk >/dev/null 2>&1; then
        ENV_TYPE="alpine"
        PKG_MANAGER="apk"
        SUDO=""
    elif command -v zypper >/dev/null 2>&1; then
        ENV_TYPE="opensuse"
        PKG_MANAGER="zypper"
        SUDO="sudo"
    elif command -v xbps-install >/dev/null 2>&1; then
        ENV_TYPE="void"
        PKG_MANAGER="xbps-install"
        SUDO="sudo"
    else
        ENV_TYPE="unknown"
        PKG_MANAGER=""
        SUDO="sudo"
    fi
    log "Detected environment: $ENV_TYPE"
}

safe_tput_cols() {
    if command -v tput >/dev/null 2>&1 && tput cols >/dev/null 2>&1; then
        tput cols
    else
        echo 80
    fi
}

safe_tput_lines() {
    if command -v tput >/dev/null 2>&1 && tput lines >/dev/null 2>&1; then
        tput lines
    else
        echo 24
    fi
}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

center_text() {
    local text="$1"
    local termwidth
    termwidth=$(safe_tput_cols)
    local clean
    clean=$(printf "%b" "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local len=${#clean}
    local padding=$(( (termwidth - len) / 2 ))
    [ $padding -lt 0 ] && padding=0
    printf "%*s%b\n" "$padding" "" "$text"
}

press_any_key() {
    center_text "${YELLOW}Press any key to continue...${NC}"
    read -r dummy </dev/tty || true
}

repeat_char() {
    local char="$1"
    local count="$2"
    local i=0
    while [ $i -lt "$count" ]; do
        printf "%s" "$char"
        i=$(( i + 1 ))
    done
}

draw_box() {
    local width=60
    local termwidth
    termwidth=$(safe_tput_cols)
    local padding=$(( (termwidth - width) / 2 ))
    [ $padding -lt 0 ] && padding=0
    printf "%${padding}s+" ""
    repeat_char "-" $(( width - 2 ))
    printf "+\n"
    for line in "$@"; do
        printf "%${padding}s| %-56s |\n" "" "$line"
    done
    printf "%${padding}s+" ""
    repeat_char "-" $(( width - 2 ))
    printf "+\n"
}

spinner() {
    local pid=$1
    local spin='|/-\\'
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spin#?}
        printf "\r${BLUE}[%c] Processing...${NC}" "$spin"
        spin=$temp${spin%"$temp"}
        sleep 0.1
    done
    printf "\r%-30s\r" " "
}

timer_start() { START=$(date +%s); }
timer_end() {
    END=$(date +%s)
    printf "${GREEN}Time: %d sec${NC}\n" "$((END - START))"
}

show_logo() {
    clear
    printf "${MAGENTA}\n"
    center_text "  ####   ####  "
    center_text "  ## ##   ##   "
    center_text "  ####    ##   "
    center_text "  ## ##   ##   "
    center_text "  ## ##  ####  "
    printf "\n"
    center_text " ####  ####  ####  ####  ####  ####  "
    center_text "##    ##    ##    ##  ## ##  ## ##  ##"
    center_text "##    ####  ##    ###### ##  ## ##  ##"
    center_text "##    ##    ##    ##  ## ##  ## ##  ##"
    center_text " ####  ####  ####  ##  ## ####  ##  ##"
    printf "${NC}\n"
    local w; w=$(safe_tput_cols)
    local line=""; local i=0
    while [ $i -lt $w ]; do line="${line}-"; i=$(( i + 1 )); done
    printf "${MAGENTA}%s${NC}\n\n" "$line"
    center_text "${CYAN}* AI-CICADA INSTALLER v4.0 *${NC}"
    local display_env="$ENV_TYPE"
    case "$ENV_TYPE" in
        wsl|wsl-ha) display_env="WSL (Windows)" ;;
        homeassistant) display_env="Home Assistant" ;;
        termux) display_env="Termux (Android)" ;;
        debian) display_env="Debian/Ubuntu" ;;
        fedora) display_env="Fedora" ;;
        arch) display_env="Arch Linux" ;;
        alpine) display_env="Alpine Linux" ;;
        opensuse) display_env="openSUSE" ;;
        void) display_env="Void Linux" ;;
    esac
    center_text "${YELLOW}Platform: ${display_env}${NC}"
    if [ "$ENV_TYPE" = "homeassistant" ] || [ "$ENV_TYPE" = "wsl-ha" ]; then
        printf "\n"
        center_text "${GREEN}[Home Assistant mode] /config/.ai-cicada${NC}"
    fi
    printf "\n"
    local w2; w2=$(safe_tput_cols)
    local line2=""; local j=0
    while [ $j -lt $w2 ]; do line2="${line2}-"; j=$(( j + 1 )); done
    printf "${MAGENTA}%s${NC}\n\n" "$line2"
    press_any_key
}

select_model() {
    clear
    center_text "${CYAN}Select Model:${NC}"
    printf "\n"
    if [ "$ENV_TYPE" = "homeassistant" ] || [ "$ENV_TYPE" = "wsl-ha" ]; then
        draw_box \
            "1) qwen2.5-coder:1.5b (HA - mало RAM)" \
            "2) qwen2.5-coder:3b   (recommended)" \
            "3) llama3.2:3b        (HA - баланс)" \
            "4) phi3:mini          (лёгкая)" \
            "5) mistral:7b         (мощная)" \
            "6) Manual input"
    else
        draw_box \
            "1) qwen2.5-coder:3b  (recommended)" \
            "2) llama3:8b" \
            "3) mistral:7b" \
            "4) phi3:mini" \
            "5) Manual input"
    fi
    printf "\n${YELLOW}Choice: ${NC}"
    read -r choice </dev/tty
    if [ "$ENV_TYPE" = "homeassistant" ] || [ "$ENV_TYPE" = "wsl-ha" ]; then
        case $choice in
            1) MODEL="qwen2.5-coder:1.5b" ;;
            2) MODEL="qwen2.5-coder:3b" ;;
            3) MODEL="llama3.2:3b" ;;
            4) MODEL="phi3:mini" ;;
            5) MODEL="mistral:7b" ;;
            6) printf "${YELLOW}Enter model name: ${NC}"; read -r MODEL </dev/tty ;;
            *) printf "${RED}Invalid choice${NC}\n"; sleep 2; select_model; return ;;
        esac
    else
        case $choice in
            1) MODEL="qwen2.5-coder:3b" ;;
            2) MODEL="llama3:8b" ;;
            3) MODEL="mistral:7b" ;;
            4) MODEL="phi3:mini" ;;
            5) printf "${YELLOW}Enter model name: ${NC}"; read -r MODEL </dev/tty ;;
            *) printf "${RED}Invalid choice${NC}\n"; sleep 2; select_model; return ;;
        esac
    fi
    log "Selected model: $MODEL"
    clear
}

select_backend() {
    clear
    center_text "${CYAN}Select AI Backend:${NC}"
    printf "\n"
    draw_box \
        "1) Ollama        (recommended, easy setup)" \
        "2) llama.cpp     (lightweight, no GPU needed)"
    printf "\n${YELLOW}Choice [1]: ${NC}"
    read -r bchoice </dev/tty
    bchoice="${bchoice:-1}"
    case $bchoice in
        2) BACKEND="llamacpp" ;;
        *) BACKEND="ollama" ;;
    esac
    log "Selected backend: $BACKEND"
    clear
}

select_llama_model() {
    clear
    center_text "${CYAN}Select llama.cpp Model:${NC}"
    printf "\n"
    draw_box \
        "1) qwen2.5-coder:0.5b  (~400MB) - best for mobile" \
        "2) qwen2.5-coder:1.5b  (~1GB)" \
        "3) qwen2.5-coder:3b    (~1.9GB)" \
        "4) Manual URL"
    printf "\n${YELLOW}Choice [1]: ${NC}"
    read -r mchoice </dev/tty
    mchoice="${mchoice:-1}"
    MODEL_DIR="$HOME/models"
    case $mchoice in
        1)
            LLAMA_MODEL_FILE="qwen2.5-coder-0.5b-instruct-q4_k_m.gguf"
            LLAMA_MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/main/$LLAMA_MODEL_FILE"
            MODEL="qwen2.5-coder-0.5b"
            ;;
        2)
            LLAMA_MODEL_FILE="qwen2.5-coder-1.5b-instruct-q4_k_m.gguf"
            LLAMA_MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/$LLAMA_MODEL_FILE"
            MODEL="qwen2.5-coder-1.5b"
            ;;
        3)
            LLAMA_MODEL_FILE="qwen2.5-coder-3b-instruct-q4_k_m.gguf"
            LLAMA_MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct-GGUF/resolve/main/$LLAMA_MODEL_FILE"
            MODEL="qwen2.5-coder-3b"
            ;;
        4)
            printf "${YELLOW}Enter model URL: ${NC}"
            read -r LLAMA_MODEL_URL </dev/tty
            LLAMA_MODEL_FILE=$(basename "$LLAMA_MODEL_URL")
            MODEL="$LLAMA_MODEL_FILE"
            ;;
        *)
            LLAMA_MODEL_FILE="qwen2.5-coder-0.5b-instruct-q4_k_m.gguf"
            LLAMA_MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/main/$LLAMA_MODEL_FILE"
            MODEL="qwen2.5-coder-0.5b"
            ;;
    esac
    LLAMA_MODEL_PATH="$MODEL_DIR/$LLAMA_MODEL_FILE"
    log "Selected llama.cpp model: $MODEL"
    clear
}

install_llama() {
    printf "${BLUE}Checking llama.cpp...${NC}\n"
    if command -v llama-server >/dev/null 2>&1 || command -v llama-cli >/dev/null 2>&1; then
        printf "${GREEN}llama.cpp already installed${NC}\n"
        return 0
    fi
    printf "${BLUE}Installing llama.cpp...${NC}\n"
    timer_start
    local exit_code=0
    local install_pid
    case $ENV_TYPE in
        termux)
            (yes N | pkg install -y llama-cpp 2>>"$LOG_FILE") & install_pid=$!
            spinner $install_pid
            wait $install_pid || exit_code=$?
            ;;
        debian|wsl)
            ($SUDO apt-get install -y llama-cpp >> "$LOG_FILE" 2>&1) & install_pid=$!
            spinner $install_pid
            wait $install_pid || true
            if ! command -v llama-server >/dev/null 2>&1; then
                printf "${YELLOW}llama-cpp not in repos, building from source...${NC}\n"
                exit_code=0
                ($SUDO apt-get install -y git cmake build-essential >> "$LOG_FILE" 2>&1 && \
                 git clone --depth 1 https://github.com/ggerganov/llama.cpp /tmp/llama.cpp >> "$LOG_FILE" 2>&1 && \
                 cd /tmp/llama.cpp && cmake -B build >> "$LOG_FILE" 2>&1 && \
                 cmake --build build -j"$(nproc)" --config Release >> "$LOG_FILE" 2>&1 && \
                 $SUDO cp build/bin/llama-server /usr/local/bin/ >> "$LOG_FILE" 2>&1 && \
                 $SUDO cp build/bin/llama-cli /usr/local/bin/ >> "$LOG_FILE" 2>&1) & install_pid=$!
                spinner $install_pid
                wait $install_pid || exit_code=$?
            fi
            ;;
        fedora)
            (sudo dnf install -y llama-cpp >> "$LOG_FILE" 2>&1) & install_pid=$!
            spinner $install_pid
            wait $install_pid || exit_code=$?
            ;;
        arch)
            (sudo pacman -S --noconfirm llama-cpp >> "$LOG_FILE" 2>&1) & install_pid=$!
            spinner $install_pid
            wait $install_pid || exit_code=$?
            ;;
        homeassistant|alpine|wsl-ha)
            (apk add --no-cache llama-cpp >> "$LOG_FILE" 2>&1) & install_pid=$!
            spinner $install_pid
            wait $install_pid || exit_code=$?
            ;;
        *)
            printf "${YELLOW}Please install llama.cpp manually: https://github.com/ggerganov/llama.cpp${NC}\n"
            return 1
            ;;
    esac
    timer_end
    if command -v llama-server >/dev/null 2>&1; then
        printf "${GREEN}llama.cpp installed${NC}\n"
        return 0
    else
        printf "${RED}llama.cpp installation failed. Check %s${NC}\n" "$LOG_FILE"
        # Don't exit, llama.cpp is optional fallback
        return 1
    fi
}

download_llama_model() {
    mkdir -p "$MODEL_DIR"
    if [ -f "$LLAMA_MODEL_PATH" ]; then
        printf "${GREEN}Model already downloaded: %s${NC}\n" "$LLAMA_MODEL_FILE"
        return 0
    fi
    printf "${BLUE}Downloading model (~400MB-2GB)...${NC}\n"
    timer_start
    local attempt=0
    local max_attempts=3
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        printf "${YELLOW}Attempt %d/%d...${NC}\n" "$attempt" "$max_attempts"
        
        if command -v wget >/dev/null 2>&1; then
            wget -q --show-progress -O "$LLAMA_MODEL_PATH.tmp" "$LLAMA_MODEL_URL" 2>&1 | tee -a "$LOG_FILE"
        elif command -v curl >/dev/null 2>&1; then
            curl -L --progress-bar -o "$LLAMA_MODEL_PATH.tmp" "$LLAMA_MODEL_URL" 2>&1 | tee -a "$LOG_FILE"
        else
            printf "${RED}No wget or curl found. Cannot download model.${NC}\n"
            return 1
        fi
        
        # Verify download (models should be at least 100MB)
        if verify_download "$LLAMA_MODEL_PATH.tmp" 104857600; then
            mv "$LLAMA_MODEL_PATH.tmp" "$LLAMA_MODEL_PATH"
            timer_end
            printf "${GREEN}Model downloaded: %s${NC}\n" "$LLAMA_MODEL_PATH"
            log "llama.cpp model downloaded: $LLAMA_MODEL_PATH"
            return 0
        fi
        
        rm -f "$LLAMA_MODEL_PATH.tmp"
        if [ $attempt -lt $max_attempts ]; then
            printf "${YELLOW}Retrying in 5 seconds...${NC}\n"
            sleep 5
        fi
    done
    
    printf "${RED}Failed to download model after %d attempts${NC}\n" "$max_attempts"
    return 1
}

PORT_LLAMA=8080
PORT_WEB=3000

launch_llamacpp() {
    printf "${BLUE}Starting llama-server on port %s...${NC}\n" "$PORT_LLAMA"
    # Check and kill existing processes on ports
    pkill -f "llama-server" 2>/dev/null || true
    for P in $PORT_LLAMA $PORT_WEB; do
        if check_port $P; then
            printf "${YELLOW}Port %s busy, killing process...${NC}\n" "$P"
            kill_port $P
        fi
    done
    sleep 1
    LLAMA_LOG="$HOME/llama-server.log"
    llama-server -m "$LLAMA_MODEL_PATH" --port "$PORT_LLAMA" --host 127.0.0.1 -c 2048 > "$LLAMA_LOG" 2>&1 &
    LLAMA_PID=$!
    printf "${YELLOW}Waiting for llama-server to start...${NC}\n"
    sleep 4
    if ! kill -0 "$LLAMA_PID" 2>/dev/null; then
        printf "${RED}llama-server failed to start. Log:${NC}\n"
        cat "$LLAMA_LOG"
        return 1
    fi
    printf "${GREEN}llama-server running (PID %s)${NC}\n" "$LLAMA_PID"
    # Check port 3000 before starting node
    if check_port $PORT_WEB; then
        printf "${YELLOW}Port %s still busy after cleanup, forcing kill...${NC}\n" "$PORT_WEB"
        kill_port $PORT_WEB
        sleep 1
    fi
    local CHAT_HOST
    CHAT_HOST=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    printf "${GREEN}Open in browser: http://%s:%s${NC}\n" "$CHAT_HOST" "$PORT_WEB"
    printf "${YELLOW}Press Ctrl+C to stop${NC}\n"
    OPENAI_BASE_URL="http://localhost:${PORT_LLAMA}/v1" \
    AI_MODEL="$MODEL" \
    node "$CHAT_DIR/server.js"
    kill "$LLAMA_PID" 2>/dev/null || true
}

fix_dpkg_termux() {
    printf "${YELLOW}Fixing broken dpkg state...${NC}\n"
    echo N | dpkg --configure -a >> "$LOG_FILE" 2>&1 || true
}

update_system() {
    printf "${BLUE}Updating system...${NC}\n"
    timer_start
    case $ENV_TYPE in
        termux)
            fix_dpkg_termux
            (yes N | pkg update -y 2>>"$LOG_FILE" && yes N | pkg upgrade -y 2>>"$LOG_FILE") &
            spinner $!
            ;;
        debian|wsl)
            (sudo DEBIAN_FRONTEND=noninteractive apt update -y >> "$LOG_FILE" 2>&1 && \
             sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y \
               -o Dpkg::Options::="--force-confold" \
               -o Dpkg::Options::="--force-confdef" >> "$LOG_FILE" 2>&1) &
            spinner $!
            ;;
        fedora)
            (sudo dnf update -y >> "$LOG_FILE" 2>&1) &
            spinner $!
            ;;
        arch)
            (sudo pacman -Syu --noconfirm >> "$LOG_FILE" 2>&1) &
            spinner $!
            ;;
        homeassistant|alpine|wsl-ha)
            (apk update >> "$LOG_FILE" 2>&1) &
            spinner $!
            ;;
        opensuse)
            (sudo zypper refresh >> "$LOG_FILE" 2>&1 && sudo zypper update -y >> "$LOG_FILE" 2>&1) &
            spinner $!
            ;;
        void)
            (sudo xbps-install -Syu >> "$LOG_FILE" 2>&1) &
            spinner $!
            ;;
        *)
            printf "${YELLOW}Unknown package manager, skipping update${NC}\n"
            return
            ;;
    esac
    timer_end
}

install_nodejs() {
    printf "${BLUE}Checking Node.js...${NC}\n"
    if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        local ver; ver=$(node --version 2>/dev/null)
        printf "${GREEN}Node.js already installed (%s)${NC}\n" "$ver"
        return 0
    fi
    printf "${BLUE}Installing Node.js...${NC}\n"
    timer_start
    local exit_code=0
    local install_pid
    case $ENV_TYPE in
        termux)   (yes N | pkg install -y nodejs 2>>"$LOG_FILE") & install_pid=$! ;;
        debian|wsl)   (sudo DEBIAN_FRONTEND=noninteractive apt install -y nodejs npm >> "$LOG_FILE" 2>&1) & install_pid=$! ;;
        fedora)   (sudo dnf install -y nodejs npm >> "$LOG_FILE" 2>&1) & install_pid=$! ;;
        arch)     (sudo pacman -S --noconfirm nodejs npm >> "$LOG_FILE" 2>&1) & install_pid=$! ;;
        homeassistant|alpine|wsl-ha) (apk add --no-cache nodejs npm >> "$LOG_FILE" 2>&1) & install_pid=$! ;;
        opensuse) (sudo zypper install -y nodejs npm >> "$LOG_FILE" 2>&1) & install_pid=$! ;;
        void)     (sudo xbps-install -y nodejs >> "$LOG_FILE" 2>&1) & install_pid=$! ;;
        *) printf "${YELLOW}Please install Node.js manually${NC}\n"; return 1 ;;
    esac
    spinner $install_pid
    wait $install_pid || exit_code=$?
    timer_end
    if [ $exit_code -ne 0 ]; then
        printf "${RED}Node.js installation failed (exit code: %d). Check %s${NC}\n" "$exit_code" "$LOG_FILE"
        exit 1
    fi
    if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        printf "${GREEN}Node.js installed: %s${NC}\n" "$(node --version)"
        return 0
    else
        printf "${RED}Node.js installation failed. Check %s${NC}\n" "$LOG_FILE"
        exit 1
    fi
}

install_sqlite_tools() {
    printf "${BLUE}Checking SQLite tools...${NC}\n"
    if command -v sqlite3 >/dev/null 2>&1; then
        printf "${GREEN}sqlite3 already available${NC}\n"
        return 0
    fi
    local exit_code=0
    case $ENV_TYPE in
        termux)   (yes N | pkg install -y sqlite 2>>"$LOG_FILE") & spinner $! ;;
        debian|wsl)   (sudo apt install -y sqlite3 >> "$LOG_FILE" 2>&1) & spinner $! ;;
        fedora)   (sudo dnf install -y sqlite >> "$LOG_FILE" 2>&1) & spinner $! ;;
        arch)     (sudo pacman -S --noconfirm sqlite >> "$LOG_FILE" 2>&1) & spinner $! ;;
        homeassistant|alpine|wsl-ha) (apk add --no-cache sqlite >> "$LOG_FILE" 2>&1) & spinner $! ;;
        opensuse) (sudo zypper install -y sqlite3 >> "$LOG_FILE" 2>&1) & spinner $! ;;
        void)     (sudo xbps-install -y sqlite >> "$LOG_FILE" 2>&1) & spinner $! ;;
    esac
    wait $! || exit_code=$?
    if [ $exit_code -ne 0 ]; then
        printf "${YELLOW}SQLite install may have failed, continuing...${NC}\n"
    fi
    # Verify installation
    if command -v sqlite3 >/dev/null 2>&1; then
        printf "${GREEN}SQLite tools ready${NC}\n"
        return 0
    else
        printf "${YELLOW}sqlite3 not available, DB features may be limited${NC}\n"
        return 1
    fi
}

install_ollama() {
    printf "${BLUE}Checking Ollama...${NC}\n"
    if command -v ollama >/dev/null 2>&1; then
        printf "${GREEN}Ollama already installed${NC}\n"
        return 0
    fi
    printf "${BLUE}Installing Ollama...${NC}\n"
    timer_start
    local exit_code=0
    local install_pid
    case $ENV_TYPE in
        termux)
            if pkg show ollama >/dev/null 2>&1; then
                (yes N | pkg install -y ollama >> "$LOG_FILE" 2>&1) & install_pid=$!
                spinner $install_pid
                wait $install_pid || exit_code=$?
            else
                printf "${YELLOW}Ollama not in pkg repos, using proot-distro...${NC}\n"
                if ! (yes N | pkg install -y proot-distro >> "$LOG_FILE" 2>&1); then
                    printf "${RED}Failed to install proot-distro${NC}\n"
                    return 1
                fi
                if ! proot-distro install ubuntu >> "$LOG_FILE" 2>&1; then
                    printf "${YELLOW}proot-distro install may have failed, continuing...${NC}\n"
                fi
                # Safe download and execute
                local INSTALLER="/data/data/com.termux/files/usr/tmp/ollama_install_$$.sh"
                if ! curl -fsSL https://ollama.com/install.sh -o "$INSTALLER" >> "$LOG_FILE" 2>&1; then
                    printf "${RED}Failed to download Ollama installer${NC}\n"
                    return 1
                fi
                if ! verify_download "$INSTALLER" 1000; then
                    printf "${RED}Ollama installer download verification failed${NC}\n"
                    return 1
                fi
                chmod +x "$INSTALLER"
                proot-distro login ubuntu -- "$INSTALLER" >> "$LOG_FILE" 2>&1 & install_pid=$!
                spinner $install_pid
                wait $install_pid || exit_code=$?
                rm -f "$INSTALLER"
                printf '#!/bin/sh\nproot-distro login ubuntu -- ollama "$@"\n' > "$PREFIX/bin/ollama"
                chmod +x "$PREFIX/bin/ollama"
            fi
            ;;
        homeassistant|wsl-ha)
            printf "${YELLOW}Home Assistant: installing Ollama binary for Alpine/musl...${NC}\n"
            ARCH=$(uname -m)
            case $ARCH in
                x86_64)  OLLAMA_BIN="ollama-linux-amd64" ;;
                aarch64) OLLAMA_BIN="ollama-linux-arm64" ;;
                armv7l)  OLLAMA_BIN="ollama-linux-arm" ;;
                *)
                    printf "${RED}Unsupported arch: %s${NC}\n" "$ARCH"
                    return 1
                    ;;
            esac
            (curl -fsSL "https://github.com/ollama/ollama/releases/latest/download/${OLLAMA_BIN}" \
                -o /usr/local/bin/ollama >> "$LOG_FILE" 2>&1 && \
             chmod +x /usr/local/bin/ollama) & install_pid=$!
            spinner $install_pid
            wait $install_pid || exit_code=$?
            ;;
        wsl)
            printf "${YELLOW}WSL detected: using standard Ollama installer...${NC}\n"
            local INSTALLER="/tmp/ollama_install_$$.sh"
            if ! curl -fsSL https://ollama.com/install.sh -o "$INSTALLER" >> "$LOG_FILE" 2>&1; then
                printf "${RED}Failed to download Ollama installer${NC}\n"
                return 1
            fi
            if ! verify_download "$INSTALLER" 1000; then
                printf "${RED}Ollama installer download verification failed${NC}\n"
                return 1
            fi
            chmod +x "$INSTALLER"
            "$INSTALLER" >> "$LOG_FILE" 2>&1 & install_pid=$!
            spinner $install_pid
            wait $install_pid || exit_code=$?
            rm -f "$INSTALLER"
            ;;
        *)
            local INSTALLER="/tmp/ollama_install_$$.sh"
            if ! curl -fsSL https://ollama.com/install.sh -o "$INSTALLER" >> "$LOG_FILE" 2>&1; then
                printf "${RED}Failed to download Ollama installer${NC}\n"
                return 1
            fi
            if ! verify_download "$INSTALLER" 1000; then
                printf "${RED}Ollama installer download verification failed${NC}\n"
                return 1
            fi
            chmod +x "$INSTALLER"
            "$INSTALLER" >> "$LOG_FILE" 2>&1 & install_pid=$!
            spinner $install_pid
            wait $install_pid || exit_code=$?
            rm -f "$INSTALLER"
            ;;
    esac
    timer_end
    if command -v ollama >/dev/null 2>&1; then
        printf "${GREEN}Ollama installed${NC}\n"
        return 0
    else
        printf "${RED}Ollama installation failed. Check %s${NC}\n" "$LOG_FILE"
        return 1
    fi
}

start_ollama_service() {
    printf "${BLUE}Starting Ollama service...${NC}\n"
    if pgrep -x "ollama" > /dev/null 2>&1; then
        printf "${GREEN}Ollama already running${NC}\n"
        return
    fi
    case $ENV_TYPE in
        termux)
            ollama serve >> "$LOG_FILE" 2>&1 &
            ;;
        homeassistant|wsl-ha)
            ollama serve >> "$LOG_FILE" 2>&1 &
            printf "${YELLOW}Ollama running in background. After reboot run: ollama serve &${NC}\n"
            ;;
        wsl)
            # WSL may not have systemd, try to use it if available, otherwise background
            if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
                sudo systemctl enable --now ollama >> "$LOG_FILE" 2>&1 || ollama serve >> "$LOG_FILE" 2>&1 &
            else
                printf "${YELLOW}WSL: Starting Ollama in background (no systemd)${NC}\n"
                ollama serve >> "$LOG_FILE" 2>&1 &
            fi
            ;;
        *)
            if command -v systemctl >/dev/null 2>&1; then
                sudo systemctl enable --now ollama >> "$LOG_FILE" 2>&1 || ollama serve >> "$LOG_FILE" 2>&1 &
            else
                ollama serve >> "$LOG_FILE" 2>&1 &
            fi
            ;;
    esac
    sleep 3
    printf "${GREEN}Ollama service started${NC}\n"
}

install_model() {
    printf "${BLUE}Checking model: %s${NC}\n" "$MODEL"
    if ollama list 2>/dev/null | grep -q "$MODEL"; then
        printf "${GREEN}Model already installed${NC}\n"
        return
    fi
    printf "${BLUE}Downloading %s...${NC}\n" "$MODEL"
    timer_start
    log "Downloading model: $MODEL"
    ollama pull "$MODEL" 2>&1 | while IFS= read -r line; do
        if echo "$line" | grep -qE '[0-9]+%'; then
            percent=$(echo "$line" | grep -oE '[0-9]+%' | tail -1)
            printf "\r${GREEN}Downloading: %-6s${NC}" "$percent"
        fi
        echo "$line" >> "$LOG_FILE"
    done
    printf "\n"
    timer_end
    printf "${GREEN}Model %s installed${NC}\n" "$MODEL"
}

install_npm_deps() {
    printf "${BLUE}Installing npm dependencies...${NC}\n"
    mkdir -p "$CHAT_DIR"
    cd "$CHAT_DIR"
    # Backup existing node_modules on re-run (idempotency)
    if [ -d "$CHAT_DIR/node_modules" ] && [ ! -d "$CHAT_DIR/node_modules.backup" ]; then
        printf "${YELLOW}Existing node_modules found, backing up...${NC}\n"
        mv "$CHAT_DIR/node_modules" "$CHAT_DIR/node_modules.backup.$(date +%s)" 2>/dev/null || true
    fi
    cat > package.json << 'PKGEOF'
{
  "name": "ai-cicada",
  "version": "5.1.0",
  "main": "server.js",
  "dependencies": {
    "better-sqlite3": "^9.4.3",
    "axios": "^1.6.0",
    "jsonwebtoken": "^9.0.2"
  }
}
PKGEOF
    # Run npm install with error capture
    if ! (npm install >> "$LOG_FILE" 2>&1); then
        printf "${RED}npm install failed! Check %s${NC}\n" "$LOG_FILE"
        # Restore backup if exists
        for backup in "$CHAT_DIR/node_modules.backup."*; do
            if [ -d "$backup" ]; then
                printf "${YELLOW}Restoring backup node_modules...${NC}\n"
                rm -rf "$CHAT_DIR/node_modules" 2>/dev/null || true
                mv "$backup" "$CHAT_DIR/node_modules"
                break
            fi
        done
        cd - > /dev/null
        return 1
    fi
    # Verify critical dependencies
    if [ ! -d "$CHAT_DIR/node_modules/better-sqlite3" ]; then
        printf "${YELLOW}better-sqlite3 not installed, using in-memory fallback${NC}\n"
        DB_FALLBACK=1
    else
        printf "${GREEN}Dependencies installed${NC}\n"
        DB_FALLBACK=0
    fi
    # Verify JWT support
    if [ ! -d "$CHAT_DIR/node_modules/jsonwebtoken" ]; then
        printf "${YELLOW}Warning: jsonwebtoken not installed, auth will use fallback${NC}\n"
    fi
    # Clean up old backups (keep last 3)
    ls -t "$CHAT_DIR/node_modules.backup."* 2>/dev/null | tail -n +4 | xargs rm -rf 2>/dev/null || true
    cd - > /dev/null
}

# Записываем server.js через python3 чтобы избежать проблем с heredoc в ash/busybox
create_server_js() {
    printf "${BLUE}Creating server.js...${NC}\n"
    python3 - "$CHAT_DIR/server.js" << 'PYEOF'
import sys

path = sys.argv[1]

code = r"""
const http   = require('http');
const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');
const https  = require('https');

const PORT       = 3000;
const MODEL      = process.env.AI_MODEL || 'qwen2.5-coder:3b';
const DB_PATH    = path.join(__dirname, 'cicada.db');
const JWT_SECRET = process.env.JWT_SECRET || crypto.randomBytes(32).toString('hex');
const JWT_EXPIRY = process.env.JWT_EXPIRY || '7d';

let jwt = null;
try { jwt = require('jsonwebtoken'); } catch(e) { console.log('jsonwebtoken not available, using simple auth'); }
let axios = null;
try { axios = require('axios'); } catch(e) { console.log('axios not available, web search disabled'); }

/* ====== SQLite init ====== */
let db = null;

function initDB() {
    try {
        const Database = require('better-sqlite3');
        db = new Database(DB_PATH);
        db.pragma('journal_mode = WAL');
        db.pragma('foreign_keys = ON');
        db.exec(
            "CREATE TABLE IF NOT EXISTS users (" +
            "  id INTEGER PRIMARY KEY AUTOINCREMENT," +
            "  username TEXT UNIQUE NOT NULL," +
            "  password TEXT NOT NULL," +
            "  created_at INTEGER DEFAULT (strftime('%s','now'))," +
            "  total_msgs INTEGER DEFAULT 0," +
            "  preferences TEXT DEFAULT '{}'" +
            ");" +
            "CREATE TABLE IF NOT EXISTS chats (" +
            "  id TEXT PRIMARY KEY," +
            "  username TEXT NOT NULL," +
            "  title TEXT NOT NULL DEFAULT 'Новый чат'," +
            "  created_at INTEGER DEFAULT (strftime('%s','now'))," +
            "  updated_at INTEGER DEFAULT (strftime('%s','now'))," +
            "  FOREIGN KEY(username) REFERENCES users(username) ON DELETE CASCADE" +
            ");" +
            "CREATE TABLE IF NOT EXISTS messages (" +
            "  id INTEGER PRIMARY KEY AUTOINCREMENT," +
            "  chat_id TEXT NOT NULL," +
            "  role TEXT NOT NULL CHECK(role IN ('user','assistant','system'))," +
            "  content TEXT NOT NULL," +
            "  created_at INTEGER DEFAULT (strftime('%s','now'))," +
            "  FOREIGN KEY(chat_id) REFERENCES chats(id) ON DELETE CASCADE" +
            ");" +
            "CREATE TABLE IF NOT EXISTS memory (" +
            "  id INTEGER PRIMARY KEY AUTOINCREMENT," +
            "  username TEXT NOT NULL," +
            "  key TEXT NOT NULL," +
            "  value TEXT NOT NULL," +
            "  category TEXT DEFAULT 'general'," +
            "  created_at INTEGER DEFAULT (strftime('%s','now'))," +
            "  updated_at INTEGER DEFAULT (strftime('%s','now'))," +
            "  UNIQUE(username, key)" +
            ");" +
            "CREATE INDEX IF NOT EXISTS idx_chats_user ON chats(username);" +
            "CREATE INDEX IF NOT EXISTS idx_msgs_chat  ON messages(chat_id);" +
            "CREATE INDEX IF NOT EXISTS idx_memory_user ON memory(username);"
        );
        console.log('SQLite DB initialised: ' + DB_PATH);
    } catch(e) {
        console.warn('better-sqlite3 not available, using in-memory store:', e.message);
        db = null;
    }
}

/* ====== In-memory fallback ====== */
const mem = { users: {}, chats: {}, memory: {} };

function hashPwd(p) { return crypto.createHash('sha256').update(p).digest('hex'); }

/* ====== User API ====== */
function createUser(username, password) {
    if (db) {
        try {
            db.prepare('INSERT INTO users (username, password) VALUES (?, ?)').run(username, hashPwd(password));
            return true;
        } catch(e) { return false; }
    }
    if (mem.users[username]) return false;
    mem.users[username] = { password: hashPwd(password), created_at: Math.floor(Date.now()/1000), total_msgs: 0, preferences: {} };
    return true;
}

function getUser(username) {
    if (db) return db.prepare('SELECT * FROM users WHERE username=?').get(username) || null;
    return mem.users[username] ? Object.assign({}, mem.users[username], { username }) : null;
}

function checkPassword(username, password) {
    const u = getUser(username);
    if (!u) return false;
    return u.password === hashPwd(password);
}

function incUserMsgs(username) {
    if (db) { db.prepare('UPDATE users SET total_msgs=total_msgs+1 WHERE username=?').run(username); return; }
    if (mem.users[username]) mem.users[username].total_msgs = (mem.users[username].total_msgs || 0) + 1;
}

/* ====== Chat API ====== */
function getUserChats(username) {
    if (db) {
        return db.prepare(
            'SELECT c.*, COUNT(m.id) as msg_count FROM chats c ' +
            'LEFT JOIN messages m ON m.chat_id=c.id ' +
            'WHERE c.username=? GROUP BY c.id ORDER BY c.updated_at DESC'
        ).all(username);
    }
    return Object.values(mem.chats).filter(function(c){ return c.username === username; })
        .sort(function(a,b){ return b.updated_at - a.updated_at; });
}

function upsertChat(chatId, username, title) {
    if (db) {
        const existing = db.prepare('SELECT id FROM chats WHERE id=?').get(chatId);
        if (existing) {
            db.prepare("UPDATE chats SET title=?, updated_at=strftime('%s','now') WHERE id=?").run(title, chatId);
        } else {
            db.prepare('INSERT INTO chats (id, username, title) VALUES (?,?,?)').run(chatId, username, title);
        }
        return;
    }
    if (!mem.chats[chatId]) {
        mem.chats[chatId] = { id: chatId, username: username, title: title, messages: [], created_at: Math.floor(Date.now()/1000), updated_at: Math.floor(Date.now()/1000) };
    } else {
        mem.chats[chatId].title = title;
        mem.chats[chatId].updated_at = Math.floor(Date.now()/1000);
    }
}

function deleteChat(chatId) {
    if (db) {
        db.prepare('DELETE FROM messages WHERE chat_id=?').run(chatId);
        db.prepare('DELETE FROM chats WHERE id=?').run(chatId);
        return;
    }
    delete mem.chats[chatId];
}

function getChatMessages(chatId) {
    if (db) return db.prepare('SELECT role, content FROM messages WHERE chat_id=? ORDER BY id ASC').all(chatId);
    return mem.chats[chatId] ? mem.chats[chatId].messages : [];
}

function addMessage(chatId, role, content) {
    if (db) {
        db.prepare('INSERT INTO messages (chat_id, role, content) VALUES (?,?,?)').run(chatId, role, content);
        db.prepare("UPDATE chats SET updated_at=strftime('%s','now') WHERE id=?").run(chatId);
        return;
    }
    if (mem.chats[chatId]) {
        mem.chats[chatId].messages.push({ role: role, content: content });
        mem.chats[chatId].updated_at = Math.floor(Date.now()/1000);
    }
}

function getUserStats(username) {
    if (db) {
        const u = getUser(username);
        const chatCount = (db.prepare('SELECT COUNT(*) as n FROM chats WHERE username=?').get(username) || { n: 0 }).n;
        const msgCount  = (db.prepare(
            'SELECT COUNT(*) as n FROM messages m JOIN chats c ON c.id=m.chat_id WHERE c.username=?'
        ).get(username) || { n: 0 }).n;
        const memCount = (db.prepare('SELECT COUNT(*) as n FROM memory WHERE username=?').get(username) || { n: 0 }).n;
        return { total_msgs: (u && u.total_msgs) || 0, chat_count: chatCount, msg_count: msgCount, memory_count: memCount, created_at: u && u.created_at };
    }
    const u = mem.users[username] || {};
    const chats = Object.values(mem.chats).filter(function(c){ return c.username === username; });
    const mems = mem.memory[username] || {};
    return {
        total_msgs: u.total_msgs || 0,
        chat_count: chats.length,
        msg_count: chats.reduce(function(s,c){ return s + c.messages.length; }, 0),
        memory_count: Object.keys(mems).length,
        created_at: u.created_at
    };
}

/* ====== MEMORY SYSTEM ====== */
function setMemory(username, key, value, category) {
    category = category || 'general';
    if (db) {
        try {
            db.prepare('INSERT OR REPLACE INTO memory (username, key, value, category, updated_at) VALUES (?, ?, ?, ?, strftime("%s","now"))')
                .run(username, key, value, category);
            return true;
        } catch(e) { console.error('Memory save error:', e); return false; }
    }
    if (!mem.memory[username]) mem.memory[username] = {};
    mem.memory[username][key] = { value: value, category: category, updated_at: Math.floor(Date.now()/1000) };
    return true;
}

function getMemory(username, key) {
    if (db) {
        const row = db.prepare('SELECT value, category FROM memory WHERE username=? AND key=?').get(username, key);
        return row || null;
    }
    if (mem.memory[username] && mem.memory[username][key]) {
        return { value: mem.memory[username][key].value, category: mem.memory[username][key].category };
    }
    return null;
}

function getAllMemory(username, category) {
    if (db) {
        if (category) {
            return db.prepare('SELECT key, value, category, updated_at FROM memory WHERE username=? AND category=? ORDER BY updated_at DESC')
                .all(username, category);
        }
        return db.prepare('SELECT key, value, category, updated_at FROM memory WHERE username=? ORDER BY updated_at DESC')
            .all(username);
    }
    const userMem = mem.memory[username] || {};
    return Object.keys(userMem).map(function(k) {
        return { key: k, value: userMem[k].value, category: userMem[k].category, updated_at: userMem[k].updated_at };
    });
}

function deleteMemory(username, key) {
    if (db) {
        db.prepare('DELETE FROM memory WHERE username=? AND key=?').run(username, key);
        return;
    }
    if (mem.memory[username]) delete mem.memory[username][key];
}

function searchMemory(username, query) {
    if (db) {
        return db.prepare("SELECT key, value, category FROM memory WHERE username=? AND (key LIKE ? OR value LIKE ?)")
            .all(username, '%' + query + '%', '%' + query + '%');
    }
    const userMem = mem.memory[username] || {};
    const results = [];
    Object.keys(userMem).forEach(function(k) {
        if (k.toLowerCase().includes(query.toLowerCase()) || userMem[k].value.toLowerCase().includes(query.toLowerCase())) {
            results.push({ key: k, value: userMem[k].value, category: userMem[k].category });
        }
    });
    return results;
}

/* ====== JWT Authentication ====== */
function generateToken(username) {
    if (!jwt) return null;
    return jwt.sign({ username: username, iat: Math.floor(Date.now()/1000) }, JWT_SECRET, { expiresIn: JWT_EXPIRY });
}

function verifyToken(token) {
    if (!jwt) return null;
    try {
        return jwt.verify(token, JWT_SECRET);
    } catch(e) {
        return null;
    }
}

function authMiddleware(req, res, next) {
    const authHeader = req.headers['authorization'];
    const token = authHeader && authHeader.split(' ')[1]; // Bearer TOKEN

    if (!token) {
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Access token required' }));
        return;
    }

    const decoded = verifyToken(token);
    if (!decoded) {
        res.writeHead(403, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Invalid or expired token' }));
        return;
    }

    req.username = decoded.username;
    next();
}

function optionalAuth(req, res, next) {
    const authHeader = req.headers['authorization'];
    const token = authHeader && authHeader.split(' ')[1];
    if (token) {
        const decoded = verifyToken(token);
        if (decoded) req.username = decoded.username;
    }
    next();
}

/* ====== WEB SEARCH ====== */
async function webSearch(query, maxResults) {
    maxResults = maxResults || 5;
    if (!axios) return { error: 'Web search not available (axios not installed)' };
    
    try {
        // DuckDuckGo HTML scraping approach
        const searchUrl = 'https://html.duckduckgo.com/html/?q=' + encodeURIComponent(query);
        const response = await axios.get(searchUrl, {
            headers: {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            },
            timeout: 10000
        });
        
        const html = response.data;
        const results = [];
        
        // Parse results from DuckDuckGo HTML
        const resultRegex = /<a rel="nofollow" class="result__a" href="([^"]+)"[^>]*>([^<]+)<\/a>/g;
        const snippetRegex = /<a rel="nofollow" class="result__snippet"[^>]*>([^<]+)<\/a>/g;
        
        let match;
        const titles = [];
        const urls = [];
        
        while ((match = resultRegex.exec(html)) !== null && urls.length < maxResults) {
            urls.push(match[1]);
            titles.push(match[2].replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>'));
        }
        
        for (let i = 0; i < urls.length; i++) {
            results.push({
                title: titles[i] || 'No title',
                url: urls[i],
                snippet: ''
            });
        }
        
        return { results: results, query: query };
    } catch(e) {
        console.error('Web search error:', e.message);
        return { error: 'Search failed: ' + e.message, results: [] };
    }
}

/* ====== TOOLS SYSTEM ====== */
const TOOLS = {
    web_search: {
        name: 'web_search',
        description: 'Search the web for current information',
        parameters: {
            query: { type: 'string', description: 'Search query' },
            max_results: { type: 'number', description: 'Maximum results (1-10)', default: 5 }
        }
    },
    memory_set: {
        name: 'memory_set',
        description: 'Save a fact or information to memory for later recall',
        parameters: {
            key: { type: 'string', description: 'Memory key/topic' },
            value: { type: 'string', description: 'Information to remember' },
            category: { type: 'string', description: 'Category (general, preference, fact)', default: 'general' }
        }
    },
    memory_get: {
        name: 'memory_get',
        description: 'Retrieve information from memory',
        parameters: {
            key: { type: 'string', description: 'Memory key to retrieve' }
        }
    },
    memory_search: {
        name: 'memory_search',
        description: 'Search through all stored memories',
        parameters: {
            query: { type: 'string', description: 'Search query' }
        }
    },
    calculate: {
        name: 'calculate',
        description: 'Perform mathematical calculations',
        parameters: {
            expression: { type: 'string', description: 'Mathematical expression' }
        }
    }
};

async function executeTool(toolName, args, username) {
    switch(toolName) {
        case 'web_search':
            return await webSearch(args.query, args.max_results || 5);
        case 'memory_set':
            const saved = setMemory(username, args.key, args.value, args.category || 'general');
            return { success: saved, key: args.key, message: 'Saved to memory: ' + args.key };
        case 'memory_get':
            const mem = getMemory(username, args.key);
            return mem || { error: 'Memory not found: ' + args.key };
        case 'memory_search':
            return { results: searchMemory(username, args.query) };
        case 'calculate':
            try {
                // Safe math evaluator - only allows numbers and basic operators
                const sanitized = args.expression.replace(/[^0-9+\-*/().\s]/g, '');
                if (sanitized.length === 0) {
                    return { error: 'Invalid expression: only numbers and + - * / ( ) allowed' };
                }
                if (sanitized.length > 100) {
                    return { error: 'Expression too long' };
                }
                // Use Function with strict mode but sanitized input
                const result = Function('"use strict"; return (' + sanitized + ')')();
                // Validate result is a number
                if (typeof result !== 'number' || !isFinite(result)) {
                    return { error: 'Invalid result type' };
                }
                return { result: result, expression: args.expression };
            } catch(e) {
                return { error: 'Calculation failed: ' + e.message };
            }
        default:
            return { error: 'Unknown tool: ' + toolName };
    }
}

function formatToolsForPrompt() {
    let prompt = '\n\nYou have access to the following tools:\n';
    Object.keys(TOOLS).forEach(function(key) {
        const tool = TOOLS[key];
        prompt += '\n' + tool.name + ': ' + tool.description;
        prompt += '\n  Parameters:';
        Object.keys(tool.parameters).forEach(function(p) {
            const param = tool.parameters[p];
            prompt += '\n    - ' + p + ' (' + param.type + '): ' + param.description;
            if (param.default) prompt += ' [default: ' + param.default + ']';
        });
    });
    prompt += '\n\nTo use a tool, respond with JSON in this format:\n';
    prompt += '{"tool": "tool_name", "arguments": {"param1": "value1", ...}}\n';
    prompt += '\nThe system will execute the tool and return results.';
    return prompt;
}

/* ====== HTTP helpers ====== */
function parseBody(req) {
    return new Promise(function(resolve, reject) {
        var body = '';
        req.on('data', function(chunk) { body += chunk; });
        req.on('end', function() {
            try { resolve(JSON.parse(body)); } catch(e) { reject(new Error('Bad JSON')); }
        });
    });
}

function jsonOk(res, data) {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(data));
}

function jsonErr(res, code, msg) {
    res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ error: msg }));
}

/* ====== HTTP Server ====== */
const server = http.createServer(async function(req, res) {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET,POST,DELETE,OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
    if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

    const url = req.url.split('?')[0];

    /* Static */
    if (req.method === 'GET' && (url === '/' || url === '/index.html')) {
        const html = fs.readFileSync(path.join(__dirname, 'index.html'));
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(html);
        return;
    }

    if (req.method === 'GET' && url === '/model') {
        return jsonOk(res, { model: MODEL, tools: Object.keys(TOOLS), web_search: !!axios });
    }

    /* Auth */
    if (req.method === 'POST' && url === '/api/register') {
        try {
            const body = await parseBody(req);
            const username = body.username; const password = body.password;
            if (!username || !password) return jsonErr(res, 400, 'username и password обязательны');
            if (username.length < 3) return jsonErr(res, 400, 'Логин минимум 3 символа');
            if (password.length < 4) return jsonErr(res, 400, 'Пароль минимум 4 символа');
            if (!createUser(username, password)) return jsonErr(res, 409, 'Логин уже занят');
            return jsonOk(res, { ok: true, username: username });
        } catch(e) { return jsonErr(res, 400, e.message); }
    }

    if (req.method === 'POST' && url === '/api/login') {
        try {
            const body = await parseBody(req);
            const username = body.username; const password = body.password;
            if (!username || !password) return jsonErr(res, 400, 'Заполните все поля');
            if (!getUser(username)) return jsonErr(res, 404, 'Пользователь не найден');
            if (!checkPassword(username, password)) return jsonErr(res, 401, 'Неверный пароль');
            const stats = getUserStats(username);
            const token = generateToken(username);
            return jsonOk(res, Object.assign({ ok: true, username: username, token: token }, stats));
        } catch(e) { return jsonErr(res, 400, e.message); }
    }

    if (req.method === 'GET' && url === '/api/stats') {
        const authHeader = req.headers['authorization'];
        const token = authHeader && authHeader.split(' ')[1];
        if (!token) return jsonErr(res, 401, 'Authorization required');
        const decoded = verifyToken(token);
        if (!decoded) return jsonErr(res, 403, 'Invalid token');
        return jsonOk(res, getUserStats(decoded.username));
    }

    /* Chats */
    if (req.method === 'GET' && url === '/api/chats') {
        const authHeader = req.headers['authorization'];
        const token = authHeader && authHeader.split(' ')[1];
        if (!token) return jsonErr(res, 401, 'Authorization required');
        const decoded = verifyToken(token);
        if (!decoded) return jsonErr(res, 403, 'Invalid token');
        return jsonOk(res, getUserChats(decoded.username));
    }

    if (req.method === 'POST' && url === '/api/chats') {
        try {
            const authHeader = req.headers['authorization'];
            const token = authHeader && authHeader.split(' ')[1];
            if (!token) return jsonErr(res, 401, 'Authorization required');
            const decoded = verifyToken(token);
            if (!decoded) return jsonErr(res, 403, 'Invalid token');
            const body = await parseBody(req);
            if (!body.chatId) return jsonErr(res, 400, 'chatId обязателен');
            upsertChat(body.chatId, decoded.username, body.title || 'Новый чат');
            return jsonOk(res, { ok: true });
        } catch(e) { return jsonErr(res, 400, e.message); }
    }

    if (req.method === 'DELETE' && url.startsWith('/api/chats/')) {
        const authHeader = req.headers['authorization'];
        const token = authHeader && authHeader.split(' ')[1];
        if (!token) return jsonErr(res, 401, 'Authorization required');
        const decoded = verifyToken(token);
        if (!decoded) return jsonErr(res, 403, 'Invalid token');
        const chatId = url.slice('/api/chats/'.length);
        if (!chatId) return jsonErr(res, 400, 'chatId required');
        // Verify ownership before deleting
        const chats = getUserChats(decoded.username);
        if (!chats.find(c => c.id === chatId)) return jsonErr(res, 403, 'Access denied');
        deleteChat(chatId);
        return jsonOk(res, { ok: true });
    }

    /* Messages */
    if (req.method === 'GET' && url.startsWith('/api/messages/')) {
        const authHeader = req.headers['authorization'];
        const token = authHeader && authHeader.split(' ')[1];
        if (!token) return jsonErr(res, 401, 'Authorization required');
        const decoded = verifyToken(token);
        if (!decoded) return jsonErr(res, 403, 'Invalid token');
        const chatId = url.slice('/api/messages/'.length);
        // Verify ownership
        const chats = getUserChats(decoded.username);
        if (!chats.find(c => c.id === chatId)) return jsonErr(res, 403, 'Access denied');
        return jsonOk(res, getChatMessages(chatId));
    }

    if (req.method === 'POST' && url === '/api/messages') {
        try {
            const authHeader = req.headers['authorization'];
            const token = authHeader && authHeader.split(' ')[1];
            if (!token) return jsonErr(res, 401, 'Authorization required');
            const decoded = verifyToken(token);
            if (!decoded) return jsonErr(res, 403, 'Invalid token');
            const body = await parseBody(req);
            if (!body.chatId || !body.role || !body.content) return jsonErr(res, 400, 'chatId, role, content обязательны');
            // Verify ownership
            const chats = getUserChats(decoded.username);
            if (!chats.find(c => c.id === body.chatId)) return jsonErr(res, 403, 'Access denied');
            addMessage(body.chatId, body.role, body.content);
            if (body.role === 'assistant') incUserMsgs(decoded.username);
            return jsonOk(res, { ok: true });
        } catch(e) { return jsonErr(res, 400, e.message); }
    }

    /* Memory API */
    if (req.method === 'GET' && url === '/api/memory') {
        const authHeader = req.headers['authorization'];
        const token = authHeader && authHeader.split(' ')[1];
        if (!token) return jsonErr(res, 401, 'Authorization required');
        const decoded = verifyToken(token);
        if (!decoded) return jsonErr(res, 403, 'Invalid token');
        const category = new URLSearchParams(req.url.split('?')[1] || '').get('category');
        return jsonOk(res, { memory: getAllMemory(decoded.username, category) });
    }

    if (req.method === 'POST' && url === '/api/memory') {
        try {
            const authHeader = req.headers['authorization'];
            const token = authHeader && authHeader.split(' ')[1];
            if (!token) return jsonErr(res, 401, 'Authorization required');
            const decoded = verifyToken(token);
            if (!decoded) return jsonErr(res, 403, 'Invalid token');
            const body = await parseBody(req);
            if (!body.key || !body.value) return jsonErr(res, 400, 'key, value required');
            const saved = setMemory(decoded.username, body.key, body.value, body.category);
            return jsonOk(res, { ok: saved, key: body.key });
        } catch(e) { return jsonErr(res, 400, e.message); }
    }

    if (req.method === 'DELETE' && url.startsWith('/api/memory/')) {
        const authHeader = req.headers['authorization'];
        const token = authHeader && authHeader.split(' ')[1];
        if (!token) return jsonErr(res, 401, 'Authorization required');
        const decoded = verifyToken(token);
        if (!decoded) return jsonErr(res, 403, 'Invalid token');
        const key = decodeURIComponent(url.slice('/api/memory/'.length));
        if (!key) return jsonErr(res, 400, 'key required');
        deleteMemory(decoded.username, key);
        return jsonOk(res, { ok: true });
    }

    /* Web Search API */
    if (req.method === 'POST' && url === '/api/search') {
        try {
            const authHeader = req.headers['authorization'];
            const token = authHeader && authHeader.split(' ')[1];
            if (!token) return jsonErr(res, 401, 'Authorization required');
            const decoded = verifyToken(token);
            if (!decoded) return jsonErr(res, 403, 'Invalid token');
            const body = await parseBody(req);
            if (!body.query) return jsonErr(res, 400, 'query required');
            const results = await webSearch(body.query, body.max_results || 5);
            return jsonOk(res, results);
        } catch(e) { return jsonErr(res, 500, e.message); }
    }

    /* Tools API */
    if (req.method === 'POST' && url === '/api/tool') {
        try {
            const authHeader = req.headers['authorization'];
            const token = authHeader && authHeader.split(' ')[1];
            if (!token) return jsonErr(res, 401, 'Authorization required');
            const decoded = verifyToken(token);
            if (!decoded) return jsonErr(res, 403, 'Invalid token');
            const body = await parseBody(req);
            if (!body.tool) return jsonErr(res, 400, 'tool required');
            const result = await executeTool(body.tool, body.arguments || {}, decoded.username);
            return jsonOk(res, result);
        } catch(e) { return jsonErr(res, 500, e.message); }
    }

    if (req.method === 'GET' && url === '/api/tools') {
        return jsonOk(res, { tools: TOOLS });
    }

    /* Ollama stream with tool support */
    if (req.method === 'POST' && url === '/chat') {
        const authHeader = req.headers['authorization'];
        const token = authHeader && authHeader.split(' ')[1];
        if (!token) {
            res.writeHead(401, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Authorization required' }));
            return;
        }
        const decoded = verifyToken(token);
        if (!decoded) {
            res.writeHead(403, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Invalid token' }));
            return;
        }
        var body = '';
        req.on('data', function(chunk) { body += chunk; });
        req.on('end', function() {
            var data;
            try { data = JSON.parse(body); }
            catch(e) { res.writeHead(400); res.end('Bad JSON'); return; }
            
            var messages = data.messages || [];
            var username = decoded.username;
            var enableTools = data.tools !== false;
            
            // Add tools info to system message if enabled
            if (enableTools) {
                var hasSystem = messages.some(function(m) { return m.role === 'system'; });
                var toolsPrompt = formatToolsForPrompt();
                if (hasSystem) {
                    messages = messages.map(function(m) {
                        if (m.role === 'system') {
                            return { role: 'system', content: m.content + toolsPrompt };
                        }
                        return m;
                    });
                } else {
                    messages.unshift({ role: 'system', content: 'You are a helpful AI assistant.' + toolsPrompt });
                }
            }

            var payload = JSON.stringify({ model: MODEL, messages: messages, stream: true });
            var options = {
                hostname: 'localhost', port: 11434, path: '/api/chat', method: 'POST',
                headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) }
            };

            res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'Connection': 'keep-alive' });

            var ollamaReq = http.request(options, function(ollamaRes) {
                ollamaRes.on('data', function(chunk) {
                    var lines = chunk.toString().split('\n').filter(Boolean);
                    lines.forEach(function(line) {
                        try {
                            var json = JSON.parse(line);
                            var text = (json && json.message && json.message.content) || '';
                            if (text) res.write('data: ' + JSON.stringify({ text: text }) + '\n\n');
                            if (json.done) res.write('data: [DONE]\n\n');
                        } catch(e) {}
                    });
                });
                ollamaRes.on('end', function() { res.end(); });
            });

            ollamaReq.on('error', function(err) {
                res.write('data: ' + JSON.stringify({ error: 'Ollama error: ' + err.message }) + '\n\n');
                res.end();
            });

            ollamaReq.write(payload);
            ollamaReq.end();
        });
        return;
    }

    res.writeHead(404);
    res.end('Not found');
});

initDB();
server.listen(PORT, '0.0.0.0', function() {
    console.log('\nAI-CICADA Web Chat v5.1 - With JWT Auth, Tools, Memory & Web Search');
    console.log('Model  : ' + MODEL);
    console.log('DB     : ' + (db ? DB_PATH : 'in-memory (fallback)'));
    console.log('Auth   : JWT enabled (' + (jwt ? 'jsonwebtoken' : 'fallback') + ')');
    console.log('Tools  : ' + Object.keys(TOOLS).join(', '));
    console.log('Open   : http://localhost:' + PORT);
    console.log('\nPress Ctrl+C to stop\n');
});
"""

with open(path, 'w') as f:
    f.write(code.lstrip('\n'))

print("server.js written OK")
PYEOF
}

create_index_html() {
    printf "${BLUE}Creating index.html...${NC}\n"
    python3 - "$CHAT_DIR/index.html" << 'PYEOF'
import sys
path = sys.argv[1]

html = r"""<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>AI-CICADA</title>
<link href="https://fonts.googleapis.com/css2?family=Unbounded:wght@400;700;900&family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#070708;--bg2:#0e0e10;--bg3:#161618;
  --border:rgba(255,255,255,0.06);--border2:rgba(255,255,255,0.12);
  --accent:#c8ff00;--accent2:#00e5ff;--accent3:#ff3cac;
  --text:#f0f0f0;--text2:#888;--text3:#555;
  --user-bg:#1a1f0a;--ai-bg:#0a0f1a;
  --r:16px;--r2:24px;
  --font-head:'Unbounded',sans-serif;--font-mono:'IBM Plex Mono',monospace;
  --glow:0 0 30px rgba(200,255,0,0.15);
}
html,body{height:100%;background:var(--bg);color:var(--text);font-family:var(--font-mono);font-size:14px;overflow:hidden}
body::before{content:'';position:fixed;inset:0;z-index:0;background-image:linear-gradient(rgba(200,255,0,0.025) 1px,transparent 1px),linear-gradient(90deg,rgba(200,255,0,0.025) 1px,transparent 1px);background-size:40px 40px;pointer-events:none}
body::after{content:'';position:fixed;width:600px;height:600px;border-radius:50%;background:radial-gradient(circle,rgba(200,255,0,0.06) 0%,transparent 70%);top:-200px;right:-200px;pointer-events:none;z-index:0}
.page{position:fixed;inset:0;z-index:10;display:flex;align-items:center;justify-content:center;padding:20px;transition:opacity .3s,transform .3s}
.page.hidden{opacity:0;pointer-events:none;transform:translateY(10px)}
.card{width:100%;max-width:420px;background:var(--bg2);border:1px solid var(--border2);border-radius:var(--r2);padding:36px 28px;box-shadow:0 40px 80px rgba(0,0,0,0.6),var(--glow);position:relative;overflow:hidden}
.card::before{content:'';position:absolute;top:0;left:0;right:0;height:2px;background:linear-gradient(90deg,var(--accent3),var(--accent),var(--accent2))}
.card-logo{display:flex;align-items:center;gap:12px;margin-bottom:28px}
.card-logo-icon{width:44px;height:44px;border-radius:12px;background:linear-gradient(135deg,var(--accent),var(--accent2));display:flex;align-items:center;justify-content:center;font-size:20px;flex-shrink:0}
.card-logo-name{font-family:var(--font-head);font-size:15px;font-weight:900;color:var(--accent);letter-spacing:2px}
.card-logo-sub{font-size:11px;color:var(--text2);margin-top:2px}
.card h2{font-family:var(--font-head);font-size:20px;font-weight:700;margin-bottom:6px;letter-spacing:1px}
.card p{color:var(--text2);font-size:13px;margin-bottom:24px;line-height:1.5}
.field{margin-bottom:14px}
.field label{display:block;font-size:11px;color:var(--text2);letter-spacing:1px;text-transform:uppercase;margin-bottom:6px}
.field input{width:100%;background:var(--bg3);border:1px solid var(--border2);border-radius:var(--r);color:var(--text);font-family:var(--font-mono);font-size:14px;padding:12px 14px;outline:none;transition:border-color .2s,box-shadow .2s}
.field input:focus{border-color:var(--accent);box-shadow:0 0 0 3px rgba(200,255,0,0.1)}
.field input::placeholder{color:var(--text3)}
.btn{width:100%;padding:14px;border:none;border-radius:var(--r);font-family:var(--font-head);font-size:13px;font-weight:700;letter-spacing:1px;cursor:pointer;transition:all .2s;margin-top:4px}
.btn-primary{background:linear-gradient(135deg,var(--accent),#aadd00);color:#000;box-shadow:0 4px 20px rgba(200,255,0,0.3)}
.btn-primary:hover{transform:translateY(-1px);box-shadow:0 8px 30px rgba(200,255,0,0.4)}
.btn-ghost{background:transparent;border:1px solid var(--border2);color:var(--text2);margin-top:10px}
.btn-ghost:hover{border-color:var(--accent2);color:var(--accent2)}
.error-msg{background:rgba(255,60,172,0.1);border:1px solid rgba(255,60,172,0.3);border-radius:8px;color:var(--accent3);padding:10px 12px;font-size:12px;margin-bottom:14px;display:none}
.error-msg.show{display:block}
#chatPage{flex-direction:column;padding:0;align-items:stretch;justify-content:flex-start}
.app-layout{display:flex;height:100dvh;width:100%}
.sidebar{width:260px;flex-shrink:0;background:var(--bg2);border-right:1px solid var(--border);display:flex;flex-direction:column;transition:transform .3s;z-index:100}
.sidebar-header{padding:16px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:10px;flex-shrink:0}
.sidebar-logo-icon{width:34px;height:34px;border-radius:9px;background:linear-gradient(135deg,var(--accent),var(--accent2));display:flex;align-items:center;justify-content:center;font-size:16px;flex-shrink:0}
.sidebar-logo-name{font-family:var(--font-head);font-size:12px;font-weight:900;color:var(--accent);letter-spacing:2px}
.sidebar-logo-sub{font-size:10px;color:var(--text2)}
.btn-new-chat{margin:12px;padding:10px 14px;background:rgba(200,255,0,0.08);border:1px solid rgba(200,255,0,0.2);border-radius:10px;color:var(--accent);font-family:var(--font-head);font-size:11px;font-weight:700;letter-spacing:1px;cursor:pointer;display:flex;align-items:center;gap:8px;transition:all .2s;flex-shrink:0}
.btn-new-chat:hover{background:rgba(200,255,0,0.15)}
.sidebar-section-title{padding:8px 16px 4px;font-size:10px;color:var(--text3);text-transform:uppercase;letter-spacing:1.5px;flex-shrink:0}
.history-list{flex:1;overflow-y:auto;padding:4px 8px}
.history-list::-webkit-scrollbar{width:3px}
.history-list::-webkit-scrollbar-thumb{background:var(--border2);border-radius:2px}
.history-item{padding:9px 10px;border-radius:8px;cursor:pointer;display:flex;align-items:center;gap:8px;transition:background .15s;margin-bottom:2px}
.history-item:hover{background:var(--bg3)}
.history-item.active{background:rgba(200,255,0,0.08)}
.history-item-icon{font-size:13px;flex-shrink:0;opacity:.6}
.history-item-text{font-size:12px;color:var(--text2);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1}
.history-item.active .history-item-text{color:var(--accent)}
.history-item-del{font-size:11px;color:var(--text3);opacity:0;cursor:pointer;flex-shrink:0;padding:2px 4px;border-radius:4px;transition:opacity .15s,color .15s}
.history-item:hover .history-item-del{opacity:1}
.history-item-del:hover{color:var(--accent3)!important;opacity:1!important}
.history-empty{padding:20px 16px;text-align:center;color:var(--text3);font-size:12px;line-height:1.6}
.sidebar-profile{padding:12px 16px;border-top:1px solid var(--border);display:flex;align-items:center;gap:10px;flex-shrink:0}
.profile-avatar{width:32px;height:32px;border-radius:50%;background:linear-gradient(135deg,var(--accent3),var(--accent));display:flex;align-items:center;justify-content:center;font-size:14px;flex-shrink:0;color:#000;font-weight:700;font-family:var(--font-head)}
.profile-info{flex:1;min-width:0}
.profile-name{font-size:12px;font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.profile-role{font-size:10px;color:var(--text2)}
.btn-logout{background:none;border:none;color:var(--text3);font-size:16px;cursor:pointer;padding:4px;border-radius:6px;transition:color .2s;flex-shrink:0}
.btn-logout:hover{color:var(--accent3)}
.chat-area{flex:1;display:flex;flex-direction:column;min-width:0;position:relative}
.topbar{display:flex;align-items:center;gap:10px;padding:10px 16px;border-bottom:1px solid var(--border);background:var(--bg2);flex-shrink:0}
.btn-menu{display:none;background:none;border:none;color:var(--text2);font-size:20px;cursor:pointer;padding:4px;flex-shrink:0}
.topbar-title{flex:1;font-family:var(--font-head);font-size:13px;font-weight:700;color:var(--text);letter-spacing:1px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.model-badge{background:var(--bg3);border:1px solid var(--border2);border-radius:20px;padding:4px 10px;font-size:11px;color:var(--accent2);white-space:nowrap;flex-shrink:0}
.status-indicator{width:8px;height:8px;border-radius:50%;background:var(--text3);flex-shrink:0;transition:background .3s}
.status-indicator.online{background:var(--accent);box-shadow:0 0 8px var(--accent)}
.status-indicator.loading{background:var(--accent2);animation:blink 1s infinite}
@keyframes blink{0%,100%{opacity:1}50%{opacity:.2}}
#messages{flex:1;overflow-y:auto;padding:20px 16px;display:flex;flex-direction:column;gap:16px;scroll-behavior:smooth}
#messages::-webkit-scrollbar{width:4px}
#messages::-webkit-scrollbar-thumb{background:var(--border);border-radius:2px}
.welcome{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:40px 20px;gap:14px}
.welcome-cicada{font-size:56px;filter:drop-shadow(0 0 20px rgba(200,255,0,0.4));animation:float 3s ease-in-out infinite}
@keyframes float{0%,100%{transform:translateY(0)}50%{transform:translateY(-8px)}}
.welcome h1{font-family:var(--font-head);font-size:22px;font-weight:900;background:linear-gradient(135deg,var(--accent),var(--accent2));-webkit-background-clip:text;-webkit-text-fill-color:transparent;letter-spacing:2px}
.welcome p{color:var(--text2);font-size:13px;line-height:1.7;max-width:300px}
.welcome-chips{display:flex;flex-wrap:wrap;gap:8px;justify-content:center;margin-top:8px}
.chip{background:var(--bg3);border:1px solid var(--border2);border-radius:20px;padding:7px 14px;font-size:12px;color:var(--text2);cursor:pointer;transition:all .2s}
.chip:hover{border-color:var(--accent);color:var(--accent);background:rgba(200,255,0,0.05)}
.msg{display:flex;gap:10px;animation:msgIn .2s ease}
@keyframes msgIn{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}
.msg.user{flex-direction:row-reverse}
.avatar{width:30px;height:30px;border-radius:9px;flex-shrink:0;margin-top:2px;display:flex;align-items:center;justify-content:center;font-size:14px;font-weight:700;font-family:var(--font-head)}
.msg.user .avatar{background:linear-gradient(135deg,var(--accent3),var(--accent));color:#000;font-size:12px}
.msg.ai .avatar{background:linear-gradient(135deg,#0a1a3a,#0a1a2a);border:1px solid rgba(0,229,255,0.3);font-size:15px}
.bubble{max-width:min(80%,520px);padding:11px 15px;border-radius:var(--r);line-height:1.65;word-break:break-word;font-size:13.5px}
.msg.user .bubble{background:var(--user-bg);border:1px solid rgba(200,255,0,0.15);border-bottom-right-radius:4px;color:#d8ffaa}
.msg.ai .bubble{background:var(--ai-bg);border:1px solid rgba(0,229,255,0.1);border-bottom-left-radius:4px}
.bubble code{background:rgba(0,229,255,0.08);border:1px solid rgba(0,229,255,0.15);border-radius:4px;padding:2px 5px;font-size:12px;color:var(--accent2)}
.bubble pre{background:#05080f;border:1px solid rgba(0,229,255,0.12);border-radius:10px;padding:12px 14px;overflow-x:auto;margin:8px 0;font-size:12px;line-height:1.5;position:relative}
.bubble pre code{background:none;border:none;padding:0;color:#8ecfff}
.copy-btn{position:absolute;top:8px;right:8px;background:var(--bg3);border:1px solid var(--border2);border-radius:5px;padding:3px 8px;font-size:10px;color:var(--text2);cursor:pointer;font-family:var(--font-mono);transition:all .15s}
.copy-btn:hover{color:var(--accent);border-color:var(--accent)}
.typing-bubble{background:var(--ai-bg);border:1px solid rgba(0,229,255,0.1);border-radius:var(--r);border-bottom-left-radius:4px;padding:14px 18px;display:flex;gap:5px;align-items:center}
.typing-bubble span{width:6px;height:6px;background:var(--accent2);border-radius:50%;animation:dot 1.2s infinite}
.typing-bubble span:nth-child(2){animation-delay:.2s}
.typing-bubble span:nth-child(3){animation-delay:.4s}
@keyframes dot{0%,80%,100%{opacity:.2;transform:scale(.8)}40%{opacity:1;transform:scale(1)}}
.typing-wrap{display:flex;gap:10px}
.input-area{padding:12px 16px;border-top:1px solid var(--border);background:var(--bg2);flex-shrink:0}
.input-wrap{display:flex;align-items:flex-end;gap:10px;background:var(--bg3);border:1px solid var(--border2);border-radius:14px;padding:10px 10px 10px 16px;transition:border-color .2s}
.input-wrap:focus-within{border-color:rgba(200,255,0,0.3)}
#input{flex:1;background:none;border:none;color:var(--text);font-family:var(--font-mono);font-size:14px;resize:none;outline:none;max-height:120px;line-height:1.5}
#input::placeholder{color:var(--text3)}
#sendBtn{width:36px;height:36px;border-radius:10px;border:none;background:var(--accent);color:#000;font-size:16px;cursor:pointer;display:flex;align-items:center;justify-content:center;flex-shrink:0;transition:all .2s}
#sendBtn:hover{background:#aadd00;transform:scale(1.05)}
#sendBtn:disabled{background:var(--bg);color:var(--text3);cursor:not-allowed;transform:none}
.sidebar-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.5);z-index:99}
.sidebar-overlay.show{display:block}
#profilePage{flex-direction:column;padding:0;align-items:stretch;justify-content:flex-start}
.profile-page{max-width:520px;width:100%;margin:0 auto;padding:30px 20px;overflow-y:auto;height:100dvh}
.profile-header{display:flex;align-items:center;gap:16px;margin-bottom:28px}
.profile-big-avatar{width:64px;height:64px;border-radius:20px;background:linear-gradient(135deg,var(--accent3),var(--accent));display:flex;align-items:center;justify-content:center;font-size:28px;color:#000;font-family:var(--font-head);font-weight:900}
.profile-big-name{font-family:var(--font-head);font-size:20px;font-weight:700}
.profile-big-sub{font-size:12px;color:var(--text2);margin-top:3px}
.stats-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:24px}
.stat-card{background:var(--bg2);border:1px solid var(--border);border-radius:14px;padding:16px 12px;text-align:center}
.stat-value{font-family:var(--font-head);font-size:22px;font-weight:900;color:var(--accent)}
.stat-label{font-size:10px;color:var(--text3);margin-top:3px;text-transform:uppercase;letter-spacing:1px}
.info-section{background:var(--bg2);border:1px solid var(--border);border-radius:16px;overflow:hidden;margin-bottom:16px}
.info-row{display:flex;align-items:center;gap:14px;padding:14px 16px;border-bottom:1px solid var(--border)}
.info-row:last-child{border-bottom:none}
.info-row-icon{font-size:18px;flex-shrink:0}
.info-row-label{font-size:10px;color:var(--text3);text-transform:uppercase;letter-spacing:1px}
.info-row-value{font-size:13px;color:var(--text);margin-top:1px}
.info-row-content{flex:1}
.btn-back{display:block;width:100%;padding:14px;background:var(--bg2);border:1px solid var(--border2);border-radius:var(--r);font-family:var(--font-head);font-size:12px;color:var(--text2);cursor:pointer;transition:all .2s;text-align:center;letter-spacing:1px}
.btn-back:hover{border-color:var(--accent);color:var(--accent)}
.db-badge{display:inline-flex;align-items:center;gap:5px;font-size:10px;color:var(--accent2);background:rgba(0,229,255,0.08);border:1px solid rgba(0,229,255,0.2);border-radius:20px;padding:3px 10px;margin-top:6px}
@media(max-width:600px){.sidebar{position:fixed;top:0;left:0;height:100%;transform:translateX(-100%)}.sidebar.open{transform:translateX(0)}.btn-menu{display:block}}
</style>
</head>
<body>

<div class="page" id="loginPage">
  <div class="card">
    <div class="card-logo">
      <div class="card-logo-icon">&#129432;</div>
      <div><div class="card-logo-name">AI-CICADA</div><div class="card-logo-sub">SQLite + JWT</div></div>
    </div>
    <h2>Вход</h2>
    <p>Войдите в аккаунт для начала работы</p>
    <div id="loginError" class="error-msg"></div>
    <div class="field"><label>Логин</label><input id="loginUser" type="text" placeholder="username"></div>
    <div class="field"><label>Пароль</label><input id="loginPass" type="password" placeholder="&#9679;&#9679;&#9679;&#9679;&#9679;&#9679;"></div>
    <button class="btn btn-primary" onclick="login()">Войти</button>
    <button class="btn btn-ghost" onclick="showPage('registerPage')">Нет аккаунта? Зарегистрироваться</button>
  </div>
</div>

<div class="page hidden" id="registerPage">
  <div class="card">
    <div class="card-logo">
      <div class="card-logo-icon">&#129432;</div>
      <div><div class="card-logo-name">AI-CICADA</div><div class="card-logo-sub">Регистрация</div></div>
    </div>
    <h2>Регистрация</h2>
    <p>Данные хранятся локально в SQLite. Защищено JWT.</p>
    <div id="regError" class="error-msg"></div>
    <div class="field"><label>Логин</label><input id="regUser" type="text" placeholder="username"></div>
    <div class="field"><label>Пароль</label><input id="regPass" type="password" placeholder="минимум 4 символа"></div>
    <div class="field"><label>Повтор пароля</label><input id="regPass2" type="password" placeholder="повторите пароль"></div>
    <button class="btn btn-primary" onclick="register()">Создать аккаунт</button>
    <button class="btn btn-ghost" onclick="showPage('loginPage')">Уже есть аккаунт? Войти</button>
  </div>
</div>

<div class="page hidden" id="chatPage">
  <div class="app-layout">
    <div class="sidebar" id="sidebar">
      <div class="sidebar-header">
        <div class="sidebar-logo-icon">&#129432;</div>
        <div><div class="sidebar-logo-name">AI-CICADA</div><div class="sidebar-logo-sub">JWT Auth</div></div>
      </div>
      <button class="btn-new-chat" onclick="newChat()">+ Новый чат</button>
      <div class="sidebar-section-title">История</div>
      <div class="history-list" id="historyList"></div>
      <div class="sidebar-profile">
        <div class="profile-avatar" id="sidebarAvatar">?</div>
        <div class="profile-info">
          <div class="profile-name" id="sidebarName">—</div>
          <div class="profile-role">JWT + SQLite</div>
        </div>
        <button class="btn-logout" onclick="showProfilePage()" title="Профиль">&#128100;</button>
        <button class="btn-logout" onclick="logout()" title="Выйти">&#x21E5;</button>
      </div>
    </div>
    <div class="sidebar-overlay" id="sidebarOverlay" onclick="closeSidebar()"></div>
    <div class="chat-area">
      <div class="topbar">
        <button class="btn-menu" onclick="openSidebar()">&#9776;</button>
        <div class="topbar-title" id="chatTitle">AI-CICADA</div>
        <div class="model-badge" id="modelBadge">загрузка...</div>
        <div class="status-indicator" id="statusDot"></div>
      </div>
      <div id="messages"></div>
      <div class="input-area">
        <div class="input-wrap">
          <textarea id="input" rows="1" placeholder="Спросите что угодно..."></textarea>
          <button id="sendBtn" onclick="send()">&#10148;</button>
        </div>
      </div>
    </div>
  </div>
</div>

<div class="page hidden" id="profilePage">
  <div class="profile-page">
    <div class="profile-header">
      <div class="profile-big-avatar" id="profileAvatar">?</div>
      <div>
        <div class="profile-big-name" id="profileName">—</div>
        <div class="profile-big-sub" id="profileSub">JWT защита</div>
        <div class="db-badge">&#128190; SQLite + JWT</div>
      </div>
    </div>
    <div class="stats-grid">
      <div class="stat-card"><div class="stat-value" id="statChats">0</div><div class="stat-label">Чатов</div></div>
      <div class="stat-card"><div class="stat-value" id="statMsgs">0</div><div class="stat-label">Сообщений</div></div>
      <div class="stat-card"><div class="stat-value" id="statDays">0</div><div class="stat-label">Дней</div></div>
    </div>
    <div class="info-section">
      <div class="info-row"><div class="info-row-icon">&#128100;</div><div class="info-row-content"><div class="info-row-label">Пользователь</div><div class="info-row-value" id="infoUser">—</div></div></div>
      <div class="info-row"><div class="info-row-icon">&#129302;</div><div class="info-row-content"><div class="info-row-label">Модель</div><div class="info-row-value" id="infoModel">—</div></div></div>
      <div class="info-row"><div class="info-row-icon">&#128197;</div><div class="info-row-content"><div class="info-row-label">Регистрация</div><div class="info-row-value" id="infoDate">—</div></div></div>
      <div class="info-row"><div class="info-row-icon">&#128190;</div><div class="info-row-content"><div class="info-row-label">Хранилище</div><div class="info-row-value">SQLite + JWT Auth</div></div></div>
    </div>
    <div class="info-section">
      <div class="info-row" style="cursor:pointer" onclick="clearAllHistory()"><div class="info-row-icon">&#128465;</div><div class="info-row-content"><div class="info-row-label">ДЕЙСТВИЕ</div><div class="info-row-value" style="color:var(--accent2)">Очистить историю чатов</div></div></div>
      <div class="info-row" style="cursor:pointer" onclick="deleteAccount()"><div class="info-row-icon">&#9888;</div><div class="info-row-content"><div class="info-row-label">ДЕЙСТВИЕ</div><div class="info-row-value" style="color:var(--accent3)">Удалить аккаунт</div></div></div>
    </div>
    <button class="btn-back" onclick="showPage('chatPage')">&larr; Вернуться к чату</button>
  </div>
</div>

<script>
var currentUser  = null;
var currentModel = '';
var currentChatId = null;
var chatHistory   = [];
var generating    = false;

var API = {
    _token: function() { return Session.getToken(); },
    _headers: function() {
        var h = { 'Content-Type': 'application/json' };
        var t = API._token();
        if (t) h['Authorization'] = 'Bearer ' + t;
        return h;
    },
    _post: function(url, data) {
        return fetch(url, { method:'POST', headers: API._headers(), body: JSON.stringify(data) }).then(function(r){ return r.json(); });
    },
    _get: function(url) {
        return fetch(url, { headers: { 'Authorization': 'Bearer ' + (API._token() || '') } }).then(function(r){ return r.json(); });
    },
    _del: function(url) {
        return fetch(url, { method:'DELETE', headers: { 'Authorization': 'Bearer ' + (API._token() || '') } }).then(function(r){ return r.json(); });
    },
    register: function(u,p)    { return API._post('/api/register', { username:u, password:p }); },
    login:    function(u,p)    { return API._post('/api/login',    { username:u, password:p }); },
    stats:    function()      { return API._get('/api/stats'); },
    getChats: function()      { return API._get('/api/chats'); },
    upsertChat: function(id,t){ return API._post('/api/chats', { chatId:id, title:t }); },
    deleteChat: function(id)   { return API._del('/api/chats/' + encodeURIComponent(id)); },
    getMsgs:  function(id)     { return API._get('/api/messages/' + encodeURIComponent(id)); },
    addMsg:   function(id,r,c){ return API._post('/api/messages', { chatId:id, role:r, content:c }); }
};

var Session = {
    get:   function() { return sessionStorage.getItem('ac_user'); },
    set:   function(u){ sessionStorage.setItem('ac_user', u); },
    clear: function() { sessionStorage.removeItem('ac_user'); sessionStorage.removeItem('ac_token'); },
    getToken: function() { return sessionStorage.getItem('ac_token'); },
    setToken: function(t){ sessionStorage.setItem('ac_token', t); }
};

function showPage(id) {
    document.querySelectorAll('.page').forEach(function(p){ p.classList.add('hidden'); });
    document.getElementById(id).classList.remove('hidden');
}

function showError(id, msg) {
    var el = document.getElementById(id);
    el.textContent = msg; el.classList.add('show');
    setTimeout(function(){ el.classList.remove('show'); }, 3000);
}

function login() {
    var u = document.getElementById('loginUser').value.trim();
    var p = document.getElementById('loginPass').value;
    if (!u || !p) return showError('loginError', 'Заполните все поля');
    API.login(u, p).then(function(res) {
        if (res.error) return showError('loginError', res.error);
        if (!res.token) return showError('loginError', 'Auth error: no token');
        currentUser = res;
        Session.set(u);
        Session.setToken(res.token);
        enterChat();
    });
}

function register() {
    var u  = document.getElementById('regUser').value.trim();
    var p  = document.getElementById('regPass').value;
    var p2 = document.getElementById('regPass2').value;
    if (!u || !p || !p2) return showError('regError', 'Заполните все поля');
    if (p !== p2) return showError('regError', 'Пароли не совпадают');
    API.register(u, p).then(function(res) {
        if (res.error) return showError('regError', res.error);
        API.login(u, p).then(function(r2) {
            if (r2.error) return showPage('loginPage');
            if (!r2.token) return showError('regError', 'Auth error: no token');
            currentUser = r2; Session.set(u); Session.setToken(r2.token); enterChat();
        });
    });
}

function logout() {
    Session.clear(); currentUser = null; currentChatId = null; chatHistory = [];
    document.getElementById('loginUser').value = '';
    document.getElementById('loginPass').value = '';
    showPage('loginPage');
}

function enterChat() {
    updateSidebarProfile();
    renderHistoryList();
    newChat();
    showPage('chatPage');
    fetch('/model').then(function(r){ return r.json(); }).then(function(d){
        currentModel = d.model;
        document.getElementById('modelBadge').textContent = d.model;
        document.getElementById('statusDot').className = 'status-indicator online';
    }).catch(function(){
        document.getElementById('modelBadge').textContent = 'Офлайн';
    });
}

function updateSidebarProfile() {
    if (!currentUser) return;
    document.getElementById('sidebarAvatar').textContent = currentUser.username[0].toUpperCase();
    document.getElementById('sidebarName').textContent   = currentUser.username;
}

function newChat() {
    currentChatId = 'chat_' + Date.now();
    chatHistory = [];
    resetMessages();
    document.getElementById('chatTitle').textContent = 'Новый чат';
    renderHistoryList();
}

function resetMessages() {
    var m = document.getElementById('messages');
    m.innerHTML = '<div class="welcome" id="welcomeBlock">' +
        '<div class="welcome-cicada">&#129432;</div>' +
        '<h1>AI-CICADA</h1>' +
        '<p>Локальный ИИ работает прямо на вашем устройстве.</p>' +
        '<div class="welcome-chips">' +
        '<div class="chip" onclick="useChip(this)">Напиши скрипт на Python</div>' +
        '<div class="chip" onclick="useChip(this)">Объясни как работает</div>' +
        '<div class="chip" onclick="useChip(this)">Найди ошибку в коде</div>' +
        '<div class="chip" onclick="useChip(this)">Помоги с задачей</div>' +
        '</div></div>';
}

function useChip(el) { document.getElementById('input').value = el.textContent; send(); }

function saveCurrentChat(firstMsg) {
    if (!currentUser) return;
    var title = firstMsg.slice(0, 40) + (firstMsg.length > 40 ? '...' : '');
    API.upsertChat(currentChatId, currentUser.username, title).then(function(){ renderHistoryList(); });
}

function loadChat(id) {
    API.getMsgs(id).then(function(msgs) {
        currentChatId = id;
        chatHistory = msgs.map(function(m){ return { role: m.role, content: m.content }; });
        resetMessages();
        var wb = document.getElementById('welcomeBlock');
        if (wb) wb.remove();
        API.getChats(currentUser.username).then(function(chats) {
            var chat = chats.find(function(c){ return c.id === id; });
            document.getElementById('chatTitle').textContent = chat ? chat.title : id;
        });
        msgs.forEach(function(m){ addMsg(m.role, m.content); });
        renderHistoryList();
        closeSidebar();
    });
}

function deleteChat(id, e) {
    e.stopPropagation();
    API.deleteChat(id).then(function() {
        if (currentChatId === id) newChat();
        else renderHistoryList();
    });
}

function renderHistoryList() {
    if (!currentUser) return;
    API.getChats(currentUser.username).then(function(chats) {
        var list = document.getElementById('historyList');
        if (!chats || !chats.length) {
            list.innerHTML = '<div class="history-empty">Нет сохранённых чатов.<br>Начните новый диалог!</div>';
            return;
        }
        list.innerHTML = chats.map(function(c) {
            return '<div class="history-item ' + (c.id === currentChatId ? 'active' : '') + '" onclick="loadChat(\'' + c.id + '\')">' +
                '<div class="history-item-icon">&#128172;</div>' +
                '<div class="history-item-text">' + escHtml(c.title) + '</div>' +
                '<div class="history-item-del" onclick="deleteChat(\'' + c.id + '\',event)">&#10005;</div>' +
                '</div>';
        }).join('');
    });
}

function send() {
    var text = document.getElementById('input').value.trim();
    if (!text || generating) return;
    generating = true;
    document.getElementById('sendBtn').disabled = true;
    document.getElementById('input').value = '';
    document.getElementById('input').style.height = 'auto';
    var wb = document.getElementById('welcomeBlock');
    if (wb) wb.remove();
    addMsg('user', text);
    chatHistory.push({ role: 'user', content: text });
    if (chatHistory.length === 1) {
        document.getElementById('chatTitle').textContent = text.slice(0, 30) + (text.length > 30 ? '...' : '');
        saveCurrentChat(text);
    }
    if (currentUser) API.addMsg(currentChatId, 'user', text);
    document.getElementById('statusDot').className = 'status-indicator loading';
    var typingEl = addTyping();
    var fullText = '';
    var aiBubble = null;
    fetch('/chat', { method:'POST', headers: API._headers(), body: JSON.stringify({ messages: chatHistory }) })
    .then(function(res) {
        var reader = res.body.getReader();
        var dec = new TextDecoder();
        function read() {
            return reader.read().then(function(x) {
                if (x.done) return;
                var lines = dec.decode(x.value).split('\n').filter(function(l){ return l.indexOf('data: ') === 0; });
                lines.forEach(function(line) {
                    var data = line.slice(6);
                    if (data === '[DONE]') return;
                    try {
                        var json = JSON.parse(data);
                        if (json.error) throw new Error(json.error);
                        if (json.text) {
                            fullText += json.text;
                            if (!aiBubble) { typingEl.remove(); aiBubble = addMsg('ai', ''); }
                            var bubble = aiBubble.querySelector('.bubble');
                            bubble.innerHTML = '';
                            bubble.appendChild(renderMd(fullText));
                            document.getElementById('messages').scrollTop = 999999;
                        }
                    } catch(e) {}
                });
                return read();
            });
        }
        return read();
    })
    .catch(function(err) { typingEl.remove(); addMsg('ai', 'Ошибка: ' + err.message); })
    .finally(function() {
        if (fullText && currentUser) {
            chatHistory.push({ role: 'assistant', content: fullText });
            API.addMsg(currentChatId, 'assistant', fullText, currentUser.username);
            saveCurrentChat(chatHistory[0] ? chatHistory[0].content : 'Чат');
        }
        generating = false;
        document.getElementById('sendBtn').disabled = false;
        document.getElementById('statusDot').className = 'status-indicator online';
        document.getElementById('input').focus();
    });
}

function addMsg(role, text) {
    var m = document.getElementById('messages');
    var div = document.createElement('div');
    div.className = 'msg ' + (role === 'user' ? 'user' : 'ai');
    var av = document.createElement('div');
    av.className = 'avatar';
    av.textContent = role === 'user' ? (currentUser ? currentUser.username[0].toUpperCase() : 'Я') : '\u{1F99F}';
    var bubble = document.createElement('div');
    bubble.className = 'bubble';
    if (text) bubble.appendChild(renderMd(text));
    div.appendChild(av); div.appendChild(bubble);
    m.appendChild(div); m.scrollTop = 999999;
    return div;
}

function addTyping() {
    var m = document.getElementById('messages');
    var div = document.createElement('div');
    div.className = 'typing-wrap';
    div.innerHTML = '<div class="avatar">&#129432;</div><div class="typing-bubble"><span></span><span></span><span></span></div>';
    m.appendChild(div); m.scrollTop = 999999;
    return div;
}

function renderMd(text) {
    var wrap = document.createElement('div');
    var BT = '\x60';
    var BT3 = BT+BT+BT;
    var parts = text.split(new RegExp('(' + BT3 + '[\\s\\S]*?' + BT3 + ')', 'g'));
    parts.forEach(function(part) {
        if (part.indexOf(BT3) === 0) {
            var code = part.replace(new RegExp('^' + BT3 + '\\w*\\n?'), '').replace(new RegExp(BT3 + '$'), '');
            var pre = document.createElement('pre');
            var btn = document.createElement('button');
            btn.className = 'copy-btn'; btn.textContent = 'копировать';
            btn.onclick = function() {
                navigator.clipboard.writeText(code);
                btn.textContent = 'скопировано';
                setTimeout(function(){ btn.textContent = 'копировать'; }, 2000);
            };
            var c = document.createElement('code'); c.textContent = code;
            pre.appendChild(btn); pre.appendChild(c); wrap.appendChild(pre);
        } else {
            var subs = part.split(new RegExp('(' + BT + '[^' + BT + ']+' + BT + ')', 'g'));
            subs.forEach(function(s) {
                if (s.charAt(0) === BT && s.charAt(s.length-1) === BT) {
                    var c = document.createElement('code'); c.textContent = s.slice(1,-1);
                    wrap.appendChild(c);
                } else {
                    wrap.appendChild(document.createTextNode(s));
                }
            });
        }
    });
    return wrap;
}

function escHtml(t) { return t.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

function showProfilePage() {
    if (!currentUser) return;
    API.stats(currentUser.username).then(function(stats) {
        document.getElementById('profileAvatar').textContent = currentUser.username[0].toUpperCase();
        document.getElementById('profileName').textContent   = currentUser.username;
        document.getElementById('profileSub').textContent    = 'AI-CICADA · SQLite';
        document.getElementById('infoUser').textContent      = currentUser.username;
        document.getElementById('infoModel').textContent     = currentModel || '—';
        var d = stats.created_at ? new Date(stats.created_at * 1000) : new Date();
        document.getElementById('infoDate').textContent = d.toLocaleDateString('ru-RU', {day:'numeric',month:'long',year:'numeric'});
        var days = Math.max(1, Math.floor((Date.now() - d.getTime()) / 86400000));
        document.getElementById('statChats').textContent = stats.chat_count || 0;
        document.getElementById('statMsgs').textContent  = stats.msg_count  || 0;
        document.getElementById('statDays').textContent  = days;
        showPage('profilePage');
        closeSidebar();
    });
}

function clearAllHistory() {
    if (!confirm('Удалить всю историю чатов?')) return;
    API.getChats(currentUser.username).then(function(chats) {
        var ps = chats.map(function(c){ return API.deleteChat(c.id); });
        Promise.all(ps).then(function(){ newChat(); showPage('chatPage'); });
    });
}

function deleteAccount() {
    if (!confirm('Удалить аккаунт и все данные? Нельзя отменить!')) return;
    API.getChats(currentUser.username).then(function(chats) {
        var ps = chats.map(function(c){ return API.deleteChat(c.id); });
        Promise.all(ps).then(function(){ logout(); });
    });
}

function openSidebar()  { document.getElementById('sidebar').classList.add('open'); document.getElementById('sidebarOverlay').classList.add('show'); }
function closeSidebar() { document.getElementById('sidebar').classList.remove('open'); document.getElementById('sidebarOverlay').classList.remove('show'); }

document.getElementById('input').addEventListener('input', function() {
    this.style.height = 'auto';
    this.style.height = Math.min(this.scrollHeight, 120) + 'px';
});
document.getElementById('input').addEventListener('keydown', function(e) {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); }
});

(function init() {
    var username = Session.get();
    var token = Session.getToken();
    if (username && token) {
        API.stats().then(function(stats) {
            if (!stats.error) {
                currentUser = Object.assign({ username: username }, stats);
                enterChat();
            } else {
                Session.clear();
                showPage('loginPage');
            }
        }).catch(function(){ Session.clear(); showPage('loginPage'); });
    } else {
        Session.clear();
        showPage('loginPage');
    }
})();
</script>
</body>
</html>"""

with open(path, 'w') as f:
    f.write(html.lstrip('\n'))

print("index.html written OK")
PYEOF
}

create_web_chat() {
    printf "${BLUE}Creating web chat files...${NC}\n"
    mkdir -p "$CHAT_DIR"
    # Backup existing files if they exist (idempotency)
    if [ -f "$CHAT_DIR/server.js" ]; then
        cp "$CHAT_DIR/server.js" "$CHAT_DIR/server.js.bak.$(date +%s)" 2>/dev/null || true
    fi
    if [ -f "$CHAT_DIR/index.html" ]; then
        cp "$CHAT_DIR/index.html" "$CHAT_DIR/index.html.bak.$(date +%s)" 2>/dev/null || true
    fi
    create_server_js
    create_index_html
    printf "${GREEN}Web chat created in %s${NC}\n" "$CHAT_DIR"
    log "Web chat created"
}

setup_alias() {
    printf "${BLUE}Setting up commands...${NC}\n"
    local SHELLRC="$HOME/.bashrc"
    if [ "$ENV_TYPE" = "homeassistant" ] || [ "$ENV_TYPE" = "alpine" ] || [ "$ENV_TYPE" = "wsl-ha" ]; then
        if [ -f "$HOME/.bashrc" ]; then SHELLRC="$HOME/.bashrc";
        else SHELLRC="$HOME/.profile"; fi
    fi
    if grep -q "# AI-CICADA" "$SHELLRC" 2>/dev/null; then
        sed -i '/# AI-CICADA/,/# END AI-CICADA/d' "$SHELLRC"
    fi
    cat >> "$SHELLRC" << ALIASEOF

# AI-CICADA
export AI_MODEL="$MODEL"
export AI_CICADA_DIR="$CHAT_DIR"

ai() {
    if ! pgrep -x "ollama" > /dev/null 2>&1; then
        printf "Starting Ollama...\n"
        ollama serve > /dev/null 2>&1 &
        sleep 3
    fi
    CLAUDE_CODE_USE_OPENAI=1 OPENAI_BASE_URL=http://localhost:11434/v1 OPENAI_MODEL=\$AI_MODEL openclaude
}

web() {
    if ! pgrep -x "ollama" > /dev/null 2>&1; then
        printf "Starting Ollama...\n"
        ollama serve > /dev/null 2>&1 &
        sleep 3
    fi
    # Check if port 3000 is in use
    if command -v lsof >/dev/null 2>&1 && lsof -Pi :3000 -sTCP:LISTEN -t >/dev/null 2>&1; then
        printf "Port 3000 busy, killing old process...\n"
        kill -9 \$(lsof -ti :3000) 2>/dev/null || true
        sleep 1
    elif command -v ss >/dev/null 2>&1 && ss -tuln 2>/dev/null | grep -q ":3000 "; then
        printf "Port 3000 busy, killing old process...\n"
        ss -tulpn 2>/dev/null | grep ":3000 " | grep -oP 'pid=\K[0-9]+' | xargs kill -9 2>/dev/null || true
        sleep 1
    fi
    # Cross-platform IP detection (works on WSL, Termux, HA, Linux)
    CHAT_IP=\$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if(\$i=="src"){print \$(i+1);exit}}' || hostname -I 2>/dev/null | awk '{print \$1}' || echo "localhost")
    printf "Web chat: http://\${CHAT_IP}:3000\n"
    AI_MODEL=\$AI_MODEL node \$AI_CICADA_DIR/server.js
}

aidb() {
    printf "DB: \$AI_CICADA_DIR/cicada.db\n"
    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "\$AI_CICADA_DIR/cicada.db" "SELECT username, total_msgs, datetime(created_at,'unixepoch') as reg FROM users;"
    fi
}

aicada() {
    case "\$1" in
        start)
            printf "Starting AI-CICADA...\n"
            if ! pgrep -x "ollama" > /dev/null 2>&1; then
                ollama serve > /dev/null 2>&1 &
                sleep 3
            fi
            if command -v lsof >/dev/null 2>&1 && lsof -Pi :3000 -sTCP:LISTEN -t >/dev/null 2>&1; then
                kill -9 \$(lsof -ti :3000) 2>/dev/null || true
                sleep 1
            fi
            CHAT_IP=\$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if(\$i=="src"){print \$(i+1);exit}}' || hostname -I 2>/dev/null | awk '{print \$1}' || echo "localhost")
            printf "Web: http://\${CHAT_IP}:3000\n"
            AI_MODEL=\$AI_MODEL node \$AI_CICADA_DIR/server.js
            ;;
        stop)
            printf "Stopping AI-CICADA...\n"
            pkill -f "node.*server.js" 2>/dev/null || true
            pkill -f "llama-server" 2>/dev/null || true
            kill -9 \$(lsof -ti :3000) 2>/dev/null || true
            printf "Stopped\n"
            ;;
        restart)
            aicada stop
            sleep 2
            aicada start
            ;;
        status)
            printf "AI-CICADA Status:\n"
            if pgrep -x "ollama" > /dev/null 2>&1; then printf "  Ollama: running\n"; else printf "  Ollama: stopped\n"; fi
            if pgrep -f "node.*server.js" > /dev/null 2>&1; then printf "  Web: running (PID: \$(pgrep -f node.*server.js | head -1))\n"; else printf "  Web: stopped\n"; fi
            if command -v lsof >/dev/null 2>&1 && lsof -Pi :3000 -sTCP:LISTEN -t >/dev/null 2>&1; then printf "  Port 3000: in use\n"; else printf "  Port 3000: available\n"; fi
            ;;
        *)
            printf "Usage: aicada {start|stop|restart|status}\n"
            ;;
    esac
}
# END AI-CICADA
ALIASEOF
    printf "${GREEN}Commands ready: 'ai', 'web', 'aidb', 'aicada'${NC}\n"
    printf "${GREEN}  aicada start|stop|restart|status${NC}\n"
}

show_ha_tips() {
    if [ "$ENV_TYPE" != "homeassistant" ] && [ "$ENV_TYPE" != "wsl-ha" ]; then return; fi
    clear
    center_text "${GREEN}Home Assistant - советы${NC}"
    printf "\n"
    draw_box \
        "Данные: /config/.ai-cicada/" \
        "БД:     /config/.ai-cicada/cicada.db" \
        "" \
        "Автозапуск Ollama:" \
        "  ollama serve &" \
        "" \
        "Веб-чат: http://<HA-IP>:3000" \
        "" \
        "Просмотр БД: команда 'aidb'"
    printf "\n"
    press_any_key
}

final_screen() {
    clear
    # Cross-platform IP detection
    local CHAT_HOST
    CHAT_HOST=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    local display_env="$ENV_TYPE"
    case "$ENV_TYPE" in
        wsl|wsl-ha) display_env="WSL (Windows)" ;;
        homeassistant) display_env="Home Assistant" ;;
        termux) display_env="Termux (Android)" ;;
        debian) display_env="Debian/Ubuntu" ;;
        fedora) display_env="Fedora" ;;
        arch) display_env="Arch Linux" ;;
        alpine) display_env="Alpine Linux" ;;
        opensuse) display_env="openSUSE" ;;
        void) display_env="Void Linux" ;;
    esac
    draw_box \
        "INSTALLATION COMPLETE" \
        "" \
        "Platform : $display_env" \
        "Model    : $MODEL" \
        "DB       : $CHAT_DIR/cicada.db" \
        "Version  : $SCRIPT_VERSION" \
        "" \
        "Commands:" \
        "  aicada start   -- start services" \
        "  aicada stop    -- stop services" \
        "  aicada status  -- check status" \
        "  web            -- http://${CHAT_HOST}:3000" \
        "  ai             -- terminal agent" \
        "  aidb           -- view database" \
        "" \
        "Log: $LOG_FILE"
    printf "\n"
    center_text "${CYAN}Restart terminal or: source ~/.bashrc${NC}"
    printf "\n"
    press_any_key
}

launch_choice() {
    clear
    center_text "${YELLOW}What to launch now?${NC}"
    printf "\n"
    draw_box "1) Browser chat (web)" "2) Terminal agent (ai)" "3) Exit"
    printf "\n${YELLOW}Choice: ${NC}"
    read -r ch </dev/tty
    # Cross-platform IP detection
    local CHAT_HOST
    CHAT_HOST=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    case $ch in
        1)
            if ! pgrep -x "ollama" > /dev/null 2>&1; then ollama serve >> "$LOG_FILE" 2>&1 & sleep 3; fi
            # Check and handle port 3000
            if check_port 3000; then
                printf "${YELLOW}Port 3000 is already in use. Killing existing process...${NC}\n"
                kill_port 3000
                sleep 1
            fi
            printf "${GREEN}Open: http://%s:3000${NC}\n" "$CHAT_HOST"
            printf "${YELLOW}Press Ctrl+C to stop${NC}\n"
            AI_MODEL="$MODEL" node "$CHAT_DIR/server.js"
            ;;
        2)
            if ! pgrep -x "ollama" > /dev/null 2>&1; then ollama serve >> "$LOG_FILE" 2>&1 & sleep 3; fi
            CLAUDE_CODE_USE_OPENAI=1 OPENAI_BASE_URL=http://localhost:11434/v1 OPENAI_MODEL="$MODEL" openclaude
            ;;
        *) printf "${GREEN}Done! Run 'ai' or 'web' anytime.${NC}\n" ;;
    esac
}

main() {
    # Delegate to CLI dispatcher
    cicada_cli "$@"
}

main "$@"
