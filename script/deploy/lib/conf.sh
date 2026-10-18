# 設定ファイルの反映。conf/default/ と conf/<サーバー名>/ のファイルを、同じ絶対パスに置く（<サーバー名> が優先）。
# deploy が新しく作ったファイルはマニフェスト（CONF_MANIFEST）に記録し、conf/ から消えたらサーバーからも消す。
# もとからサーバーにあったファイル（nginx.conf など）は、conf/ から消しても消さない。
# 書き換えたり消したりした元のファイルは CONF_BACKUP に残し、conf::restore で戻せる

CONF_STATE_DIR=/var/lib/isucon-deploy
CONF_MANIFEST=$CONF_STATE_DIR/manifest
CONF_BACKUP="/var/backups/isucon-deploy/$(date +%Y%m%d-%H%M%S)"
CONF_CHANGED=()   # この実行で書き換えた・作った・消したファイル（conf/ からの相対パス。例: etc/nginx/nginx.conf）

conf::list() {  # conf/default と conf/<名前> にあるファイルの相対パス（重複なし）
  local d
  for d in default "$NAME"; do
    [[ -d $REPO_DIR/conf/$d ]] && (cd "$REPO_DIR/conf/$d" && find . -type f ! -name '.*' | sed 's#^\./##')
  done | sort -u
}

conf::matches() {  # $1: 相対パス、$2: 含める正規表現、$3: 除く正規表現（空なら除かない）
  [[ $1 =~ $2 ]] || return 1
  [[ -z $3 ]] || ! [[ $1 =~ $3 ]]
}

conf::backup() {  # $1: 相対パス。今のファイルを CONF_BACKUP に写す
  sudo mkdir -p "$(dirname "$CONF_BACKUP/$1")"
  sudo cp -p "/$1" "$CONF_BACKUP/$1"
}

conf::manifest() {  # マニフェストの中身（なければ空）
  sudo cat "$CONF_MANIFEST" 2> /dev/null || true
}

# $1 の正規表現に合い、$2 の正規表現（空なら除かない）に合わないファイルを反映する。
# $3 は反映待ちの印の名前で、最初にファイルを変える直前に印を付ける（reload や restart の前に止まっても、次の実行でやり直せるように）。
# 変わったファイルがあれば 0、なければ 1 を返す
conf::sync() {
  local include=$1 exclude=$2 key=$3 rel src dst changed=1
  local -A current=()

  while IFS= read -r rel; do
    conf::matches "$rel" "$include" "$exclude" || continue
    current[$rel]=1
    src="$REPO_DIR/conf/$NAME/$rel"; [[ -f $src ]] || src="$REPO_DIR/conf/default/$rel"
    dst="/$rel"
    if sudo test -f "$dst" && sudo cmp -s "$src" "$dst"; then continue; fi
    changed=0
    if sudo test -f "$dst"; then sudo diff -u "$dst" "$src" || true; else echo "新規: $dst"; fi
    dry && continue
    pending::mark "$key"
    if sudo test -f "$dst"; then
      conf::backup "$rel"
      sudo tee "$dst" < "$src" > /dev/null   # 中身だけ書き換え、所有者と権限は元のファイルのまま
    else
      # 作る前にマニフェストへ書き足す（作った直後に止まっても、後で conf/ から消したときに消せるように）
      echo "$rel" | sudo tee -a "$CONF_MANIFEST" > /dev/null
      sudo mkdir -p "$(dirname "$dst")"
      sudo install -m 644 "$src" "$dst"
    fi
    CONF_CHANGED+=("$rel")
  done < <(conf::list)

  # deploy が作ったが、今の conf/ にはないファイルを消す
  while IFS= read -r rel; do
    [[ -n $rel ]] && conf::matches "$rel" "$include" "$exclude" || continue
    [[ -z ${current[$rel]:-} ]] && sudo test -f "/$rel" || continue
    changed=0
    echo "削除: /${rel}（conf/ から消えた）"
    dry && continue
    pending::mark "$key"
    conf::backup "$rel"
    sudo rm -f "/$rel"
    CONF_CHANGED+=("$rel")
  done < <(conf::manifest)
  return $changed
}

conf::restore() {  # $1 の正規表現に合う、この実行で変えたファイルを元に戻す
  local rel
  for rel in "${CONF_CHANGED[@]}"; do
    [[ $rel =~ $1 ]] || continue
    if sudo test -f "$CONF_BACKUP/$rel"; then sudo cp -p "$CONF_BACKUP/$rel" "/$rel"
    else sudo rm -f "/$rel"; fi
    echo "戻した: /$rel"
  done
}

conf::changed_under() {  # この実行で、$1 で始まるファイルを変えたか
  local rel
  for rel in "${CONF_CHANGED[@]}"; do [[ $rel == "$1"* ]] && return 0; done
  return 1
}

# マニフェストから、重複と、もうサーバーにないファイル（conf/ から消して削除したもの、巻き戻しで消したもの）を除く
conf::tidy_manifest() {
  dry && return 0
  sudo test -f "$CONF_MANIFEST" || return 0
  local rel
  while IFS= read -r rel; do
    [[ -n $rel ]] && sudo test -f "/$rel" && echo "$rel"
  done < <(conf::manifest | sort -u) | sudo tee "$CONF_MANIFEST.new" > /dev/null   # 読みながら同じファイルに書くと消えるので、別名で書いてから置き換える
  sudo mv "$CONF_MANIFEST.new" "$CONF_MANIFEST"
}

# --- 反映待ちの印 ---
# 設定ファイルを変えてから reload や restart が終わるまでの間に止まると、次の実行ではファイルに差分がないので reload されない。
# それを防ぐため、ファイルを変える直前に印を付け、reload や restart が成功したら外す。印が残っていれば、差分がなくてもやり直す

pending::mark() {  # $1: 名前（common、mysql、nginx）
  sudo mkdir -p "$CONF_STATE_DIR/pending"
  sudo touch "$CONF_STATE_DIR/pending/$1"
}

pending::exists() {  # $1: 名前
  sudo test -f "$CONF_STATE_DIR/pending/$1"
}

pending::clear() {  # $1: 名前
  sudo rm -f "$CONF_STATE_DIR/pending/$1"
}
