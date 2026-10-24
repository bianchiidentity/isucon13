#!/usr/bin/env bash
# 1 台目（このサーバー）と同じリポジトリの状態を、ほかのサーバーに作る。1 台目を git にした後に、1 台目で 1 回実行する
#
# 使い方（手元から ssh -A で 1 台目に入り、ログインしたユーザーのまま）:
#   sudo --preserve-env=SSH_AUTH_SOCK /home/isucon/isucon13/script/setup-repo/join.sh [--login=ubuntu] [--dry-run] \
#     isu1=192.168.0.11 isu2=192.168.0.12 isu3=192.168.0.13
#
# 名前=IP を全台ぶん並べる（このサーバー自身も）。名前は ./deploy --server= と conf/<名前>/ に使う。
# ほかのサーバーへの最初の接続には、転送した手元の鍵で --login のユーザーとして入る（isucon に切り替えると転送が切れるので root で動かす）。
# 何度実行しても同じ結果になる。済んだ段は飛ばす
set -euo pipefail

SETUP_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SETUP_DIR/../.." && pwd)"
source "$REPO_DIR/script/lib/common.sh"
# shellcheck source=../deploy/deploy.env
source "$REPO_DIR/script/deploy/deploy.env"

WEBAPP_LINK=/home/isucon/webapp   # systemd や env.sh が指す webapp の場所。リポジトリの webapp へのリンクにする
LOGIN=ubuntu
DRY=0
PAIRS=()

as_app() { sudo -u "$APP_USER" -H "$@"; }
app_git() { as_app git -C "$REPO_DIR" "$@"; }

parse_args() {
  local arg
  for arg in "$@"; do
    case $arg in
      --login=*) LOGIN="${arg#*=}" ;;
      --dry-run) DRY=1 ;;
      *=*) PAIRS+=("$arg") ;;
      *) die "unknown argument: $arg（名前=IP で渡す）" ;;
    esac
  done
  if (( ${#PAIRS[@]} == 0 )); then
    die "名前=IP を 1 つ以上渡す"
  fi
  if (( EUID != 0 )); then
    die "sudo --preserve-env=SSH_AUTH_SOCK で実行する"
  fi
  APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
  KEY=$APP_HOME/.ssh/id_ed25519     # GitHub の deploy key。サーバー間の ssh にも使う
}

# 1 台目が、ほかの台に配れる状態か（鍵がある、push 済み、webapp がリンク）を確かめ、ORIGIN、BRANCH、SHA を決める
check_first_server() {
  if [[ ! -f $KEY ]]; then
    die "$KEY が無い。README の「1 台目」で鍵を作り、deploy key に登録する"
  fi

  ORIGIN="$(app_git remote get-url origin)"
  if [[ $ORIGIN != git@* ]]; then
    die "origin が ssh ではない（$ORIGIN）。git remote set-url origin git@github.com:<owner>/<repo>.git"
  fi

  if [[ -n $(app_git status --porcelain --untracked-files=no) ]]; then
    die "コミットしていない変更がある。commit と push をしてから実行する"
  fi

  if ! BRANCH="$(app_git symbolic-ref --short HEAD)"; then
    die "ブランチにいない"
  fi

  # ほかの台は GitHub から取るので、HEAD が push 済みである必要がある
  app_git fetch -q origin
  SHA="$(app_git rev-parse HEAD)"
  if [[ $SHA != "$(app_git rev-parse -q --verify "origin/$BRANCH" || true)" ]]; then
    die "HEAD が origin/$BRANCH と一致しない。push してから実行する"
  fi

  if [[ ! -L $WEBAPP_LINK || $(readlink -f "$WEBAPP_LINK") != "$REPO_DIR/webapp" ]]; then
    die "$WEBAPP_LINK がリポジトリの webapp へのリンクになっていない。先に 1 台目を git にする"
  fi

  if (( ! DRY )) && ! ssh-add -l > /dev/null 2>&1; then
    die "手元の鍵が転送されていない。手元から ssh -A で入り直し、sudo に --preserve-env=SSH_AUTH_SOCK を付ける"
  fi
}

# 全台の ~/.ssh/config に書く、名前と IP の対応（CONFIG_BLOCK）と、それを書くコマンド（UPDATE_CONFIG）を作る。
# どの台からでも ./deploy --server= を実行できるようにする。
# 印の行で囲んだ範囲だけを毎回書き直す（IP が変わっても、実行し直せば直る）
build_config() {
  local p b64
  CONFIG_BLOCK="# >>> setup-repo（join.sh が書き直す。手で直さない）"$'\n'
  for p in "${PAIRS[@]}"; do
    CONFIG_BLOCK+="Host ${p%%=*}"$'\n'"  HostName ${p#*=}"$'\n'"  User $APP_USER"$'\n'
    CONFIG_BLOCK+="  IdentityFile ~/.ssh/id_ed25519"$'\n'"  StrictHostKeyChecking accept-new"$'\n'
  done
  CONFIG_BLOCK+="# <<< setup-repo"
  b64="$(printf '%s\n' "$CONFIG_BLOCK" | base64 -w0)"
  # $1 の config から前の印の範囲を消し、新しい範囲を足す。このサーバーでも、ほかの台に送っても動く
  UPDATE_CONFIG='f=$1; touch "$f"; awk "/^# >>> setup-repo/{s=1} !s{print} /^# <<< setup-repo/{s=0}" "$f" > "$f.new"; echo '"$b64"' | base64 -d >> "$f.new"; mv "$f.new" "$f"; chmod 600 "$f"'
}

# このサーバーの isucon の ~/.ssh/config と authorized_keys
setup_local_ssh() {
  local ssh_dir=$APP_HOME/.ssh
  log "このサーバー: $APP_USER の ~/.ssh/config と authorized_keys"
  printf '%s\n' "$CONFIG_BLOCK" | sed -n 's/^Host /config: /p'
  if (( ! DRY )); then
    as_app bash -c "$UPDATE_CONFIG" _ "$ssh_dir/config"
  fi

  # 鍵は全台で共有するので、どの台からでも isu1 に入れるようにする（./deploy --server= は自分自身にも ssh する）
  if (( ! DRY )); then
    as_app touch "$ssh_dir/authorized_keys"
    as_app chmod 600 "$ssh_dir/authorized_keys"
  fi
  if ! grep -qxF "$(cat "$KEY.pub")" "$ssh_dir/authorized_keys" 2> /dev/null; then
    echo "authorized_keys に自分の鍵を足す"
    if (( ! DRY )); then
      as_app tee -a "$ssh_dir/authorized_keys" < "$KEY.pub" > /dev/null
    fi
  fi
}

# 手元の鍵で $LOGIN として入り、isucon に鍵（deploy key と、ほかの台からの ssh）、~/.ssh/config、GitHub の known_hosts を置く
remote_keys() {  # $1: IP
  local ip=$1 priv pub
  priv="$(base64 -w0 "$KEY")"
  pub="$(cat "$KEY.pub")"
  # shellcheck disable=SC2087  # 変数はこちらで展開してから送る
  ssh -o StrictHostKeyChecking=accept-new "$LOGIN@$ip" sudo bash -s <<EOF
set -euo pipefail
h=\$(getent passwd $APP_USER | cut -d: -f6)
install -d -m 700 -o $APP_USER -g $APP_USER "\$h/.ssh"
cd "\$h/.ssh"
touch authorized_keys known_hosts

if ! grep -qxF '$pub' authorized_keys; then
  echo '$pub' >> authorized_keys
fi

# 違う鍵が既にあれば、消さずに退避する（その台の人が自分で作った鍵かもしれない）
echo '$priv' | base64 -d > id_ed25519.new
if [ ! -e id_ed25519 ]; then
  mv id_ed25519.new id_ed25519
  echo '鍵を置いた'
elif cmp -s id_ed25519.new id_ed25519; then
  rm id_ed25519.new
else
  bak=id_ed25519.bak.\$(date +%Y%m%d-%H%M%S)
  mv id_ed25519 "\$bak"
  if [ -e id_ed25519.pub ]; then
    mv id_ed25519.pub "\$bak.pub"
  fi
  mv id_ed25519.new id_ed25519
  echo "違う鍵があったので ~/.ssh/\$bak に退避し、共有の鍵を置いた"
fi
echo '$pub' > id_ed25519.pub

if ! grep -q '^github.com ' known_hosts; then
  ssh-keyscan -t ed25519 github.com 2> /dev/null >> known_hosts
fi

bash -c '$UPDATE_CONFIG' _ config
chmod 600 id_ed25519 authorized_keys
chown $APP_USER:$APP_USER id_ed25519 id_ed25519.pub authorized_keys known_hosts config
EOF
}

# isucon で入り、clone してブランチを合わせ、webapp をリポジトリへのリンクにする
remote_repo() {  # $1: 名前
  # shellcheck disable=SC2087
  as_app ssh -o BatchMode=yes "$1" bash -s <<EOF
set -euo pipefail
if [ -d '$REPO_DIR/.git' ]; then
  cd '$REPO_DIR'
  git fetch -q origin
else
  git clone -q '$ORIGIN' '$REPO_DIR'
  cd '$REPO_DIR'
fi
git checkout -q '$BRANCH'
git merge -q --ff-only 'origin/$BRANCH'
if [ "\$(git rev-parse HEAD)" != '$SHA' ]; then
  echo "HEAD が 1 台目と一致しない: \$(git rev-parse --short HEAD)" >&2
  exit 1
fi
echo "リポジトリ: $BRANCH \$(git log -1 --format='%h %s')"

# 途中で失敗しても、やり直せば続きから進む。アプリを止めたら印を書き、起動したら消す
was_active='$REPO_DIR/.git/setup-repo-app-was-active'
start_if_stopped() {
  if [ -e "\$was_active" ]; then
    sudo systemctl start '$APP_SERVICE'
    rm "\$was_active"
  fi
}

if [ -L '$WEBAPP_LINK' ] && [ "\$(readlink -f '$WEBAPP_LINK')" = '$REPO_DIR/webapp' ]; then
  start_if_stopped
  echo "webapp はリンク済み。$APP_SERVICE: \$(systemctl is-active '$APP_SERVICE' || true)"
  exit 0
elif [ -d '$WEBAPP_LINK' ] && [ ! -L '$WEBAPP_LINK' ] && [ ! -e '$WEBAPP_LINK.orig' ]; then
  from='$WEBAPP_LINK'           # 初回
elif [ ! -e '$WEBAPP_LINK' ] && [ -d '$WEBAPP_LINK.orig' ]; then
  from='$WEBAPP_LINK.orig'      # 前の実行が、移した後に止まった
else
  echo '$WEBAPP_LINK と $WEBAPP_LINK.orig が想定外の状態。中身を確かめ、要らないほうを消してから実行する' >&2
  ls -ld '$WEBAPP_LINK' '$WEBAPP_LINK.orig' >&2 || true
  exit 1
fi

# git に入れなかったもの（ビルドしたバイナリ、依存のライブラリ、データ）を元の webapp から写す。追跡しているファイルは上書きしない。
# アプリが動いたままでも読むだけなので、止める前に写す。
# 写すのはリポジトリにある名前だけ。リポジトリで消したもの（使わない言語の実装）まで写すと、
# 中の .gitignore が無いので node_modules などが未追跡で残る
for src in "\$from"/* "\$from"/.[!.]*; do
  name=\$(basename "\$src")
  if [ "\$name" = .git ] || [ ! -e "$REPO_DIR/webapp/\$name" ]; then
    continue
  fi
  rsync -a --ignore-existing "\$src" '$REPO_DIR/webapp/'
done
git clean -fdq -- webapp   # 消したファイルを写していたら消す
if [ -n "\$(git status --porcelain -- webapp)" ]; then
  echo "webapp に未追跡・変更のファイルがある:" >&2
  git status --short -- webapp | head >&2
fi

if [ "\$from" = '$WEBAPP_LINK' ]; then
  if [ "\$(systemctl is-active '$APP_SERVICE' || true)" = active ]; then
    touch "\$was_active"
    sudo systemctl stop '$APP_SERVICE'
  fi
  mv '$WEBAPP_LINK' '$WEBAPP_LINK.orig'
fi
ln -s '$REPO_DIR/webapp' '$WEBAPP_LINK'
echo "webapp をリンクにした（元は $WEBAPP_LINK.orig）"
start_if_stopped
echo "$APP_SERVICE: \$(systemctl is-active '$APP_SERVICE' || true)"
EOF
}

main() {
  local p name ip my_ips names failed=()
  parse_args "$@"
  check_first_server
  build_config
  setup_local_ssh

  my_ips=" $(hostname -I) "
  for p in "${PAIRS[@]}"; do
    name=${p%%=*} ip=${p#*=}
    if [[ $my_ips == *" $ip "* ]]; then
      log "$name: このサーバーなので飛ばす"
      continue
    fi
    log "$name（$ip）"
    if (( DRY )); then
      echo "[dry-run] $LOGIN@$ip で $APP_USER に鍵を置き、$REPO_DIR に clone し（$BRANCH ${SHA:0:7}）、$WEBAPP_LINK をリンクにする"
      continue
    fi
    if ! remote_keys "$ip" || ! remote_repo "$name"; then
      failed+=("$name")
    fi
  done

  if (( ${#failed[@]} )); then
    die "失敗: ${failed[*]}。直してから、もう一度同じコマンドを実行する"
  fi
  names=$(printf '%s\n' "${PAIRS[@]}" | cut -d= -f1 | paste -sd,)
  log "完了。次は isucon で ./deploy --server=$names --dry-run を実行し、全台の差分を確かめる"
}

main "$@"
