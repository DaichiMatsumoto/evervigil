using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace EverVigil.Broker;

internal sealed class AuthenticatedClientProcess : IDisposable
{
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const uint StillActive = 259;
    private const uint TokenQuery = 0x0008;
    private const int ErrorInsufficientBuffer = 122;
    private const int SecurityMandatoryMediumRid = 0x2000;
    private const int SecurityMandatoryHighRid = 0x3000;

    private readonly SafeProcessHandle _processHandle;

    private AuthenticatedClientProcess(
        SafeProcessHandle processHandle,
        uint processId,
        SecurityIdentifier userSid,
        uint sessionId,
        int integrityRid,
        long creationTime)
    {
        _processHandle = processHandle;
        ProcessId = processId;
        UserSid = userSid;
        SessionId = sessionId;
        IntegrityRid = integrityRid;
        CreationTime = creationTime;
    }

    internal uint ProcessId { get; }

    internal SecurityIdentifier UserSid { get; }

    internal uint SessionId { get; }

    internal int IntegrityRid { get; }

    internal long CreationTime { get; }

    internal SafeProcessHandle ProcessHandle => _processHandle;

    internal static AuthenticatedClientProcess OpenAndValidate(uint processId)
    {
        if (processId == 0 || processId == Environment.ProcessId)
        {
            throw new UnauthorizedAccessException("Broker client PID is invalid.");
        }

        var processHandle = OpenProcess(
            ProcessQueryLimitedInformation,
            inheritHandle: false,
            processId);
        if (processHandle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            processHandle.Dispose();
            throw new Win32Exception(error, "Could not retain the broker client process handle.");
        }

        try
        {
            if (!OpenProcessToken(processHandle, TokenQuery, out var tokenHandle))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Could not read the broker client process token.");
            }
            using (tokenHandle)
            {
                var userSid = ReadUserSid(tokenHandle);
                var integrityRid = ReadIntegrityRid(tokenHandle);
                if (integrityRid is < SecurityMandatoryMediumRid or >= SecurityMandatoryHighRid)
                {
                    throw new UnauthorizedAccessException(
                        "Broker client must be a Medium integrity process.");
                }
                if (!ProcessIdToSessionId(processId, out var clientSessionId))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Could not resolve the broker client session.");
                }
                if (!ProcessIdToSessionId((uint)Environment.ProcessId, out var brokerSessionId) ||
                    clientSessionId != brokerSessionId)
                {
                    throw new UnauthorizedAccessException(
                        "Broker client is not in the broker's interactive session.");
                }
                var creationTime = ReadCreationTime(processHandle);
                return new AuthenticatedClientProcess(
                    processHandle,
                    processId,
                    userSid,
                    clientSessionId,
                    integrityRid,
                    creationTime);
            }
        }
        catch
        {
            processHandle.Dispose();
            throw;
        }
    }

    internal void RequireOriginalProcessStillActive()
    {
        if (_processHandle.IsInvalid || _processHandle.IsClosed ||
            GetProcessId(_processHandle) != ProcessId ||
            !GetExitCodeProcess(_processHandle, out var exitCode) ||
            exitCode != StillActive ||
            ReadCreationTime(_processHandle) != CreationTime)
        {
            throw new UnauthorizedAccessException(
                "The retained broker client process is no longer the original live process.");
        }
    }

    internal static void RequireBrokerHighIntegrity()
    {
        using var identity = WindowsIdentity.GetCurrent(
            TokenAccessLevels.Query | TokenAccessLevels.Duplicate);
        if (identity.User is null ||
            !new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
        {
            throw new UnauthorizedAccessException("Privileged broker requires administrator elevation.");
        }
        var integrityRid = ReadIntegrityRid(identity.AccessToken);
        if (integrityRid < SecurityMandatoryHighRid)
        {
            throw new UnauthorizedAccessException("Privileged broker is not running at High integrity.");
        }
    }

    public void Dispose() => _processHandle.Dispose();

    private static long ReadCreationTime(SafeProcessHandle processHandle)
    {
        if (!GetProcessTimes(
                processHandle,
                out var creationTime,
                out _,
                out _,
                out _))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "Could not read the broker client process creation time.");
        }
        return creationTime.ToLong();
    }

    private static SecurityIdentifier ReadUserSid(SafeAccessTokenHandle tokenHandle)
    {
        using var buffer = ReadTokenInformation(tokenHandle, TokenInformationClass.TokenUser);
        var tokenUser = Marshal.PtrToStructure<TokenUser>(buffer.DangerousGetHandle());
        return new SecurityIdentifier(tokenUser.User.Sid);
    }

    private static int ReadIntegrityRid(SafeAccessTokenHandle tokenHandle)
    {
        using var buffer = ReadTokenInformation(
            tokenHandle,
            TokenInformationClass.TokenIntegrityLevel);
        var label = Marshal.PtrToStructure<TokenMandatoryLabel>(buffer.DangerousGetHandle());
        var countPointer = GetSidSubAuthorityCount(label.Label.Sid);
        if (countPointer == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Token integrity SID is invalid.");
        }
        var count = Marshal.ReadByte(countPointer);
        if (count == 0)
        {
            throw new InvalidDataException("Token integrity SID has no RID.");
        }
        var ridPointer = GetSidSubAuthority(label.Label.Sid, (uint)(count - 1));
        if (ridPointer == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Token integrity RID is invalid.");
        }
        return Marshal.ReadInt32(ridPointer);
    }

    private static SafeHGlobalBuffer ReadTokenInformation(
        SafeAccessTokenHandle tokenHandle,
        TokenInformationClass informationClass)
    {
        _ = GetTokenInformation(
            tokenHandle,
            informationClass,
            IntPtr.Zero,
            0,
            out var requiredLength);
        var error = Marshal.GetLastWin32Error();
        if (requiredLength == 0 || error != ErrorInsufficientBuffer)
        {
            throw new Win32Exception(error, "Could not size token information.");
        }

        var buffer = new SafeHGlobalBuffer(requiredLength);
        if (!GetTokenInformation(
                tokenHandle,
                informationClass,
                buffer.DangerousGetHandle(),
                requiredLength,
                out _))
        {
            var readError = Marshal.GetLastWin32Error();
            buffer.Dispose();
            throw new Win32Exception(readError, "Could not read token information.");
        }
        return buffer;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeProcessHandle OpenProcess(
        uint desiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandle,
        uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetProcessId(SafeProcessHandle processHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetExitCodeProcess(
        SafeProcessHandle processHandle,
        out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetProcessTimes(
        SafeProcessHandle processHandle,
        out FileTime creationTime,
        out FileTime exitTime,
        out FileTime kernelTime,
        out FileTime userTime);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(
        SafeProcessHandle processHandle,
        uint desiredAccess,
        out SafeAccessTokenHandle tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(
        SafeAccessTokenHandle tokenHandle,
        TokenInformationClass tokenInformationClass,
        IntPtr tokenInformation,
        int tokenInformationLength,
        out int returnLength);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern IntPtr GetSidSubAuthority(IntPtr sid, uint subAuthority);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ProcessIdToSessionId(uint processId, out uint sessionId);

    private enum TokenInformationClass
    {
        TokenUser = 1,
        TokenIntegrityLevel = 25
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SidAndAttributes
    {
        internal IntPtr Sid;
        internal uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TokenUser
    {
        internal SidAndAttributes User;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TokenMandatoryLabel
    {
        internal SidAndAttributes Label;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileTime
    {
        internal uint LowDateTime;
        internal uint HighDateTime;

        internal readonly long ToLong() =>
            ((long)HighDateTime << 32) | LowDateTime;
    }

    private sealed class SafeHGlobalBuffer : SafeHandle
    {
        internal SafeHGlobalBuffer(int bytes)
            : base(IntPtr.Zero, ownsHandle: true)
        {
            SetHandle(Marshal.AllocHGlobal(bytes));
        }

        public override bool IsInvalid => handle == IntPtr.Zero;

        protected override bool ReleaseHandle()
        {
            Marshal.FreeHGlobal(handle);
            return true;
        }
    }
}
