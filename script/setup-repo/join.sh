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
for arg in "$@"; do
  case $arg in
    --login=*) LOGIN="${arg#*=}" ;;
    --dry-run) DRY=1 ;;
    *=*) PAIRS+=("$arg") ;;
    *) die "unknown argument: $arg（名前=IP で渡す）" ;;
  esac
done
(( ${#PAIRS[@]} )) || die "名前=IP を 1 つ以上渡す"
(( EUID == 0 )) || die "sudo --preserve-env=SSH_AUTH_SOCK で実行する"

as_app() { sudo -u "$APP_USER" -H "$@"; }
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
KEY=$APP_HOME/.ssh/id_ed25519     # GitHub の deploy key。サーバー間の ssh にも使う

# --- 1 台目の確認 ---------------------------------------------------------------

[[ -f $KEY ]] || die "$KEY が無い。README の「1 台目」で鍵を作り、deploy key に登録する"
ORIGIN="$(as_app git -C "$REPO_DIR" remote get-url origin)"
[[ $ORIGIN == git@* ]] || die "origin が ssh ではない（$ORIGIN）。git remote set-url origin git@github.com:<owner>/<repo>.git"
[[ -z $(as_app git -C "$REPO_DIR" status --porcelain --untracked-files=no) ]] || die "コミットしていない変更がある。commit と push をしてから実行する"
BRANCH="$(as_app git -C "$REPO_DIR" symbolic-ref --short HEAD)" || die "ブランチにいない"
as_app git -C "$REPO_DIR" fetch -q origin
SHA="$(as_app git -C "$REPO_DIR" rev-parse HEAD)"
[[ $SHA == "$(as_app git -C "$REPO_DIR" rev-parse -q --verify "origin/$BRANCH" || true)" ]] \
  || die "HEAD が origin/$BRANCH と一致しない。push してから実行する（ほかのサーバーは GitHub から取る）"
[[ -L $WEBAPP_LINK && $(readlink -f "$WEBAPP_LINK") == "$REPO_DIR/webapp" ]] \
  || die "$WEBAPP_LINK がリポジトリの webapp へのリンクになっていない。先に 1 台目を git にする"
if (( ! DRY )) && ! ssh-add -l > /dev/null 2>&1; then
  die "手元の鍵が転送されていない。手元から ssh -A で入り直し、sudo に --preserve-env=SSH_AUTH_SOCK を付ける"
fi
MY_IPS=" $(hostname -I) "

# --- このサーバーの ssh の設定 ----------------------------------------------------

# 全台の ~/.ssh/config に書く、名前と IP の対応。どの台からでも ./deploy --server= を実行できるようにする。
# 印の行で囲んだ範囲だけを毎回書き直す（IP が変わっても、実行し直せば直る）
CONFIG_BLOCK="# >>> setup-repo（join.sh が書き直す。手で直さない）"$'\n'
for p in "${PAIRS[@]}"; do
  CONFIG_BLOCK+="Host ${p%%=*}"$'\n'"  HostName ${p#*=}"$'\n'"  User $APP_USER"$'\n'
  CONFIG_BLOCK+="  IdentityFile ~/.ssh/id_ed25519"$'\n'"  StrictHostKeyChecking accept-new"$'\n'
done
CONFIG_BLOCK+="# <<< setup-repo"
CONFIG_B64="$(printf '%s\n' "$CONFIG_BLOCK" | base64 -w0)"
# $1 の config から前の印の範囲を消し、新しい範囲を足す。root でも isucon でも動く
UPDATE_CONFIG='f=$1; touch "$f"; awk "/^# >>> setup-repo/{s=1} !s{print} /^# <<< setup-repo/{s=0}" "$f" > "$f.new"; echo '"$CONFIG_B64"' | base64 -d >> "$f.new"; mv "$f.new" "$f"; chmod 600 "$f"'

log "このサーバー: $APP_USER の ~/.ssh/config と authorized_keys"
SSH_DIR=$APP_HOME/.ssh
printf '%s\n' "$CONFIG_BLOCK" | sed -n 's/^Host /config: /p'
(( DRY )) || as_app bash -c "$UPDATE_CONFIG" _ "$SSH_DIR/config"
as_app touch "$SSH_DIR/authorized_keys"
as_app chmod 600 "$SSH_DIR/authorized_keys"
# 鍵は全台で共有するので、どの台からでも isu1 に入れるようにする（./deploy --server= は自分自身にも ssh する）
if ! grep -qxF "$(cat "$KEY.pub")" "$SSH_DIR/authorized_keys"; then
  echo "authorized_keys に自分の鍵を足す"
  (( DRY )) || as_app tee -a "$SSH_DIR/authorized_keys" < "$KEY.pub" > /dev/null
fi

# --- 各サーバー -----------------------------------------------------------------

# 手元の鍵で $LOGIN として入り、isucon に鍵（deploy key と、ほかの台からの ssh）、~/.ssh/config、GitHub の known_hosts を置く
remote_keys() {  # $1: IP
  local ip=$1 priv pub
  priv="$(base64 -w0 "$KEY")" pub="$(cat "$KEY.pub")"
  # shellcheck disable=SC2087  # 変数はこちらで展開してから送る
  ssh -o StrictHostKeyChecking=accept-new "$LOGIN@$ip" sudo bash -s <<EOF
set -euo pipefail
h=\$(getent passwd $APP_USER | cut -d: -f6)
install -d -m 700 -o $APP_USER -g $APP_USER "\$h/.ssh"
cd "\$h/.ssh"
touch authorized_keys known_hosts
grep -qxF '$pub' authorized_keys || echo '$pub' >> authorized_keys
echo '$priv' | base64 -d > id_ed25519.new
if cmp -s id_ed25519.new id_ed25519; then rm id_ed25519.new; else mv id_ed25519.new id_ed25519; echo '鍵を置いた'; fi
echo '$pub' > id_ed25519.pub
grep -q '^github.com ' known_hosts || ssh-keyscan -t ed25519 github.com 2> /dev/null >> known_hosts
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
  cd '$REPO_DIR'; git fetch -q origin
else
  git clone -q '$ORIGIN' '$REPO_DIR'; cd '$REPO_DIR'
fi
git checkout -q '$BRANCH'
git merge -q --ff-only 'origin/$BRANCH'
[ "\$(git rev-parse HEAD)" = '$SHA' ] || { echo "HEAD が 1 台目と一致しない: \$(git rev-parse --short HEAD)" >&2; exit 1; }
echo "リポジトリ: $BRANCH \$(git log -1 --format='%h %s')"

if [ -L '$WEBAPP_LINK' ] && [ "\$(readlink -f '$WEBAPP_LINK')" = '$REPO_DIR/webapp' ]; then
  echo "webapp はリンク済み"
  exit 0
fi
[ -e '$WEBAPP_LINK.orig' ] && { echo '$WEBAPP_LINK.orig が既にある。中身を確かめて、要らなければ消してから実行する' >&2; exit 1; }
active=\$(systemctl is-active '$APP_SERVICE' || true)
[ "\$active" = active ] && sudo systemctl stop '$APP_SERVICE'
mv '$WEBAPP_LINK' '$WEBAPP_LINK.orig'
ln -s '$REPO_DIR/webapp' '$WEBAPP_LINK'
# git に入れなかったもの（ビルドしたバイナリ、依存のライブラリ、データ）を元の webapp から写す。追跡しているファイルは上書きしない。
# 写すのはリポジトリにある名前だけ。リポジトリで消したもの（使わない言語の実装）まで写すと、
# 中の .gitignore が無いので node_modules などが未追跡で残る
for src in '$WEBAPP_LINK.orig'/* '$WEBAPP_LINK.orig'/.[!.]*; do
  name=\$(basename "\$src")
  [ "\$name" != .git ] && [ -e "$REPO_DIR/webapp/\$name" ] || continue
  rsync -a --ignore-existing "\$src" '$REPO_DIR/webapp/'
done
git clean -fdq -- webapp   # 消したファイルを写していたら消す
[ -z "\$(git status --porcelain -- webapp)" ] || { echo "webapp に未追跡・変更のファイルがある:" >&2; git status --short -- webapp | head >&2; }
echo "webapp をリンクにした（元は $WEBAPP_LINK.orig）"
[ "\$active" = active ] && sudo systemctl start '$APP_SERVICE'
echo "$APP_SERVICE: \$(systemctl is-active '$APP_SERVICE' || true)（実行前: \$active）"
EOF
}

failed=()
for p in "${PAIRS[@]}"; do
  name=${p%%=*} ip=${p#*=}
  if [[ $MY_IPS == *" $ip "* ]]; then log "$name: このサーバーなので飛ばす"; continue; fi
  log "$name（$ip）"
  if (( DRY )); then
    echo "[dry-run] $LOGIN@$ip で $APP_USER に鍵を置き、$REPO_DIR に clone し（$BRANCH ${SHA:0:7}）、$WEBAPP_LINK をリンクにする"
    continue
  fi
  remote_keys "$ip" || { failed+=("$name"); continue; }
  remote_repo "$name" || failed+=("$name")
done

(( ${#failed[@]} == 0 )) || die "失敗: ${failed[*]}。直してから、もう一度同じコマンドを実行する"
names=$(printf '%s\n' "${PAIRS[@]}" | cut -d= -f1 | paste -sd,)
log "完了。次は isucon で ./deploy --server=$names --dry-run を実行し、全台の差分を確かめる"
