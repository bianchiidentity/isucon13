#!/usr/bin/env bash
# 実サービスに触れず、版・ソース・起動成果物の不一致を検出する。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$ROOT/script/lib/common.sh"
source "$ROOT/script/deploy/lib/steps.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
REPO_DIR="$TEST_DIR/repo"
APP_DIR="$REPO_DIR/webapp/go"
APP_BINARY="$APP_DIR/isupipe"
APP_USER="test"
APP_SERVICE=isupipe-go.service
WORK_DIR="$TEST_DIR/work"
mkdir -p "$APP_DIR" "$WORK_DIR"
printf 'package main\n' > "$APP_DIR/main.go"
printf 'binary\n' > "$APP_BINARY"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m fixture
REVISION="$(git -C "$REPO_DIR" rev-parse HEAD)"
BUILD_REVISION=$REVISION
STAMP="$(app::source_hash)"
RUNNING_HASH="$(sha256sum "$APP_BINARY" | cut -d' ' -f1)"
app::build_info() { printf '\tbuild\tvcs.revision=%s\n\tbuild\tvcs.modified=true\n' "$BUILD_REVISION"; }
app::main_pid() { echo 123; }
sudo() {
  if [[ $1 == -u ]]; then shift 2; "$@"; return; fi
  case "$1 $2" in
    'cat /var/lib/isucon-deploy/app-source-sha256') printf '%s\n' "$STAMP" ;;
    'sha256sum /proc/123/exe') printf '%s  /proc/123/exe\n' "$RUNNING_HASH" ;;
    'systemctl is-active') return 0 ;;
    'systemctl daemon-reload') touch "$TEST_DIR/reloaded" ;;
    'cmp -s') return 1 ;;
    'install -D') shift; install "$@" ;;
    *) "$@" ;;
  esac
}
# /etc に書かず、生成された drop-in だけを確認する。
install() { cp "$4" "$TEST_DIR/dropin.conf"; }
expect_failure() {
  if (app::verify_running > "$TEST_DIR/output" 2>&1); then echo "expected failure: $1" >&2; exit 1; fi
  grep -Fq "$1" "$TEST_DIR/output" || { cat "$TEST_DIR/output"; exit 1; }
}
app::verify_running > /dev/null
BUILD_REVISION=wrong
expect_failure 'バイナリの版が不一致'
BUILD_REVISION=$REVISION
RUNNING_HASH=wrong
expect_failure '実行中バイナリとビルド成果物が不一致'
RUNNING_HASH="$(sha256sum "$APP_BINARY" | cut -d' ' -f1)"
printf '// changed\n' >> "$APP_DIR/main.go"
expect_failure 'ビルド後にソースが変わっている'
STAMP="$(app::source_hash)"
app::verify_running > /dev/null
app::configure_service
printf '[Service]\nWorkingDirectory=%s\nExecStart=\nExecStart=%s\n' "$APP_DIR" "$APP_BINARY" > "$TEST_DIR/expected"
cmp "$TEST_DIR/expected" "$TEST_DIR/dropin.conf"
[[ -f $TEST_DIR/reloaded ]]
dry() { return 0; }
rm "$TEST_DIR/reloaded"
step::app > /dev/null
[[ ! -f $TEST_DIR/reloaded ]]
echo 'PASS: matching build, revision mismatch, running binary mismatch, changed source, systemd override, dry-run'
