# タスク一元管理リポジトリ

仕事からプライベートまで、すべてのタスクを **GitHub Issues + Projects** で管理する。
Claude はこのファイルの規約に従って Issue とボードを操作する。

設計の意図は [docs/design.md](docs/design.md)、実際の運用例は [docs/examples.md](docs/examples.md) にある。

## 構成

| 場所 | 役割 |
|---|---|
| GitHub Issues | タスク1件 = Issue 1件。概要 + チェックリストを持つ |
| GitHub Projects v2 | 4列のカンバン。Issue の状態を可視化する |
| `scripts/task.sh` | すべての操作の入口。Claude はこれを呼ぶ |
| `scripts/bootstrap.sh` | GitHub 側の初期構築（1回だけ） |
| `.claude/skills/` | Claude 用スキル（起票 / 進捗 / 統合 / デイリー / 情報収集） |
| `docs/profile.md` | **プロフィール。タイトル・ラベル・優先度・期限の判定材料**（各自で作る） |
| `ideas/daily/` | トレンド収集・URL要約の出力先 |

`scripts/project.env` に Project の各種 ID が入っている。自動生成なので手で編集しない。

## ステータス規約

| ステータス | 意味 | WIP上限 |
|---|---|---|
| **To do** | 未着手。いつかやる〜今週やるまで全部ここ | — |
| **Pending** | 自分以外の要因で止まっている / 意図的に寝かせた。**待ち対象を必ずコメントに残す** | 10 |
| **In progress** | 今まさに手を動かしている | 5 |
| **Done** | 完了条件を満たした。Issue も close | — |

「なんとなく手が止まった」は Pending ではなく **To do に戻す**。

## Issue の書き方

すべての Issue は最低限これを持つ。

```markdown
## 概要
なぜ今やるのか / 期限の根拠を含む1〜3行

## 完了に必要な手順
- [ ] 実行可能な単位に割った項目（3〜7個）
- [ ] 「調べる」で止めず、判断や成果物まで書く

## 完了条件
これが済んだら Done と言い切れる状態
```

領域はラベルで表す: `Study` `Career` `Work` `Circle` `Dev` `Tech` `Health` `Life` `Money` `Idea` `Routine`
（判定規則は `docs/profile.md` の「固有名詞 → ラベル 対応表」）
優先度と期限は Projects のフィールド (`Priority` = P0/P1/P2, `Due`) で持つ。

## Claude の操作ルール

- 起票・デイリーの前に **`docs/profile.md` を読む**。ラベル・タイトル・優先度・期限は
  そこの規則に従って決め、毎回聞き返さない
- タスク操作は **必ず `./scripts/task.sh` 経由**。`gh project item-edit` を直接叩かない
  （Issue の open/close と Project のステータスがずれるため）
- ステータスはユーザーの明示があったときだけ動かす。進捗を推測して変えない
- `done` はチェックリストが残っていると止まる。残項目を提示してから判断を仰ぐ
- close を伴う操作（`merge`、not planned close）は実行前に対象を1行で提示して確認する
- 5分で終わる用事は Issue にしない

よく使うコマンド:

```bash
./scripts/task.sh board             # カンバンを見る
./scripts/task.sh add ...           # 起票
./scripts/task.sh start 12          # In progress へ
./scripts/task.sh check 12 "..."    # チェックリスト消し込み
./scripts/task.sh due 12 2026-09-30 # 期限を設定
./scripts/task.sh done 12           # 完了
./scripts/task.sh stale 7           # 放置検知
./scripts/task.sh merge 12 15       # 重複統合
```

## スキル

| skill | いつ動く |
|---|---|
| `task-add` | 「タスク追加」「〜やらないと」 |
| `task-board` | 「今日のタスク」「進捗どう」「#12 やる」「終わった」 |
| `task-merge` | 「重複してる」「まとめて」「整理して」 |
| `daily-brief` | 「おはよう」「今日なにやる」 |
| `neta-trend-daily` | 「今日のトレンド」「ネタ収集」 |
| `url-digest` | URL を投げられたとき |

## 興味領域

`neta-trend-daily` と `url-digest` が興味度を判定するときの基準。
**ここは各自で書き換える。** 下は記入例。

- AI / LLM の開発への応用
- Web セキュリティ（OWASP、脆弱性、サプライチェーン攻撃）
- 個人開発 / SaaS 運営（収益化、Technical SEO）
- OSS 開発・コミュニティ
- JavaScript / TypeScript の技術スタック
- キャリア・人生設計
