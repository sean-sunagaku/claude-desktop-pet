# Claude Desktop ペット機能 — 技術検証レポート

検証日: 2026-07-14 / 環境: macOS 26.5.1 (Darwin 25.5.0), Claude Desktop 1.20186.1 (Electron 42.5.1)

## 結論

**可能。MVP 実装済み。**

- **Claude Code 系のセッション**（Claude Desktop 内の CCD・CLI・Cursor 拡張すべて）は、
  ローカルファイルの監視だけで「誰が・どのプロジェクトで・何を送り・どのツールを実行し・
  何と返答したか」まで**本文つきリアルタイム**で取得できる。追加権限・ハック不要。
- **Claude Desktop アプリ自体のイベント**（メッセージ送信・セッション一時停止など）も
  アプリのログから取得できる。
- **claude.ai の Web チャット**（Desktop 内のチャット画面）のメッセージ単位の検知だけは
  現状未対応。CDP（Chrome DevTools Protocol）が有力な拡張パスだが、検証に制約があった（後述）。

## 発見したシグナル源の評価

| # | ソース | 得られる情報 | 鮮度 | 採用 |
|---|---|---|---|---|
| 1 | `~/.claude/projects/<proj>/<session>.jsonl` | transcript 全部: user 発話 / tool_use(ツール名・入力) / tool_result / assistant 本文 / cwd / isSidechain | 追記即時 | ✅ 主柱 |
| 2 | `~/.claude/history.jsonl` | 全セッション横断のユーザープロンプト本文 + project + sessionId | 送信瞬間 | ✅ |
| 3 | `~/Library/Logs/Claude/main.log` | `LocalSessions.sendMessage: sessionId=…, messageLength=…` / `[CCD] Pausing session … (idle_timeout)` / `[CCD start-timing] … first_assistant=…ms` / `[SkillsPlugin] Window focused` など | 即時 | ✅ |
| 4 | `~/.claude/sessions/<pid>.json` | 稼働中セッションのレジストリ `{pid, sessionId, cwd, name, entrypoint}`（pid 生存確認で現役判定） | 数秒 | ✅ |
| 5 | `~/Library/Application Support/Claude/{IndexedDB, Session Storage, Local Storage, Cookies}` | mtime バースト＝「アプリが何かしている」程度。定期書き込みノイズ多数 | 秒〜分 | ❌ 弱シグナル |
| 6 | `~/Library/Logs/Claude/claude.ai-web.log` | renderer のエラー/警告が中心。メッセージライフサイクルなし | — | ❌ |
| 7 | CDP (`--remote-debugging-port`) | 理論上すべて（後述） | 即時 | △ 将来拡張 |
| 8 | MCP サーバーを Desktop に登録 | モデルがそのツールを呼んだ時しか観測できない（プッシュ通知は仕様上不可） | — | ❌ |
| 9 | claude.ai API を Cookie 流用で直接ポーリング | 会話一覧・履歴 | — | ❌ 認証情報の扱いが不適切なので却下 |

### transcript (JSONL) の主要フィールド（実測）

```jsonc
{"type":"user","cwd":"/path/to/project","isSidechain":false,
 "message":{"role":"user","content":"こんにちは"}, "timestamp":"2026-07-14T04:34:19.000Z"}
{"type":"assistant","message":{"content":[
  {"type":"tool_use","name":"Bash","input":{...}},   // ← ツール実行
  {"type":"text","text":"できたよ！"}                  // ← 応答本文
]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"…"}]}}
```

- `content` が文字列 or `{type:"text"}` 配列 → 人間の発話（`isMeta` と `<` 始まりは除外）
- `tool_result` を含む user 行 → エージェント継続（人間の発話ではない）
- `isSidechain: true` → サブエージェントの transcript
- assistant の text は**ブロック確定時**に書かれる（トークン単位ではない）

## Claude Desktop の内部構造（観察結果）

- Electron 42.5.1、bundle id `com.anthropic.claudefordesktop`
- **ローカルに listen している TCP ポートなし**（`lsof` 確認）→ ローカル API 経由の連携は不可
- `app.asar` の文字列解析で `LocalSessions.*` の内部 API 語彙を 40 以上確認
  （start / stop / sendMessage / summarizeTranscript / teleportToCloud / startSideChat …）
  → CCD 関連イベントは今後も main.log に出続ける見込み
- レンダラーの起動引数に機能フラグ多数（`plushRaccoon`, `quietPenguin`, `chillingSloth*`,
  `wakeScheduler` など動物コードネーム群 — 本家にもマスコット的な何かが仕込まれつつある気配）

### Electron Fuses（バイナリから実測）

| Fuse | 状態 |
|---|---|
| RunAsNode | **DISABLED** |
| EnableNodeOptionsEnvironmentVariable | **DISABLED** |
| EnableNodeCliInspectArguments (--inspect 系) | **DISABLED** |
| EnableCookieEncryption | ENABLED |
| EnableEmbeddedAsarIntegrityValidation | ENABLED |
| OnlyLoadAppFromAsar | ENABLED |

→ Node 系のデバッグ経路は全て焼き切られたセキュリティ強化ビルド。
ASAR 改ざん・環境変数注入・`ELECTRON_RUN_AS_NODE` はいずれも不可。

## CDP 実験の結果（Task: claude.ai Web チャット監視）

**やったこと**: 実行中の本体を殺さないため、別 `--user-data-dir` で 2 つ目のインスタンスを
`--remote-debugging-port=9333` 付きで起動 → `curl /json/version` を試行。

**結果**: 2 つ目のインスタンスは **Electron のシングルトンロックにより即終了**
（ポート開かず・ログ出力なし）。`--user-data-dir` は Electron の userData を変えないため
ロックを回避できない。さらに本検証セッション自体が Claude Desktop 内で動作しており
（`~/.claude/sessions` で entrypoint=claude-desktop を確認）、本体の再起動テストは
自分のセッションを殺すため実施しなかった。

**判断材料**: `--remote-debugging-port` は fuse の対象外の Chromium レイヤーの引数で、
Electron 本体にこれを無効化する標準機構はない（Slack/VS Code 等でも有効なのは周知のとおり）。
通る可能性は高いが、上記 fuse 構成から Anthropic が独自パッチで塞いでいる可能性も否定できない。

**ユーザーが 30 秒で白黒つけられる検証手順**（Claude Desktop を使っていない時に）:

```bash
osascript -e 'quit app "Claude"'; sleep 3
open -a Claude --args --remote-debugging-port=9333
sleep 8
curl -s http://127.0.0.1:9333/json/list | python3 -m json.tool | head -30
# JSON が返れば CDP 有効。普通に再起動すれば元通り（フラグは永続しない）
```

**有効だった場合に作れるもの**:
- `/json/list` のページタイトル = 開いている会話タイトルの取得
- WebSocket で `Network.enable` → `claude.ai/api/**/completion` への
  `requestWillBeSent`（送信）/ `dataReceived`（ストリーミング中）/ `loadingFinished`（完了）で
  Web チャットもメッセージ単位で実況可能
- Swift からは `URLSessionWebSocketTask` で直接喋れる（依存ライブラリ不要）

**リスク**: デバッグポートはローカルの全プロセスから接続できるため常時有効化は非推奨。
Claude Pet に組み込むなら「ポートが開いていれば使う」opt-in 設計が適切。

## 実装した MVP のアーキテクチャ

```
┌──────────────────────────────┐      ┌──────────┐      ┌─────────────┐
│ Watchers (1s ポーリング + 差分tail) │ →   │ PetBrain │  →   │  PetView    │
│  • ClaudeCodeWatcher (jsonl)  │ Pet  │ 状態マシン │ 状態  │ AppKit 描画  │
│  • HistoryWatcher (history)   │ Event│          │      │ 30fps アニメ │
│  • DesktopLogWatcher (main.log)│      └──────────┘      └─────────────┘
│  • SessionsRegistry (sessions)│
└──────────────────────────────┘
```

- 状態: `idle → thinking →（tool_use で）working →（応答で）celebrating → idle → sleeping`
- ウィンドウ: borderless / 透過 / `.floating` / 全スペース追従 / LSUIElement（Dock 非表示）
- 検証容易性: `SIGUSR1`=自己スナップショット PNG、`SIGUSR2`=デモ、`CLAWN_*` 環境変数で監視先差し替え

## 検証済み事項

1. ✅ フェイクデータで 3 ウォッチャー × 全イベント種の発火と状態遷移（ログで確認）
2. ✅ **実環境**で、この開発セッション自身の `TaskUpdate` / `Bash` 実行を 1 秒以内に検知し
   「ターミナルで作業中 [pet]」と実況（スクリーンショット `docs/images/real_working.png`）
3. ✅ 全モーションの描画品質（`docs/images/*.png`）
4. ✅ ビルド〜起動〜メニューバー常駐〜終了の一連

## 既知の制約

- claude.ai Web チャットのメッセージ単位検知は未対応（上記 CDP 待ち）
- 追尾は「最新更新の transcript」1 本（並行セッションは最後に動いた方を実況）
- assistant 本文はブロック確定ごと（トークン単位の途中経過は出ない）
- Desktop の main.log はローテーションで main1.log に切り替わる（TailReader は追従済み）

## 次のステップ案

1. CDP watcher の opt-in 実装（Web チャット対応）
2. 複数セッションの同時表示（セッションごとにミニ Clawn を並べる？）
3. 吹き出しクリックで該当セッション/プロジェクトへジャンプ
4. 応答完了時のサウンド・通知センター連携
5. アプリアイコン・ログイン項目登録の自動化・Sparkle 等での配布
