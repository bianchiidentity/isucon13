#!/usr/bin/env bash
# base-conf が入れない計測と運用のツールを入れる。各サーバーで root で実行する
#
# 使い方: sudo script/setup-tools/setup-tools.sh            入れる
#         sudo script/setup-tools/setup-tools.sh --dry-run  入れるものを表示するだけ
#
# 1. apt: graphviz（pprof のグラフ）、sysstat（pidstat、iostat、mpstat）
# 2. mysqldef（./deploy がスキーマの差分を当てる）を版を固定して入れる
# 入っているものは飛ばす。何度実行しても同じ結果になる。
# alp、pt-query-digest、jq は base-conf が入れるので、ここでは入れない
set -euo pipefail

MYSQLDEF_VERSION=v3.11.26
APT_PACKAGES=(graphviz sysstat)
# sysstat が入れる定期収集。10 分ごとに sadc が動き、計測に混ざるので止める（pidstat などは止めても使える）
SYSSTAT_UNITS=(sysstat.service sysstat-collect.timer sysstat-summary.timer)

MODE=apply
case "${1:-}" in
  "") ;;
  -n|--dry-run) MODE=dry-run ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac
[[ $EUID -eq 0 ]] || { echo "root で実行してください" >&2; exit 1; }

log() { printf '\n== %s\n' "$*"; }
dry() { [[ $MODE == dry-run ]]; }

# --- 1. apt ---
install_apt() {
  log "apt のパッケージ"
  local missing=() p
  for p in "${APT_PACKAGES[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
  done
  if (( ${#missing[@]} == 0 )); then
    echo "入っている: ${APT_PACKAGES[*]}"
  else
    echo "入れる: ${missing[*]}"
    if ! dry; then
      # 一覧が古くて見つからないときだけ update する。update は自動アップデートの対象を増やすので、なるべく避ける
      apt-cache show "${missing[@]}" >/dev/null 2>&1 || apt-get -o DPkg::Lock::Timeout=120 update -qq
      # needrestart がライブラリの更新を理由に nginx や MySQL を再起動しないよう、一覧の表示だけにする
      DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
        apt-get -o DPkg::Lock::Timeout=120 install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
    fi
  fi
  if ! dry && dpkg-query -W -f='${Status}' sysstat 2>/dev/null | grep -q 'install ok installed'; then
    systemctl disable --now "${SYSSTAT_UNITS[@]}" 2>/dev/null || true
  fi
  return 0
}

# --- 2. mysqldef ---
install_mysqldef() {
  log "mysqldef"
  local cur=""
  command -v mysqldef >/dev/null && cur="$(mysqldef --version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  if [[ ${cur#v} == "${MYSQLDEF_VERSION#v}" ]]; then
    echo "入っている: $cur"; return 0
  fi
  local url="https://github.com/sqldef/sqldef/releases/download/$MYSQLDEF_VERSION/mysqldef_linux_$(dpkg --print-architecture).tar.gz"
  echo "入れる（今: ${cur:-なし}）: $url"
  dry && return 0
  curl -fsSL "$url" | tar -xz -C /usr/local/bin mysqldef
}

show_versions() {
  log "版"
  command -v dot >/dev/null && dot -V 2>&1
  command -v pidstat >/dev/null && pidstat -V 2>&1 | head -1
  command -v mysqldef >/dev/null && mysqldef --version
  for u in "${SYSSTAT_UNITS[@]}"; do
    systemctl cat "$u" >/dev/null 2>&1 && printf '%s: %s\n' "$u" "$(systemctl is-enabled "$u" 2>/dev/null || true)"
  done
  return 0
}

install_apt
install_mysqldef
show_versions
log "完了（${MODE}）"
