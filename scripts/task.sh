#!/usr/bin/env bash
# 日々のタスク操作はすべてこのスクリプト経由で行う。
# Claude はこれを呼ぶだけでよく、GraphQL を直接叩く必要はない。
#
#   ./scripts/task.sh board
#   ./scripts/task.sh add --title "賃貸の更新手続き" --label Life --priority P1 \
#        --summary "契約満了 2026/03/31。2ヶ月前までに意思表示が必要。" \
#        --check "管理会社に連絡" --check "更新契約書を返送" --dod "控えをスキャンして保管"
#   ./scripts/task.sh start 12
#   ./scripts/task.sh move 12 pending --reason "先方の返事待ち"
#   ./scripts/task.sh check 12 "更新契約書"
#   ./scripts/task.sh done 12
#   ./scripts/task.sh merge 12 15 18
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"
  cat <<'EOF'

サブコマンド:
  board                      ステータス別のカンバンを表示
  list [--status S] [--label L] [--json]
  show <issue>               Issue 本文とチェックリスト進捗
  add ...                    Issue を作って Project に載せる
  move <issue> <status>      To do / Pending / In progress / Done
  start <issue>              = move <issue> "In progress"
  done <issue>               チェックリスト全消化を確認して close + Done
  check <issue> <部分一致文字列>   チェックリストの項目に [x] を付ける
  uncheck <issue> <部分一致文字列>
  note <issue> <本文>        Issue にコメント（作業ログ）
  due <issue> <YYYY-MM-DD>   期限を設定（Project の Due と本文の「## 期限」を更新）
  stale [days]               指定日数動いていないものを列挙（既定 7）
  merge <keep> <dup>...      重複 Issue を keep に統合して close
  sync                       Project 未登録の open issue をまとめて追加
EOF
}

# ---------------------------------------------------------------- helpers

ensure_item() {
  # issue番号を受け取り、Project item id を返す（未登録なら追加する）
  local num="$1" id
  id=$(item_id_for_issue "$num")
  if [ -z "$id" ]; then
    local url="https://github.com/$OWNER/$REPO/issues/$num"
    id=$(gh project item-add "$PROJECT_NUMBER" --owner "$OWNER" --url "$url" --format json | jq -r .id)
  fi
  printf '%s' "$id"
}

set_status() {
  local item="$1" status="$2"
  gh project item-edit --id "$item" --project-id "$PROJECT_ID" \
    --field-id "$STATUS_FIELD_ID" --single-select-option-id "$(status_option_id "$status")" >/dev/null
}

issue_body() { gh issue view "$1" --repo "$OWNER/$REPO" --json body --jq .body; }

checklist_progress() {
  # stdin: body -> "done/total"
  local body total done_
  body=$(cat)
  total=$(printf '%s\n' "$body" | grep -cE '^\s*- \[[ xX]\]' || true)
  done_=$(printf '%s\n' "$body" | grep -cE '^\s*- \[[xX]\]' || true)
  printf '%s/%s' "$done_" "$total"
}

# ---------------------------------------------------------------- board

cmd_board() {
  local items
  items=$(fetch_items)
  echo "# $PROJECT_URL"
  echo
  local s
  for s in "To do" "Pending" "In progress" "Done"; do
    local n
    n=$(printf '%s' "$items" | jq -r --arg s "$s" '[.[] | select(.status==$s)] | length')
    printf '## %s (%s)\n' "$s" "$n"
    printf '%s' "$items" | jq -r --arg s "$s" '
      [.[] | select(.status==$s)]
      | sort_by(( .priority | if .=="P0" then 0 elif .=="P1" then 1 elif .=="P2" then 2 else 3 end ),
                ( .due | if .=="" then "9999-99-99" else . end ))
      | .[]
      | "  " + (if .number then "#" + (.number|tostring) else "(draft)" end)
        + " " + .title
        + (if .priority != "" then "  [" + .priority + "]" else "" end)
        + (if .due != "" then "  due:" + .due else "" end)
        + (if (.labels|length) > 0 then "  {" + (.labels|join(",")) + "}" else "" end)'
    echo
  done
}

# ---------------------------------------------------------------- list

cmd_list() {
  local status="" label="" as_json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) status=$(status_canonical "$2"); shift 2 ;;
      --label) label="$2"; shift 2 ;;
      --json) as_json=1; shift ;;
      *) die "不明な引数: $1" ;;
    esac
  done
  local items
  items=$(fetch_items \
    | jq --arg s "$status" '[.[] | select($s=="" or .status==$s)]' \
    | jq --arg l "$label" '[.[] | select($l=="" or (.labels | index($l)))]')
  if [ "$as_json" = "1" ]; then
    printf '%s\n' "$items" | jq '[.[] | del(.body)]'
  else
    printf '%s' "$items" | jq -r '.[] |
      (if .number then "#" + (.number|tostring) else "(draft)" end)
      + "\t" + .status + "\t" + .title'
  fi
}

# ---------------------------------------------------------------- show

cmd_show() {
  local num="${1:?issue番号が必要です}"
  gh issue view "$num" --repo "$OWNER/$REPO" --json number,title,state,labels,url,body \
    --template '#{{.number}} {{.title}}  [{{.state}}]
{{.url}}
labels: {{range .labels}}{{.name}} {{end}}

{{.body}}
'
  local prog
  prog=$(issue_body "$num" | checklist_progress)
  echo
  echo "checklist: $prog"
  local item
  item=$(item_id_for_issue "$num")
  if [ -n "$item" ]; then
    fetch_items | jq -r --arg n "$num" '.[] | select((.number|tostring)==$n)
      | "status: " + .status + "  priority: " + .priority + "  due: " + .due'
  else
    echo "status: (Project 未登録)"
  fi
}

# ---------------------------------------------------------------- add

cmd_add() {
  local title="" summary="" dod="" due="" priority="" status="To do"
  local labels=() checks=() notes=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --summary) summary="$2"; shift 2 ;;
      --check) checks+=("$2"); shift 2 ;;
      --dod) dod="$2"; shift 2 ;;
      --due) due="$2"; shift 2 ;;
      --label) labels+=("$2"); shift 2 ;;
      --priority) priority="$2"; shift 2 ;;
      --status) status=$(status_canonical "$2"); shift 2 ;;
      --notes) notes="$2"; shift 2 ;;
      *) die "不明な引数: $1" ;;
    esac
  done
  [ -n "$title" ] || die "--title は必須です"
  [ -n "$summary" ] || die "--summary は必須です（未来の自分が読んで思い出せる粒度で）"
  [ "${#checks[@]}" -gt 0 ] || die "--check を最低1つ指定してください"

  local tmp
  tmp=$(mktemp)
  {
    echo "## 概要"
    echo
    echo "$summary"
    echo
    echo "## 完了に必要な手順"
    echo
    local c
    for c in "${checks[@]}"; do echo "- [ ] $c"; done
    if [ -n "$dod" ]; then
      echo
      echo "## 完了条件"
      echo
      echo "$dod"
    fi
    if [ -n "$due" ]; then
      echo
      echo "## 期限"
      echo
      echo "$due"
    fi
    if [ -n "$notes" ]; then
      echo
      echo "## メモ"
      echo
      echo "$notes"
    fi
  } > "$tmp"

  local args=(issue create --repo "$OWNER/$REPO" --title "$title" --body-file "$tmp")
  local l
  for l in "${labels[@]:-}"; do [ -n "$l" ] && args+=(--label "$l"); done

  local url
  url=$(gh "${args[@]}")
  rm -f "$tmp"
  local num="${url##*/}"

  local item
  item=$(gh project item-add "$PROJECT_NUMBER" --owner "$OWNER" --url "$url" --format json | jq -r .id)
  set_status "$item" "$status"
  [ -n "$priority" ] && gh project item-edit --id "$item" --project-id "$PROJECT_ID" \
    --field-id "$PRIORITY_FIELD_ID" --single-select-option-id "$(priority_option_id "$priority")" >/dev/null
  [ -n "$due" ] && gh project item-edit --id "$item" --project-id "$PROJECT_ID" \
    --field-id "$DUE_FIELD_ID" --date "$due" >/dev/null

  echo "created #$num [$status] $title"
  echo "$url"
}

# ---------------------------------------------------------------- status 変更

cmd_move() {
  local num="${1:?issue番号}" raw="${2:?status}"; shift 2
  local reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) reason="$2"; shift 2 ;;
      *) die "不明な引数: $1" ;;
    esac
  done
  local status item
  status=$(status_canonical "$raw")
  item=$(ensure_item "$num")
  set_status "$item" "$status"
  if [ -n "$reason" ]; then
    gh issue comment "$num" --repo "$OWNER/$REPO" --body "**$status**: $reason" >/dev/null
  fi
  if [ "$status" = "Done" ]; then
    gh issue close "$num" --repo "$OWNER/$REPO" >/dev/null 2>&1 || true
  else
    gh issue reopen "$num" --repo "$OWNER/$REPO" >/dev/null 2>&1 || true
  fi
  echo "#$num -> $status"
}

cmd_done() {
  local num="${1:?issue番号}" force=0
  shift || true
  [ "${1:-}" = "--force" ] && force=1
  local prog
  prog=$(issue_body "$num" | checklist_progress)
  if [ "$force" = "0" ] && [ "${prog%%/*}" != "${prog##*/}" ]; then
    echo "未消化のチェックリストがあります ($prog)。" >&2
    issue_body "$num" | grep -E '^\s*- \[ \]' >&2 || true
    echo "それでも完了にするなら --force を付けてください。" >&2
    exit 1
  fi
  cmd_move "$num" Done
}

# ---------------------------------------------------------------- チェックリスト

toggle_check() {
  # $3 = 変更前の状態 (" " or "x"), $4 = 変更後の状態
  local num="$1" needle="$2" from="$3" to="$4" tmp body out
  body=$(issue_body "$num")
  out=$(printf '%s\n' "$body" | awk -v needle="$needle" -v from="$from" -v to="$to" '
    BEGIN { marker = "- [" from "]" }
    {
      if (!hit && index(tolower($0), marker) > 0 && index($0, needle) > 0) {
        sub(/\[[ xX]\]/, "[" to "]"); hit = 1
      }
      print
    }
    END { if (!hit) exit 3 }
  ') || die "「$needle」を含む $( [ "$from" = " " ] && echo 未チェック || echo チェック済み ) の項目が #$num に見つかりません"
  tmp=$(mktemp)
  printf '%s\n' "$out" > "$tmp"
  gh issue edit "$num" --repo "$OWNER/$REPO" --body-file "$tmp" >/dev/null
  rm -f "$tmp"
  echo "#$num checklist: $(printf '%s\n' "$out" | checklist_progress)"
}

cmd_check()   { toggle_check "${1:?issue番号}" "${2:?検索文字列}" " " "x"; }
cmd_uncheck() { toggle_check "${1:?issue番号}" "${2:?検索文字列}" "x" " "; }

cmd_note() {
  local num="${1:?issue番号}"; shift
  [ $# -gt 0 ] || die "コメント本文が必要です"
  gh issue comment "$num" --repo "$OWNER/$REPO" --body "$*" >/dev/null
  echo "#$num にコメントしました"
}

cmd_due() {
  local num="${1:?issue番号}" date="${2:?期限 (YYYY-MM-DD)}"
  printf '%s' "$date" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'     || die "期限は YYYY-MM-DD 形式で指定してください: $date"
  local item out tmp
  item=$(ensure_item "$num")
  gh project item-edit --id "$item" --project-id "$PROJECT_ID"     --field-id "$DUE_FIELD_ID" --date "$date" >/dev/null
  out=$(issue_body "$num" | awk -v date="$date" '
    /^## 期限[[:space:]]*$/ { print; hit = 1; skip = 1; next }
    skip && /^## / { print ""; print date; print ""; skip = 0 }
    skip { next }
    { print }
    END {
      if (skip) { print ""; print date }
      else if (!hit) { print ""; print "## 期限"; print ""; print date }
    }
  ')
  tmp=$(mktemp)
  printf '%s
' "$out" > "$tmp"
  gh issue edit "$num" --repo "$OWNER/$REPO" --body-file "$tmp" >/dev/null
  rm -f "$tmp"
  echo "#$num due: $date"
}

# ---------------------------------------------------------------- stale

cmd_stale() {
  local days="${1:-7}" cutoff
  cutoff=$(date -u -d "-${days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
    || cutoff=$(python -c "import datetime;print((datetime.datetime.utcnow()-datetime.timedelta(days=$days)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  echo "## ${days}日以上動いていないタスク（Done 以外）"
  fetch_items | jq -r --arg c "$cutoff" '
    [.[] | select(.status != "Done" and .updatedAt < $c)]
    | sort_by(.updatedAt) | .[]
    | "  #" + (.number|tostring) + "  [" + .status + "]  " + .title
      + "  (last: " + (.updatedAt|split("T")[0]) + ")"'
}

# ---------------------------------------------------------------- merge

cmd_merge() {
  local keep="${1:?統合先の issue 番号}"; shift
  [ $# -gt 0 ] || die "統合する重複 issue 番号を1つ以上指定してください"
  local keep_body dup
  keep_body=$(issue_body "$keep")
  local tmp
  tmp=$(mktemp)
  printf '%s\n' "$keep_body" > "$tmp"
  for dup in "$@"; do
    [ "$dup" = "$keep" ] && continue
    local dup_title dup_checks
    dup_title=$(gh issue view "$dup" --repo "$OWNER/$REPO" --json title --jq .title)
    dup_checks=$(issue_body "$dup" | grep -E '^\s*- \[[ xX]\]' || true)
    {
      echo
      echo "<!-- merged from #$dup -->"
      echo "### #$dup $dup_title から統合"
      [ -n "$dup_checks" ] && printf '%s\n' "$dup_checks"
    } >> "$tmp"
    gh issue comment "$dup" --repo "$OWNER/$REPO" \
      --body "重複のため #$keep に統合しました。以降の進捗は #$keep で追跡します。" >/dev/null
    gh issue close "$dup" --repo "$OWNER/$REPO" --reason "not planned" >/dev/null
    local item
    item=$(item_id_for_issue "$dup")
    [ -n "$item" ] && set_status "$item" Done
    echo "  #$dup -> #$keep に統合して close"
  done
  gh issue edit "$keep" --repo "$OWNER/$REPO" --body-file "$tmp" >/dev/null
  rm -f "$tmp"
  echo "#$keep に統合しました: $(issue_body "$keep" | checklist_progress)"
}

# ---------------------------------------------------------------- sync

cmd_sync() {
  local nums n item added=0
  nums=$(gh issue list --repo "$OWNER/$REPO" --state open --limit 500 --json number --jq '.[].number')
  for n in $nums; do
    item=$(item_id_for_issue "$n")
    if [ -z "$item" ]; then
      item=$(gh project item-add "$PROJECT_NUMBER" --owner "$OWNER" \
        --url "https://github.com/$OWNER/$REPO/issues/$n" --format json | jq -r .id)
      set_status "$item" "To do"
      echo "  added #$n"
      added=$((added+1))
    fi
  done
  echo "$added 件を Project に追加しました"
}

# ---------------------------------------------------------------- dispatch

sub="${1:-help}"
[ $# -gt 0 ] && shift || true
case "$sub" in
  help|-h|--help) usage; exit 0 ;;
esac

require_gh
load_env

case "$sub" in
  board)   cmd_board "$@" ;;
  list)    cmd_list "$@" ;;
  show)    cmd_show "$@" ;;
  add)     cmd_add "$@" ;;
  move)    cmd_move "$@" ;;
  start)   cmd_move "${1:?issue番号}" "In progress" ;;
  done)    cmd_done "$@" ;;
  check)   cmd_check "$@" ;;
  uncheck) cmd_uncheck "$@" ;;
  note)    cmd_note "$@" ;;
  due)     cmd_due "$@" ;;
  stale)   cmd_stale "$@" ;;
  merge)   cmd_merge "$@" ;;
  sync)    cmd_sync "$@" ;;
  *) usage; die "不明なサブコマンド: $sub" ;;
esac
