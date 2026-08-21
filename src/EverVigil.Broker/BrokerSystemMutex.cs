using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace EverVigil.Broker;

internal static class BrokerSystemMutex
{
    internal const string Name = "Global\\EverVigil.SystemTransaction";
    private const string SecurityDescriptorSddl =
        "D:P(A;;0x00100001;;;AU)(A;;0x001F0001;;;SY)(A;;0x001F0001;;;BA)";
    private const uint MutexAllAccess = 0x001F0001;
    private const uint DaclSecurityInformation = 0x00000004;
    private const uint WaitObject0 = 0x00000000;
    private const uint WaitAbandoned = 0x00000080;
    private const uint WaitTimeout = 0x00000102;
    private static readonly TimeSpan Timeout = TimeSpan.FromMinutes(10);

    internal static T Execute<T>(Func<T> action)
    {
        ArgumentNullException.ThrowIfNull(action);
        using var mutex = CreateOrOpen();
        var wait = WaitForSingleObject(mutex, checked((uint)Timeout.TotalMilliseconds));
        if (wait == WaitTimeout)
        {
            throw new TimeoutException(
                "Another EverVigil system transaction did not finish within 10 minutes.");
        }
        if (wait is not (WaitObject0 or WaitAbandoned))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "Could not acquire the protected system transaction mutex.");
        }

        try
        {
            ValidateSecurity(mutex);
            return action();
        }
        finally
        {
            if (!ReleaseMutex(mutex))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Could not release the protected system transaction mutex.");
            }
        }
    }

    private static SafeWaitHandle CreateOrOpen()
    {
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor(
                SecurityDescriptorSddl,
                1,
                out var securityDescriptor,
                out _))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "Could not create the fixed system transaction mutex ACL.");
        }
        try
        {
            var attributes = new SecurityAttributes
            {
                Length = Marshal.SizeOf<SecurityAttributes>(),
                SecurityDescriptor = securityDescriptor,
                InheritHandle = false
            };
            var mutex = CreateMutexEx(
                ref attributes,
                Name,
                flags: 0,
                MutexAllAccess);
            if (mutex.IsInvalid)
            {
                var error = Marshal.GetLastWin32Error();
                mutex.Dispose();
                throw new Win32Exception(
                    error,
                    "Could not create or open the protected system transaction mutex.");
            }
            return mutex;
        }
        finally
        {
            _ = LocalFree(securityDescriptor);
        }
    }

    private static void ValidateSecurity(SafeWaitHandle mutex)
    {
        _ = GetKernelObjectSecurity(
            mutex,
            DaclSecurityInformation,
            null,
            0,
            out var requiredLength);
        var error = Marshal.GetLastWin32Error();
        if (requiredLength == 0 || error != 122)
        {
            throw new Win32Exception(error, "Could not size system transaction mutex ACL.");
        }
        var descriptorBytes = new byte[requiredLength];
        if (!GetKernelObjectSecurity(
                mutex,
                DaclSecurityInformation,
                descriptorBytes,
                descriptorBytes.Length,
                out _))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "Could not read system transaction mutex ACL.");
        }
        var descriptor = new RawSecurityDescriptor(descriptorBytes, 0);
        if ((descriptor.ControlFlags & ControlFlags.DiscretionaryAclProtected) == 0 ||
            descriptor.DiscretionaryAcl is null)
        {
            throw new UnauthorizedAccessException("System transaction mutex DACL is not protected.");
        }
        var expected = new Dictionary<string, int>(StringComparer.Ordinal)
        {
            [new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null).Value] =
                unchecked((int)0x00100001),
            [new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null).Value] =
                unchecked((int)MutexAllAccess),
            [new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null).Value] =
                unchecked((int)MutexAllAccess)
        };
        foreach (GenericAce genericAce in descriptor.DiscretionaryAcl)
        {
            if (genericAce is not CommonAce ace ||
                ace.AceQualifier != AceQualifier.AccessAllowed ||
                ace.SecurityIdentifier is null ||
                !expected.Remove(ace.SecurityIdentifier.Value, out var expectedMask) ||
                ace.AccessMask != expectedMask ||
                ace.AceFlags != AceFlags.None)
            {
                throw new UnauthorizedAccessException(
                    "System transaction mutex DACL is not the fixed coordination ACL.");
            }
        }
        if (expected.Count != 0)
        {
            throw new UnauthorizedAccessException(
                "System transaction mutex DACL is missing a required principal.");
        }
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(
        string stringSecurityDescriptor,
        uint stringSdRevision,
        out IntPtr securityDescriptor,
        out uint securityDescriptorSize);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeWaitHandle CreateMutexEx(
        ref SecurityAttributes mutexAttributes,
        string name,
        uint flags,
        uint desiredAccess);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetKernelObjectSecurity(
        SafeWaitHandle handle,
        uint requestedInformation,
        byte[]? securityDescriptor,
        int length,
        out int lengthNeeded);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(SafeWaitHandle handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReleaseMutex(SafeWaitHandle mutex);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        internal int Length;
        internal IntPtr SecurityDescriptor;

        [MarshalAs(UnmanagedType.Bool)]
        internal bool InheritHandle;
    }
}
