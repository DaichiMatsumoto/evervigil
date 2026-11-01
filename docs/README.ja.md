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
- 別途導入した`@evenrealities/even-terminal` 0.10.5
- 導入済みかつユーザー自身が認証済みのCodex CLI
- Claudeを使う場合は、ユーザー自身が認証済みのClaude Code
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
選択して保存し、同じinstallerを再実行してsystem設定を完了します。

## Codex・Claudeの開始フォルダとモデル

次回リリース向けのソースでは、`設定`画面からそれぞれ独立して指定できます。

1. `Codex`と`Claude`の各欄で、CLIの実行ファイルと新規セッションの開始フォルダを選びます。
   Claude CLIのパスが空欄の場合はEven Terminal同梱のSDK用CLIを使います。
2. サービスの稼働中にモデルのプルダウンを開くと、各CLIのモデル候補を取得します。
   CLIパス・開始フォルダを変更した場合は、一度保存して再起動してから候補を取得してください。
   モデルIDの直接入力もできます。空欄なら各CLIの設定を使います。利用可能なモデルは契約とCLIに依存します。
3. `保存して再起動`を押し、Evenから新規セッションを作成します。

開始フォルダの既定値はWindowsユーザーフォルダです。リクエストにフォルダ指定があれば
そちらを優先し、既存セッションは元のフォルダを維持します。フォルダが削除された場合は
エラーになり、別の場所では開始しません。モデル指定は再起動後のEverVigil管理下の
リクエストへ適用します。既に別端末で動作中のClaude CLIは、その端末のモデル設定を使います。

EverVigilからの起動では`%USERPROFILE%\.even-terminal\config.json`のClaudeツール承認設定だけを
引き継ぎます。起動パス・モデル・ポート等はEverVigilで設定し、認証と各CLI固有の設定は各CLIで管理してください。
設定や診断画像を公開する際は、ユーザー名・実際のプロジェクトパス・接続情報を除いてください。

モデル候補はCodexの`model/list`とClaude Agent SDKの`supportedModels()`で取得します。
Claudeの候補取得はプロンプトを送らず、セッションを保存せずに終了します。

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

対応する公式package `@evenrealities/even-terminal` 0.10.5は、Tailscaleモードで
Tailscale IPv4とloopbackに待ち受けます。loopback限定ではないため、backendへの
直接受信を遮断する所有Firewallルールは引き続き必要です。

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

EverVigil v2.0.0が最初で現在唯一の公開Releaseです。EverVigilに自動更新機能は
ありません。将来のReleaseでは、GitHub Releaseから新版installerを取得し、実行前に
SHA-256を確認してください。検証済みEverVigilを更新する場合、installerは対応する
設定、DPAPI保護済みtoken、自動起動選択を保持します。保護commit境界より前の失敗では
検証済みの更新前状態を復元し、状態が曖昧または検証不能ならfail-closedで停止します。
Release固有の更新要件は、そのReleaseへ記載します。

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
