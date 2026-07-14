# CLAUDE.md — Claude Pet 開発ガイド（AI エージェント向け）

Claude Pet は Claude Desktop / Claude Code のセッション活動をローカルファイル監視で実況する
macOS デスクトップペット。Swift + AppKit、依存ライブラリゼロ、`swiftc` 一発ビルド。

## ビルドとデプロイ

```bash
make build      # build/ClaudePet.app（swiftc -O、ad-hoc 署名。実体は ./build.sh）
make install    # ビルド → pkill → /Applications へ配置 → 起動（デプロイの正規手順）
make run        # その場でデバッグ起動（CLAWN_DEBUG=1 フォアグラウンド）
make icon       # tools/render_icon.swift からアイコン全サイズ再生成
make uninstall  # 停止 + /Applications と UserDefaults を削除
```

- Xcode プロジェクトは無い。ソースは `Sources/ClawnPet/*.swift` を丸ごとコンパイル。
- フレームワークは AppKit / UserNotifications / ServiceManagement のみ。
  **AVFoundation を追加しない**（音声機能は削除済み）。
- CI（GitHub Actions）は `./build.sh` を直接呼ぶ。Makefile を変えても build.sh は残すこと。
- **名前の使い分け**: アプリ名・表示名は「Claude Pet」、.app と実行ファイルは `ClaudePet`（スペース回避）。
  bundle id `com.sunagaku.clawnpet`・ソースディレクトリ `Sources/ClawnPet/`・`CLAWN_*` 環境変数・
  `clawn.*` defaults キーは**旧名のまま**（内部識別子。変えると設定・自動起動登録が飛ぶ）。
  キャラクター名は「Clawn くん」で継続。

## 検証（ヘッドレスでできる）

スクリーンショット権限なしで見た目検証ができる自己スナップショット機構がある:

```bash
# フェイクセッションで起動（実環境を汚さない）
mkdir -p /tmp/ft/proj-a
echo '{"type":"user","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'","sessionId":"s1","cwd":"/Users/dev/web-app","message":{"role":"user","content":[{"type":"text","text":"テスト"}]}}' >> /tmp/ft/proj-a/11111111-2222-3333-4444-555555555555.jsonl
CLAWN_DEBUG=1 CLAWN_WATCH_DIR=/tmp/ft CLAWN_SNAPSHOT_PATH=/tmp/snap.png build/ClaudePet.app/Contents/MacOS/ClaudePet &
sleep 3 && kill -USR1 $!   # → /tmp/snap.png に現在の見た目が出る
```

- transcript に行を **append すると 1 秒以内に反応**する（thinking/working/celebrating の遷移テスト）。
- `CLAWN_TEST_FACING=1|-1` で向き演出を固定してスナップ確認。
- `SIGUSR2` = 全モーションのデモ再生。`CLAWN_DEBUG=1` でイベント・mouseUp ヒット判定が stderr に出る。
- ウィンドウの実座標検証は `CGWindowListCopyWindowInfo` で bounds を読む（owner 名は **「Claude Pet」**
  = CFBundleDisplayName。実行ファイル名 ClaudePet とは別物）。

## 変更時の約束

- **音声実況（VOICEVOX / システム音声）は 2026-07-14 にユーザー要望で全削除した。復活させない。**
- ウィンドウ位置は**右下角アンカー**（`clawn.right` / `clawn.bottom`）で保存・復元する。
  左下 origin 基準に戻すと「開閉・再起動でカニがずれる」バグが再発する（docs/PITFALLS.md #1）。
- カニの描画は開閉どちらも**右下 116×112 領域に 0.52 倍**の単一パス。開閉でサイズ・位置を変えない。
- facing（移動方向を向く演出）はウィンドウの **maxX（右端）** 差分で検出する。origin.x に変えると
  開閉の伸縮を移動と誤検知する（PITFALLS.md #2）。
- UI の見た目・配置は ChatGPT Desktop のペットが基準（ユーザーの好み）。
  カード=ダークテーマ、˅=頭上中央、あふれは +N チップ。
- コミットメッセージは日本語。機能単位でまとめてコミットし、README（日英）と
  docs/architecture.html を**実装と同期**させてからコミットする。

## ファイル構成（詳細は docs/architecture.html）

| ファイル | 責務 |
|---|---|
| `Sources/ClawnPet/main.swift` | NSApplication を accessory で起動 |
| `Sources/ClawnPet/PetCore.swift` | PetEvent / PetMood / PetBrain（セッション別状態マシン） |
| `Sources/ClawnPet/Watchers.swift` | TailReader と 4 ウォッチャー（transcript / history / main.log / registry） |
| `Sources/ClawnPet/PetView.swift` | カニ描画・カード・バッジ/˅・クリック/ドラッグ判定 |
| `Sources/ClawnPet/Notifier.swift` | 応答通知（UNUserNotificationCenter → osascript フォールバック） |
| `Sources/ClawnPet/CDPWatcher.swift` | claude.ai Web チャット監視（`CLAWN_CDP_PORT` 指定時のみ） |
| `Sources/ClawnPet/AppDelegate.swift` | 結線・ウィンドウ管理・ルーティング・メニュー |
| `tools/render_icon.swift` | アプリアイコンをコードから描画 |

## ドキュメントの置き場所

- ユーザー向け: `README.md`（日）/ `README.en.md`（英）— 必ず両方更新
- 設計資料: `docs/architecture.html`（自己完結 HTML。実装変更時に同期必須）
- シグナル源の調査記録: `docs/FEASIBILITY.md`
- 開発ガイド: `docs/DEVELOPMENT.md` / ハマりどころ: `docs/PITFALLS.md`
- 変更履歴: `CHANGELOG.md`
