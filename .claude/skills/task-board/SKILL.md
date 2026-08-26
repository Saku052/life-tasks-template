---
name: task-board
description: GitHub Projects のカンバン（To do / Pending / In progress / Done）を読み取って進捗状況を把握し、ステータス変更・チェックリストの消し込み・完了処理を行う。「今日のタスク」「ボード見せて」「進捗どう」「#12 やる」「終わった」「止まってる」「棚卸し」など、既存タスクの状況確認と状態遷移に使う。
---

# 進捗把握とステータス操作

## 前提

`scripts/project.env` が必要。無ければ `./scripts/bootstrap.sh` を実行する。

## ステータスの定義

この4つを厳密に使い分ける。曖昧に置かない。

| ステータス | 意味 | 入れる条件 |
|---|---|---|
| **To do** | 未着手 | まだ手を付けていない。いつかやる〜今週やるまで全部ここ |
| **Pending** | 停止中 | **自分以外の要因**で進まない（相手待ち・日程待ち）、または意図的に寝かせた |
| **In progress** | 進行中 | 今まさに手を動かしている。**同時に5件まで** |
| **Done** | 完了 | 完了条件を満たした。Issue も close する |

「なんとなく手が止まった」は Pending ではなく To do に戻す。
Pending にするときは必ず `--reason` で**何を待っているか**を残す。

## 実行手順

### 状況を見る

```bash
./scripts/task.sh board          # ステータス別カンバン
./scripts/task.sh stale 7        # 7日以上動いていないもの
./scripts/task.sh list --status "In progress"
./scripts/task.sh show 12        # 本文とチェックリスト進捗
```

報告するときは生出力を貼らない。次の形に整える：

1. **今日動かすもの** — In progress + P0/期限が近いもの
2. **詰まっているもの** — Pending の一覧と待っている対象
3. **気になる点** — In progress が5件超、7日以上放置、期限超過

### 状態を動かす

```bash
./scripts/task.sh start 12                              # In progress へ
./scripts/task.sh move 12 pending --reason "管理会社の返信待ち"
./scripts/task.sh move 12 todo                          # 手が止まったので戻す
./scripts/task.sh check 12 "更新契約書"                  # チェックリストを消し込む
./scripts/task.sh note 12 "見積もり3社取得。A社が最安"     # 作業ログを残す
./scripts/task.sh done 12                               # 完了 → close + Done
```

`done` はチェックリストが残っていると止まる。
残項目を提示して、本当に完了なら `--force`、そうでなければ残りを消化するよう促す。

### 週次の棚卸しを頼まれたら

1. `board` と `stale 7` を実行
2. In progress が5件を超えていたら、進んでいないものを To do に戻すよう提案
3. Pending の待ち対象が解消していないか1件ずつ確認
4. 30日以上放置の To do は「やらない」判断も選択肢として出す（close 理由は not planned）

## 注意

- ステータス変更は必ず `task.sh` 経由。`gh project item-edit` を直接叩かない（Issue の open/close と揃わなくなる）。
- 進捗の推測で状態を変えない。ユーザーの明示があったときだけ動かす。
- Issue 番号が不明なときは `list` でタイトル検索してから操作する。
