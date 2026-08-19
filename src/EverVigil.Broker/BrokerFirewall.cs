using System.Globalization;
using System.Runtime.InteropServices;
using EverVigil.Compatibility;

namespace EverVigil.Broker;

internal sealed class BrokerFirewall
{
    private const string CurrentMainPrefix = "EverVigil - block direct backend access";
    private const string CurrentTemporaryPrefix = "EverVigil - pending backend block";
    private const string LegacyMainPrefix =
        LegacyCompatibility.Firewall.RulePrefix;
    private const string LegacyTemporaryPrefix =
        LegacyCompatibility.Firewall.TemporaryRulePrefix;

    private readonly string _ownerSid;

    internal BrokerFirewall(string ownerSid)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(ownerSid);
        _ownerSid = ownerSid;
        CurrentMainName = $"{CurrentMainPrefix} [{ownerSid}]";
        CurrentTemporaryName = $"{CurrentTemporaryPrefix} [{ownerSid}]";
        LegacyMainName = $"{LegacyMainPrefix} [{ownerSid}]";
        LegacyTemporaryName = $"{LegacyTemporaryPrefix} [{ownerSid}]";
    }

    internal string CurrentMainName { get; }

    internal string CurrentTemporaryName { get; }

    internal string LegacyMainName { get; }

    internal string LegacyTemporaryName { get; }

    internal IReadOnlyList<FirewallRuleIdentity> CapturePreflight(
        BrokerAppliedLedger? applied,
        bool allowLegacyMigration,
        int legacyBackendPort = 3457)
    {
        ValidatePort(legacyBackendPort);
        var snapshots = new List<FirewallRuleIdentity>();
        var currentMain = ReadSingleByName(CurrentMainName);
        var currentTemporary = ReadSingleByName(CurrentTemporaryName);
        if (applied is null)
        {
            if (!allowLegacyMigration &&
                (currentMain is not null || currentTemporary is not null))
            {
                throw new BrokerRefusalException(
                    "Current Firewall rules exist without a protected applied ledger.",
                    Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch);
            }
            if (allowLegacyMigration)
            {
                foreach (var current in new[] { currentMain, currentTemporary })
                {
                    if (current is null)
                    {
                        continue;
                    }
                    var expectedName = ReferenceEquals(current, currentMain)
                        ? CurrentMainName
                        : CurrentTemporaryName;
                    if (!IsExpectedIdentity(current, expectedName, legacyBackendPort))
                    {
                        throw new BrokerRefusalException(
                            "Current Firewall rule cannot be adopted as fixed v1.2.1 state.",
                            Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch);
                    }
                    snapshots.Add(current);
                }
            }
        }
        else
        {
            if (currentMain is null ||
                !IsExpectedIdentity(currentMain, CurrentMainName, applied.Configuration.BackendPort) ||
                currentTemporary is not null &&
                !IsExpectedIdentity(
                    currentTemporary,
                    CurrentTemporaryName,
                    applied.Configuration.BackendPort))
            {
                throw new BrokerRefusalException(
                    "Current Firewall rules do not match protected applied identity.",
                    Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch);
            }
            snapshots.Add(currentMain);
            if (currentTemporary is not null)
            {
                snapshots.Add(currentTemporary);
            }
        }

        var legacyMain = ReadSingleByName(LegacyMainName);
        var legacyTemporary = ReadSingleByName(LegacyTemporaryName);
        if (!allowLegacyMigration && (legacyMain is not null || legacyTemporary is not null))
        {
            throw new BrokerRefusalException(
                "Legacy Firewall rules exist outside an authorized migration.",
                Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch);
        }
        if (allowLegacyMigration)
        {
            foreach (var legacy in new[] { legacyMain, legacyTemporary })
            {
                if (legacy is null)
                {
                    continue;
                }
                var expectedName = ReferenceEquals(legacy, legacyMain)
                    ? LegacyMainName
                    : LegacyTemporaryName;
                if (!IsExpectedIdentity(legacy, expectedName, legacyBackendPort))
                {
                    throw new BrokerRefusalException(
                        "Legacy Firewall rule does not match its fixed v1 identity.",
                        Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch);
                }
                snapshots.Add(legacy);
            }
        }
        return snapshots;
    }

    internal void ConfigureTarget(
        int backendPort,
        IReadOnlyList<FirewallRuleIdentity> originalRules,
        bool removeLegacy)
    {
        ValidatePort(backendPort);
        RequireMatchesSnapshot(originalRules);
        DeleteExpectedIfPresent(CurrentTemporaryName, originalRules, [backendPort]);
        DeleteExpectedIfPresent(
            CurrentMainName,
            originalRules,
            originalRules.Where(rule => rule.Name == CurrentMainName)
                .Select(rule => rule.BackendPort)
                .Append(backendPort)
                .ToArray());
        AddExpected(CurrentMainName, backendPort);
        if (removeLegacy)
        {
            DeleteExpectedIfPresent(
                LegacyTemporaryName,
                originalRules,
                originalRules.Where(rule => rule.Name == LegacyTemporaryName)
                    .Select(rule => rule.BackendPort).ToArray());
            DeleteExpectedIfPresent(
                LegacyMainName,
                originalRules,
                originalRules.Where(rule => rule.Name == LegacyMainName)
                    .Select(rule => rule.BackendPort).ToArray());
        }
        RequireExpected(CurrentMainName, backendPort);
        RequireAbsent(CurrentTemporaryName);
        if (removeLegacy)
        {
            RequireAbsent(LegacyMainName);
            RequireAbsent(LegacyTemporaryName);
        }
    }

    internal void RestoreSnapshot(
        IReadOnlyList<FirewallRuleIdentity> originalRules,
        int transactionTargetPort)
    {
        ValidatePort(transactionTargetPort);
        foreach (var name in new[]
                 {
                     CurrentTemporaryName,
                     CurrentMainName,
                     LegacyTemporaryName,
                     LegacyMainName
                 })
        {
            var current = ReadSingleByName(name);
            if (current is null)
            {
                continue;
            }
            var original = originalRules.SingleOrDefault(rule =>
                string.Equals(rule.Name, name, StringComparison.Ordinal));
            var allowedPort = original?.BackendPort ?? transactionTargetPort;
            if (!IsExpectedIdentity(current, name, allowedPort))
            {
                throw new BrokerRefusalException(
                    "Firewall rollback found a rule outside protected ownership evidence.",
                    Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch,
                    pendingRecovery: true);
            }
            DeleteRule(name);
        }
        foreach (var original in originalRules)
        {
            AddExpected(original.Name, original.BackendPort);
        }
        RequireMatchesSnapshot(originalRules);
    }

    internal void RemoveAppliedRules(
        BrokerAppliedLedger applied,
        IReadOnlyList<FirewallRuleIdentity> durableSnapshot)
    {
        ArgumentNullException.ThrowIfNull(applied);
        DeleteExpectedIfPresent(
            CurrentTemporaryName,
            durableSnapshot,
            [applied.Configuration.BackendPort]);
        DeleteExpectedIfPresent(
            CurrentMainName,
            durableSnapshot,
            [applied.Configuration.BackendPort]);
        RequireAbsent(CurrentMainName);
        RequireAbsent(CurrentTemporaryName);
    }

    internal void VerifyTarget(int backendPort, bool requireLegacyAbsent)
    {
        RequireExpected(CurrentMainName, backendPort);
        RequireAbsent(CurrentTemporaryName);
        if (requireLegacyAbsent)
        {
            RequireAbsent(LegacyMainName);
            RequireAbsent(LegacyTemporaryName);
        }
    }

    internal void RemoveLegacyRules(IReadOnlyList<FirewallRuleIdentity> durableSnapshot)
    {
        DeleteExpectedIfPresent(LegacyTemporaryName, durableSnapshot, [3457]);
        DeleteExpectedIfPresent(LegacyMainName, durableSnapshot, [3457]);
        RequireAbsent(LegacyMainName);
        RequireAbsent(LegacyTemporaryName);
    }

    private void RequireMatchesSnapshot(IReadOnlyList<FirewallRuleIdentity> snapshot)
    {
        foreach (var name in new[]
                 {
                     CurrentMainName,
                     CurrentTemporaryName,
                     LegacyMainName,
                     LegacyTemporaryName
                 })
        {
            var expected = snapshot.SingleOrDefault(rule =>
                string.Equals(rule.Name, name, StringComparison.Ordinal));
            var current = ReadSingleByName(name);
            if (expected is null && current is null)
            {
                continue;
            }
            if (expected is null || current is null || !FullIdentityEquals(current, expected))
            {
                throw new BrokerRefusalException(
                    "Firewall state changed after durable preflight.",
                    Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch,
                    pendingRecovery: true);
            }
        }
    }

    private void DeleteExpectedIfPresent(
        string name,
        IReadOnlyList<FirewallRuleIdentity> originalRules,
        IReadOnlyCollection<int> transactionOwnedPorts)
    {
        var current = ReadSingleByName(name);
        if (current is null)
        {
            return;
        }
        var original = originalRules.SingleOrDefault(rule =>
            string.Equals(rule.Name, name, StringComparison.Ordinal));
        if (original is not null && FullIdentityEquals(original, current))
        {
            DeleteRule(name);
            return;
        }
        if (
            !transactionOwnedPorts.Any(port => IsExpectedIdentity(current, name, port)))
        {
            throw new BrokerRefusalException(
                "Firewall deletion was refused for an unowned full identity.",
                Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch,
                pendingRecovery: true);
        }
        DeleteRule(name);
    }

    private static bool FullIdentityEquals(
        FirewallRuleIdentity left,
        FirewallRuleIdentity right) =>
        string.Equals(left.Name, right.Name, StringComparison.Ordinal) &&
        left.BackendPort == right.BackendPort &&
        left.Enabled == right.Enabled &&
        left.Direction == right.Direction &&
        left.Action == right.Action &&
        left.Profiles == right.Profiles &&
        left.EdgeTraversal == right.EdgeTraversal &&
        left.EdgeTraversalOptions == right.EdgeTraversalOptions &&
        left.Protocol == right.Protocol &&
        string.Equals(left.RemotePorts, right.RemotePorts, StringComparison.Ordinal) &&
        string.Equals(left.LocalAddresses, right.LocalAddresses, StringComparison.Ordinal) &&
        string.Equals(left.RemoteAddresses, right.RemoteAddresses, StringComparison.Ordinal) &&
        string.Equals(left.ApplicationName, right.ApplicationName, StringComparison.Ordinal) &&
        string.Equals(left.LocalAppPackageId, right.LocalAppPackageId, StringComparison.Ordinal) &&
        left.Interfaces.SequenceEqual(right.Interfaces, StringComparer.Ordinal) &&
        string.Equals(left.InterfaceTypes, right.InterfaceTypes, StringComparison.Ordinal) &&
        string.Equals(left.ServiceName, right.ServiceName, StringComparison.Ordinal) &&
        left.SecureFlags == right.SecureFlags &&
        string.Equals(
            left.LocalUserAuthorizedList,
            right.LocalUserAuthorizedList,
            StringComparison.Ordinal) &&
        string.Equals(
            left.RemoteUserAuthorizedList,
            right.RemoteUserAuthorizedList,
            StringComparison.Ordinal) &&
        string.Equals(
            left.RemoteMachineAuthorizedList,
            right.RemoteMachineAuthorizedList,
            StringComparison.Ordinal) &&
        string.Equals(left.Description, right.Description, StringComparison.Ordinal) &&
        string.Equals(left.Grouping, right.Grouping, StringComparison.Ordinal) &&
        string.Equals(left.IcmpTypesAndCodes, right.IcmpTypesAndCodes, StringComparison.Ordinal);

    private static FirewallRuleIdentity? ReadSingleByName(string ruleName)
    {
        var matches = ReadRulesByName(ruleName);
        if (matches.Count > 1)
        {
            throw new BrokerRefusalException(
                "Duplicate named Firewall rules were detected.",
                Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch);
        }
        return matches.SingleOrDefault();
    }

    private static IReadOnlyList<FirewallRuleIdentity> ReadRulesByName(string ruleName)
    {
        NativeComDispatch? policy = null;
        NativeComDispatch? rules = null;
        IReadOnlyList<NativeComDispatch>? candidates = null;
        try
        {
            policy = NativeComDispatch.Create(NativeComDispatch.NetFwPolicy2ClassId);
            rules = policy.GetDispatchProperty("Rules");
            candidates = rules.EnumerateDispatchProperty("_NewEnum");
            var matches = new List<FirewallRuleIdentity>();
            foreach (var candidate in candidates)
            {
                if (string.Equals(
                        candidate.GetRequiredStringProperty("Name"),
                        ruleName,
                        StringComparison.OrdinalIgnoreCase))
                {
                    matches.Add(ReadIdentity(candidate));
                }
            }
            return matches;
        }
        catch (COMException exception)
        {
            throw new InvalidOperationException(
                "Windows Firewall rules could not be inspected safely.",
                exception);
        }
        finally
        {
            if (candidates is not null)
            {
                foreach (var candidate in candidates)
                {
                    candidate.Dispose();
                }
            }
            rules?.Dispose();
            policy?.Dispose();
        }
    }

    private static FirewallRuleIdentity ReadIdentity(NativeComDispatch rule)
    {
        var localPorts = rule.GetOptionalStringProperty("LocalPorts");
        if (!int.TryParse(
                localPorts,
                NumberStyles.None,
                CultureInfo.InvariantCulture,
                out var backendPort))
        {
            backendPort = 0;
        }
        return new FirewallRuleIdentity(
            rule.GetRequiredStringProperty("Name"),
            backendPort,
            rule.GetBooleanProperty("Enabled"),
            rule.GetInt32Property("Direction"),
            rule.GetInt32Property("Action"),
            rule.GetInt32Property("Profiles"),
            rule.GetBooleanProperty("EdgeTraversal"),
            rule.GetInt32Property("EdgeTraversalOptions"),
            rule.GetInt32Property("Protocol"),
            rule.GetOptionalStringProperty("RemotePorts"),
            rule.GetOptionalStringProperty("LocalAddresses"),
            rule.GetOptionalStringProperty("RemoteAddresses"),
            rule.GetOptionalStringProperty("ApplicationName"),
            rule.GetOptionalStringProperty("LocalAppPackageId"),
            rule.GetStringArrayProperty("Interfaces"),
            rule.GetOptionalStringProperty("InterfaceTypes"),
            rule.GetOptionalStringProperty("ServiceName"),
            rule.GetInt32Property("SecureFlags"),
            rule.GetOptionalStringProperty("LocalUserAuthorizedList"),
            rule.GetOptionalStringProperty("RemoteUserAuthorizedList"),
            rule.GetOptionalStringProperty("RemoteMachineAuthorizedList"),
            rule.GetOptionalStringProperty("Description"),
            rule.GetOptionalStringProperty("Grouping"),
            rule.GetOptionalStringProperty("IcmpTypesAndCodes"));
    }

    private static bool IsExpectedIdentity(
        FirewallRuleIdentity rule,
        string name,
        int backendPort) =>
        string.Equals(rule.Name, name, StringComparison.Ordinal) &&
        rule.BackendPort == backendPort &&
        rule.Enabled &&
        rule.Direction == 1 &&
        rule.Action == 0 &&
        rule.Profiles == int.MaxValue &&
        !rule.EdgeTraversal &&
        rule.EdgeTraversalOptions == 0 &&
        rule.Protocol == 6 &&
        string.Equals(rule.RemotePorts, "*", StringComparison.Ordinal) &&
        string.Equals(rule.LocalAddresses, "*", StringComparison.Ordinal) &&
        string.Equals(rule.RemoteAddresses, "*", StringComparison.Ordinal) &&
        IsUnset(rule.ApplicationName) &&
        IsUnset(rule.LocalAppPackageId) &&
        rule.Interfaces.Count == 0 &&
        string.Equals(rule.InterfaceTypes, "All", StringComparison.Ordinal) &&
        IsUnset(rule.ServiceName) &&
        rule.SecureFlags == 0 &&
        IsUnset(rule.LocalUserAuthorizedList) &&
        IsUnset(rule.RemoteUserAuthorizedList) &&
        IsUnset(rule.RemoteMachineAuthorizedList) &&
        IsUnset(rule.Description) &&
        IsUnset(rule.Grouping) &&
        IsUnset(rule.IcmpTypesAndCodes);

    private static void AddExpected(string name, int backendPort)
    {
        ValidatePort(backendPort);
        RequireAbsent(name);
        NativeComDispatch? policy = null;
        NativeComDispatch? rules = null;
        NativeComDispatch? rule = null;
        try
        {
            policy = NativeComDispatch.Create(NativeComDispatch.NetFwPolicy2ClassId);
            rules = policy.GetDispatchProperty("Rules");
            rule = NativeComDispatch.Create(NativeComDispatch.NetFwRuleClassId);
            rule.SetProperty("Name", name);
            rule.SetProperty("Enabled", true);
            rule.SetProperty("Direction", 1);
            rule.SetProperty("Action", 0);
            rule.SetProperty("Profiles", int.MaxValue);
            rule.SetProperty("EdgeTraversal", false);
            rule.SetProperty("Protocol", 6);
            rule.SetProperty("LocalPorts", backendPort.ToString(CultureInfo.InvariantCulture));
            rule.SetProperty("RemotePorts", "*");
            rule.SetProperty("LocalAddresses", "*");
            rule.SetProperty("RemoteAddresses", "*");
            rule.SetProperty("InterfaceTypes", "All");
            rules.InvokeMethod("Add", rule);
        }
        finally
        {
            rule?.Dispose();
            rules?.Dispose();
            policy?.Dispose();
        }
        RequireExpected(name, backendPort);
    }

    private static void DeleteRule(string name)
    {
        NativeComDispatch? policy = null;
        NativeComDispatch? rules = null;
        try
        {
            policy = NativeComDispatch.Create(NativeComDispatch.NetFwPolicy2ClassId);
            rules = policy.GetDispatchProperty("Rules");
            rules.InvokeMethod("Remove", name);
        }
        finally
        {
            rules?.Dispose();
            policy?.Dispose();
        }
        RequireAbsent(name);
    }

    private static void RequireExpected(string name, int backendPort)
    {
        var rule = ReadSingleByName(name);
        if (rule is null || !IsExpectedIdentity(rule, name, backendPort))
        {
            throw new InvalidOperationException("Windows Firewall rule identity verification failed.");
        }
    }

    private static void RequireAbsent(string name)
    {
        if (ReadRulesByName(name).Count != 0)
        {
            throw new InvalidOperationException("Windows Firewall rule remained unexpectedly.");
        }
    }

    private static bool IsUnset(string? value) => string.IsNullOrEmpty(value);

    private static void ValidatePort(int port)
    {
        if (port is < 1024 or > 65535)
        {
            throw new ArgumentOutOfRangeException(nameof(port));
        }
    }
}
