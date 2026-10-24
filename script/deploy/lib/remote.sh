# 複数台への反映（--server=）。各サーバーに ssh し、このサーバーの HEAD と同じコミットを反映させる。
# MySQL の役割のサーバーを 1 段目、それ以外を 2 段目にし、段の中は並列（--serial なら 1 台ずつ）で反映する

REMOTE_LOG_DIR=""   # サーバーごとのログと結果の置き場所
REMOTE_BRANCH=""
REMOTE_SHA=""
REMOTE_OPTS=()      # 各サーバーの ./deploy に渡すオプション

# 各サーバーで実行するコマンド。dry-run のときは、作業ツリーを動かさないように、一時的な worktree で差分だけを見る
remote::command() {  # $1: サーバー名
  local h=$1 opts="${REMOTE_OPTS[*]:-}"
  local fetch="set -e; cd '$REPO_DIR'; git fetch -q origin"
  if dry; then
    # 前の dry-run が途中で止まって残した worktree を片付けてから作る
    echo "$fetch; find /tmp -maxdepth 1 -name 'isucon-deploy-dry.*' -mmin +10 -exec rm -rf {} +; git worktree prune; \
      wt=/tmp/isucon-deploy-dry.\$\$; git worktree add -q --detach \"\$wt\" '$REMOTE_SHA'; \
      trap 'git -C \"$REPO_DIR\" worktree remove --force \"\$wt\"' EXIT; \
      cd \"\$wt\"; DEPLOY_ORIG_REPO='$REPO_DIR' ./deploy --local --name='$h' $opts"
  else
    echo "$fetch; git checkout -q '$REMOTE_BRANCH'; git merge -q --ff-only 'origin/$REMOTE_BRANCH'; \
      [ \"\$(git rev-parse HEAD)\" = '$REMOTE_SHA' ] || { echo 'HEAD が一致しない' >&2; exit 1; }; \
      ./deploy --local --name='$h' $opts"
  fi
}

remote::deploy_one() {  # $1: サーバー名。出力の行頭にサーバー名を付けて流し、ログファイルにも残す
  local h=$1
  # shellcheck disable=SC2029  # 変数はこちらで展開してから送る
  ssh -o BatchMode=yes "$h" "$(remote::command "$h")" 2>&1 | tee "$REMOTE_LOG_DIR/$h.log" | sed -u "s/^/[$h] /"
  return "${PIPESTATUS[0]}"
}

# $@ のサーバーに反映し、結果を「名前 終了コード 秒」で <名前>.result に書く。全部成功なら 0
remote::deploy_group() {
  local h failed=0
  for h in "$@"; do
    (
      start=$EPOCHREALTIME rc=0
      remote::deploy_one "$h" || rc=$?
      echo "$h $rc $(elapsed "$start")" > "$REMOTE_LOG_DIR/$h.result"
      exit "$rc"
    ) &
    if (( SERIAL )); then wait $! || return 1; fi
  done
  wait || true
  for h in "$@"; do
    [[ $(cut -d' ' -f2 "$REMOTE_LOG_DIR/$h.result" 2> /dev/null) == 0 ]] || failed=1
  done
  return $failed
}

remote::show_results() {  # $@: サーバー名
  local h name rc sec
  log "結果"
  for h in "$@"; do
    if [[ -f $REMOTE_LOG_DIR/$h.result ]]; then read -r name rc sec < "$REMOTE_LOG_DIR/$h.result"
    else name=$h rc="-" sec="-"; fi
    case $rc in
      0) printf '%-10s 成功  %s 秒\n' "$name" "$sec" ;;
      -) printf '%-10s 未実行（途中で止めたため）\n' "$name" ;;
      *) printf '%-10s 失敗  %s 秒  ログ: %s\n' "$name" "$sec" "$REMOTE_LOG_DIR/$name.log" ;;
    esac
  done
  for h in "$@"; do
    [[ -f $REMOTE_LOG_DIR/$h.result && $(cut -d' ' -f2 "$REMOTE_LOG_DIR/$h.result") != 0 ]] || continue
    echo; echo "-- [$h] ログの最後の 10 行"; tail -10 "$REMOTE_LOG_DIR/$h.log"
  done
}

# 他のサーバーは GitHub から取ってくるので、このサーバーの HEAD が push 済みである必要がある
remote::check_pushed() {
  [[ -z $(git -C "$REPO_DIR" status --porcelain --untracked-files=no) ]] || die "コミットしていない変更がある。commit と push をしてから実行する"
  REMOTE_BRANCH="$(git -C "$REPO_DIR" symbolic-ref --short HEAD)" || die "ブランチにいない"
  git -C "$REPO_DIR" fetch -q origin
  REMOTE_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
  local origin_sha
  origin_sha="$(git -C "$REPO_DIR" rev-parse -q --verify "origin/$REMOTE_BRANCH" || true)"
  # dry-run は取り込まないので、origin が進んでいるだけなら、本番で取り込んだ後と同じ origin の版で差分を見る
  if dry && [[ -n $origin_sha && $REMOTE_SHA != "$origin_sha" ]] \
    && git -C "$REPO_DIR" merge-base --is-ancestor "$REMOTE_SHA" "$origin_sha"; then
    echo "（dry-run）origin/$REMOTE_BRANCH が進んでいるので、その版（${origin_sha:0:7}）で差分を見る"
    REMOTE_SHA=$origin_sha
  fi
  [[ $REMOTE_SHA == "$origin_sha" ]] || die "HEAD が origin/$REMOTE_BRANCH と一致しない。push してから実行する"
}

remote::fan_out() {
  local h hosts=() first=() rest=()
  dry && REMOTE_OPTS+=(--dry-run)
  (( ALLOW_DROP )) && REMOTE_OPTS+=(--allow-drop)
  [[ -n $ONLY ]] && REMOTE_OPTS+=("--only=$ONLY")
  remote::check_pushed
  REMOTE_LOG_DIR="/tmp/isucon-deploy/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$REMOTE_LOG_DIR"

  # MySQL のサーバーを先にする（スキーマを変えてからアプリを再起動する）
  IFS=, read -ra hosts <<< "$SERVERS"
  for h in "${hosts[@]}"; do
    if role_has "$(roles_of "$h")" mysql; then first+=("$h"); else rest+=("$h"); fi
  done
  log "$REMOTE_BRANCH $(git -C "$REPO_DIR" log -1 --format='%h %s' "$REMOTE_SHA")"
  echo "1 段目（mysql）: ${first[*]:-なし}、2 段目: ${rest[*]:-なし}$( (( SERIAL )) && echo '（直列）' || echo '（並列）')"

  if (( ${#first[@]} )) && ! remote::deploy_group "${first[@]}"; then
    remote::show_results "${first[@]}" "${rest[@]}"
    die "1 段目で失敗したので、2 段目には反映していない"
  fi
  if (( ${#rest[@]} )) && ! remote::deploy_group "${rest[@]}"; then
    remote::show_results "${first[@]}" "${rest[@]}"
    die "失敗したサーバーがある。直してから、もう一度同じコマンドを実行する"
  fi
  remote::show_results "${first[@]}" "${rest[@]}"
}
