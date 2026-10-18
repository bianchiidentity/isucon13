#!/usr/bin/env bash
# E2E 実行環境の前提チェック。
#   usage: check_env.sh <e2e_dir> <url> [<url>...]
# <e2e_dir> には npm install 済み（@playwright/test 入り）のディレクトリを渡す。
# sudo が必要な修正は自分では実行せず、ユーザーに頼むコマンドとして表示する。
set -u
dir="${1:?usage: check_env.sh <e2e_dir> <url>...}"; shift
ng=0

echo "== node"
if command -v node >/dev/null; then node -v; else echo "NG: node がない"; ng=1; fi

echo "== 接続先"
for u in "$@"; do
  host=$(echo "$u" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')
  ip=$(getent hosts "$host" | awk '{print $1}' | head -1)
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$u")
  echo "$u -> ${ip:-名前解決できない} HTTP $code"
  [ -z "$ip" ] && { echo "  NG: /etc/hosts に $host を追加してもらう必要がある"; ng=1; }
  [ "$code" = "000" ] && { echo "  NG: 接続できない（サーバ停止 / セキュリティグループ / hosts を確認）"; ng=1; }
done

echo "== Chromium"
cd "$dir" || exit 1
if [ ! -d node_modules/@playwright/test ]; then
  echo "NG: $dir で npm install していない"; exit 1
fi
npx playwright install chromium >/dev/null 2>&1 || echo "WARN: chromium のダウンロードに失敗"
out=$(node -e "
const { chromium } = require('@playwright/test');
chromium.launch().then(b => b.close()).then(() => console.log('OK'), e => { console.log(e.message); process.exit(1) });
" 2>&1)
if echo "$out" | grep -q '^OK'; then
  echo "OK: Chromium 起動"
else
  echo "$out" | grep -m3 -E 'error while loading shared libraries|Host system is missing' || echo "$out" | tail -3
  echo "NG: Chromium の依存ライブラリが足りない。ユーザーに次を実行してもらう（sudo が必要）:"
  echo "  cd $(pwd) && sudo env \"PATH=\$PATH\" npx playwright install-deps chromium"
  ng=1
fi

echo "== 日本語フォント"
if fc-list :lang=ja 2>/dev/null | grep -q .; then echo "OK"; else
  echo "WARN: 日本語フォントがなくスクショが豆腐になる。install-deps で入るが、足りなければ: sudo apt install -y fonts-noto-cjk"
fi

exit $ng
