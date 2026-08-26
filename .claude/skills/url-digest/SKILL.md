---
name: url-digest
description: 渡された複数のURL（通常記事・X/Twitter・Hacker News・Reddit）を読み取り、コアメッセージとコミュニティの反応を日本語で要約して ideas/daily/YYYYMMDD-digest.md に保存する。「このURLまとめて」「記事を要約して」など、URLの一括要約を求められたときに使う。
---

# URL要約

複数のURLを読み取り、コアメッセージがわかるように要約する。

## 入力形式

ユーザーからURLが1つ以上渡される。URLは改行区切りまたはスペース区切りで提供される。

## 実行手順

### 1. URL種別判定

渡されたURLを以下のカテゴリに分類：

**通常記事**:
- 上記以外のURL
- 直接WebFetchで取得

**X (Twitter)** (`x.com/*` または `twitter.com/*`):
- JavaScriptが必要なためWebFetchでは取得不可
- ブラウザ自動化ツール（claude-in-chrome）を使用

**Hacker News** (`news.ycombinator.com/item?id=XXX`):
- コメントページから元記事URLを取得
- 元記事とコメントの両方を分析

**Reddit** (`reddit.com/r/*/comments/*` または `www.reddit.com/r/*/comments/*`):
- curlでJSON形式で取得（WebFetchはreddit.comをブロック）
- 元記事とコメントの両方を分析

### 2. コンテンツ取得

#### 通常記事

WebFetchツールで内容を取得：

- タイトルと本文を抽出
- コアメッセージを要約

#### X (Twitter)

JavaScriptレンダリングが必要なため、ブラウザ自動化ツールを使用：

1. **ブラウザセッション準備**:
   - `tabs_context_mcp`でタブ情報を取得（`createIfEmpty: true`）
   - `tabs_create_mcp`で新しいタブを作成

2. **ページ取得**:
   - `navigate`ツールでX.comのURLに移動
   - ページ読み込み完了まで待機（`computer`ツールの`wait`アクション、2-3秒）

3. **コンテンツ抽出**:
   - `get_page_text`でツイート本文を取得
   - または`read_page`でアクセシビリティツリーから構造化データを取得

4. **抽出する情報**:
   - ツイート本文
   - 投稿者名・ハンドル
   - 画像/動画の有無（あれば内容を説明）
   - リプライ・引用がある場合はその文脈

#### Hacker News

1. **HNコメントページ取得**:
   - Hacker News Algolia APIを使用: `https://hn.algolia.com/api/v1/items/{item_id}`
   - `item_id`はURLから抽出（`item?id=XXXXX`のXXXXX部分）

   ```bash
   curl -s "https://hn.algolia.com/api/v1/items/{item_id}" | jq '.'
   ```

   データ構造:
   - `title`: 記事タイトル
   - `url`: 元記事URL（nullの場合はHN投稿自体が本文）
   - `points`: ポイント数
   - `children`: コメントの配列（各コメントは `text` フィールドを持つ）

2. **元記事取得**:
   - `url`フィールドが存在する場合、WebFetchで元記事を取得
   - `url`がnullの場合、`text`フィールドが本文

3. **コメント分析**:
   - `children`配列から上位5件程度のコメントを確認
   - 興味深いインサイト、反論、追加情報を抽出

#### Reddit

**重要**: 投稿情報とコメントは別々のjqクエリで取得すること（一度に取得するとjqエラーになる）

1. **投稿情報の取得**:

   ```bash
   curl -s -H "User-Agent: url-digest/1.0" \
   "https://old.reddit.com/r/{subreddit}/comments/{post_id}.json" \
   | jq '.[0].data.children[0].data | {title, url, selftext, is_self}'
   ```

2. **コメントの取得**（別クエリで実行）:

   ```bash
   curl -s -H "User-Agent: url-digest/1.0" \
   "https://old.reddit.com/r/{subreddit}/comments/{post_id}.json" \
   | jq '[.[1].data.children[:8][].data | select(.body) | {body: .body[0:500], score}]'
   ```

   **注意**: `select(.body != null)`は使わない（感嘆符がシェルでエスケープされるため）。`select(.body)`を使う。

3. **元記事取得**:
   - `url`フィールドが外部URLの場合、WebFetchで元記事を取得
   - 自己投稿（`is_self: true`）の場合、`selftext`が本文

4. **コメント分析**:
   - 上位コメントから興味深いインサイト、反論、追加情報を抽出

### 3. 要約生成

各URLについて以下を生成：

**タイトル**:
- 記事の元タイトル
- 英語の場合は日本語に翻訳

**要約**:
- コアメッセージを3-5行で要約
- 何が重要なのか、なぜ注目に値するのかを明確に
- HN/Redditの場合は以下も含める:
  - コミュニティの反応（賛否、議論のポイント）
  - 興味深いコメントからのインサイト
  - 補足情報や反論

**URL**:
- 入力されたURL（HN/Redditの場合はそのまま）

### 4. 出力

**まず「要約完了。」というメッセージを返してから、結果をファイルに保存。**

#### ファイル出力

`ideas/daily/YYYYMMDD-digest.md` に保存（YYYYMMDDは実行日）。

#### フォーマット

```markdown
# URL Digest: YYYY-MM-DD

---

## [記事タイトル]

要約本文。コアメッセージを3-5行で記述。
HN/Redditの場合はコミュニティの反応やインサイトも含める。

URL

---

## [記事タイトル2]

要約本文。

URL

---
```

## 注意事項

- **すべての記事にURLを必ず含める**
- **英語タイトルは日本語に翻訳**
- **HN/Redditは元記事とコメントの両方を確認**（これが重要）
- **X.comはブラウザ自動化ツールを使用**（WebFetchではJSレンダリング不可）
- Redditはcurlを使用（WebFetchはブロックされる）
- Reddit APIレート制限に注意（1分あたり60リクエスト程度）
- 要約は簡潔に、核心を突く内容で
- 出力ファイルのYYYYMMDDは実行日の日付を使用（`date +%Y%m%d` で取得）
- 出力先ディレクトリが無い場合は `mkdir -p ideas/daily` で作成してから保存
