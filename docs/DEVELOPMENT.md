# DEVELOPMENT — 開発ガイド

ClawnPet をビルド・検証・デプロイするための実務ガイドです。
設計の全体像は [architecture.html](architecture.html)、ハマりどころは [PITFALLS.md](PITFALLS.md) を参照。

## 必要環境

- macOS（開発時は Darwin 25 / Apple Silicon で確認）
- Xcode Command Line Tools（`swiftc` が使えれば OK。Xcode 本体・SwiftPM 不要）

## ビルド

```bash
make build      # = ./build.sh → build/ClawnPet.app
make help       # ターゲット一覧
```

`build.sh` がやること:

1. `build/ClawnPet.app/Contents/{MacOS,Resources}` を作成
2. `Resources/Info.plist`（`LSUIElement=1` = Dock 非表示）と `AppIcon.icns` をコピー
3. `swiftc -O -swift-version 5 Sources/ClawnPet/*.swift -framework AppKit -framework UserNotifications`
4. ad-hoc 署名（`codesign --force --sign -`）

インクリメンタルビルドは無い（全ファイル一括コンパイル、およそ数秒）。

## 実行とデプロイ

```bash
make run        # その場でデバッグ起動（CLAWN_DEBUG=1・フォアグラウンド・Ctrl-C で終了）
make install    # /Applications へデプロイ（pkill → コピー → 起動）
make restart    # 常駐版の再起動
make uninstall  # 停止 + アプリと設定の削除
```

シングルトンロック等は無いが、複数起動すると同じファイルを監視する Clawn が
複数並ぶだけなので、`install` / `restart` は必ず `pkill` を先に行う（Makefile がやる）。
`make run` のテスト起動も **UserDefaults ドメインは /Applications 版と同じ**なので注意
（[PITFALLS.md](PITFALLS.md) #5）。

## 検証レシピ

### 1. フェイクセッションで状態遷移を再現する

`CLAWN_WATCH_DIR` で監視ディレクトリを差し替えれば、実環境（`~/.claude`）を汚さずに
全遷移をテストできる。ディレクトリ構造は `<watchdir>/<プロジェクト名>/<uuid>.jsonl`。

```bash
FT=/tmp/clawn-fixture; mkdir -p $FT/proj-demo
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

# ユーザー発話 → thinking
cat >> $FT/proj-demo/11111111-2222-3333-4444-555555555555.jsonl <<EOF
{"type":"user","timestamp":"$NOW","sessionId":"demo","cwd":"/Users/dev/web-app","message":{"role":"user","content":[{"type":"text","text":"テストして"}]}}
EOF

# ツール実行 → working
cat >> $FT/proj-demo/11111111-2222-3333-4444-555555555555.jsonl <<EOF
{"type":"assistant","timestamp":"$NOW","sessionId":"demo","cwd":"/Users/dev/web-app","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}
EOF

# 応答本文 → celebrating
cat >> $FT/proj-demo/11111111-2222-3333-4444-555555555555.jsonl <<EOF
{"type":"assistant","timestamp":"$NOW","sessionId":"demo","cwd":"/Users/dev/web-app","message":{"role":"assistant","content":[{"type":"text","text":"できたよ！"}]}}
EOF
```

ポイント:

- `cwd` の**末尾ディレクトリ名がカードのタイトル**になる（無いと sessionId 先頭 8 文字）。
- mtime が 30 分以内の transcript だけが追跡対象。イベントは追記から **1 秒以内**に反映。
- timestamp が古い行（20 秒超）は新規追跡時のバックフィルで捨てられるので、必ず現在時刻で書く。

### 2. 自己スナップショット（スクリーンショット権限不要）

```bash
CLAWN_DEBUG=1 CLAWN_WATCH_DIR=$FT \
CLAWN_SNAPSHOT_PATH=/tmp/clawn.png \
build/ClawnPet.app/Contents/MacOS/ClawnPet > /tmp/clawn.log 2>&1 &

sleep 3
kill -USR1 $(pgrep -f ClawnPet | head -1)   # PetView が自分を PNG に描き出す
open /tmp/clawn.png
```

`open` 経由で起動した場合も環境変数は引き継がれる。`CLAWN_SNAPSHOT_PATH` 未指定時は
`$TMPDIR/clawn_snapshot.png`。

### 3. 見た目のバリエーション確認

| 手段 | 効果 |
|---|---|
| `SIGUSR2` / メニュー「デモ再生」 | 全モーション（thinking→working→celebrating→idle→sleeping）を順に再生 |
| `CLAWN_TEST_FACING=1` / `-1` | 移動方向を向く演出を右/左に固定 |
| `defaults write com.sunagaku.clawnpet clawn.collapsed -bool false` | 開いた状態で起動（fake 8 セッションで +N チップも確認できる） |

### 4. ウィンドウ位置・開閉の数値検証

見た目に頼らず座標で検証する（スクリプト例は PITFALLS.md #7）:

```bash
# CGWindowList で bounds を読む。owner 名は「Clawnくん」（CFBundleDisplayName）
swift -e 'import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String:Any]]
for w in l where (w["kCGWindowOwnerName"] as? String) == "Clawnくん" { print(w["kCGWindowBounds"]!) }'
```

開閉・再起動で **右下角（maxX / maxY）が不変**であることが正しい状態。

## デバッグ用の環境変数・シグナル一覧

| 名前 | 意味 |
|---|---|
| `CLAWN_DEBUG=1` | イベント / 状態遷移 / mouseUp ヒット判定を stderr へ |
| `CLAWN_WATCH_DIR` | transcript 監視ルートの差し替え（既定 `~/.claude/projects`） |
| `CLAWN_HISTORY` / `CLAWN_MAINLOG` | history.jsonl / main.log のパス差し替え |
| `CLAWN_SNAPSHOT_PATH` | SIGUSR1 スナップショットの出力先 |
| `CLAWN_TEST_FACING` | 向き演出の固定（1=右, -1=左） |
| `CLAWN_CDP_PORT` | claude.ai Web チャット監視を有効化（opt-in） |
| `CLAWN_DEMO=1` | 起動と同時にデモ再生 |
| `SIGUSR1` | 自己スナップショット PNG |
| `SIGUSR2` | デモ再生のトグル |

## UserDefaults（com.sunagaku.clawnpet）

| キー | 意味 |
|---|---|
| `clawn.collapsed` | 開閉状態（未設定 = とじる） |
| `clawn.right` / `clawn.bottom` | ウィンドウ位置（**右下角**アンカー） |
| `clawn.notify` | 返信の通知センター表示（既定 ON） |

`build/` のバイナリを直接実行しても Bundle.main が解決されるため
**同じドメインを読み書きする**点に注意（PITFALLS.md #5）。

## アプリアイコンの再生成

アイコンはコードで描いている（`tools/render_icon.swift`）。描画を変えたら:

```bash
make icon       # 全 10 サイズを再生成して Resources/AppIcon.icns を更新
make install    # アプリに反映
```

個別サイズのプレビューは `swift tools/render_icon.swift /tmp/preview.png 512`。
手でループを書く場合は zsh の単語分割の罠に注意（[PITFALLS.md](PITFALLS.md) #6）。

## CI

GitHub Actions（`.github/workflows/`）が push ごとに `./build.sh` を実行して
ビルドが通ることだけ確認する。成果物の配布はまだしていない。

## リリース（未実施 / TODO）

- ad-hoc 署名のため、配布先マシンでは Gatekeeper の回避（右クリック→開く）が必要
- ちゃんと配るなら: Developer ID 証明書で署名 → `notarytool` で公証 → GitHub Releases に zip
- 通知センターの許可が下りない問題も署名で解消される見込み（現状は osascript フォールバック）
