#!/usr/bin/env bash
# どの ISUCON の問題でも初回に入れてよい設定を、サーバーに適用する。リポジトリを各サーバーに clone し、root で実行する
#
# 使い方: sudo script/base-conf/apply.sh            適用する
#         sudo script/base-conf/apply.sh --dry-run  変わる内容を diff で表示するだけ
#         sudo script/base-conf/apply.sh --revert   nginx と MySQL の設定を適用前に戻す（自動アップデートとツールはそのまま）
#
# 1. OS の自動アップデートを止める
# 2. 計測ツール（alp、pt-query-digest）と、./deploy-check が使う jq を入れる
# 3. nginx: conf.d/isucon.conf を置き、nginx.conf の worker の数、fd の上限、接続数を上げて、元の access_log を外す
# 4. MySQL / MariaDB: zz-isucon.cnf を置いて再起動する
# 入っていないミドルウェアの段は飛ばす。何度実行しても同じ結果になる。
# nginx.conf の元のファイルは、初回だけ /var/backups/isucon-base-conf/ に保存する
set -euo pipefail

CONF_DIR="$(cd "$(dirname "$0")" && pwd)/conf"
BACKUP_DIR=/var/backups/isucon-base-conf
ALP_VERSION=1.0.21
NGINX_RLIMIT=65535
NGINX_CONNECTIONS=4096

MODE=apply
case "${1:-}" in
  "") ;;
  -n|--dry-run) MODE=dry-run ;;
  --revert) MODE=revert ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac
[[ $EUID -eq 0 ]] || { echo "root で実行してください" >&2; exit 1; }

log() { printf '\n== %s\n' "$*"; }
dry() { [[ $MODE == dry-run ]]; }

# --- 1. OS の自動アップデート ---
# AMI のパッケージの一覧は古く、apt-get update を引き金に数百のパッケージが更新され、MySQL まで再起動した（isucon12）
stop_auto_updates() {
  log "OS の自動アップデート"
  if ! dry; then
    systemctl stop apt-daily-upgrade.service apt-daily.service unattended-upgrades.service 2>/dev/null || true
    systemctl disable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service 2>/dev/null || true
    # 更新の途中で止めたときに、壊れたパッケージが残っていないか
    dpkg --audit
  fi
  for u in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service; do
    printf '%s: %s\n' "$u" "$(systemctl is-enabled "$u" 2>/dev/null || true)"
  done
}

# --- 2. 計測ツール ---
install_tools() {
  log "計測ツール"
  if ! command -v pt-query-digest >/dev/null || ! command -v jq >/dev/null; then
    echo "percona-toolkit と jq を入れる"
    if ! dry; then
      # 止めた自動アップデートがまだ apt のロックを持っていることがあるので、空くまで待つ
      apt-get -o DPkg::Lock::Timeout=120 update -qq
      DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -qq --no-install-recommends percona-toolkit jq >/dev/null
    fi
  fi
  if ! command -v alp >/dev/null; then
    local url="https://github.com/tkuchiki/alp/releases/download/v$ALP_VERSION/alp_linux_$(dpkg --print-architecture).tar.gz"
    echo "alp を入れる: $url"
    if ! dry; then
      # root で展開すると、アーカイブの持ち主（uid 1001 など）が再現される。root の持ち主にする
      curl -fsSL "$url" | tar -xz --no-same-owner -C /usr/local/bin alp
    fi
  fi
  command -v alp >/dev/null && alp --version
  command -v pt-query-digest >/dev/null && pt-query-digest --version
  return 0
}

# --- 3. nginx ---
# 値が小さいときだけ上げる。元の値のほうが大きければ触らない
raise_directive() {  # $1: ファイル, $2: ディレクティブ, $3: 値
  local cur
  cur="$(grep -oP "^\s*$2\s+\K[0-9]+(?=\s*;)" "$1" | head -1 || true)"
  if [[ -n $cur ]]; then
    (( cur < $3 )) && sed -i -E "s/^([[:space:]]*$2)[[:space:]]+[0-9]+[[:space:]]*;/\1 $3;/" "$1"
  elif [[ $2 == worker_connections ]]; then
    sed -i -E "/^[[:space:]]*events[[:space:]]*\{/a\    $2 $3;" "$1"
  elif grep -Eq '^[[:space:]]*worker_processes[[:space:]]' "$1"; then
    sed -i -E "/^[[:space:]]*worker_processes[[:space:]]/a $2 $3;" "$1"
  else
    sed -i "1i $2 $3;" "$1"
  fi
  return 0
}

# nginx.conf の写しを編集する。conf.d に置けない main と events のディレクティブだけを変える
edit_nginx_conf() {  # $1: 入力, $2: 出力
  cp -p "$1" "$2"
  # worker が数字（1 など）に固定されていたら、CPU のコア数ぶん動かす。1 のままなのはワーカー 1 と同じ明らかな誤り
  sed -i -E 's/^([[:space:]]*worker_processes)[[:space:]]+[0-9]+[[:space:]]*;/\1 auto;/' "$2"
  # 1 つの接続で、クライアント側と upstream 側の fd を使う。1024 のままだと Too many open files で 500 になる（private-isu）
  raise_directive "$2" worker_rlimit_nofile "$NGINX_RLIMIT"
  # 768 だと「worker_connections are not enough」になる（private-isu）
  raise_directive "$2" worker_connections "$NGINX_CONNECTIONS"
  # http の access_log は conf.d/isucon.conf の ltsv に置き換える。残すと同じファイルに 2 行ずつ記録される
  sed -i -E 's|^([[:space:]]*)(access_log[[:space:]].*)$|\1# \2  # isucon: conf.d/isucon.conf の ltsv に置き換えた|' "$2"
}

apply_nginx() {
  log "nginx"
  local conf=/etc/nginx/nginx.conf dropin=/etc/nginx/conf.d/isucon.conf
  if ! command -v nginx >/dev/null || [[ ! -f $conf ]]; then
    echo "nginx がないので飛ばす"; return 0
  fi
  if ! grep -Eq '^[[:space:]]*include[[:space:]]+/etc/nginx/conf\.d/\*\.conf' "$conf"; then
    echo "nginx.conf が conf.d/*.conf を読み込んでいないので飛ばす。手で入れる" >&2; return 0
  fi

  local edited prev_conf prev_dropin=""
  edited="$(mktemp)"; prev_conf="$(mktemp)"
  edit_nginx_conf "$conf" "$edited"
  diff -u "$conf" "$edited" || true
  diff -u "$( [[ -f $dropin ]] && echo "$dropin" || echo /dev/null)" "$CONF_DIR/nginx/isucon.conf" || true

  # server ブロックに access_log があると、http に置いた ltsv より優先される
  grep -lE '^[[:space:]]*access_log[[:space:]]' /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf 2>/dev/null \
    | grep -v "^$dropin\$" | sed 's/^/注意: access_log を持つファイル（ltsv にするか消す）: /' || true

  dry && return 0
  mkdir -p "$BACKUP_DIR"
  [[ -e $BACKUP_DIR/nginx.conf ]] || cp -p "$conf" "$BACKUP_DIR/nginx.conf"
  cp -p "$conf" "$prev_conf"
  if [[ -f $dropin ]]; then prev_dropin="$(mktemp)"; cp -p "$dropin" "$prev_dropin"; fi

  cat "$edited" > "$conf"
  install -m 644 "$CONF_DIR/nginx/isucon.conf" "$dropin"
  if ! nginx -t; then
    echo "nginx -t に失敗したので元に戻す" >&2
    cat "$prev_conf" > "$conf"
    if [[ -n $prev_dropin ]]; then cp -p "$prev_dropin" "$dropin"; else rm -f "$dropin"; fi
    return 1
  fi
  reload_nginx
}

reload_nginx() {
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
    sleep 1
    # reload の直後は古い worker が終了待ちで残っているので、いちばん新しい worker を見る
    local pid; pid="$(pgrep -n -f '^nginx: worker' || true)"
    [[ -n $pid ]] && echo "worker の $(grep 'Max open files' "/proc/$pid/limits")"
  else
    echo "nginx は止まっている。設定だけ置いた"
  fi
  return 0
}

revert_nginx() {
  log "nginx を戻す"
  [[ -f $BACKUP_DIR/nginx.conf ]] || { echo "保存した nginx.conf がないので飛ばす"; return 0; }
  cat "$BACKUP_DIR/nginx.conf" > /etc/nginx/nginx.conf
  rm -f /etc/nginx/conf.d/isucon.conf
  nginx -t && reload_nginx
}

# --- 4. MySQL / MariaDB ---
mysql_paths() {  # 「設定のディレクトリ サービス名」を出す
  local dir="" svc=""
  for d in /etc/mysql/mysql.conf.d /etc/mysql/mariadb.conf.d /etc/mysql/conf.d; do
    [[ -d $d ]] && { dir=$d; break; }
  done
  for s in mysql mariadb mysqld; do
    systemctl cat "$s.service" >/dev/null 2>&1 && { svc=$s; break; }
  done
  echo "$dir $svc"
}

restart_mysql() {  # $1: サービス名。動いていたときだけ再起動する
  if systemctl is-active --quiet "$1"; then
    systemctl restart "$1"
    echo "注意: MySQL を再起動した。アプリがソケットをコンテナにマウントしているなら、アプリも再起動する"
  else
    echo "$1 は止まっている。設定だけ置いた"
  fi
}

show_mysql_values() {
  local q='SELECT @@log_bin, @@innodb_flush_log_at_trx_commit, @@innodb_doublewrite, @@max_connections, @@slow_query_log, @@slow_query_log_file, @@long_query_time'
  if ! mysql -e "$q" 2>/dev/null; then
    echo "root でログインできないので、設定ファイル上の値を出す（実際の値は mysql -uroot -p で確かめる）"
    my_print_defaults --mysqld | grep -E 'log.bin|flush_log|doublewrite|max_connections|slow_query|long_query' || true
  fi
}

apply_mysql() {
  log "MySQL"
  local dir svc dropin
  read -r dir svc <<< "$(mysql_paths)"
  if ! command -v mysqld >/dev/null && ! command -v mariadbd >/dev/null || [[ -z $dir || -z $svc ]]; then
    echo "このホストに MySQL がないので飛ばす（コンテナなら compose の command か my.cnf に同じ値を入れる）"; return 0
  fi
  dropin="$dir/zz-isucon.cnf"
  diff -u "$( [[ -f $dropin ]] && echo "$dropin" || echo /dev/null)" "$CONF_DIR/mysql/zz-isucon.cnf" || true
  dry && return 0
  if [[ -f $dropin ]] && cmp -s "$dropin" "$CONF_DIR/mysql/zz-isucon.cnf"; then
    echo "変更なし（再起動しない）"; show_mysql_values; return 0
  fi

  local was_active=0
  systemctl is-active --quiet "$svc" && was_active=1
  install -m 644 "$CONF_DIR/mysql/zz-isucon.cnf" "$dropin"
  restart_mysql "$svc"
  if (( was_active )) && ! systemctl is-active --quiet "$svc"; then
    echo "$svc が起動しないので設定を外す" >&2
    journalctl -u "$svc" -n 20 --no-pager >&2 || true
    rm -f "$dropin"; systemctl restart "$svc"
    return 1
  fi
  show_mysql_values
}

revert_mysql() {
  log "MySQL を戻す"
  local dir svc
  read -r dir svc <<< "$(mysql_paths)"
  [[ -n $dir && -f $dir/zz-isucon.cnf ]] || { echo "zz-isucon.cnf がないので飛ばす"; return 0; }
  rm -f "$dir/zz-isucon.cnf"
  restart_mysql "$svc"
}

case $MODE in
  apply|dry-run) stop_auto_updates; install_tools; apply_nginx; apply_mysql ;;
  revert) revert_nginx; revert_mysql ;;
esac
log "完了（${MODE}）"
