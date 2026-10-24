# 反映の前の git の取り込み（--no-pull で止める）。
# origin/<今のブランチ> を取り込み、main 以外のブランチなら origin/main もマージする。
# main にはチームで承認した改善が入るので、それを含めて測らないと今のスコアがわからない（TODO 8）。
# HEAD が変わったら ./deploy を実行し直す。bash はスクリプトを少しずつ読むので、実行中に deploy.sh が書き換わると壊れる

SYNC_MAIN=main

sync::git() { git -C "$REPO_DIR" "$@"; }

# $1: 切り替えるブランチ（空なら今のブランチ）、残り: 実行し直すときの ./deploy の引数
sync::run() {
  local target=$1 branch before; shift
  sync::git fetch -q origin
  if dry; then
    sync::show_pending "${target:-$(sync::git symbolic-ref --short -q HEAD || true)}"
    return 0
  fi
  # 切り替えだけでも deploy.sh が変わりうるので、切り替える前の HEAD と比べる
  before="$(sync::git rev-parse HEAD)"
  if [[ -n $target ]]; then sync::switch "$target"; fi
  branch="$(sync::git symbolic-ref --short -q HEAD)" \
    || die "ブランチにいない。--branch=<名前> で切り替えるか、--no-pull で今の作業ツリーを反映する"
  sync::merge "origin/${branch}"
  if [[ $branch != "$SYNC_MAIN" ]]; then sync::merge "origin/${SYNC_MAIN}"; fi
  if [[ $(sync::git rev-parse HEAD) != "$before" ]]; then
    log "取り込んだ（${branch}）"
    sync::git log --oneline "$before..HEAD" | head -20
    # --branch は済んだので外す（--no-pull と一緒には使えない）
    local a args=()
    for a in "$@"; do [[ $a == --branch=* ]] || args+=("$a"); done
    exec "$REPO_DIR/deploy" "${args[@]}" --no-pull
  fi
}

sync::switch() {  # $1: ブランチ
  if [[ -n $(sync::git status --porcelain --untracked-files=no) ]]; then
    die "コミットしていない変更がある。commit するか戻してから --branch=$1 で切り替える"
  fi
  sync::git checkout -q "$1" || die "$1 に切り替えられない"
}

# $1 をマージする（fast-forward できればそうなる）。衝突したら取り消して止まる
sync::merge() {  # $1: origin/<ブランチ>
  local conflicts
  if ! sync::git rev-parse -q --verify "$1" > /dev/null; then
    echo "${1} が無い（push していないブランチ）ので、取り込まない"
    return 0
  fi
  if sync::git merge-base --is-ancestor "$1" HEAD; then return 0; fi
  if ! sync::git merge -q --no-edit "$1"; then
    conflicts="$(sync::git diff --name-only --diff-filter=U | paste -sd' ' -)"
    # 途中のマージが残っていれば取り消し、マージする前の状態に戻す
    if sync::git rev-parse -q --verify MERGE_HEAD > /dev/null; then sync::git merge --abort; fi
    die "${1} をマージできない${conflicts:+（衝突: ${conflicts}）}。手でマージしてから実行するか、--no-pull で今の作業ツリーを反映する"
  fi
}

# dry-run は取り込まず、取り込む予定のコミットを表示する
sync::show_pending() {  # $1: ブランチ（空ならブランチにいない）
  local b=$1
  log "取り込む予定（dry-run なので取り込まない。下の差分には含まれない）"
  if [[ -z $b ]]; then echo "ブランチにいない"; return 0; fi
  if [[ $b != "$(sync::git symbolic-ref --short -q HEAD || true)" ]]; then echo "$b に切り替える"; fi
  if sync::git rev-parse -q --verify "origin/$b" > /dev/null; then
    sync::git log --oneline "HEAD..origin/$b" | sed "s|^|origin/$b: |" | head -20
  fi
  if [[ $b != "$SYNC_MAIN" ]]; then
    sync::git log --oneline "HEAD..origin/$SYNC_MAIN" | sed "s|^|origin/$SYNC_MAIN: |" | head -20
  fi
}
