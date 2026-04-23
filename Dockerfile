# AI-CICADA Docker Image
# Multi-stage build for optimized size

FROM node:18-slim AS base

# Install system dependencies
RUN apt-get update && apt-get install -y \
    python3 \
    make \
    g++ \
    curl \
    ca-certificates \
    sqlite3 \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Create app directory
WORKDIR /app

# Copy package files first for better caching
COPY package.json ./

# Install npm dependencies
RUN npm install && \
    npm cache clean --force

# Production stage
FROM node:18-slim AS production

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    sqlite3 \
    curl \
    ca-certificates \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r cicada && useradd -r -g cicada cicada

WORKDIR /app

# Copy dependencies from base
COPY --from=base /app/node_modules ./node_modules
COPY --from=base /app/package.json ./

# Copy application files
COPY server.js ./
COPY index.html ./
COPY entrypoint.sh ./
RUN chmod +x entrypoint.sh

# Create data directory with proper permissions
RUN mkdir -p /data && chown -R cicada:cicada /data /app

# Environment variables
ENV NODE_ENV=production
ENV PORT=3000
ENV DB_PATH=/data/cicada.db
ENV JWT_SECRET=auto-generate
ENV OLLAMA_HOST=http://ollama:11434

# Expose port
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3000/api/health || exit 1

# Switch to non-root user
USER cicada

# Volume for persistent data
VOLUME ["/data"]

ENTRYPOINT ["./entrypoint.sh"]
CMD ["start"]
