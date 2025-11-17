#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/salarx/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 community-scripts ORG
# Author: vhsdream
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/maxdorninger/MediaManager

APP="MediaManager"
var_tags="${var_tags:-arr}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-3072}"
var_disk="${var_disk:-4}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/mediamanager ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  setup_uv

  if check_for_gh_release "mediamanager" "maxdorninger/MediaManager"; then
    msg_info "Stopping Service"
    systemctl stop mediamanager
    msg_ok "Stopped Service"

    # Fetch upstream code
    fetch_and_deploy_gh_release \
      "MediaManager" \
      "maxdorninger/MediaManager" \
      "tarball" \
      "latest" \
      "/opt/mediamanager"

    msg_info "Updating ${APP}"

    MM_DIR="/opt/mm"
    export CONFIG_DIR="${MM_DIR}/config"
    export FRONTEND_FILES_DIR="${MM_DIR}/web/build"
    export PUBLIC_VERSION=""
    export PUBLIC_API_URL=""
    export BASE_PATH="/web"

    # Fix permissions before build
    chown -R $MM_USER:$MM_GROUP /opt/mediamanager
    chown -R $MM_USER:$MM_GROUP $MM_DIR

    cd /opt/mediamanager/web

    # Run frontend build as media user
    sudo -u $MM_USER npm ci --no-fund --no-audit
    sudo -u $MM_USER npm run build

    rm -rf "$FRONTEND_FILES_DIR"/build
    cp -r build "$FRONTEND_FILES_DIR"

    export BASE_PATH=""
    export VIRTUAL_ENV="${MM_DIR}/venv"

    cd /opt/mediamanager

    rm -rf "$MM_DIR"/{media_manager,alembic*}
    cp -r {media_manager,alembic*} "$MM_DIR"

    # Run uv sync as media user
    sudo -u $MM_USER /usr/local/bin/uv sync \
      --locked --active -n -p cpython3.13 --managed-python

    # Fix permissions again after update
    chown -R $MM_USER:$MM_GROUP $MM_DIR

    # Patch start.sh if necessary
    if ! grep -q "LOG_FILE" "$MM_DIR"/start.sh; then
      sed -i "\|build\"$|a\export LOG_FILE=\"$CONFIG_DIR/media_manager.log\"" "$MM_DIR"/start.sh
    fi

    msg_ok "Updated $APP"

    msg_info "Starting Service"
    systemctl start mediamanager
    msg_ok "Started Service"
    msg_ok "Updated successfully!"
  fi
  exit
}

export MM_USER="media"
export MM_GROUP="media"

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8000${CL}"
