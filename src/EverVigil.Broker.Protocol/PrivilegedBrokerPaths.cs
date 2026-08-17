namespace EverVigil.Broker.Protocol;

public static class PrivilegedBrokerPaths
{
    public const string BrokerFileName = "EverVigil.Broker.exe";
    public const string PackageDirectoryName = "broker";
    public const string StateDirectoryName = "State";
    public const string PendingJournalFileName = "pending-system-configuration.json";
    public const string AppliedLedgerFileName = "applied-system-configuration.json";
    public const string TransactionReceiptFileName = "last-system-transaction.json";
    public const string InstallationReceiptFileName = "installation.json";
    public const string RetirementReceiptFileName = "retirement.json";

    public static string GetBrokerRoot(string commonApplicationData) =>
        Path.Combine(
            RequireAbsoluteRoot(commonApplicationData),
            "EverVigil",
            "Broker");

    public static string GetVersionRoot(string commonApplicationData, string version) =>
        Path.Combine(GetBrokerRoot(commonApplicationData), NormalizeVersion(version));

    public static string GetProtectedExecutablePath(
        string commonApplicationData,
        string version) =>
        Path.Combine(GetVersionRoot(commonApplicationData, version), BrokerFileName);

    public static string GetInstallationReceiptPath(
        string commonApplicationData,
        string version) =>
        Path.Combine(
            GetVersionRoot(commonApplicationData, version),
            InstallationReceiptFileName);

    public static string GetRetirementReceiptPath(
        string commonApplicationData,
        string version) =>
        Path.Combine(
            GetVersionRoot(commonApplicationData, version),
            RetirementReceiptFileName);

    public static string GetStateRoot(string commonApplicationData) =>
        Path.Combine(GetBrokerRoot(commonApplicationData), StateDirectoryName);

    public static string GetOwnerStateRoot(string commonApplicationData, string ownerSid)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(ownerSid);
        if (ownerSid.Length > 184 ||
            !ownerSid.StartsWith("S-", StringComparison.Ordinal) ||
            ownerSid.Skip(2).Any(character =>
                character is not (>= '0' and <= '9') and not '-'))
        {
            throw new ArgumentException("Broker owner SID is invalid.", nameof(ownerSid));
        }
        return Path.Combine(GetStateRoot(commonApplicationData), ownerSid);
    }

    public static string GetPendingJournalPath(
        string commonApplicationData,
        string ownerSid) =>
        Path.Combine(
            GetOwnerStateRoot(commonApplicationData, ownerSid),
            PendingJournalFileName);

    public static string GetAppliedLedgerPath(
        string commonApplicationData,
        string ownerSid) =>
        Path.Combine(
            GetOwnerStateRoot(commonApplicationData, ownerSid),
            AppliedLedgerFileName);

    public static string GetTransactionReceiptPath(
        string commonApplicationData,
        string ownerSid) =>
        Path.Combine(
            GetOwnerStateRoot(commonApplicationData, ownerSid),
            TransactionReceiptFileName);

    private static string RequireAbsoluteRoot(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var fullPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
        if (!Path.IsPathFullyQualified(fullPath))
        {
            throw new ArgumentException("Common application data path is not absolute.", nameof(path));
        }
        return fullPath;
    }

    private static string NormalizeVersion(string version)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(version);
        if (!Version.TryParse(version, out var parsed) ||
            parsed.Major < 0 || parsed.Minor < 0 || parsed.Build < 0)
        {
            throw new ArgumentException("Broker version is invalid.", nameof(version));
        }
        return $"{parsed.Major}.{parsed.Minor}.{parsed.Build}";
    }
}
