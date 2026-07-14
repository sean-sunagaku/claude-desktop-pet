# CHANGELOG

すべて 2026-07-14 の開発。バージョンは git タグではなくドキュメント上の呼称です
（該当コミットを併記）。

## v0.5 — 導入コマンドと常駐運用の整備

- **アプリ名を「Claude Pet」に改名**。.app / 実行ファイルは `ClaudePet`（スペース回避）、
  ウィンドウ owner 名は「Claude Pet」。bundle id・`CLAWN_*` 環境変数・`clawn.*` defaults・
  ソースディレクトリは互換性のため旧名のまま。キャラクター名は「Clawn くん」で継続
- GitHub Actions の CI を削除（個人開発でローカル `make build` 検証で十分なため）

- Makefile 追加: `make install` / `run` / `restart` / `uninstall` / `icon` / `clean`（`abea5f5`）
- 🦀 メニューに「ログイン時に起動」トグル（`SMAppService`。BTM 登録・解除を実機検証済み）
- `tools/watch_resources.sh`: 長時間稼働のリソース観測用 CSV レコーダー
- ドキュメント体系の整備: リポジトリ CLAUDE.md / docs/DEVELOPMENT.md /
  docs/PITFALLS.md / CHANGELOG.md、README 日英に索引（`def3660`）

## v0.4 — ChatGPT ペット構造への刷新と音声削除

- カニは開閉どちらも右下 116×112 領域に 0.52 倍で描画する単一パスに統一。
  開閉でサイズも画面位置も変わらない（`53068fb`）
- 閉: セッション数バッジ（作業中オレンジ / ふだん緑）をクリックでひらく。
  開: 頭上中央の ˅ でとじる。カードに載り切らない分は「+N」チップ（`dd04540`）
- 吹き出しを廃止し、カード・通知に一本化（`53068fb`）
- カードと UI をダークテーマ化（ChatGPT Desktop のタスクカード風、`81ec4e2`）
- ドラッグ中は進行方向を向く演出（ウィンドウ右端の差分検出、`d9b95e0` `221f6ac`）
- ウィンドウ位置を右下角アンカーで保存・復元（再起動ズレ修正、`e2609b1`）
- クリック割り当て変更: シングル=なでる / ダブル=開閉（誤クリックで巨大化しない、`701edc1`）
- 展開時サイズのコンパクト化（`6833724`）
- **音声実況（VOICEVOX / システム音声）を全削除**（`0306a13`）
- MultiTranscriptWatcher の追跡上限 6→12（表示 6 枚 + +N、`dd04540`）
- architecture.html を現行実装に全面同期、AppKit 選定理由を追記（`0ecbdae` `85ea7f6`）

## v0.3 — 通知・CDP・ミニ表示デフォルト（`a345289`）

- デフォルトをミニ表示に変更、右上にセッション数バッジ
- Notifier: 応答到着を通知センターへ（ad-hoc 署名環境は osascript フォールバック、
  通知タップで該当セッションへジャンプ）
- CDPWatcher: `CLAWN_CDP_PORT` 指定時のみ claude.ai Web チャットを実況（opt-in）
- （音声）セッションごとの VOICEVOX 話者割り当て — v0.4 で削除

## v0.2 — マルチセッションとジャンプ（`268adda`）

- セッションカード: アクティブな transcript を並行追跡してスタック表示
- カードクリックで `claude://resume?session=<uuid>` を開き、Claude Desktop 上で
  該当セッションにフォーカス（ディープリンクのパラメータ名を app.asar から特定・実証）
- クリックで開閉（ミニ表示）
- アプリアイコンを Claude 風（テラコッタ #DA7756 + 白カニ）に刷新。
  `tools/render_icon.swift` でコードから全サイズ生成
- （音声）VOICEVOX ずんだもん実況 — v0.4 で削除

## v0.1.0 — MVP（`4e78705`）

- カニのマスコット Clawn（NSBezierPath 手続き描画、5 つの気分と全モーション）
- シグナル源の調査と 4 ウォッチャー実装
  （transcript / history.jsonl / Desktop main.log / sessions レジストリ）
- セッション別状態マシン（PetBrain）とイベントルーティング
- 常時最前面・borderless・全スペース追従のフローティングウィンドウ
- メニューバー 🦀、デモ再生、SIGUSR1 自己スナップショット
- README（日英）、docs/FEASIBILITY.md（技術検証レポート）、GitHub Actions CI
- OSS 公開: https://github.com/sean-sunagaku/claude-desktop-pet （MIT）
