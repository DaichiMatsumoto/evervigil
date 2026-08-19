using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using EverVigil.Core;
using EverVigil.Core.Localization;

namespace EverVigil.Infrastructure;

internal sealed class TokenStore
{
    private static readonly TimeSpan CrossProcessLockTimeout = TimeSpan.FromSeconds(30);

    private readonly object _gate = new();
    private readonly DataPaths _paths;
    private readonly byte[] _entropy;
    private readonly string _crossProcessMutexName;
    private string? _cachedToken;

    public string? LastRecoveryMessage { get; private set; }

    public string? LastRecoveryMessageResourceKey { get; private set; }

    public TokenStore(DataPaths paths)
    {
        _paths = paths;
        _entropy = SHA256.HashData(Encoding.UTF8.GetBytes(paths.TokenEntropyContext));
        var userScope = WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName;
        _crossProcessMutexName = paths.TokenMutexNameTemplate.Replace(
            "{ownerSid}",
            userScope,
            StringComparison.Ordinal);
        AccessControlService.RestrictDirectory(paths.DataRoot);
    }

    public string GetOrCreate()
    {
        lock (_gate)
        {
            if (_cachedToken is not null)
            {
                return _cachedToken;
            }

            return WithCrossProcessLock(() =>
            {
                if (File.Exists(_paths.TokenPath))
                {
                    try
                    {
                        _cachedToken = Unprotect(File.ReadAllBytes(_paths.TokenPath));
                        return _cachedToken;
                    }
                    catch (Exception exception) when (exception is CryptographicException or InvalidDataException)
                    {
                        QuarantineUnreadableToken();
                        LastRecoveryMessageResourceKey = "TokenQuarantinedRecovery";
                        LastRecoveryMessage = AppLocalizer.Text(LastRecoveryMessageResourceKey);
                    }
                }

                var generatedToken = TokenUtility.Generate();
                Persist(generatedToken);
                _cachedToken = generatedToken;
                return _cachedToken;
            });
        }
    }

    public string Regenerate()
    {
        lock (_gate)
        {
            return WithCrossProcessLock(() =>
            {
                var generatedToken = TokenUtility.Generate();
                Persist(generatedToken);
                _cachedToken = generatedToken;
                return _cachedToken;
            });
        }
    }

    public bool ImportLegacyFileIfMissing(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var token = File.ReadAllText(path, Encoding.ASCII).Trim();
        if (!TokenUtility.IsValid(token))
        {
            throw new InvalidDataException("Legacy token must contain exactly 32 hexadecimal characters.");
        }

        lock (_gate)
        {
            return WithCrossProcessLock(() =>
            {
                if (File.Exists(_paths.TokenPath))
                {
                    return false;
                }

                var normalizedToken = token.ToLowerInvariant();
                Persist(normalizedToken);
                _cachedToken = normalizedToken;
                return true;
            });
        }
    }

    private T WithCrossProcessLock<T>(Func<T> action)
    {
        using var mutex = new Mutex(initiallyOwned: false, _crossProcessMutexName);
        var acquired = false;
        try
        {
            try
            {
                acquired = mutex.WaitOne(CrossProcessLockTimeout);
            }
            catch (AbandonedMutexException)
            {
                acquired = true;
            }

            if (!acquired)
            {
                throw new TimeoutException("Timed out waiting for exclusive token storage access.");
            }

            return action();
        }
        finally
        {
            if (acquired)
            {
                mutex.ReleaseMutex();
            }
        }
    }

    private void Persist(string token)
    {
        var protectedBytes = ProtectedData.Protect(
            Encoding.ASCII.GetBytes(token),
            _entropy,
            DataProtectionScope.CurrentUser);
        var temporaryPath = $"{_paths.TokenPath}.{Guid.NewGuid():N}.tmp";
        try
        {
            using (var stream = AccessControlService.CreateRestrictedFile(
                       temporaryPath,
                       FileMode.CreateNew,
                       FileShare.None,
                       bufferSize: 4096,
                       FileOptions.WriteThrough))
            {
                stream.Write(protectedBytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporaryPath, _paths.TokenPath, overwrite: true);
            AccessControlService.RestrictFile(_paths.TokenPath);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private string Unprotect(byte[] protectedBytes)
    {
        var bytes = ProtectedData.Unprotect(
            protectedBytes,
            _entropy,
            DataProtectionScope.CurrentUser);
        var token = Encoding.ASCII.GetString(bytes);
        if (!TokenUtility.IsValid(token))
        {
            throw new InvalidDataException("Stored token is invalid.");
        }

        return token;
    }

    private void QuarantineUnreadableToken()
    {
        var quarantinePath = $"{_paths.TokenPath}.invalid-{DateTime.Now:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}";
        File.Move(_paths.TokenPath, quarantinePath);
        AccessControlService.RestrictFile(quarantinePath);

        foreach (var staleFile in Directory
                     .EnumerateFiles(_paths.DataRoot, "token.dat.invalid-*")
                     .OrderByDescending(File.GetLastWriteTimeUtc)
                     .Skip(3))
        {
            try
            {
                File.Delete(staleFile);
            }
            catch (IOException)
            {
                // Stale quarantine cleanup must not prevent token recovery.
            }
            catch (UnauthorizedAccessException)
            {
                // The active token is already recovered; retry cleanup on a later recovery.
            }
        }
    }
}
