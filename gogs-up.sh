#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# ------------------- Defaults -------------------
BASE=$(pwd)/gogs
ADMIN_USER="dojo"
ADMIN_EMAIL="operations@dojobits.io"
# Gogs v0.13, AMD64
GOGS_VER=sha256:d21b5323e2f2c91850fe8a1f032ffde00b874502373a2339df961d674972907d
ADMIN_PASS=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c12)
SECRET_KEY=$(openssl rand -hex 16)

mkdir -p "${BASE}/conf" "${BASE}/data"

# ------------------- Generate the docker‑compose.yml ---------------------
cat > "${BASE}/docker-compose.yml" <<EOF
services:
  gogs:
    image: gogs/gogs@${GOGS_VER}
    container_name: gogs
    restart: unless-stopped
    ports:
      - "3000:3000"
      - "2222:22"
    volumes:
      - ./data:/data
      - ./conf:/data/gogs/conf
EOF

# ------------------- Bring the compose up -------------------------------
cd "${BASE}"
docker compose up -d

MAX_WAIT=10   # seconds
WAITED=0

echo "⏳ Waiting for Gogs to start (up to ${MAX_WAIT}s)…"
until curl -sf http://localhost:3000/ >/dev/null; do
    sleep 2
    WAITED=$((WAITED + 2))
    if ((WAITED >= MAX_WAIT)); then
        echo "Gogs is not reachable – aborting ❌"
        exit 1
    fi
done
echo "Gogs is up! ✅"

# ------------------- Do the setup -------------------------------

DB_FILE="${BASE}/data/gogs.db"
if [ ! -f "$DB_FILE" ]; then
    curl -fsSL -X POST "http://localhost:3000/install" \
      -F "db_type=SQLite3" \
      -F "db_path=/data/gogs.db" \
      -F "app_name=Gogs" \
      -F "repo_root_path=/data/git" \
      -F "run_user=git" \
      -F "domain=localhost" \
      -F "ssh_port=22" \
      -F "http_port=3000" \
      -F "app_url=http://localhost:3000/" \
      -F "log_root_path=/app/gogs/log" \
      -F "default_branch=main" \
      -F "admin_name=${ADMIN_USER}" \
      -F "admin_passwd=${ADMIN_PASS}" \
      -F "admin_confirm_passwd=${ADMIN_PASS}" \
      -F "admin_email=${ADMIN_EMAIL}"
fi


# -------------------  Show the credentials -------------------
echo "   Gogs is ready! 🎉"
echo "   URL      : http://localhost:3000/"
echo "   admin    : ${ADMIN_USER}"
echo "   password : ${ADMIN_PASS}"
echo "   (you can change the password later via the UI)"

