using System.Security.AccessControl;
using System.Security.Principal;

namespace EverVigil.Infrastructure;

internal static class AccessControlService
{
    public static void RestrictDirectory(string path)
    {
        var currentUser = WindowsIdentity.GetCurrent().User ??
            throw new InvalidOperationException("The current Windows user SID is unavailable.");
        RestrictDirectory(path, currentUser.Value);
    }

    internal static void RestrictDirectory(string path, string ownerSid)
    {
        Directory.CreateDirectory(path);
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        AddRules(
            security,
            ParseOwnerSid(ownerSid),
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit);
        new DirectoryInfo(path).SetAccessControl(security);
    }

    public static void RestrictFile(string path)
    {
        var currentUser = WindowsIdentity.GetCurrent().User ??
            throw new InvalidOperationException("The current Windows user SID is unavailable.");
        RestrictFile(path, currentUser.Value);
    }

    internal static void RestrictFile(string path, string ownerSid)
    {
        var security = CreateFileSecurity(ownerSid);
        new FileInfo(path).SetAccessControl(security);
    }

    internal static FileStream CreateRestrictedFile(
        string path,
        FileMode mode,
        FileShare share,
        int bufferSize,
        FileOptions options)
    {
        var currentUser = WindowsIdentity.GetCurrent().User ??
            throw new InvalidOperationException("The current Windows user SID is unavailable.");
        return CreateRestrictedFile(
            path,
            currentUser.Value,
            mode,
            share,
            bufferSize,
            options);
    }

    internal static FileStream CreateRestrictedFile(
        string path,
        string ownerSid,
        FileMode mode,
        FileShare share,
        int bufferSize,
        FileOptions options) =>
        FileSystemAclExtensions.Create(
            new FileInfo(path),
            mode,
            FileSystemRights.Write,
            share,
            bufferSize,
            options,
            CreateFileSecurity(ownerSid));

    private static FileSecurity CreateFileSecurity(string ownerSid)
    {
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        AddRules(security, ParseOwnerSid(ownerSid), InheritanceFlags.None);
        return security;
    }

    private static SecurityIdentifier ParseOwnerSid(string ownerSid)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(ownerSid);
        try
        {
            return new SecurityIdentifier(ownerSid);
        }
        catch (ArgumentException exception)
        {
            throw new ArgumentException("The owner SID is invalid.", nameof(ownerSid), exception);
        }
    }

    private static void AddRules(
        FileSystemSecurity security,
        SecurityIdentifier ownerSid,
        InheritanceFlags inheritanceFlags)
    {
        var identities = new[]
        {
            ownerSid,
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null)
        };

        foreach (var identity in identities)
        {
            security.AddAccessRule(new FileSystemAccessRule(
                identity,
                FileSystemRights.FullControl,
                inheritanceFlags,
                PropagationFlags.None,
                AccessControlType.Allow));
        }
    }
}
