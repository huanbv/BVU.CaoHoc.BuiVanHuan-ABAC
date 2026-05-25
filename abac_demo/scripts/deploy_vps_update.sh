#!/usr/bin/env bash
# =============================================================================
# Cập nhật code ABAC Demo trên VPS từ Git + cài lại thư viện Python + restart
#
# Chuẩn bị một lần trên VPS:
#   chmod +x scripts/deploy_vps_update.sh
#   (Tuỳ chọn) Cho phép root dùng git với repo này — chạy 1 lần:
#   git config --global --add safe.directory /var/www/abac
#
# Cập nhật hàng ngày (mặc định không ghi đè file sửa tay):
#   sudo ./scripts/deploy_vps_update.sh
#
# Nếu git báo conflict vì file sửa trên VPS (vd. requirements.txt):
#   sudo FORCE_RESTORE=1 ./scripts/deploy_vps_update.sh
#
# Tuỳ chỉnh đường dẫn / service / user web:
#   sudo DEPLOY_REPO=/var/www/abac DEPLOY_SERVICE=abac-demo ./scripts/deploy_vps_update.sh
#
# ENV:
#   DEPLOY_REPO       Thư mục chứa .git            (mặc định: /var/www/abac)
#   DEPLOY_APP        Thư mục Flask (abac_demo)  (mặc định: $DEPLOY_REPO/abac_demo)
#   DEPLOY_VENV       Python venv                   (mặc định: $DEPLOY_APP/venv)
#   DEPLOY_SERVICE    systemd unit                  (mặc định: abac-demo)
#   DEPLOY_BRANCH     Nhánh git                     (mặc định: main)
#   DEPLOY_USER       Owner cho deploy_app          (mặc định: www-data)
#   FORCE_RESTORE     1 = git restore . trước pull  (ghi đè mọi sửa cục bộ!)
#   AUTO_SAFE_DIR     1 = thêm safe.directory một lần (tránh dubious ownership)
#   SKIP_PULL         1 = không pull (chỉ pip + chown + restart)
#   SKIP_PIP          1 = không chạy pip
#   SKIP_CHOWN        1 = không chown
#   SKIP_RESTART      1 = không systemctl restart
# =============================================================================

set -euo pipefail

DEPLOY_REPO="${DEPLOY_REPO:-/var/www/abac}"
DEPLOY_APP="${DEPLOY_APP:-${DEPLOY_REPO}/abac_demo}"
DEPLOY_VENV="${DEPLOY_VENV:-${DEPLOY_APP}/venv}"
DEPLOY_SERVICE="${DEPLOY_SERVICE:-abac-demo}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
DEPLOY_REMOTE="${DEPLOY_REMOTE:-origin}"
DEPLOY_USER="${DEPLOY_USER:-www-data}"

FORCE_RESTORE="${FORCE_RESTORE:-0}"
AUTO_SAFE_DIR="${AUTO_SAFE_DIR:-0}"
SKIP_PULL="${SKIP_PULL:-0}"
SKIP_PIP="${SKIP_PIP:-0}"
SKIP_CHOWN="${SKIP_CHOWN:-0}"
SKIP_RESTART="${SKIP_RESTART:-0}"

log() { printf '[deploy] %s\n' "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Thiếu lệnh: $1 — cài đặt hoặc dùng đúng PATH." >&2
    exit 1
  }
}

need_cmd git
need_cmd systemctl

if [[ ! -d "${DEPLOY_REPO}/.git" ]]; then
  echo "Không thấy git repo tại: ${DEPLOY_REPO} (thiếu .git)." >&2
  exit 1
fi

if [[ ! -d "${DEPLOY_APP}" ]]; then
  echo "Không thấy thư mục ứng dụng: ${DEPLOY_APP}" >&2
  exit 1
fi

if [[ ! -x "${DEPLOY_VENV}/bin/pip" ]]; then
  echo "Không thấy venv pip: ${DEPLOY_VENV}/bin/pip — kiểm tra DEPLOY_VENV." >&2
  exit 1
fi

if [[ "${AUTO_SAFE_DIR}" == "1" ]]; then
  if ! git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "${DEPLOY_REPO}"; then
    git config --global --add safe.directory "${DEPLOY_REPO}"
    log "Đã thêm git safe.directory → ${DEPLOY_REPO}"
  fi
fi

cd "${DEPLOY_REPO}"

if [[ "${SKIP_PULL}" != "1" ]]; then
  if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
    if [[ "${FORCE_RESTORE}" == "1" ]]; then
      log "Working tree có thay đổi → git restore . (FORCE_RESTORE=1)"
      git restore .
    else
      echo "" >&2
      echo "Lỗi: repo có file thay đổi cục bộ, không thể pull an toàn." >&2
      echo "Chạy: git status && git diff" >&2
      echo "Hoặc ghi đè hết chỉnh sửa trên VPS: sudo FORCE_RESTORE=1 $0" >&2
      exit 2
    fi
  fi

  log "git fetch ${DEPLOY_REMOTE} ${DEPLOY_BRANCH}"
  git fetch "${DEPLOY_REMOTE}" "${DEPLOY_BRANCH}"
  log "git pull ${DEPLOY_REMOTE} ${DEPLOY_BRANCH}"
  git pull "${DEPLOY_REMOTE}" "${DEPLOY_BRANCH}"
else
  log "Bỏ qua pull (SKIP_PULL=1)"
fi

REQ="${DEPLOY_APP}/requirements.txt"
if [[ "${SKIP_PIP}" != "1" ]]; then
  if [[ ! -f "${REQ}" ]]; then
    echo "Không thấy ${REQ}" >&2
    exit 1
  fi
  log "pip install -r requirements.txt (--upgrade)"
  "${DEPLOY_VENV}/bin/pip" install --upgrade pip >/dev/null
  "${DEPLOY_VENV}/bin/pip" install -r "${REQ}"
else
  log "Bỏ qua pip (SKIP_PIP=1)"
fi

if [[ "${SKIP_CHOWN}" != "1" ]]; then
  log "chown -R ${DEPLOY_USER}:${DEPLOY_USER} ${DEPLOY_APP}"
  chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_APP}"
else
  log "Bỏ qua chown (SKIP_CHOWN=1)"
fi

if [[ "${SKIP_RESTART}" != "1" ]]; then
  log "systemctl restart ${DEPLOY_SERVICE}"
  systemctl restart "${DEPLOY_SERVICE}"
  systemctl --no-pager -l status "${DEPLOY_SERVICE}" || true
else
  log "Bỏ qua restart (SKIP_RESTART=1)"
fi

log "Hoàn tất."
