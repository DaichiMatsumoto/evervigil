# EverVigil v2.0.0

Release status: private release candidate pending verification and approval.

This is an independent community project. It is not an official Even Realities product and is not developed, operated, maintained, certified, security-reviewed, or supported by Even Realities.

## English

### New product and repository

- Establishes EverVigil as a new product in a new repository with no inherited
  Git commits, branches, tags, Releases, or artifacts.
- Continues the useful process-supervision behavior of the legacy v1.2.1
  application while changing every user-facing product surface to EverVigil.
- Uses original `temporary-placeholder` icon artwork that is not derived from
  Even Realities artwork. No certification or recognition badge is included.

### Compatibility and operation

- Uses an in-place v1.2.1 upgrade path to preserve settings, the
  DPAPI-protected bridge token, installation ownership, and startup preference.
- Removes or replaces only validated legacy resources owned by the prior
  installation so old processes, startup entries, shortcuts, Firewall rules,
  Serve routes, and installation files do not remain duplicated.
- Keeps Even Terminal launch, Codex app-server launch, child-process
  supervision, bounded restart, Windows login startup, tray operation,
  Tailscale Serve, local QR generation, health checks, credential redaction,
  transactional rollback, safe uninstall, and English/Japanese UI.

### Distribution and security

- The user installs `@evenrealities/even-terminal` separately. EverVigil does
  not bundle, fork, patch, or redistribute that package.
- Installation and update are manual: download
  `EverVigil-2.0.0-Setup.exe` from the approved GitHub Release, verify the
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

### 新製品と新リポジトリ

- 旧Gitのcommit、branch、tag、Release、artifactを継承せず、EverVigilを
  新しい製品・新しいリポジトリとして構築します。
- 旧v1.2.1アプリケーションの有用なプロセス監督機能を継承しつつ、
  ユーザー向け名称をすべてEverVigilへ変更します。
- Even Realitiesのアートワークから派生していない、独自生成の
  `temporary-placeholder`アイコンを使用します。認定・認識バッジは含みません。

### 互換性と動作

- v1.2.1からのin-place upgradeにより、設定、DPAPI保護済みbridge token、
  導入所有情報、自動起動設定を保持します。
- 旧プロセス、自動起動、ショートカット、Firewallルール、Serve経路、
  導入ファイルは、旧導入による所有を検証できたものだけを置換・撤去し、
  移行後の重複を防ぎます。
- Even Terminal起動、Codex app-server起動、子プロセス監視、上限付き再起動、
  Windowsログイン時起動、通知領域操作、Tailscale Serve、ローカルQR生成、
  health check、認証情報秘匿化、transactional rollback、安全なuninstall、
  日英UIを維持します。

### 配布とセキュリティ

- `@evenrealities/even-terminal`はユーザーが別途導入します。EverVigilは
  このpackageをbundle、fork、patch、再配布しません。
- 導入・更新は手動です。承認済みGitHub Releaseから
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

## SHA-256

`EverVigil-2.0.0-Setup.exe`

```text
{{EVERVIGIL_INSTALLER_SHA256}}
```
