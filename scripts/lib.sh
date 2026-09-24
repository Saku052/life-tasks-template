#!/usr/bin/env bash
# 共通処理。各スクリプトから source して使う。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/project.env"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">> $*" >&2; }

# Windows: winget でインストールした直後は既存シェルの PATH に反映されていないことがある
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    command -v gh >/dev/null 2>&1 || PATH="$PATH:/c/Program Files/GitHub CLI"
    if ! command -v jq >/dev/null 2>&1; then
      PATH="$PATH:$HOME/AppData/Local/Microsoft/WinGet/Links"
      for _d in "$HOME"/AppData/Local/Microsoft/WinGet/Packages/jqlang.jq*/; do
        [ -d "$_d" ] && PATH="$PATH:${_d%/}"
      done
      unset _d
    fi
    export PATH
    ;;
esac

require_gh() {
  command -v gh >/dev/null 2>&1 || die "gh が見つかりません。https://cli.github.com/ からインストールしてください。"
  gh auth status >/dev/null 2>&1 || die "gh が未認証です。'gh auth login' を実行してください。"
  if ! gh auth status 2>&1 | grep -q "'project'"; then
    die "gh のトークンに project スコープがありません。'gh auth refresh -s project,read:project' を実行してください。"
  fi
}

load_env() {
  [ -f "$ENV_FILE" ] || die "$ENV_FILE がありません。先に scripts/bootstrap.sh を実行してください。"
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  : "${OWNER:?}" "${REPO:?}" "${PROJECT_NUMBER:?}" "${PROJECT_ID:?}" "${STATUS_FIELD_ID:?}"
}

# ステータス名 -> single select option id
status_option_id() {
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    "to do"|todo|"to-do") echo "$OPT_TODO" ;;
    pending|hold|"on hold") echo "$OPT_PENDING" ;;
    "in progress"|inprogress|"in-progress"|doing|wip) echo "$OPT_INPROGRESS" ;;
    done|complete|completed|closed) echo "$OPT_DONE" ;;
    *) die "不明なステータス: $1 (To do / Pending / In progress / Done)" ;;
  esac
}

status_canonical() {
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    "to do"|todo|"to-do") echo "To do" ;;
    pending|hold|"on hold") echo "Pending" ;;
    "in progress"|inprogress|"in-progress"|doing|wip) echo "In progress" ;;
    done|complete|completed|closed) echo "Done" ;;
    *) die "不明なステータス: $1" ;;
  esac
}

priority_option_id() {
  case "$(echo "$1" | tr '[:lower:]' '[:upper:]')" in
    P0|HIGH|高) echo "$PRIO_P0" ;;
    P1|MID|MEDIUM|中) echo "$PRIO_P1" ;;
    P2|LOW|低) echo "$PRIO_P2" ;;
    *) die "不明な優先度: $1 (P0 / P1 / P2)" ;;
  esac
}

# issue番号 -> project item id （未追加なら空文字）
item_id_for_issue() {
  local num="$1"
  gh api graphql -f query='
    query($owner:String!, $repo:String!, $num:Int!) {
      repository(owner:$owner, name:$repo) {
        issue(number:$num) {
          projectItems(first:10) { nodes { id project { id } } }
        }
      }
    }' -f owner="$OWNER" -f repo="$REPO" -F num="$num" \
    --jq ".data.repository.issue.projectItems.nodes[] | select(.project.id==\"$PROJECT_ID\") | .id" 2>/dev/null | head -1
}

# 全アイテムを JSON 配列で取得（ページング対応）
fetch_items() {
  local after="" out="[]" page args
  while :; do
    # 初回は after 変数を渡さない（GraphQL 側で null 扱いになる）
    args=(api graphql -f id="$PROJECT_ID")
    [ -n "$after" ] && args+=(-f after="$after")
    page=$(gh "${args[@]}" -f query='
      query($id:ID!, $after:String) {
        node(id:$id) {
          ... on ProjectV2 {
            items(first:100, after:$after) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id
                updatedAt
                content {
                  __typename
                  ... on Issue {
                    number title url state updatedAt
                    labels(first:10) { nodes { name } }
                    body
                  }
                  ... on DraftIssue { title body }
                }
                fieldValues(first:20) {
                  nodes {
                    ... on ProjectV2ItemFieldSingleSelectValue {
                      name field { ... on ProjectV2FieldCommon { name } }
                    }
                    ... on ProjectV2ItemFieldDateValue {
                      date field { ... on ProjectV2FieldCommon { name } }
                    }
                  }
                }
              }
            }
          }
        }
      }' --jq '.data.node.items')
    out=$(printf '%s\n%s' "$out" "$page" | jq -s '.[0] + [.[1].nodes[] | {
      itemId: .id,
      type: (.content.__typename // "Unknown"),
      number: (.content.number // null),
      title: (.content.title // "(no title)"),
      url: (.content.url // null),
      state: (.content.state // null),
      updatedAt: (.content.updatedAt // .updatedAt),
      labels: [(.content.labels.nodes // [])[].name],
      body: (.content.body // ""),
      status: ([.fieldValues.nodes[] | select(.field.name=="Status") | .name][0] // "(未設定)"),
      priority: ([.fieldValues.nodes[] | select(.field.name=="Priority") | .name][0] // ""),
      due: ([.fieldValues.nodes[] | select(.field.name=="Due") | .date][0] // "")
    }]')
    [ "$(printf '%s' "$page" | jq -r '.pageInfo.hasNextPage')" = "true" ] || break
    after=$(printf '%s' "$page" | jq -r '.pageInfo.endCursor')
  done
  printf '%s' "$out"
}
