# EverVigil v2.0.0

First public release.

This is an independent community project. It is not an official Even Realities product and is not developed, operated, maintained, certified, security-reviewed, or supported by Even Realities.

## English

### First public release

- Introduces EverVigil as an independent Windows tray utility with its own
  product name, repository, executable, installer, and visual identity.
- Uses factual, non-prominent compatibility references only where needed to
  explain operation with the separately installed Even Terminal package.
- Displays the independent-project notice in the README, release material,
  installer, and application About page.

### Brand and distribution boundaries

- Uses independently created original icon artwork made from neutral geometric
  shapes. No Even Realities logo, favicon, derived icon, product icon, or other
  visual brand asset is included.
- Does not display a recognition, certification, endorsement, or compatibility
  badge.
- Ships EverVigil source under GPL-3.0-only without bundling, modifying,
  patching, forking, or redistributing `@evenrealities/even-terminal` or Codex.
- Has no automatic updater, analytics endpoint, telemetry service, relay
  service, or project-operated cloud backend.

### Capabilities and reliability

- Provides Tailnet identity display and connection-URL copy actions in a
  standard medium-integrity session while protecting broker state with a
  restrictive ACL.
- Keeps the protected shared-state directory non-listable and exposes values
  only after validating the current user's protected identity ledger.
- Treats the packaged English and Japanese screenshot assets as part of the
  exact owned installation layout while rejecting unknown files and
  directories fail-closed.
- Defines no application-wide workspace field and exports neither `PROJECT_DIR`
  nor a global `--cwd`; requested and saved task working directories remain
  owned by the separately installed provider.
- Uses an ACL-restricted internal `BridgeHost` as the bridge process host rather
  than a configured workspace, and retains it during rollback or uninstall
  whenever it contains files.

### Operation

- Provides Even Terminal launch, Codex app-server launch, child-process
  supervision, bounded restart, Windows login startup, tray operation,
  Tailscale Serve, local QR generation, health checks, credential redaction,
  transactional rollback for future EverVigil updates, safe uninstall, and
  English/Japanese UI.

### Distribution and security

- The user installs `@evenrealities/even-terminal` separately. EverVigil does
  not bundle, fork, patch, or redistribute that package.
- Installation and update are manual: download
  `EverVigil-2.0.0-Setup.exe` from the GitHub Release, verify the
  published SHA-256, and run the installer. There is no automatic updater.
- The installer is unsigned and may trigger Microsoft Defender SmartScreen.
- Tailscale Serve is Tailnet-only, depends on Tailnet ACLs, and does not use
  Funnel. Unrelated Serve routes and Firewall rules are not overwritten or
  removed.
- The tested upstream `@evenrealities/even-terminal` 0.8.1 listener binds to
  `0.0.0.0`. EverVigil does not patch it; an owned Firewall block rule is the
  required mitigation, and strict loopback-only binding remains a release risk.
- Uninstall stops owned processes, removes owned system and application
  resources, and lets the user retain or remove settings and the encrypted
  token. Tailscale, Node.js, Codex, the separately installed Even Terminal
  package, and unrelated user data are not removed.

## 日本語

### 初回公開リリース

- 独自の製品名、repository、実行file、installer、visual identityを持つ独立
  Windows tray utilityとしてEverVigilを初めて公開します。
- 別途導入するEven Terminal packageとの動作関係を説明する必要がある箇所だけで、
  事実に限定した非顕著な互換性表現を使用します。
- 独立projectであることを示すnoticeをREADME、Release material、installer、
  application About pageへ表示します。

### ブランドと配布の境界

- 中立的な幾何形状から独自に制作したoriginal iconを使用します。Even Realitiesの
  logo、favicon、派生icon、product icon、その他のvisual brand assetは含みません。
- 認識、認定、推奨、互換性を示すbadgeは表示しません。
- EverVigil sourceをGPL-3.0-onlyで配布し、`@evenrealities/even-terminal`と
  Codexをbundle、変更、patch、fork、再配布しません。
- 自動updater、analytics endpoint、telemetry service、relay service、
  project独自のcloud backendはありません。

### 機能と信頼性

- 制限ACLでbroker stateを保護しながら、標準のmedium-integrity sessionで
  Tailnet identityの表示と接続URLのコピーを提供します。
- 保護shared-state directoryを列挙不可とし、現在のユーザーに属する保護identity
  ledgerを検証した後だけ値を表示します。
- packageに含まれる日英screenshot assetを厳密な所有導入layoutとして扱い、未知の
  fileやdirectoryはfail-closedで拒否します。
- アプリ全体のworkspace fieldを持たず、`PROJECT_DIR`をexportせず、global `--cwd`も
  指定しません。各taskの要求済み／保存済みworking directoryは、別途導入した
  providerが管理します。
- ACLを制限した内部`BridgeHost`を設定workspaceではなくbridge processのhostとして
  使用し、fileを含む場合はrollback／uninstallでも保持します。

### 動作

- Even Terminal起動、Codex app-server起動、子process監視、上限付き再起動、
  Windows login時起動、通知領域操作、Tailscale Serve、ローカルQR生成、health check、
  認証情報秘匿化、将来のEverVigil更新に対するtransactional rollback、安全な
  uninstall、日英UIを提供します。

### 配布とセキュリティ

- `@evenrealities/even-terminal`はユーザーが別途導入します。EverVigilは
  このpackageをbundle、fork、patch、再配布しません。
- 導入・更新は手動です。GitHub Releaseから
  `EverVigil-2.0.0-Setup.exe`を取得し、公開SHA-256を照合してから実行します。
  自動更新機能はありません。
- installerは未署名で、Microsoft Defender SmartScreenが警告する場合があります。
- Tailscale ServeはTailnet内だけで利用し、Tailnet ACLに依存します。
  Funnelは使用せず、無関係なServe経路やFirewallルールを変更・削除しません。
- 検証対象の公式`@evenrealities/even-terminal` 0.8.1はlistenerを`0.0.0.0`へbindします。
  EverVigilはこれをpatchせず、所有Firewall block ruleを必須の緩和策とします。
  厳密なloopback-only bindはRelease riskとして残ります。
- uninstallは所有するプロセスとシステム・アプリ資源だけを撤去し、設定と
  暗号化tokenを保持するか削除するかを選べます。Tailscale、Node.js、Codex、
  別途導入したEven Terminal package、無関係なユーザーデータは削除しません。
