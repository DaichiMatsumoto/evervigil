# EverVigil product identity shared by installation and maintenance scripts.

$script:EverVigilProductAppId = 'D1ACB787-2308-4AC4-91BD-A6A3856E7AF0'
$script:EverVigilProductUninstallRegistrySubKey =
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\{D1ACB787-2308-4AC4-91BD-A6A3856E7AF0}_is1'

$script:EverVigilSettingsFileName = 'settings.json'
$script:EverVigilProtectedTokenFileName = 'token.dat'
$script:EverVigilTransactionJournalFileName = 'install-transaction.json'
$script:EverVigilTransactionRecoveryDirectoryName = 'install-transactions'
$script:EverVigilTransactionSchemaVersion = 3
$script:EverVigilInstallerPublishDirectoryPrefix = 'install-publish-'
$script:EverVigilAppliedSystemConfigurationFileName = 'applied-system-configuration.json'
$script:EverVigilSystemConfigurationRequiredFileName = 'system-configuration-required'
$script:EverVigilDiagnosticLoggingMarkerFileName = 'diagnostic-logging.enabled'
$script:EverVigilLogDirectoryName = 'Logs'
$script:EverVigilLogFileName = 'evervigil.log'

$script:EverVigilSystemTransactionMutex = 'Global\EverVigil.SystemTransaction'
$script:EverVigilInstallerTaskPrefix = 'EverVigil Installer'
