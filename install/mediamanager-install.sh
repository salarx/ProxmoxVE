#!/usr/bin/env bash

# Copyright (c) 2025 Community Scripts ORG
# Author: vhsdream
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/maxdorninger/MediaManager

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

read -r -p "${TAB3}Enter the email address of your first admin user: " admin_email
if [[ "$admin_email" ]]; then
  EMAIL="$admin_email"
fi

MM_USER="${MM_USER:-media}"
MM_GROUP="${MM_GROUP:-media}"

setup_yq
NODE_VERSION="24" setup_nodejs
setup_uv
PG_VERSION="17" setup_postgresql

msg_info "Setting up PostgreSQL"
DB_NAME="mm_db"
DB_USER="mm_user"
DB_PASS="$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | cut -c1-13)"
$STD sudo -u postgres psql -c "CREATE ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASS';"
$STD sudo -u postgres psql -c "CREATE DATABASE $DB_NAME WITH OWNER $DB_USER TEMPLATE template0;"
$STD sudo -u postgres psql -c "ALTER ROLE $DB_USER SET client_encoding TO 'utf8';"
{
  echo "MediaManager Credentials"
  echo "MediaManager Database User: $DB_USER"
  echo "MediaManager Database Password: $DB_PASS"
  echo "MediaManager Database Name: $DB_NAME"
} >>~/mediamanager.creds
msg_ok "Set up PostgreSQL"

fetch_and_deploy_gh_release "MediaManager" "maxdorninger/MediaManager" "tarball" "latest" "/opt/mediamanager"

msg_info "Configuring MediaManager"
MM_DIR="/opt/mm"
MEDIA_DIR="${MM_DIR}/media"
export CONFIG_DIR="${MM_DIR}/config"
export FRONTEND_FILES_DIR="${MM_DIR}/web/build"

# create mm dir and make sure ownership is correct
mkdir -p "$MM_DIR"
chown -R $MM_USER:$MM_GROUP /opt/mediamanager "$MM_DIR"

# go to source web directory
cd /opt/mediamanager/web

# create Svelte/Vite .env so PUBLIC_* are available during build
cat <<EOF >/opt/mediamanager/web/.env
PUBLIC_VERSION=""
PUBLIC_API_URL=""
BASE_PATH="/web"
EOF
chown $MM_USER:$MM_GROUP /opt/mediamanager/web/.env

# ensure web source is owned by media before npm
chown -R $MM_USER:$MM_GROUP /opt/mediamanager/web

# run frontend build as media
sudo -u $MM_USER npm ci --no-fund --no-audit
sudo -u $MM_USER npm run build

# copy build into mm output
mkdir -p {"$MM_DIR"/web,"$MEDIA_DIR","$CONFIG_DIR"}
cp -r build "$FRONTEND_FILES_DIR"

# prepare uv home inside /opt/mm so python installs are media-owned
export UV_HOME="${MM_DIR}/.py"
mkdir -p "$UV_HOME"
chown -R $MM_USER:$MM_GROUP "$UV_HOME"

# explicitly set virtual env path variable (keeps behavior explicit)
export VIRTUAL_ENV="${MM_DIR}/venv"

cd /opt/mediamanager
cp -r {media_manager,alembic*} "$MM_DIR"

# Run uv sync as media, but using media-owned UV_HOME so python is installed under /opt/mm/.py
sudo -u $MM_USER UV_HOME="$UV_HOME" /usr/local/bin/uv sync --locked --active -n -p cpython3.13 --managed-python

# Fix permissions after syncing python & venv
chown -R $MM_USER:$MM_GROUP "$MM_DIR"
msg_ok "Configured MediaManager"

msg_info "Creating config and start script"
LOCAL_IP="$(hostname -I | awk '{print $1}')"
SECRET="$(openssl rand -hex 32)"

sed -e "s/localhost:8/$LOCAL_IP:8/g" \
  -e "s|/data/|$MEDIA_DIR/|g" \
  -e 's/"db"/"localhost"/' \
  -e "s/user = \"MediaManager\"/user = \"$DB_USER\"/" \
  -e "s/password = \"MediaManager\"/password = \"$DB_PASS\"/" \
  -e "s/dbname = \"MediaManager\"/dbname = \"$DB_NAME\"/" \
  -e "/^token_secret/s/=.*/= \"$SECRET\"/" \
  -e "s/admin@example.com/$EMAIL/" \
  -e '/^admin_emails/s/, .*/]/' \
  /opt/mediamanager/config.example.toml >"$CONFIG_DIR"/config.toml

mkdir -p "$MEDIA_DIR"/{images,tv,movies,torrents}
chown -R $MM_USER:$MM_GROUP "$MEDIA_DIR" "$CONFIG_DIR" "$FRONTEND_FILES_DIR" "$MM_DIR"

# create start script (explicit VIRTUAL_ENV + UV_HOME + explicit uv path)
cat <<'EOF' >"$MM_DIR"/start.sh
#!/usr/bin/env bash

export CONFIG_DIR="__CONFIG_DIR__"
export FRONTEND_FILES_DIR="__FRONTEND_FILES_DIR__"
export LOG_FILE="$CONFIG_DIR/media_manager.log"
export BASE_PATH=""
export VIRTUAL_ENV="__VIRTUAL_ENV__"
export UV_HOME="__UV_HOME__"

cd /opt/mm
source ./venv/bin/activate

/usr/local/bin/uv run alembic upgrade head
/usr/local/bin/uv run fastapi run ./media_manager/main.py --port 8000
EOF

# fill placeholders with real values (use simple sed to avoid variable interpolation at here-doc)
sed -i "s|__CONFIG_DIR__|$CONFIG_DIR|g" "$MM_DIR"/start.sh
sed -i "s|__FRONTEND_FILES_DIR__|$FRONTEND_FILES_DIR|g" "$MM_DIR"/start.sh
sed -i "s|__VIRTUAL_ENV__|$VIRTUAL_ENV|g" "$MM_DIR"/start.sh
sed -i "s|__UV_HOME__|$UV_HOME|g" "$MM_DIR"/start.sh

chmod +x "$MM_DIR"/start.sh
chown $MM_USER:$MM_GROUP "$MM_DIR"/start.sh
msg_ok "Created config and start script"

msg_info "Creating service"
cat <<EOF >/etc/systemd/system/mediamanager.service
[Unit]
Description=MediaManager Backend Service
After=network.target

[Service]
User=$MM_USER
Group=$MM_GROUP
Type=simple
WorkingDirectory=${MM_DIR}
ExecStart=/usr/bin/bash start.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl enable -q --now mediamanager
msg_ok "Created service"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt -y autoremove
$STD apt -y autoclean
$STD apt -y clean
msg_ok "Cleaned"
