#!/bin/bash
# AI-CICADA Docker Entrypoint

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
DATA_DIR="${DATA_DIR:-/data}"
DB_PATH="${DB_PATH:-$DATA_DIR/cicada.db}"
PORT="${PORT:-3000}"
OLLAMA_HOST="${OLLAMA_HOST:-http://ollama:11434}"
AI_MODEL="${AI_MODEL:-qwen2.5-coder:3b}"

# Generate JWT secret if not provided
if [ -z "$JWT_SECRET" ] || [ "$JWT_SECRET" = "auto-generate" ]; then
    JWT_SECRET=$(head -c 32 /dev/urandom | xxd -p -c 64 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | head -c 64)
    export JWT_SECRET
fi

# Wait for Ollama to be ready
wait_for_ollama() {
    printf "${BLUE}Waiting for Ollama at %s...${NC}\n" "$OLLAMA_HOST"
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -s "$OLLAMA_HOST/api/tags" > /dev/null 2>&1; then
            printf "${GREEN}Ollama is ready!${NC}\n"
            return 0
        fi
        attempt=$((attempt + 1))
        printf "${YELLOW}Attempt %d/%d - waiting 5s...${NC}\n" "$attempt" "$max_attempts"
        sleep 5
    done
    
    printf "${RED}Ollama failed to start${NC}\n"
    return 1
}

# Pull model if not exists
pull_model() {
    printf "${BLUE}Checking model: %s${NC}\n" "$AI_MODEL"
    
    # Check if model exists
    if curl -s "$OLLAMA_HOST/api/tags" | grep -q "$AI_MODEL"; then
        printf "${GREEN}Model already available${NC}\n"
        return 0
    fi
    
    printf "${YELLOW}Pulling model %s...${NC}\n" "$AI_MODEL"
    curl -X POST "$OLLAMA_HOST/api/pull" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$AI_MODEL\"}" \
        --silent --show-error || true
    
    # Wait for pull to complete
    printf "${YELLOW}Waiting for model download...${NC}\n"
    local attempts=0
    while [ $attempts -lt 60 ]; do
        if curl -s "$OLLAMA_HOST/api/tags" | grep -q "$AI_MODEL"; then
            printf "${GREEN}Model ready!${NC}\n"
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 10
    done
    
    printf "${RED}Model pull timeout${NC}\n"
    return 1
}

# Initialize database
init_database() {
    mkdir -p "$DATA_DIR"
    
    if [ ! -f "$DB_PATH" ]; then
        printf "${BLUE}Initializing database...${NC}\n"
        sqlite3 "$DB_PATH" << 'SQL'
CREATE TABLE IF NOT EXISTS users (
    username TEXT PRIMARY KEY,
    password_hash TEXT NOT NULL,
    created_at INTEGER DEFAULT (strftime('%s', 'now')),
    total_msgs INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS chats (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL,
    title TEXT,
    created_at INTEGER DEFAULT (strftime('%s', 'now')),
    FOREIGN KEY (username) REFERENCES users(username)
);

CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at INTEGER DEFAULT (strftime('%s', 'now')),
    FOREIGN KEY (chat_id) REFERENCES chats(id)
);

CREATE TABLE IF NOT EXISTS memory (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    category TEXT DEFAULT 'general',
    created_at INTEGER DEFAULT (strftime('%s', 'now')),
    UNIQUE(username, key)
);
SQL
        printf "${GREEN}Database initialized${NC}\n"
    fi
}

# Start server
start_server() {
    printf "${BLUE}Starting AI-CICADA server...${NC}\n"
    printf "  Port: %s\n" "$PORT"
    printf "  Model: %s\n" "$AI_MODEL"
    printf "  Ollama: %s\n" "$OLLAMA_HOST"
    printf "  Database: %s\n" "$DB_PATH"
    
    exec node server.js
}

# Health check endpoint
health_check() {
    curl -f http://localhost:$PORT/api/health > /dev/null 2>&1
}

# Main command dispatcher
case "${1:-start}" in
    start)
        wait_for_ollama
        pull_model
        init_database
        start_server
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
    
    health)
        if health_check; then
            echo "healthy"
            exit 0
        else
            echo "unhealthy"
            exit 1
        fi
        ;;
    
    shell|bash|sh)
        exec /bin/bash
        ;;
    
    *)
        exec "$@"
        ;;
esac
