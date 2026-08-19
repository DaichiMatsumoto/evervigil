using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Xml;
using System.Xml.Linq;
using EverVigil.Compatibility;

namespace EverVigil.Broker;

internal sealed class LegacyScheduledTask
{
    internal const string FixedTaskName =
        LegacyCompatibility.OlderEvenTerminalCodex.ScheduledTaskName;
    private const int MaximumTaskXmlCharacters = 512 * 1024;
    private readonly string _ownerSid;
    private readonly string _profilePath;
    private readonly string _powerShellPath;
    private readonly HashSet<string> _allowedLauncherPaths;

    internal LegacyScheduledTask(string ownerSid)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(ownerSid);
        _ownerSid = ownerSid;
        var ownerPaths = LegacyV121Evidence.ResolveOwnerPaths(ownerSid);
        _profilePath = ownerPaths.ProfilePath;
        _powerShellPath = Path.GetFullPath(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            LegacyCompatibility.OlderEvenTerminalCodex.PowerShellRelativeToProgramFiles));
        _allowedLauncherPaths = BuildAllowedLauncherPaths(
            _profilePath,
            ownerPaths.LocalAppDataPath);
    }

    internal LegacyTaskIdentity? CaptureIfOwned()
    {
        var xml = ReadTaskXml();
        if (xml is null)
        {
            return null;
        }
        ValidateOwnedXml(xml);
        return new LegacyTaskIdentity(FixedTaskName, xml);
    }

    internal void RemoveOwned(LegacyTaskIdentity snapshot)
    {
        ValidateSnapshot(snapshot);
        var current = ReadTaskXml();
        if (current is null)
        {
            return;
        }
        ValidateOwnedXml(current);
        if (!FixedTimeEquals(HashXml(current), HashXml(snapshot.Xml)))
        {
            throw new BrokerRefusalException(
                "Legacy scheduled task changed after durable preflight.",
                Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch,
                pendingRecovery: true);
        }
        WithRootFolder((root, task) =>
        {
            if (task is null)
            {
                return;
            }
            task.InvokeMethod("Stop", 0);
            root.InvokeMethod("DeleteTask", FixedTaskName, 0);
        });
        if (ReadTaskXml() is not null)
        {
            throw new InvalidOperationException("Legacy scheduled task remained after removal.");
        }
    }

    internal void RestoreOwned(LegacyTaskIdentity snapshot)
    {
        ValidateSnapshot(snapshot);
        var current = ReadTaskXml();
        if (current is not null)
        {
            ValidateOwnedXml(current);
            if (!FixedTimeEquals(HashXml(current), HashXml(snapshot.Xml)))
            {
                throw new BrokerRefusalException(
                    "Legacy scheduled task name is occupied by another identity.",
                    Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch,
                    pendingRecovery: true);
            }
            return;
        }
        WithRootFolder((root, _) =>
        {
            root.InvokeMethod(
                "RegisterTask",
                FixedTaskName,
                snapshot.Xml,
                6,
                NativeComDispatch.NativeComMissing.Value,
                NativeComDispatch.NativeComMissing.Value,
                3,
                NativeComDispatch.NativeComMissing.Value);
        });
        var restored = ReadTaskXml() ??
            throw new InvalidOperationException("Legacy scheduled task was not restored.");
        ValidateOwnedXml(restored);
    }

    private string? ReadTaskXml()
    {
        string? xml = null;
        WithRootFolder((_, task) =>
        {
            if (task is null)
            {
                return;
            }
            xml = task.GetRequiredStringProperty("Xml");
        });
        return xml;
    }

    private void WithRootFolder(
        Action<NativeComDispatch, NativeComDispatch?> action)
    {
        NativeComDispatch? service = null;
        NativeComDispatch? root = null;
        NativeComDispatch? task = null;
        try
        {
            service = NativeComDispatch.Create(NativeComDispatch.TaskSchedulerClassId);
            service.InvokeMethod("Connect");
            root = service.InvokeDispatchMethod("GetFolder", @"\");
            try
            {
                task = root.InvokeDispatchMethod("GetTask", FixedTaskName);
            }
            catch (COMException exception) when (
                unchecked((uint)exception.HResult) is 0x80070002 or 0x8004130F)
            {
                task = null;
            }
            action(root, task);
        }
        finally
        {
            task?.Dispose();
            root?.Dispose();
            service?.Dispose();
        }
    }

    private void ValidateSnapshot(LegacyTaskIdentity snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!string.Equals(snapshot.Name, FixedTaskName, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Legacy task snapshot name is invalid.");
        }
        ValidateOwnedXml(snapshot.Xml);
    }

    private void ValidateOwnedXml(string xml)
    {
        if (string.IsNullOrWhiteSpace(xml) || xml.Length > MaximumTaskXmlCharacters)
        {
            throw new InvalidDataException("Legacy scheduled task XML size is invalid.");
        }
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Prohibit,
            XmlResolver = null,
            MaxCharactersInDocument = MaximumTaskXmlCharacters
        };
        XDocument document;
        using (var reader = XmlReader.Create(new StringReader(xml), settings))
        {
            document = XDocument.Load(reader, LoadOptions.None);
        }
        var root = document.Root ??
            throw new InvalidDataException("Legacy scheduled task XML root is missing.");
        var ns = root.Name.Namespace;
        if (!string.Equals(
                ns.NamespaceName,
                "http://schemas.microsoft.com/windows/2004/02/mit/task",
                StringComparison.Ordinal) ||
            !string.Equals(root.Name.LocalName, "Task", StringComparison.Ordinal))
        {
            throw new InvalidDataException("Legacy scheduled task XML namespace is invalid.");
        }

        var actions = root.Element(ns + "Actions")?.Elements().ToArray() ?? [];
        if (actions.Length != 1 || actions[0].Name != ns + "Exec")
        {
            throw new BrokerRefusalException(
                "Legacy scheduled task has an unexpected action set.",
                Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch);
        }
        var command = actions[0].Element(ns + "Command")?.Value;
        var arguments = actions[0].Element(ns + "Arguments")?.Value;
        var workingDirectory = actions[0].Element(ns + "WorkingDirectory")?.Value;
        if (!string.Equals(
                Path.GetFullPath(command ?? string.Empty),
                _powerShellPath,
                StringComparison.OrdinalIgnoreCase) ||
            !string.IsNullOrEmpty(workingDirectory))
        {
            throw new BrokerRefusalException(
                "Legacy scheduled task executable identity is unexpected.",
                Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch);
        }
        var matchingLauncher = _allowedLauncherPaths.SingleOrDefault(path =>
            string.Equals(
                arguments,
                LegacyCompatibility.OlderEvenTerminalCodex.LauncherArgumentsTemplate.Replace(
                    "{launcherPath}",
                    path,
                    StringComparison.Ordinal),
                StringComparison.OrdinalIgnoreCase));
        if (matchingLauncher is null)
        {
            throw new BrokerRefusalException(
                "Legacy scheduled task arguments are unexpected.",
                Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch);
        }
        var principals = root.Element(ns + "Principals")?.Elements(ns + "Principal").ToArray() ?? [];
        if (principals.Length != 1 ||
            !string.Equals(
                principals[0].Element(ns + "UserId")?.Value,
                _ownerSid,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new BrokerRefusalException(
                "Legacy scheduled task principal is not the authenticated owner SID.",
                Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch);
        }
    }

    internal static bool IsAllowedLauncherPathForTests(
        string profilePath,
        string localAppDataPath,
        string candidatePath) =>
        BuildAllowedLauncherPaths(profilePath, localAppDataPath).Contains(
            Path.GetFullPath(candidatePath));

    private static HashSet<string> BuildAllowedLauncherPaths(
        string profilePath,
        string localAppDataPath)
    {
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            Path.GetFullPath(Path.Combine(
                profilePath,
                LegacyCompatibility.OlderEvenTerminalCodex
                    .LocalAppDataLauncherRelativeToProfile)),
            Path.GetFullPath(Path.Combine(
                localAppDataPath,
                LegacyCompatibility.OlderEvenTerminalCodex
                    .LocalAppDataLauncherRelativeToLocalAppData))
        };
        var profileDirectory = Path.GetFileName(
            Path.TrimEndingDirectorySeparator(profilePath));
        if (string.IsNullOrWhiteSpace(profileDirectory))
        {
            throw new InvalidDataException("Authenticated owner profile directory is invalid.");
        }
        foreach (var driveLetter in Enumerable.Range('A', 26).Select(value => (char)value))
        {
            paths.Add(Path.GetFullPath(Path.Combine(
                $@"{driveLetter}:\",
                LegacyCompatibility.OlderEvenTerminalCodex
                    .DriveLauncherRelativeToProfileDirectory.Replace(
                        "{profileDirectory}",
                        profileDirectory,
                        StringComparison.Ordinal))));
        }
        return paths;
    }

    private static byte[] HashXml(string xml) =>
        SHA256.HashData(Encoding.UTF8.GetBytes(xml));

    private static bool FixedTimeEquals(byte[] left, byte[] right) =>
        CryptographicOperations.FixedTimeEquals(left, right);
}
