# life-tasks-template

**仕事からプライベートまで、すべてのタスクを GitHub Issues + Projects で一元管理する仕組み。**
Claude Code から自然言語で操作する。

```
> タスク追加：8/30までにA社のESを提出
```

この一言で、ラベル・優先度・期限・チェックリスト付きの Issue が立ち、カンバンに載る。
聞き返しは発生しない。判断材料が `docs/profile.md` に書いてあるため。

実際の変換の様子は [docs/examples.md](docs/examples.md)、
なぜこの設計なのかは [docs/design.md](docs/design.md) にまとめてある。

---

## 何が入っているか

| 場所 | 役割 |
|---|---|
| `scripts/task.sh` | すべての操作の入口。起票・状態遷移・消し込み・統合・放置検知 |
| `scripts/bootstrap.sh` | リポジトリ・ラベル・Projects v2 を一括構築（1回だけ実行） |
| `.claude/skills/` | Claude 用スキル6種（起票 / 進捗 / 統合 / デイリー / 情報収集 / URL要約） |
| `docs/profile.example.md` | プロフィールのテンプレート。**ここを埋めるほど聞き返されなくなる** |
| `.github/labels.yml` | 領域ラベル11種の定義 |
| `CLAUDE.md` | Claude が従う運用規約 |

## セットアップ

### 1. 前提ツール

```bash
gh --version   # GitHub CLI
jq --version
```

未導入なら `winget install GitHub.cli` / `winget install jqlang.jq`
（macOS なら `brew install gh jq`）。

### 2. 認証（project スコープが必須）

```bash
gh auth login              # GitHub.com / HTTPS / ブラウザ認証
gh auth refresh -s project,read:project
```

### 3. GitHub 側を構築

```bash
./scripts/bootstrap.sh --repo life --title "life ロードマップ"
```

これで以下が作られる。

- **private** リポジトリ（タスクの中身は他人に見せるものではないので private が既定）
- ラベル11種（Study / Career / Work / Circle / Dev / Tech / Health / Life / Money / Idea / Routine）
- Projects v2
  - `Status` = To do / Pending / In progress / Done
  - `Priority` = P0 / P1 / P2
  - `Due` = 日付
- `scripts/project.env`（各種 ID。以降のコマンドが参照する。`.gitignore` 済み）

### 4. 画面側の設定（API で作れないので手動、1回だけ）

Project を開いて:

1. ビュー名の右の `v` → **Layout: Board**
2. **Group by: Status** → 4列になる
3. 各列の `...` → **Set limit**（In progress = 5, Pending = 10）
4. 右上 **Workflows** で有効化
   - `Item added to project` → Set Status = **To do**
   - `Item closed` → Set Status = **Done**
   - `Auto-add to project` → 対象リポジトリ / `is:issue is:open`

`.github/ISSUE_TEMPLATE/config.yml` の Project URL も自分のものに書き換える。

### 5. プロフィールを作る

```bash
cp docs/profile.example.md docs/profile.md
```

自分の情報で埋める。**このファイルの埋まり具合が使い心地を決める。**
特に「固有名詞 → ラベル 対応表」に自分のサークル名・勤務先・プロダクト名を足していくと、
「〇〇やらないと」の一言でラベルが確定するようになる。

> `docs/profile.md` は `.gitignore` 済み。氏名・所属・生活圏が入るため、
> **勤務先や通学先は店舗名・キャンパス名まで書かない**こと。
> 「A社のバイト」程度の粒度で十分機能する。

## 使い方

Claude Code に話しかけるだけでよい。スキルが対応するコマンドに変換する。

```
> タスク追加：賃貸の更新手続き。契約満了3/31で2ヶ月前までに連絡が必要
> 今日なにやる
> #12 やる
> #12 の「更新契約書」終わった
> #12 と #15 重複してるからまとめて
> 今日のトレンド集めて
```

直接叩く場合:

```bash
./scripts/task.sh help
./scripts/task.sh board                        # カンバンを表示
./scripts/task.sh add --title "..." --summary "..." --check "..." --label Life --priority P1
./scripts/task.sh start 12                     # In progress へ
./scripts/task.sh move 12 pending --reason "先方の返事待ち"
./scripts/task.sh check 12 "契約書"             # チェックリストを消し込む
./scripts/task.sh due 12 2026-09-30            # 期限を設定
./scripts/task.sh done 12                      # 完了（チェック残があれば止まる）
./scripts/task.sh stale 7                      # 7日動いていないものを列挙
./scripts/task.sh merge 12 15 18               # 重複を統合して close
./scripts/task.sh sync                         # Project 未登録の Issue を取り込む
```

## ステータスの使い分け

| | 意味 | 上限 |
|---|---|---|
| **To do** | 未着手。いつかやる〜今週やるまで全部ここ | — |
| **Pending** | **自分以外の要因**で止まっている / 意図的に寝かせた | 10 |
| **In progress** | 今まさに手を動かしている | 5 |
| **Done** | 完了条件を満たした。Issue も close | — |

手が止まっただけなら Pending ではなく To do に戻す。
Pending にするときは何を待っているかを必ず残す（`--reason`）。ここを緩めると Pending がゴミ箱になる。

「今週」「今月」といった**時間軸の列は作らない**。列は手の動きだけを表し、
時間は `Due` フィールドが持つ。理由は [docs/design.md](docs/design.md) に書いた。

## 週次の棚卸し

```
> 週次の棚卸しして
```

`board` と `stale 7` を突き合わせ、In progress の詰まり・30日放置の To do・
解消済みの Pending を洗い出して整理する。

## ディレクトリ

```
.claude/skills/         Claude 用スキル
.github/
  ISSUE_TEMPLATE/       Web から起票するときのフォーム
  labels.yml            ラベル定義（bootstrap が同期）
scripts/
  bootstrap.sh          初期構築
  task.sh               日々の操作の入口
  lib.sh                共通処理
  project.env.example   自動生成される project.env の見本
docs/
  profile.example.md    プロフィールのテンプレート
  design.md             設計メモ
  examples.md           運用例
ideas/daily/            トレンド収集・URL要約の出力先
```

## 注意

- **このリポジトリはテンプレート。** Issue には応募先企業・取引先・他人との調整内容など、
  公開できない情報が入る。`bootstrap.sh` が private リポジトリを作るのはそのため
- `scripts/project.env` と `docs/profile.md` は追跡しない。fork して使う場合も同じ扱いを推奨する

## 出典

情報収集スキル（`neta-trend-daily` / `url-digest`）は
[hand-dot/claude-code-skills gist](https://gist.github.com/hand-dot/bf6f928dce14095d5eef4f6aae63275e) をフォークし、
Claude Code のスキル構造（`skills/<name>/SKILL.md`）に整形したもの。

コンセプトは [GitHubで人生を管理する](https://zenn.dev/hand_dot/articles/85c9640b7dcc66)。
