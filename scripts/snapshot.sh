#!/usr/bin/env bash
# 私用ボードの閲覧用コピーを暗号化して secret gist に書き出す。
# 会社PCなど GitHub にログインしない端末から「読むだけ」で私用タスクを見るための仕組み。
#
#   ./scripts/snapshot.sh             # 書き出す（中身が変わっていなければ何もしない）
#   ./scripts/snapshot.sh --force     # 変わっていなくても書き出す
#   ./scripts/snapshot.sh --dry-run   # 暗号化前の JSON を表示するだけ（手元での確認用）
#
# 必要な値（scripts/snapshot.env か環境変数）:
#   SNAPSHOT_GIST_ID      書き出し先の secret gist の ID
#   SNAPSHOT_PASSPHRASE   暗号化の合言葉（会社PC側と同じもの）
# Project の ID は scripts/project.env（GitHub Actions では環境変数 PROJECT_ID）から読む。
#
# 暗号形式は openssl enc の AES-256-CBC / PBKDF2-SHA256 / 200000回（base64・1行）。
# 会社PC側の office.sh（openssl）とボード画面（WebCrypto）が同じ形式で復号する。
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SNAPSHOT_ENV="$SCRIPT_DIR/snapshot.env"
SNAPSHOT_FILE="life-snapshot.txt"
HASH_FILE="life-snapshot.hash"
PBKDF2_ITER=200000
KEEP_DONE_DAYS=14

MODE=write
case "${1:-}" in
  --dry-run) MODE=dry ;;
  --force) MODE=force ;;
  "") ;;
  *) die "不明な引数: $1" ;;
esac

[ -f "$ENV_FILE" ] && . "$ENV_FILE"
[ -f "$SNAPSHOT_ENV" ] && . "$SNAPSHOT_ENV"
: "${PROJECT_ID:?PROJECT_ID がありません（scripts/project.env か環境変数）}"
if [ "$MODE" != dry ]; then
  : "${SNAPSHOT_GIST_ID:?SNAPSHOT_GIST_ID がありません（scripts/snapshot.env か環境変数）}"
  : "${SNAPSHOT_PASSPHRASE:?SNAPSHOT_PASSPHRASE がありません（scripts/snapshot.env か環境変数）}"
fi
command -v gh >/dev/null 2>&1 || die "gh が見つかりません"
command -v jq >/dev/null 2>&1 || die "jq が見つかりません"

# Done は直近のものだけ載せる（会社PCのボードを軽く保つ）
cutoff=$(date -u -d "-${KEEP_DONE_DAYS} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
  || cutoff=$(date -u -v-"${KEEP_DONE_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)

json=$(fetch_items | jq --arg cut "$cutoff" '{
  version: 1,
  items: [.[] | select(.type == "Issue")
              | select(.status != "Done" or .updatedAt >= $cut)
              | {number, title, status, priority, due, labels, body, updatedAt, url}]
}')

# Pending は「何を待っているか」を添える（task.sh move --reason が残すコメント）
pending=$(printf '%s' "$json" | jq -r '.items[] | select(.status == "Pending") | "\(.number)\t\(.url)"')
while IFS=$'\t' read -r num url; do
  [ -n "$num" ] || continue
  reason=$(gh issue view "$url" --json comments \
    --jq '[.comments[].body | select(startswith("**Pending**:"))] | last // "" | sub("^\\*\\*Pending\\*\\*: *"; "")' \
    2>/dev/null || true)
  [ -n "$reason" ] || continue
  json=$(printf '%s' "$json" | jq --argjson n "$num" --arg r "$reason" \
    '(.items[] | select(.number == $n)) += {pendingReason: $r}')
done <<EOF
$pending
EOF

# 会社PCからは GitHub のリンクを開けないので URL は載せない
json=$(printf '%s' "$json" | jq -c '.items |= map(del(.url))')

if [ "$MODE" = dry ]; then
  printf '%s\n' "$json" | jq .
  exit 0
fi

# 中身が変わっていなければ gist を更新しない（履歴を増やさないため）。
# 比較には合言葉付きのハッシュ（HMAC）を使い、平文のハッシュは外に出さない。
hash=$(printf '%s' "$json" | openssl dgst -sha256 -hmac "$SNAPSHOT_PASSPHRASE" | awk '{print $NF}')
if [ "$MODE" != force ]; then
  prev=$(gh api "gists/$SNAPSHOT_GIST_ID" --jq ".files[\"$HASH_FILE\"].content // \"\"" 2>/dev/null || true)
  if [ "$prev" = "$hash" ]; then
    echo "snapshot: 変更なし"
    exit 0
  fi
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cipher=$(printf '%s' "$json" | jq -c --arg now "$now" '. + {generatedAt: $now}' \
  | SNAPSHOT_PASSPHRASE="$SNAPSHOT_PASSPHRASE" openssl enc -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" \
      -md sha256 -salt -a -A -pass env:SNAPSHOT_PASSPHRASE)
[ -n "$cipher" ] || die "暗号化に失敗しました"

jq -n --arg f "$SNAPSHOT_FILE" --arg c "$cipher" --arg hf "$HASH_FILE" --arg h "$hash" \
  '{files: {($f): {content: $c}, ($hf): {content: $h}}}' \
  | gh api -X PATCH "gists/$SNAPSHOT_GIST_ID" --input - >/dev/null

echo "snapshot: 書き出しました ($(printf '%s' "$json" | jq '.items | length') 件, $now)"
