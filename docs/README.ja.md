# EverVigil 利用ガイド

[English](README.en.md) | [技術概要](TECHNICAL_OVERVIEW.ja.md) | [技術リファレンス](REFERENCE.ja.md) | [ルートREADME](../README.md)

This is an independent community project. It is not an official Even Realities product and is not developed, operated, maintained, certified, security-reviewed, or supported by Even Realities.

EverVigilは、Even Terminalを起動可能な状態に保つ独立したWindows通知領域
ユーティリティです。ユーザーが別途導入したEven Terminal packageとCodex
app-serverを管理し、これらの依存製品をEverVigilへ同梱しません。

## 前提

- Windows 11 x64
- PowerShell 7
- Node.js
- 別途導入した`@evenrealities/even-terminal`
- 導入済みかつユーザー自身が認証済みのCodex CLI
- 対象Tailnetへ接続済みのTailscale

EverVigilはCodexの認証情報を要求・読取り・保存・送信しません。設定された
Codex実行ファイルを、別途導入済みのEven Terminalから子プロセスとして起動する
だけです。

セットアップEXEは.NETランタイムを含みます。.NET SDKとInno Setupが必要なのは、
ソースからビルドする場合だけです。

## v2.0.0のインストール

1. GitHub Release
   <https://github.com/DaichiMatsumoto/evervigil/releases>から
   `EverVigil-2.0.0-Setup.exe`を取得します。
2. SHA-256を計算し、Releaseに掲載された正確な値と照合します。
3. installerを実行し、独立プロジェクトnoticeと導入先を確認して完了します。

コミュニティビルドはAuthenticode未署名のため、Microsoft Defender SmartScreenが
警告する場合があります。警告表示はhash検証の代替ではありません。実行前に
SHA-256を独立に確認してください。

既定の導入先は`%LOCALAPPDATA%\Programs\EverVigil`です。network path、保護された
system tree、一時tree、reparse point、SUBST drive、path aliasなど、安全性や実体が
曖昧な導入先は拒否します。通常権限で動作し、system構成が必要な導入ではApplyと
検証後Commitの短時間UACを最大2回使用します。通常の監視処理を常時昇格状態で動かしません。

依存実行ファイルを検出できない場合は通知領域画面を開き、正しい実行ファイルを
選択して保存し、同じinstallerを再実行してsystem設定を完了します。EverVigilは
アプリ全体のproject directoryを設定・注入しません。各Codex taskの要求済み／
保存済みworking directoryは、別途導入したproviderが管理します。

## ネットワーク構成

既定経路は次のとおりです。

```text
Even client / G2
  -> Tailscale Tailnet
  -> Tailscale Serve :3456
  -> 127.0.0.1:3457 Even Terminal
  -> 127.0.0.1:8765 Codex app-server
```

想定するServe操作は次と同等です。

```powershell
tailscale serve --yes --bg --http 3456 http://127.0.0.1:3457
```

EverVigilはTailscale Funnelを使用しません。port 3456はTailnet内だけで利用でき、
到達可否はTailnet ACLに依存します。Serveの転送先は上記loopback addressです。
アプリ所有・ユーザー識別可能なWindows Firewallルールでもport 3457への直接受信を
遮断します。

現在の検証対象である公式package `@evenrealities/even-terminal` 0.8.1は、HTTP listenerを
`0.0.0.0`へbindします。EverVigilは公式packageをpatchしないため、現時点では厳密な
loopback-only bindを強制できません。Firewallルールは必須の緩和策であり、この上流制約は
解決済みとせずRelease riskとして残します。

Serve経路を変更・削除する前に、転送先を永続化済み所有記録と照合します。別の
アプリやユーザーが所有する経路は変更しません。Firewall撤去にも同じ所有規則を
適用します。

## QRで接続

通知領域画面の接続panelを開きます。秘密情報は既定で非表示です。`表示`を選ぶと、
次のURLとローカル生成QR codeを表示します。

```text
http://<Tailscale-hostname>:3456/?token=<bridge-token>&defaultProvider=codex
```

URLとQR codeはcredentialです。EverVigilは次を実施します。

- QR codeをローカル生成し、外部QR serviceへpayloadを送りません。
- 約60秒後に再び非表示にします。
- windowが非アクティブになった時点で直ちに非表示にします。
- copyした値がclipboard履歴や他アプリに残る可能性を警告します。
- clipboard内容が変わっていなければ設定時間後に消去します。
- QR payloadやtokenをログへ書きません。

接続URLやQR codeをscreenshot、chat、Issue、診断bundleへ含めないでください。

約60秒という上限は表示credentialを隠す時間であり、tokenを失効させません。漏洩が
疑われる場合はtokenを再生成してください。

## 日常操作

通知領域menuからEverVigilを開き、managed serviceの開始・停止・再起動、health確認、
秘匿化済みログの閲覧を行います。windowを閉じると通知領域へ戻ります。EverVigilを
止める場合は通知領域の`終了`を使います。

自動起動を有効にすると、Windows login時に`EverVigil` Startup entryが通知領域
アプリだけを起動します。子process treeをWindows Job Objectへ所属させ、再起動・
更新・削除時に所有する子孫を停止します。反復障害には上限付き指数backoffと
crash-loop抑制を適用します。

## 手動更新

EverVigilに自動更新機能はありません。将来のReleaseでは、GitHub Releaseから新版installerを
取得し、実行前にSHA-256を確認してください。Release固有の更新要件は、そのReleaseへ記載します。

## 旧v1.2.1からのupgrade

EverVigil v2.0.0はin-place upgradeを採用します。既存のinstaller identityを内部の
移行keyとして保持することで、同じWindowsユーザーの対応する設定とDPAPI保護済み
tokenを安全に継続できます。このidentityはユーザー向け製品名ではありません。

移行時は、旧resourceを停止・削除する前に所有権を検証します。対応する設定、token、
自動起動選択を保持し、ユーザー向け名称をEverVigilへ置換します。新版が正常になった後で、
所有確認できた旧process、Startup entry、shortcut、Firewall rule、Serve経路、
transaction、support、program resourceだけを撤去し、重複を残しません。所有が
曖昧な場合はfail-closedで停止し、手動解決を要求します。

DPAPIで復号可能な状態を保つため、検証済みv1.2.1導入ではmigration中に互換data root、
entropy context、同期名を継続使用する場合があります。これらは`LegacyCompatibility`
内部だけに保持します。`token.dat`を手動移動しないでください。currentと旧data rootの
両方に永続状態がある場合、正本を推測せずfail-closedにします。

## アンインストール

次のいずれかから実行します。

- Windowsの`設定 > アプリ > インストールされているアプリ`
- Start menuのEverVigil uninstall shortcut

uninstallerはEverVigilとEverVigilが起動した子processを停止し、所有するTailscale
Serve経路とWindows Firewall構成だけを撤去し、EverVigilの自動起動・shortcut、
所有確認済み導入directory、transaction、一時fileを削除します。設定と暗号化tokenを
将来の再導入用に保持するか、削除するかを選べます。保持時は非公開の`BridgeHost`
process directoryも残します。削除を選んだ場合、空の`BridgeHost`は削除し、fileを
含む場合はそのfileを消さず正確な保持pathを報告します。

Tailscale、Node.js、Codex、`@evenrealities/even-terminal`、無関係な経路・rule・
folder・設定・ユーザー作成fileは削除しません。

## セキュリティ境界

- bridge tokenは16 random bytesを32桁16進文字列へencodeして生成します。
- application-specific entropy付きDPAPI `CurrentUser`で保護し、制限ACLで保存します。
- managed childへ`BRIDGE_TOKEN`環境変数で渡し、command lineへ載せません。
- child稼働中の`BRIDGE_TOKEN`はprocess環境内では平文であり、same-user software、
  administrator、process dumpから観測される可能性があります。DPAPIが保護するのは
  保存時のtokenです。
- URL query token、Bearer credential、既知token、32桁16進形式の値をログ前に秘匿化します。
- DPAPI `CurrentUser`は同じWindowsユーザーで動く悪意あるcodeを防ぐ境界ではなく、
  administratorもsecurity boundaryとして扱いません。
- Tailnetへの到達制御はTailscale identityとACL policyに依存します。
- Tailnet制御はnetwork到達範囲を狭めますが、bridge tokenの代替ではありません。
- telemetry、独自cloud backend、public relay、Funnel公開を追加しません。

詳細は[セキュリティ詳細](SECURITY.ja.md)と[技術概要](TECHNICAL_OVERVIEW.ja.md)を
参照してください。

## ライセンス

EverVigil source codeは[GNU General Public License version 3 only](../LICENSE)
（`GPL-3.0-only`）で提供します。iconは独自作成した正式なoriginal artworkです。
出自は[NOTICE.md](../NOTICE.md)に記載しています。
