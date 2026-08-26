#!/usr/bin/env bash
# GitHub 側（リポジトリ / ラベル / Projects v2）を一括で構築する。
# 使い方: ./scripts/bootstrap.sh [--repo life] [--title "life ロードマップ"] [--push]
#         ./scripts/bootstrap.sh --labels-only   # ラベルだけ貼り直す（Project は触らない）
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

REPO_NAME="life"
PROJECT_TITLE="life ロードマップ"
DO_PUSH=0
LABELS_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_NAME="$2"; shift 2 ;;
    --title) PROJECT_TITLE="$2"; shift 2 ;;
    --push) DO_PUSH=1; shift ;;
    --labels-only) LABELS_ONLY=1; shift ;;
    *) die "不明な引数: $1" ;;
  esac
done

require_gh
command -v jq >/dev/null 2>&1 || die "jq が見つかりません。"

OWNER=$(gh api user --jq .login)
info "owner: $OWNER"

# ---------- 1. リポジトリ ----------
if gh repo view "$OWNER/$REPO_NAME" >/dev/null 2>&1; then
  info "リポジトリは既にあります: $OWNER/$REPO_NAME"
else
  info "リポジトリを作成します: $OWNER/$REPO_NAME (private)"
  gh repo create "$OWNER/$REPO_NAME" --private \
    --description "仕事からプライベートまで、すべてのタスクを Issues + Projects で一元管理する" >/dev/null
fi

cd "$REPO_ROOT"
[ -d .git ] || { info "git init"; git init -q -b main; }
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "https://github.com/$OWNER/$REPO_NAME.git"
else
  git remote add origin "https://github.com/$OWNER/$REPO_NAME.git"
fi

# Issue テンプレートを使うには Issues が有効である必要がある
gh api -X PATCH "repos/$OWNER/$REPO_NAME" -F has_issues=true >/dev/null

# ---------- 2. ラベル ----------
sync_labels() {
info "ラベルを同期します"
awk '
  /^- name:/ { if (n != "") print n "\t" c "\t" d; n=$0; sub(/^- name: */,"",n); c=""; d="" }
  /^  color:/ { c=$0; sub(/^  color: */,"",c); gsub(/"/,"",c) }
  /^  description:/ { d=$0; sub(/^  description: */,"",d) }
  END { if (n != "") print n "\t" c "\t" d }
' "$REPO_ROOT/.github/labels.yml" | while IFS=$'\t' read -r name color desc; do
  [ -n "$name" ] || continue
  gh label create "$name" --repo "$OWNER/$REPO_NAME" --color "$color" \
    --description "$desc" --force >/dev/null && echo "   label: $name"
done
}

if [ "$LABELS_ONLY" = "1" ]; then
  sync_labels
  info "ラベルのみ同期しました（Project には触れていません）"
  exit 0
fi
sync_labels

# ---------- 3. Project ----------
EXISTING=$(gh project list --owner "$OWNER" --format json --limit 100 \
  | jq -r --arg t "$PROJECT_TITLE" '.projects[] | select(.title==$t) | .number' | head -1)

if [ -n "$EXISTING" ]; then
  info "Project は既にあります: #$EXISTING ($PROJECT_TITLE)"
  PROJECT_NUMBER="$EXISTING"
  PROJECT_JSON=$(gh project view "$PROJECT_NUMBER" --owner "$OWNER" --format json)
  PROJECT_ID=$(printf '%s' "$PROJECT_JSON" | jq -r .id)
  PROJECT_URL=$(printf '%s' "$PROJECT_JSON" | jq -r .url)
else
  info "Project を作成します: $PROJECT_TITLE"
  CREATED=$(gh project create --owner "$OWNER" --title "$PROJECT_TITLE" --format json)
  PROJECT_NUMBER=$(printf '%s' "$CREATED" | jq -r .number)
  PROJECT_ID=$(printf '%s' "$CREATED" | jq -r .id)
  PROJECT_URL=$(printf '%s' "$CREATED" | jq -r .url)
fi

# ---------- 4. Status フィールドを 4 段階に作り替える ----------
FIELDS=$(gh api graphql -f query='
  query($id:ID!) {
    node(id:$id) { ... on ProjectV2 {
      fields(first:50) { nodes {
        ... on ProjectV2FieldCommon { id name dataType }
        ... on ProjectV2SingleSelectField { id name options { id name } }
      } }
    } }
  }' -f id="$PROJECT_ID" --jq '.data.node.fields.nodes')

STATUS_FIELD_ID=$(printf '%s' "$FIELDS" | jq -r '.[] | select(.name=="Status") | .id')
[ -n "$STATUS_FIELD_ID" ] || die "Status フィールドが見つかりません"

info "Status を To do / Pending / In progress / Done に設定します"
STATUS_OPTS=$(gh api graphql -f query="
  mutation {
    updateProjectV2Field(input: {
      fieldId: \"$STATUS_FIELD_ID\"
      singleSelectOptions: [
        {name: \"To do\",       color: GRAY,  description: \"未着手。いつかやる〜今週やるまで全部ここ\"}
        {name: \"Pending\",     color: RED,   description: \"自分以外の要因で止まっている / 意図的に寝かせている\"}
        {name: \"In progress\", color: BLUE,  description: \"今まさに手を動かしている\"}
        {name: \"Done\",        color: GREEN, description: \"完了条件を満たした\"}
      ]
    }) { projectV2Field { ... on ProjectV2SingleSelectField { options { id name } } } }
  }" --jq '.data.updateProjectV2Field.projectV2Field.options')

opt() { printf '%s' "$STATUS_OPTS" | jq -r --arg n "$1" '.[] | select(.name==$n) | .id'; }
OPT_TODO=$(opt "To do")
OPT_PENDING=$(opt "Pending")
OPT_INPROGRESS=$(opt "In progress")
OPT_DONE=$(opt "Done")

# ---------- 5. Priority / Due フィールド ----------
PRIORITY_FIELD_ID=$(printf '%s' "$FIELDS" | jq -r '.[] | select(.name=="Priority") | .id')
if [ -z "$PRIORITY_FIELD_ID" ]; then
  info "Priority フィールドを作成します"
  PRIO_JSON=$(gh api graphql -f query="
    mutation {
      createProjectV2Field(input: {
        projectId: \"$PROJECT_ID\", dataType: SINGLE_SELECT, name: \"Priority\"
        singleSelectOptions: [
          {name: \"P0\", color: RED,    description: \"今日やる / 落とすと痛い\"}
          {name: \"P1\", color: YELLOW, description: \"今週やる\"}
          {name: \"P2\", color: GRAY,   description: \"いつかやる\"}
        ]
      }) { projectV2Field { ... on ProjectV2SingleSelectField { id options { id name } } } }
    }" --jq '.data.createProjectV2Field.projectV2Field')
  PRIORITY_FIELD_ID=$(printf '%s' "$PRIO_JSON" | jq -r .id)
  PRIO_OPTS=$(printf '%s' "$PRIO_JSON" | jq -c .options)
else
  PRIO_OPTS=$(printf '%s' "$FIELDS" | jq -c '.[] | select(.name=="Priority") | .options')
fi
popt() { printf '%s' "$PRIO_OPTS" | jq -r --arg n "$1" '.[] | select(.name==$n) | .id'; }
PRIO_P0=$(popt P0)
PRIO_P1=$(popt P1)
PRIO_P2=$(popt P2)

DUE_FIELD_ID=$(printf '%s' "$FIELDS" | jq -r '.[] | select(.name=="Due") | .id')
if [ -z "$DUE_FIELD_ID" ]; then
  info "Due フィールドを作成します"
  DUE_FIELD_ID=$(gh api graphql -f query="
    mutation {
      createProjectV2Field(input: {projectId: \"$PROJECT_ID\", dataType: DATE, name: \"Due\"})
      { projectV2Field { ... on ProjectV2FieldCommon { id } } }
    }" --jq '.data.createProjectV2Field.projectV2Field.id')
fi

# ---------- 6. リポジトリを Project に紐付け ----------
if gh project link "$PROJECT_NUMBER" --owner "$OWNER" --repo "$OWNER/$REPO_NAME" >/dev/null 2>&1; then
  info "リポジトリを Project にリンクしました"
else
  info "リンク済み（またはスキップ）"
fi

# ---------- 7. 設定を保存 ----------
cat > "$ENV_FILE" <<EOF
# scripts/bootstrap.sh が自動生成。手で編集しない。
OWNER="$OWNER"
REPO="$REPO_NAME"
PROJECT_NUMBER="$PROJECT_NUMBER"
PROJECT_ID="$PROJECT_ID"
PROJECT_URL="$PROJECT_URL"
STATUS_FIELD_ID="$STATUS_FIELD_ID"
OPT_TODO="$OPT_TODO"
OPT_PENDING="$OPT_PENDING"
OPT_INPROGRESS="$OPT_INPROGRESS"
OPT_DONE="$OPT_DONE"
PRIORITY_FIELD_ID="$PRIORITY_FIELD_ID"
PRIO_P0="$PRIO_P0"
PRIO_P1="$PRIO_P1"
PRIO_P2="$PRIO_P2"
DUE_FIELD_ID="$DUE_FIELD_ID"
EOF
info "設定を書き出しました: $ENV_FILE"

# Issue テンプレートのリンク先を実際の Project に差し替え
sed -i "s#https://github.com/users/OWNER_PLACEHOLDER/projects/PROJECT_NUMBER_PLACEHOLDER#$PROJECT_URL#" \
  "$REPO_ROOT/.github/ISSUE_TEMPLATE/config.yml" 2>/dev/null || true

if [ "$DO_PUSH" = "1" ]; then
  info "初回 push します"
  git add -A
  git commit -q -m "chore: setup task management with Issues + Projects" || true
  git push -u origin main
fi

cat <<EOF

============================================================
 セットアップ完了
============================================================
 リポジトリ : https://github.com/$OWNER/$REPO_NAME
 Project    : $PROJECT_URL

 残りは GitHub の画面でしかできない設定です（1回だけ）:

 1) Project を開き、ビュー名の右の v から Layout を Board に変更
 2) Group by に Status を指定 -> To do / Pending / In progress / Done の4列になる
 3) 各列の ... > Set limit で WIP 上限を設定（推奨: In progress = 5, Pending = 10）
 4) 右上 Workflows で以下を有効化:
      - Item added to project -> Set Status = To do
      - Item closed           -> Set Status = Done
      - Auto-add to project   -> リポジトリ $REPO_NAME の is:issue is:open

 以降は Claude に話しかけるだけで運用できます:
   「タスク追加: 賃貸の更新手続き」
   「今日のボード見せて」
   「#12 を進行中にして」
============================================================
EOF
