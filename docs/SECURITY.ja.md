# EverVigil セキュリティ詳細

[English](SECURITY.en.md) | [報告ポリシー](../SECURITY.md) | [技術概要](TECHNICAL_OVERVIEW.ja.md)

対象release: EverVigil v2.0.0。Repository:
<https://github.com/DaichiMatsumoto/evervigil>。

## Bridge token

- 暗号学的に安全な乱数生成器で16 bytesを生成し、32桁の小文字16進文字列へencodeします。
- application-specific entropy付きWindows DPAPI `CurrentUser`でtokenを保護します。
- data directoryとtoken fileに、current user、`SYSTEM`、local administratorだけを
  許可する制限ACLを設定します。
- 一時fileから原子的にmoveし、partial writeを有効tokenとして扱いません。
- managed bridgeへ`BRIDGE_TOKEN`環境変数で渡し、command-line argumentへ含めません。
- 平文tokenを設定、Git、setup package、ログへ保存しません。

managed bridge稼働中はchild process環境内に平文tokenが存在し、same-user process
inspection、crash dump、administratorから見える可能性があります。DPAPIが保護するのは
保存時tokenであり、これらの主体からlive processを保護しません。

DPAPI `CurrentUser`は、同じWindowsユーザーで動く悪意あるsoftwareから保護する境界では
ありません。local administratorもuser sessionへaccess・干渉できるためsecurity boundary
ではありません。Windows accountとdevice自体を保護してください。

## Codex認証情報

EverVigilはCodex認証情報を要求、調査、読取り、保存、copy、export、送信しません。
認証はユーザーが別途導入したCodex CLIが管理します。EverVigilが保存するのは、子processを
起動・health-checkするために必要な実行pathとlocal app-server portだけです。
managed bridge環境は非secretな明示allowlistから再構築し、親processのAPI key、Codex認証
環境変数、proxy変数、継承search pathをthird-party Node processへ渡しません。

## QR・表示・clipboard

- token、接続URL、QR codeはcredentialとして既定非表示にします。
- QR codeをローカル生成し、外部serviceへpayloadを送りません。
- 明示的な`表示`操作が必要で、約60秒後に再び隠します。
- window非アクティブ時は直ちに隠します。
- copy時はclipboard履歴や他applicationへ残る可能性を警告します。
- 内容が変わっていなければ設定時間後に消去し、clipboard lock時は上限付き再試行します。
- token再生成は確認を要求し、再生成前にserviceが動いていた場合だけ再起動します。

約60秒の表示上限はtokenを失効・rotateしません。漏洩が疑われる場合は再生成してください。

URLまたはQR codeを取得した者はbridge tokenを取得したことになります。screen capture、
accessibility software、clipboard manager、same-user processが、意図的に表示したsecretを
観測できる可能性があります。

## Network

- 想定経路はTailnet client -> Tailscale Serve `:3456` ->
  `127.0.0.1:3457` -> `127.0.0.1:8765`です。
- Serve転送先とCodex app-serverはloopback addressを使用します。アプリ所有・SID識別可能な
  Windows Firewall ruleでEven Terminal backendへの直接受信を遮断します。
- 検証対象の公式`@evenrealities/even-terminal` 0.8.1はlistenerを`0.0.0.0`へbindします。
  EverVigilはこれをpatchしないため、現時点で厳密なloopback-only bindを保証できません。
  所有Firewall ruleは必須の緩和策であり、この点はRelease riskとして残ります。
- Tailscale ServeはTailnet-onlyで、Tailnet ACL policyに依存し、Funnelを使いません。
- public-Internet listener、telemetry endpoint、独自cloud backend、外部relayを追加しません。
- Serve経路とFirewall ruleは、保護broker台帳、user identity、target、期待属性が一致した
  場合だけ変更・削除します。
- health、表示、copyはさらに、read-onlyの現在Serve statusで保護対象root proxyの完全一致と
  Funnel無効を確認できる場合だけ許可します。
- 無関係または曖昧な経路・ruleは変更しません。
- 初回Applyでは、Setupがpackage brokerのsource path全体をlock・検証してから昇格し、同じprocessで
  canonical ProgramData brokerの導入と認証済みApplyを完了します。以後の操作で昇格するのは
  canonical brokerだけです。通知領域EXE、PowerShell script、user-writableな導入fileを昇格しません。
- brokerはmedium-integrity named-pipe clientのprocess、SID、session、integrity level、nonceを
  認証し、特権所有権証拠を保護済みSID別ProgramData journal/台帳だけへ保存します。
- 初回のsystem構成が成功する場合のUACは、導入＋Applyと検証後Commitの短時間2回までです。
  通常監視を常時昇格しません。
- system設定の欠損・破損・未適用時はbackend起動を禁止します。

Tailnet所属だけではaccess許可になりません。Tailnet administratorはbridge credentialと
deviceに適したACL policyを維持する必要があります。
network到達制御はbridge-token認証の代替ではなく、same-host softwareはloopback endpointへ
接続を試みられます。

## Process supervision

- EverVigilとNode.jsをconsole windowなしで起動します。
- 子孫生成前にbridge launcherをWindows Job Objectへ所属させます。
- Job Object終了によりrestart、rollback、exit、uninstall時に所有process treeを回収します。
- single-instance同期をWindows user単位にします。
- restart backoffとcrash-loop抑制により反復復旧へ上限を設けます。
- Startupはuser権限で動き、昇格maintenanceは分離した短時間処理です。

## Logging and redaction

- URLの`token` query値、Bearer credential、既知bridge token、32桁16進token形式値を
  書込み前に秘匿化します。
- QR payloadと完全な接続URLをログへ出しません。
- log sizeと世代数を制限し、制限ACLを適用します。
- 通常運用では子processのstdoutとstderrを排出しますが保持しません。
- Codex認証情報を収集・記録しません。

診断出力にはlocal path、hostname、process error、application contentが残る場合があります。
共有前に手動で確認・sanitizationしてください。

## Install・手動更新・rollback・removal

- 自動更新機能はありません。GitHub Releaseを手動取得し、SHA-256を検証して実行します。
- コミュニティbinaryは未署名でMicrosoft Defender SmartScreenが警告する場合があります。
- 未署名v2.0.0 brokerの初回bootstrapはpublisher認証済みtrust anchorではありません。将来の
  broker置換には承認済みcode signingまたはOS-trusted installer設計が必要です。
- SHA-256一致が示すのはfile identityであり、publisher identityや安全性ではありません。
- installerとchecksumを同じReleaseから取得する場合、SHA-256だけではpublisher真正性を
  独立に証明できないため、repositoryとRelease identityも確認してください。
- setupは最終filesystem targetを検証し、曖昧なalias、reparse point、保護tree、無関係な
  non-empty destinationを拒否します。
- 変更前に永続journalと検証済みsnapshotを作り、update有効化失敗時は設定、token、
  自動起動設定を復元します。
- 旧service再起動前にrollbackを検証し、検証不能なら起動禁止を維持します。
- uninstallは所有processを停止し、所有確認済み経路、rule、Startup entry、shortcut、
  support data、transaction、一時data、検証済み導入directoryだけを削除します。
- 設定とDPAPI tokenを保持・削除するかをユーザーが選択します。
- 保持を選ぶと暗号化tokenと設定をdata directoryへ意図的に残します。削除を選んでも
  非空の内部`BridgeHost`はpathを報告して保持し、空の場合だけ所有確認後に削除します。
- Tailscale、Node.js、Codex、`@evenrealities/even-terminal`、無関係な経路・rule、
  独自作成されたuser dataは削除しません。

## 外部dependencyの制限

EverVigilはWindows、Tailscale、Node.js、Even Terminal、Codexに依存します。各製品は独自の
update、availability、authentication、security modelを持ちます。EverVigilのhealth checkと
所有権検査は、それらの製品を認定するものではありません。
