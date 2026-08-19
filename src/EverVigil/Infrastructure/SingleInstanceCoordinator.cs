using System.Security.AccessControl;
using System.Security.Principal;
using EverVigil.Compatibility;

namespace EverVigil.Infrastructure;

internal sealed class SingleInstanceCoordinator : IDisposable
{
    private readonly Mutex _mutex;
    private readonly EventWaitHandle _showEvent;
    private readonly EventWaitHandle _shutdownEvent;
    private readonly bool _ownsMutex;

    public SingleInstanceCoordinator() : this(CreateDefaultScope())
    {
    }

    internal static string CreateDefaultScope()
    {
        var userScope = WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName;
        return LegacyCompatibility.Synchronization.InstanceScopeTemplate.Replace(
            "{ownerSid}",
            userScope,
            StringComparison.Ordinal);
    }

    internal SingleInstanceCoordinator(string scope)
    {
        var currentUser = WindowsIdentity.GetCurrent().User ??
            throw new InvalidOperationException("The current Windows user SID is unavailable.");
        _mutex = MutexAcl.Create(
            initiallyOwned: true,
            $"{scope}-Mutex",
            out var createdNew,
            CreateMutexSecurity(currentUser));
        if (createdNew)
        {
            _ownsMutex = true;
        }
        else
        {
            try
            {
                _ownsMutex = _mutex.WaitOne(0);
            }
            catch (AbandonedMutexException)
            {
                _ownsMutex = true;
            }
        }

        _showEvent = EventWaitHandleAcl.Create(
            initialState: false,
            EventResetMode.AutoReset,
            $"{scope}-Show",
            out _,
            CreateEventSecurity(currentUser));
        _shutdownEvent = EventWaitHandleAcl.Create(
            initialState: false,
            EventResetMode.AutoReset,
            $"{scope}-Shutdown",
            out _,
            CreateEventSecurity(currentUser));
    }

    public bool IsPrimary => _ownsMutex;

    public void SignalShow() => _showEvent.Set();

    public void SignalShutdown() => _shutdownEvent.Set();

    public bool ConsumeShowRequest() => _showEvent.WaitOne(0);

    public bool ConsumeShutdownRequest() => _shutdownEvent.WaitOne(0);

    private static MutexSecurity CreateMutexSecurity(SecurityIdentifier currentUser)
    {
        var security = new MutexSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        foreach (var identity in GetAllowedIdentities(currentUser))
        {
            security.AddAccessRule(new MutexAccessRule(
                identity,
                MutexRights.FullControl,
                AccessControlType.Allow));
        }

        return security;
    }

    private static EventWaitHandleSecurity CreateEventSecurity(SecurityIdentifier currentUser)
    {
        var security = new EventWaitHandleSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        foreach (var identity in GetAllowedIdentities(currentUser))
        {
            security.AddAccessRule(new EventWaitHandleAccessRule(
                identity,
                EventWaitHandleRights.FullControl,
                AccessControlType.Allow));
        }

        return security;
    }

    private static SecurityIdentifier[] GetAllowedIdentities(SecurityIdentifier currentUser) =>
    [
        currentUser,
        new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
        new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null)
    ];

    public void Dispose()
    {
        _showEvent.Dispose();
        _shutdownEvent.Dispose();
        if (_ownsMutex)
        {
            try
            {
                _mutex.ReleaseMutex();
            }
            catch (ApplicationException)
            {
                // Ownership may already have been released during process teardown.
            }
        }

        _mutex.Dispose();
    }
}
