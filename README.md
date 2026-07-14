# 🦀 ClawnPet — Clawn くんデスクトップペット

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-AppKit-orange) ![License](https://img.shields.io/badge/license-MIT-green)

**English → [README.en.md](README.en.md)**

Claude Desktop / Claude Code の作業をデスクトップの隅から見守って実況してくれる、
macOS ネイティブのデスクトップペットです。ChatGPT Desktop の Pet 機能のような
「アプリの外に住むマスコット」を Claude 用に作った MVP です。

> **非公式プロジェクトです。** Anthropic とは無関係で、公認・提携もありません。
> Claude アプリがローカルに書き出すファイルを**読むだけ**で動作し、
> ネットワーク送信・アプリへの介入・自動操作は一切行いません。

| 待機 | 考え中 | 作業中 | 返答が来た！ |
|---|---|---|---|
| ![idle](docs/images/idle.png) | ![thinking](docs/images/1_thinking.png) | ![working](docs/images/2_working.png) | ![celebrating](docs/images/3_celebrating.png) |

## なにができる？

- **常時最前面のフローティング表示**（Dock には出ない・全スペース追従・フルスクリーン上にも出せる）
- **メッセージ送信を検知**して「かんがえ中」— 送ったプロンプトの本文を吹き出しに表示
- **ツール実行を実況** — 「ターミナルで作業中」「コードをカキカキ中」などツール別の実況
- **返答が来たらジャンプしてお祝い** — 応答本文の先頭を吹き出しに表示
- **8分なにもないと寝る**（イベントが来たら起きる）
- 稼働中の Claude Code セッション数を表示（`session ×N`）
- 対象: **Claude Desktop 内の Claude Code（CCD）/ CLI / Cursor 拡張など全ての Claude Code セッション** + Claude Desktop アプリのメッセージ送信イベント

## インストール & 起動

```bash
./build.sh                        # ビルド（要 Xcode Command Line Tools / Swift）
open build/ClawnPet.app           # 起動
```

常用するなら:

```bash
cp -R build/ClawnPet.app /Applications/
open /Applications/ClawnPet.app
```

ログイン時に自動起動したい場合: システム設定 → 一般 → ログイン項目 に ClawnPet.app を追加。

## 操作

| 操作 | 動作 |
|---|---|
| ドラッグ | 好きな場所に移動（位置は記憶される） |
| ダブルクリック | なでる（よろこぶ） |
| 右クリック / メニューバーの 🦀 | メニュー（デモ再生・スナップショット・位置リセット・終了） |

## 状態一覧

| 状態 | トリガー | 見た目 |
|---|---|---|
| idle | 起動時・作業完了後 | ゆらゆら待機 |
| thinking | プロンプト送信を検知 | 目線が上に・20秒超で汗 |
| working | tool_use を検知 | ハサミをカタカタ・ツール名を実況 |
| celebrating | アシスタントの返答本文を検知 | ジャンプ＋キラキラ（7秒） |
| sleeping | 8分イベントなし | Zzz（イベントで起床） |

## 仕組み（読み取りのみ・外部送信なし）

ローカルのファイルを**読むだけ**で動きます。ネットワーク送信・書き込みは一切しません。

| 監視対象 | 得られる情報 |
|---|---|
| `~/.claude/projects/**/*.jsonl` | セッション transcript（ユーザー発話 / tool_use / 応答本文 / プロジェクト名） |
| `~/.claude/history.jsonl` | 送信したプロンプト本文（全セッション横断） |
| `~/Library/Logs/Claude/main.log` | Claude Desktop のメッセージ送信・セッション一時停止イベント |
| `~/.claude/sessions/*.json` | 稼働中セッション数（pid 生存確認つき） |

最も新しく更新された transcript を自動追尾するので、複数セッションを行き来しても
「いま動いているセッション」を実況します。詳しい調査結果は
[docs/FEASIBILITY.md](docs/FEASIBILITY.md) を参照。

## デバッグ用環境変数

| 変数 | 意味 |
|---|---|
| `CLAWN_DEBUG=1` | イベント/状態遷移を stderr にログ |
| `CLAWN_DEMO=1` | 起動時に全モーションのデモを再生 |
| `CLAWN_WATCH_DIR` / `CLAWN_HISTORY` / `CLAWN_MAINLOG` | 監視パスの差し替え（テスト用） |
| `CLAWN_SNAPSHOT_PATH` | スナップショット PNG の保存先 |

シグナル: `SIGUSR1` = スナップショット保存、`SIGUSR2` = デモ開始/停止。

## アンインストール

メニューバー 🦀 → 「Clawn を終了」→ `/Applications/ClawnPet.app` を削除。
（保存されるのはウィンドウ位置の UserDefaults のみ）

## プロジェクト構成

```
Sources/ClawnPet/
├── main.swift         # エントリポイント
├── AppDelegate.swift  # ウィンドウ・メニューバー・タイマー・デモ・シグナル
├── PetCore.swift      # PetEvent / PetBrain（状態マシン）
├── PetView.swift      # Clawn くんの描画・アニメーション・吹き出し
└── Watchers.swift     # TailReader / transcript・history・main.log の監視
```
