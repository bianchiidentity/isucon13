# 1 台のサーバーで実行する各段。step::<名前> を run_step が呼ぶ

STEP_TIMES=()   # 段ごとの所要時間（「名前 秒」）

# $1 の段を実行し、かかった時間を記録する。役割に含まれない段と、--only で外した段は飛ばす
run_step() {
  local step=$1 start
  [[ $step == common ]] || role_has "$ROLES" "$step" || return 0
  [[ -z $ONLY || ",$ONLY," == *",$step,"* ]] || return 0
  start=$EPOCHREALTIME
  "step::$step"
  STEP_TIMES+=("$step $(elapsed "$start")")
}

# --- 共通の設定（systemd、sysctl、環境変数のファイルなど） ---
step::common() {
  log "共通の設定（nginx と MySQL 以外）"
  step::needs_apply common '.' '^etc/(nginx|mysql)/' || return 0
  # どちらも何度実行しても害がないので、変わったものを見分けずに両方行う
  sudo systemctl daemon-reload
  sudo sysctl --system > /dev/null
  echo "systemctl daemon-reload と sysctl --system を実行した"
  pending::clear common
}

# 設定ファイルを反映し、reload や restart が要るなら 0 を返す（dry-run なら差分を表示するだけで 1）。
# $1: 反映待ちの印の名前、$2: 含める正規表現、$3: 除く正規表現
step::needs_apply() {
  local key=$1 changed=0
  conf::sync "$2" "$3" "$key" && changed=1
  if pending::exists "$key"; then
    (( changed )) || echo "前回の実行が reload / restart の前に止まっていたので、やり直す"
    changed=1
  fi
  (( changed )) || { echo "変更なし"; return 1; }
  ! dry
}

# --- MySQL ---
step::mysql() {
  log "MySQL の設定"
  if step::needs_apply mysql '^etc/mysql/' ''; then mysql::restart_or_restore; fi
  mysql::apply_schema
}

mysql::restart_or_restore() {
  if sudo systemctl restart "$MYSQL_SERVICE"; then
    echo "MySQL を再起動した"
    pending::clear mysql
    return 0
  fi
  sudo journalctl -u "$MYSQL_SERVICE" -n 20 --no-pager >&2 || true
  conf::restore '^etc/mysql/'
  # 戻した設定で起動できれば、ファイルと動いている設定がそろうので、反映待ちの印を外す
  sudo systemctl restart "$MYSQL_SERVICE" && pending::clear mysql
  die "MySQL が起動しないので、設定を元に戻した"
}

mysql::install_mysqldef() {
  command -v mysqldef > /dev/null && return 0
  local url="https://github.com/sqldef/sqldef/releases/latest/download/mysqldef_linux_$(dpkg --print-architecture).tar.gz"
  echo "mysqldef を入れる: $url"
  # root で展開すると、アーカイブの持ち主（uid 1001 など）が再現される。root の持ち主にする
  curl -fsSL "$url" | sudo tar -xz --no-same-owner -C /usr/local/bin mysqldef
}

mysql::apply_schema() {
  log "スキーマ（sqldef）"
  [[ -n ${SCHEMA_FILE:-} ]] || { echo "SCHEMA_FILE が空なので飛ばす"; return 0; }
  [[ -f $SCHEMA_FILE ]] || die "SCHEMA_FILE がない: $SCHEMA_FILE"
  mysql::install_mysqldef

  local out schema="$WORK_DIR/schema.sql" args=(-u "$DB_USER" -p "$DB_PASS" -h "$DB_HOST" -P "$DB_PORT")
  # sqldef は「あるべき姿」の CREATE 文だけを受け取る。ISUCON の schema.sql によくある DROP TABLE IF EXISTS は除く
  grep -viE '^[[:space:]]*DROP[[:space:]]+TABLE' "$SCHEMA_FILE" > "$schema"

  out="$(mysqldef "${args[@]}" --dry-run "$DB_NAME" < "$schema")" || { echo "$out"; die "mysqldef --dry-run に失敗した"; }
  echo "$out"
  grep -q 'Nothing is modified' <<< "$out" && return 0
  # schema.sql に書き漏れがあると、sqldef はその列やインデックスを消そうとする
  if grep -qiE '(^|[[:space:]])DROP[[:space:]]' <<< "$out" && (( ! ALLOW_DROP )); then
    die "DROP が含まれる。schema.sql の書き漏れでないか確かめ、意図どおりなら --allow-drop を付けて実行する"
  fi
  dry && return 0
  # 新しい sqldef は、--enable-drop がないと DROP を飛ばす
  if (( ALLOW_DROP )) && mysqldef --help 2>&1 | grep -q -- '--enable-drop'; then args+=(--enable-drop); fi
  mysqldef "${args[@]}" "$DB_NAME" < "$schema"
}

# --- nginx ---
step::nginx() {
  log "nginx の設定"
  step::needs_apply nginx '^etc/nginx/' '' || return 0
  # 失敗したときは印を残す。戻したファイルが、動いている設定と同じとは限らない（前の実行が reload の前に止まっていた場合）
  sudo nginx -t || { conf::restore '^etc/nginx/'; die "nginx -t に失敗したので、設定を元に戻した"; }
  sudo systemctl reload nginx
  echo "nginx を reload した"
  pending::clear nginx
}

# --- app ---
step::app() {
  log "app（${APP_DIR}）"
  dry && { echo "(dry-run) build と restart は飛ばす"; return 0; }
  # go のビルドキャッシュとバイナリの所有者をそろえるため、アプリのユーザーでビルドする
  sudo -u "$APP_USER" env PATH="$GO_BIN_DIR:$PATH" HOME="$(getent passwd "$APP_USER" | cut -d: -f6)" \
    bash -c "cd '$APP_DIR' && $BUILD_CMD" || die "ビルドに失敗した（アプリは再起動していない）"
  local since old_pid
  since="$(date '+%Y-%m-%d %H:%M:%S')"
  old_pid="$(app::main_pid)"
  sudo systemctl restart "$APP_SERVICE"
  if ! app::wait_ready "$old_pid"; then
    sudo journalctl -u "$APP_SERVICE" -n 30 --no-pager >&2 || true
    die "$APP_SERVICE が起動しない"
  fi
  echo "$APP_SERVICE を再起動した（MainPID ${old_pid} → $(app::main_pid)）"
  sudo journalctl -u "$APP_SERVICE" --since "$since" --no-pager 2> /dev/null | grep -iE 'error|panic|fatal' | tail -5 || true
  journald::warn_suppressed "$since"
}

app::main_pid() {
  systemctl show -p MainPID --value "$APP_SERVICE" 2> /dev/null || echo 0
}

# APP_HEALTH_URL があれば、HTTP で何か返るまで待つ（404 でも起動はしている）。なければ 2 秒後に systemd の状態だけを見る
# 再起動の前と MainPID が変わったことも確かめる（古いプロセスの応答を、新しいプロセスの起動と取り違えないように）
app::wait_ready() {  # $1: 再起動の前の MainPID
  local old_pid=$1 i code pid
  if [[ -z ${APP_HEALTH_URL:-} ]]; then
    sleep 2
    sudo systemctl is-active --quiet "$APP_SERVICE" || return 1
    pid="$(app::main_pid)"
    [[ $pid != 0 && $pid != "$old_pid" ]] || { echo "MainPID が変わっていない（${pid}）" >&2; return 1; }
    return 0
  fi
  for (( i = 0; i < APP_START_TIMEOUT * 2; i++ )); do
    sudo systemctl is-active --quiet "$APP_SERVICE" || return 1
    pid="$(app::main_pid)"
    if [[ $pid == 0 || $pid == "$old_pid" ]]; then sleep 0.5; continue; fi
    code="$(curl -s -o /dev/null -m 1 -w '%{http_code}' "$APP_HEALTH_URL" || true)"
    if [[ $code != 000 ]]; then echo "応答あり（HTTP ${code}、約 $(( i / 2 )) 秒）"; return 0; fi
    sleep 0.5
  done
  echo "$APP_START_TIMEOUT 秒たっても $APP_HEALTH_URL が応答しない" >&2
  return 1
}

# --- journald ---
# journald は、1 つのサービスが短い間に大量に書くとログを捨てる（RateLimitBurst）。捨てるとエラーの集計が欠けるので警告する
journald::warn_suppressed() {  # $1: いつ以降を見るか（journalctl の --since の形式）
  local lines
  lines="$(sudo journalctl -u systemd-journald --since "$1" --no-pager 2> /dev/null | grep -i 'suppressed' || true)"
  [[ -z $lines ]] && return 0
  echo "警告: journald がログを捨てている。アプリのログからのエラーの集計は欠けている" >&2
  echo "$lines" | tail -3 >&2
}

# --- 反映した版の記録 ---
# bench がこのファイルを結果のディレクトリに写し、どの版を測ったかを残す
DEPLOYED_FILE=/var/lib/isucon-deploy/deployed

deployed::git_state() {  # $1: ディレクトリ。「<リポジトリ> <コミット> <clean|dirty>」を出す
  local top sha dirty=clean
  top="$(sudo -u "$APP_USER" git -C "$1" rev-parse --show-toplevel 2> /dev/null)" || { echo "$1 （git ではない）"; return 0; }
  sha="$(sudo -u "$APP_USER" git -C "$top" rev-parse --short HEAD 2> /dev/null || echo '-')"
  [[ -n $(sudo -u "$APP_USER" git -C "$top" status --porcelain --untracked-files=no 2> /dev/null) ]] && dirty=dirty
  echo "$top $sha $dirty"
}

deployed::record() {
  dry && return 0
  local repo app
  repo="$(deployed::git_state "$REPO_DIR")"
  app="$(deployed::git_state "$APP_DIR")"
  sudo mkdir -p "$(dirname "$DEPLOYED_FILE")"
  {
    echo "time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "server: ${NAME}（${ROLES}）"
    echo "steps: ${STEP_TIMES[*]:-なし}"
    echo "repo: $repo"
    # webapp がリポジトリの外の別の git にあるときだけ、別に書く
    [[ ${app%% *} == "${repo%% *}" ]] || echo "webapp: $app"
  } | sudo tee "$DEPLOYED_FILE" > /dev/null
}
