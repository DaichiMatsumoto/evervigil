using System.Security.AccessControl;
using System.Security.Principal;

namespace EverVigil.Broker;

internal static class ProtectedBrokerAccess
{
    private static readonly SecurityIdentifier SystemSid = new(
        WellKnownSidType.LocalSystemSid,
        null);
    private static readonly SecurityIdentifier AdministratorsSid = new(
        WellKnownSidType.BuiltinAdministratorsSid,
        null);
    private static readonly SecurityIdentifier UsersSid = new(
        WellKnownSidType.BuiltinUsersSid,
        null);

    private const FileSystemRights DangerousRights =
        FileSystemRights.WriteData |
        FileSystemRights.CreateFiles |
        FileSystemRights.AppendData |
        FileSystemRights.CreateDirectories |
        FileSystemRights.WriteExtendedAttributes |
        FileSystemRights.DeleteSubdirectoriesAndFiles |
        FileSystemRights.WriteAttributes |
        FileSystemRights.Delete |
        FileSystemRights.ChangePermissions |
        FileSystemRights.TakeOwnership;

    internal static void CreateBinaryDirectory(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var info = new DirectoryInfo(path);
        if (info.Exists)
        {
            ValidateDirectory(path, allowUsersReadAndExecute: true);
            return;
        }

        var security = CreateDirectorySecurity(allowUsersReadAndExecute: true);
        info.Create(security);
        ValidateDirectory(path, allowUsersReadAndExecute: true);
    }

    internal static void CreateStateDirectory(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var info = new DirectoryInfo(path);
        if (info.Exists)
        {
            ValidateDirectory(path, allowUsersReadAndExecute: false);
            return;
        }

        var security = CreateDirectorySecurity(allowUsersReadAndExecute: false);
        info.Create(security);
        ValidateDirectory(path, allowUsersReadAndExecute: false);
    }

    internal static void CreateStateRootDirectory(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var info = new DirectoryInfo(path);
        if (!info.Exists)
        {
            var security = CreateDirectorySecurity(allowUsersReadAndExecute: false);
            AddDirectoryRule(
                security,
                UsersSid,
                FileSystemRights.Traverse |
                FileSystemRights.ReadAttributes |
                FileSystemRights.Synchronize,
                InheritanceFlags.None);
            info.Create(security);
        }
        ValidateDirectory(path, allowUsersReadAndExecute: true);
        var stateSecurity = info.GetAccessControl(AccessControlSections.Access);
        var usersRules = stateSecurity.GetAccessRules(
                includeExplicit: true,
                includeInherited: true,
                typeof(SecurityIdentifier))
            .Cast<FileSystemAccessRule>()
            .Where(rule =>
                ((SecurityIdentifier)rule.IdentityReference).Equals(UsersSid))
            .ToArray();
        if (usersRules.Length != 1 ||
            (usersRules[0].FileSystemRights & FileSystemRights.ListDirectory) != 0 ||
            (usersRules[0].FileSystemRights & DangerousRights) != 0)
        {
            throw new InvalidDataException(
                "Protected State root must grant Users traverse without list or write access.");
        }
    }

    internal static void CreateOwnerStateDirectory(
        string path,
        SecurityIdentifier ownerSid)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        ArgumentNullException.ThrowIfNull(ownerSid);
        var info = new DirectoryInfo(path);
        if (info.Exists)
        {
            ValidateOwnerStateDirectory(path, ownerSid);
            return;
        }

        var security = CreateDirectorySecurity(allowUsersReadAndExecute: false);
        AddDirectoryRule(
            security,
            ownerSid,
            FileSystemRights.ReadAndExecute |
            FileSystemRights.ListDirectory |
            FileSystemRights.ReadAttributes |
            FileSystemRights.ReadExtendedAttributes |
            FileSystemRights.Synchronize,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit);
        info.Create(security);
        ValidateOwnerStateDirectory(path, ownerSid);
    }

    internal static void ProtectBinaryFile(string path)
    {
        var security = new FileSecurity();
        security.SetOwner(AdministratorsSid);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        AddFileRule(security, SystemSid, FileSystemRights.FullControl);
        AddFileRule(security, AdministratorsSid, FileSystemRights.FullControl);
        AddFileRule(
            security,
            UsersSid,
            FileSystemRights.ReadAndExecute |
            FileSystemRights.ReadAttributes |
            FileSystemRights.ReadExtendedAttributes |
            FileSystemRights.Synchronize);
        new FileInfo(path).SetAccessControl(security);
        ValidateFile(path, allowUsersReadAndExecute: true);
    }

    internal static void ProtectStateFile(string path)
    {
        var security = new FileSecurity();
        security.SetOwner(AdministratorsSid);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        AddFileRule(security, SystemSid, FileSystemRights.FullControl);
        AddFileRule(security, AdministratorsSid, FileSystemRights.FullControl);
        new FileInfo(path).SetAccessControl(security);
        ValidateFile(path, allowUsersReadAndExecute: false);
    }

    internal static void ProtectOwnerStateFile(
        string path,
        SecurityIdentifier ownerSid)
    {
        ArgumentNullException.ThrowIfNull(ownerSid);
        var security = new FileSecurity();
        security.SetOwner(AdministratorsSid);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        AddFileRule(security, SystemSid, FileSystemRights.FullControl);
        AddFileRule(security, AdministratorsSid, FileSystemRights.FullControl);
        AddFileRule(
            security,
            ownerSid,
            FileSystemRights.Read |
            FileSystemRights.ReadAndExecute |
            FileSystemRights.Synchronize);
        new FileInfo(path).SetAccessControl(security);
        ValidateOwnerStateFile(path, ownerSid);
    }

    internal static void GrantDeleteOnlyFile(
        string path,
        SecurityIdentifier ownerSid)
    {
        ArgumentNullException.ThrowIfNull(ownerSid);
        try
        {
            ValidateRetirementFile(path, ownerSid);
            return;
        }
        catch (InvalidDataException)
        {
            ValidateFile(path, allowUsersReadAndExecute: true);
        }
        var info = new FileInfo(path);
        var security = info.GetAccessControl(
            AccessControlSections.Access | AccessControlSections.Owner);
        AddFileRule(
            security,
            ownerSid,
            FileSystemRights.Delete |
            FileSystemRights.Read |
            FileSystemRights.ReadAttributes |
            FileSystemRights.ReadExtendedAttributes |
            FileSystemRights.ReadPermissions |
            FileSystemRights.Synchronize);
        info.SetAccessControl(security);
        ValidateRetirementSecurity(
            info.GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner),
            ownerSid);
    }

    internal static void GrantDeleteOnlyDirectory(
        string path,
        SecurityIdentifier ownerSid)
    {
        ArgumentNullException.ThrowIfNull(ownerSid);
        try
        {
            ValidateRetirementDirectory(path, ownerSid);
            return;
        }
        catch (InvalidDataException)
        {
            ValidateDirectory(path, allowUsersReadAndExecute: true);
        }
        var info = new DirectoryInfo(path);
        var security = info.GetAccessControl(
            AccessControlSections.Access | AccessControlSections.Owner);
        AddDirectoryRule(
            security,
            ownerSid,
            FileSystemRights.Delete |
            FileSystemRights.Traverse |
            FileSystemRights.ReadAttributes |
            FileSystemRights.ReadExtendedAttributes |
            FileSystemRights.ReadPermissions |
            FileSystemRights.Synchronize,
            InheritanceFlags.None);
        info.SetAccessControl(security);
        ValidateRetirementSecurity(
            info.GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner),
            ownerSid);
    }

    internal static void ValidateRetirementFile(
        string path,
        SecurityIdentifier ownerSid)
    {
        var info = new FileInfo(path);
        if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidDataException(
                $"Protected retirement file is missing or redirected: {path}");
        }
        ValidateRetirementSecurity(
            info.GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner),
            ownerSid);
    }

    internal static void ValidateRetirementDirectory(
        string path,
        SecurityIdentifier ownerSid)
    {
        var info = new DirectoryInfo(path);
        if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidDataException(
                $"Protected retirement directory is missing or redirected: {path}");
        }
        ValidateRetirementSecurity(
            info.GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner),
            ownerSid);
    }

    internal static void ValidateOwnerStateDirectory(
        string path,
        SecurityIdentifier ownerSid)
    {
        var info = new DirectoryInfo(path);
        if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidDataException(
                $"Protected owner state directory is missing or is a reparse point: {path}");
        }
        ValidateOwnerStateSecurity(
            info.GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner),
            ownerSid);
    }

    internal static void ValidateOwnerStateFile(
        string path,
        SecurityIdentifier ownerSid)
    {
        var info = new FileInfo(path);
        if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidDataException(
                $"Protected owner state file is missing or is a reparse point: {path}");
        }
        ValidateOwnerStateSecurity(
            info.GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner),
            ownerSid);
    }

    internal static void ValidateDirectory(string path, bool allowUsersReadAndExecute)
    {
        var info = new DirectoryInfo(path);
        if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidDataException(
                $"Protected broker directory is missing or is a reparse point: {path}");
        }
        ValidateSecurity(
            info.GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner),
            allowUsersReadAndExecute,
            isDirectory: true);
    }

    internal static void ValidateFile(string path, bool allowUsersReadAndExecute)
    {
        var info = new FileInfo(path);
        if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidDataException(
                $"Protected broker file is missing or is a reparse point: {path}");
        }
        ValidateSecurity(
            info.GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner),
            allowUsersReadAndExecute,
            isDirectory: false);
    }

    internal static void ValidateProtectedTemporaryFile(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidDataException(
                $"Protected temporary file is missing or redirected: {path}");
        }
        var security = info.GetAccessControl(
            AccessControlSections.Access | AccessControlSections.Owner);
        var owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (owner is null ||
            !owner.Equals(SystemSid) && !owner.Equals(AdministratorsSid))
        {
            throw new InvalidDataException(
                "Protected temporary file owner is not privileged.");
        }
        foreach (FileSystemAccessRule rule in security.GetAccessRules(
                     includeExplicit: true,
                     includeInherited: true,
                     typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType != AccessControlType.Allow ||
                (rule.FileSystemRights & DangerousRights) == 0)
            {
                continue;
            }
            var sid = (SecurityIdentifier)rule.IdentityReference;
            if (!sid.Equals(SystemSid) && !sid.Equals(AdministratorsSid))
            {
                throw new InvalidDataException(
                    "A non-privileged principal can modify a protected temporary file.");
            }
        }
    }

    internal static void ValidateNoReparsePoints(string basePath, string targetPath)
    {
        var expectedBase = Path.TrimEndingDirectorySeparator(Path.GetFullPath(basePath));
        var expectedTarget = Path.TrimEndingDirectorySeparator(Path.GetFullPath(targetPath));
        if (!expectedTarget.StartsWith(
                expectedBase + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(expectedTarget, expectedBase, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("Protected broker path escaped ProgramData.");
        }

        var current = expectedTarget;
        while (current.Length >= expectedBase.Length)
        {
            if ((Directory.Exists(current) || File.Exists(current)) &&
                (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidDataException(
                    $"Protected broker path contains a reparse point: {current}");
            }
            if (string.Equals(current, expectedBase, StringComparison.OrdinalIgnoreCase))
            {
                break;
            }
            current = Path.GetDirectoryName(current) ??
                throw new InvalidDataException("Protected broker path ancestry is invalid.");
        }
    }

    private static DirectorySecurity CreateDirectorySecurity(bool allowUsersReadAndExecute)
    {
        var security = new DirectorySecurity();
        security.SetOwner(AdministratorsSid);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        const InheritanceFlags inheritance =
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        AddDirectoryRule(security, SystemSid, FileSystemRights.FullControl, inheritance);
        AddDirectoryRule(security, AdministratorsSid, FileSystemRights.FullControl, inheritance);
        if (allowUsersReadAndExecute)
        {
            AddDirectoryRule(
                security,
                UsersSid,
                FileSystemRights.ReadAndExecute |
                FileSystemRights.ListDirectory |
                FileSystemRights.ReadAttributes |
                FileSystemRights.ReadExtendedAttributes |
                FileSystemRights.Synchronize,
                inheritance);
        }
        return security;
    }

    private static void ValidateSecurity(
        FileSystemSecurity security,
        bool allowUsersReadAndExecute,
        bool isDirectory)
    {
        if (!security.AreAccessRulesProtected)
        {
            throw new InvalidDataException("Protected broker ACL inheritance is enabled.");
        }
        var owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (owner is null ||
            !owner.Equals(SystemSid) && !owner.Equals(AdministratorsSid))
        {
            throw new InvalidDataException("Protected broker owner is not SYSTEM or Administrators.");
        }

        var rules = security.GetAccessRules(
            includeExplicit: true,
            includeInherited: true,
            typeof(SecurityIdentifier));
        var systemFullControl = false;
        var administratorsFullControl = false;
        foreach (FileSystemAccessRule rule in rules)
        {
            if (rule.IsInherited || rule.AccessControlType != AccessControlType.Allow)
            {
                throw new InvalidDataException("Protected broker ACL contains an inherited or deny ACE.");
            }
            var sid = (SecurityIdentifier)rule.IdentityReference;
            if (sid.Equals(SystemSid))
            {
                systemFullControl |= (rule.FileSystemRights & FileSystemRights.FullControl) ==
                    FileSystemRights.FullControl;
                continue;
            }
            if (sid.Equals(AdministratorsSid))
            {
                administratorsFullControl |=
                    (rule.FileSystemRights & FileSystemRights.FullControl) ==
                    FileSystemRights.FullControl;
                continue;
            }
            if (allowUsersReadAndExecute && sid.Equals(UsersSid))
            {
                if ((rule.FileSystemRights & DangerousRights) != 0)
                {
                    throw new InvalidDataException("Protected broker Users ACE is writable.");
                }
                continue;
            }
            throw new InvalidDataException(
                $"Protected broker ACL contains an unexpected principal: {sid.Value}");
        }

        if (!systemFullControl || !administratorsFullControl)
        {
            throw new InvalidDataException("Protected broker ACL is missing administrative control.");
        }
        _ = isDirectory;
    }

    private static void ValidateOwnerStateSecurity(
        FileSystemSecurity security,
        SecurityIdentifier ownerSid)
    {
        if (!security.AreAccessRulesProtected)
        {
            throw new InvalidDataException("Protected owner state ACL inheritance is enabled.");
        }
        var owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (owner is null ||
            !owner.Equals(SystemSid) && !owner.Equals(AdministratorsSid))
        {
            throw new InvalidDataException(
                "Protected owner state owner is not SYSTEM or Administrators.");
        }

        var systemFullControl = false;
        var administratorsFullControl = false;
        var ownerRead = false;
        foreach (FileSystemAccessRule rule in security.GetAccessRules(
                     includeExplicit: true,
                     includeInherited: true,
                     typeof(SecurityIdentifier)))
        {
            if (rule.IsInherited || rule.AccessControlType != AccessControlType.Allow)
            {
                throw new InvalidDataException(
                    "Protected owner state ACL contains an inherited or deny ACE.");
            }
            var sid = (SecurityIdentifier)rule.IdentityReference;
            if (sid.Equals(SystemSid))
            {
                systemFullControl |= (rule.FileSystemRights & FileSystemRights.FullControl) ==
                    FileSystemRights.FullControl;
                continue;
            }
            if (sid.Equals(AdministratorsSid))
            {
                administratorsFullControl |=
                    (rule.FileSystemRights & FileSystemRights.FullControl) ==
                    FileSystemRights.FullControl;
                continue;
            }
            if (sid.Equals(ownerSid))
            {
                if ((rule.FileSystemRights & DangerousRights) != 0)
                {
                    throw new InvalidDataException(
                        "Protected owner state SID has write access.");
                }
                ownerRead = true;
                continue;
            }
            throw new InvalidDataException(
                $"Protected owner state ACL contains an unexpected principal: {sid.Value}");
        }
        if (!systemFullControl || !administratorsFullControl || !ownerRead)
        {
            throw new InvalidDataException(
                "Protected owner state ACL is missing required access.");
        }
    }

    private static void ValidateRetirementSecurity(
        FileSystemSecurity security,
        SecurityIdentifier retirementOwnerSid)
    {
        if (!security.AreAccessRulesProtected)
        {
            throw new InvalidDataException(
                "Protected retirement ACL inheritance is enabled.");
        }
        var owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (owner is null ||
            !owner.Equals(SystemSid) && !owner.Equals(AdministratorsSid))
        {
            throw new InvalidDataException(
                "Protected retirement owner is not SYSTEM or Administrators.");
        }

        var systemFullControl = false;
        var administratorsFullControl = false;
        var deleteOnlyPresent = false;
        foreach (FileSystemAccessRule rule in security.GetAccessRules(
                     includeExplicit: true,
                     includeInherited: true,
                     typeof(SecurityIdentifier)))
        {
            if (rule.IsInherited || rule.AccessControlType != AccessControlType.Allow)
            {
                throw new InvalidDataException(
                    "Protected retirement ACL contains an inherited or deny ACE.");
            }
            var sid = (SecurityIdentifier)rule.IdentityReference;
            if (sid.Equals(SystemSid))
            {
                systemFullControl |= (rule.FileSystemRights & FileSystemRights.FullControl) ==
                    FileSystemRights.FullControl;
                continue;
            }
            if (sid.Equals(AdministratorsSid))
            {
                administratorsFullControl |=
                    (rule.FileSystemRights & FileSystemRights.FullControl) ==
                    FileSystemRights.FullControl;
                continue;
            }
            if (sid.Equals(UsersSid))
            {
                if ((rule.FileSystemRights & DangerousRights) != 0)
                {
                    throw new InvalidDataException(
                        "Protected retirement Users ACE is writable.");
                }
                continue;
            }
            if (sid.Equals(retirementOwnerSid))
            {
                if (!ProtectedBrokerRetirement.AreRetirementOwnerRightsDeleteOnly(
                        rule.FileSystemRights))
                {
                    throw new InvalidDataException(
                        "Retirement owner has rights beyond fixed-object deletion.");
                }
                deleteOnlyPresent = true;
                continue;
            }
            throw new InvalidDataException(
                $"Protected retirement ACL contains an unexpected principal: {sid.Value}");
        }
        if (!systemFullControl || !administratorsFullControl || !deleteOnlyPresent)
        {
            throw new InvalidDataException(
                "Protected retirement ACL is missing required access.");
        }
    }

    private static void AddDirectoryRule(
        DirectorySecurity security,
        SecurityIdentifier identity,
        FileSystemRights rights,
        InheritanceFlags inheritance) =>
        security.AddAccessRule(new FileSystemAccessRule(
            identity,
            rights,
            inheritance,
            PropagationFlags.None,
            AccessControlType.Allow));

    private static void AddFileRule(
        FileSecurity security,
        SecurityIdentifier identity,
        FileSystemRights rights) =>
        security.AddAccessRule(new FileSystemAccessRule(
            identity,
            rights,
            InheritanceFlags.None,
            PropagationFlags.None,
            AccessControlType.Allow));
}
