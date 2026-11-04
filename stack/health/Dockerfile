FROM node:24-trixie-slim

ENV NODE_ENV=production
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY server.mjs healthcheck.mjs digest.mjs ./
COPY src ./src

# The image's built-in unprivileged user (uid/gid 1000). The application files stay root-owned and read-only to it.
USER node

EXPOSE 8080

# Liveness of this service (see healthcheck.mjs); the PostgreSQL verdict is what /healthz itself reports.
HEALTHCHECK --interval=30s --timeout=15s --start-period=15s --retries=3 CMD ["node", "/app/healthcheck.mjs"]

# Exec form: node is PID 1 (or tini's child with `init: true`) and receives SIGTERM directly.
STOPSIGNAL SIGTERM
CMD ["node", "server.mjs"]
