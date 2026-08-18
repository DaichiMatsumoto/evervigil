using System.Runtime.InteropServices;

namespace EverVigil.Broker;

// NativeAOT cannot use runtime-generated COM activation or reflection dispatch.
// This deliberately small IDispatch client owns every pointer and VARIANT.
internal sealed unsafe class NativeComDispatch : IDisposable
{
    internal static readonly Guid NetFwPolicy2ClassId =
        new("E2B3C97F-6AE1-41AC-817A-F6F92166D7DD");
    internal static readonly Guid NetFwRuleClassId =
        new("2C5BC43E-3369-4C33-AB0C-BE9469677AF4");
    internal static readonly Guid TaskSchedulerClassId =
        new("0F87369F-A4E5-4CFC-BD3E-73E6154572DD");

    private static readonly Guid DispatchInterfaceId =
        new("00020400-0000-0000-C000-000000000046");
    private static readonly Guid EnumVariantInterfaceId =
        new("00020404-0000-0000-C000-000000000046");
    private const uint InProcessServer = 0x1;
    private const uint LocaleInvariant = 0x7F;
    private const ushort DispatchMethod = 0x1;
    private const ushort DispatchPropertyGet = 0x2;
    private const ushort DispatchPropertyPut = 0x4;
    private const int DispatchPropertyPutId = -3;
    private const int ParameterNotFound = unchecked((int)0x80020004);
    private const int DispatchException = unchecked((int)0x80020009);
    private const int ChangedApartmentMode = unchecked((int)0x80010106);
    private const uint ControlFacilityError = 0x800A0000;
    private const ushort VariantEmpty = 0;
    private const ushort VariantNull = 1;
    private const ushort VariantInt16 = 2;
    private const ushort VariantInt32 = 3;
    private const ushort VariantBstr = 8;
    private const ushort VariantDispatch = 9;
    private const ushort VariantError = 10;
    private const ushort VariantBoolean = 11;
    private const ushort VariantVariant = 12;
    private const ushort VariantUnknown = 13;
    private const ushort VariantUInt16 = 18;
    private const ushort VariantUInt32 = 19;
    private const ushort VariantInt = 22;
    private const ushort VariantUInt = 23;
    private const ushort VariantArray = 0x2000;
    private nint _pointer;

    private NativeComDispatch(nint pointer)
    {
        if (pointer == 0)
        {
            throw new ArgumentException("COM pointer is null.", nameof(pointer));
        }
        _pointer = pointer;
    }

    internal static NativeComDispatch Create(Guid classId)
    {
        EnsureComApartment();
        var interfaceId = DispatchInterfaceId;
        nint pointer = 0;
        var result = CoCreateInstance(
            &classId,
            0,
            InProcessServer,
            &interfaceId,
            &pointer);
        ThrowForResult(result, "COM class activation failed.");
        return new NativeComDispatch(pointer);
    }

    internal NativeComDispatch GetDispatchProperty(string name)
    {
        using var value = Invoke(name, DispatchPropertyGet, []);
        return value.TakeDispatch(name);
    }

    internal string? GetOptionalStringProperty(string name)
    {
        using var value = Invoke(name, DispatchPropertyGet, []);
        return value.TakeOptionalString(name);
    }

    internal string GetRequiredStringProperty(string name) =>
        GetOptionalStringProperty(name) is { Length: > 0 } value
            ? value
            : throw new InvalidDataException($"COM property '{name}' is missing.");

    internal int GetInt32Property(string name)
    {
        using var value = Invoke(name, DispatchPropertyGet, []);
        return value.TakeInt32(name);
    }

    internal bool GetBooleanProperty(string name)
    {
        using var value = Invoke(name, DispatchPropertyGet, []);
        return value.TakeBoolean(name);
    }

    internal IReadOnlyList<string> GetStringArrayProperty(string name)
    {
        using var value = Invoke(name, DispatchPropertyGet, []);
        return value.TakeStringArray(name);
    }

    internal void SetProperty(string name, object value)
    {
        ArgumentNullException.ThrowIfNull(value);
        using var result = Invoke(name, DispatchPropertyPut, [value]);
        result.RequireEmpty(name);
    }

    internal void InvokeMethod(string name, params object[] arguments)
    {
        using var result = Invoke(name, DispatchMethod, arguments);
    }

    internal NativeComDispatch InvokeDispatchMethod(string name, params object[] arguments)
    {
        using var value = Invoke(name, DispatchMethod, arguments);
        return value.TakeDispatch(name);
    }

    internal string InvokeStringMethod(string name, params object[] arguments)
    {
        using var result = Invoke(name, DispatchMethod, arguments);
        return result.TakeOptionalString(name) ??
            throw new InvalidDataException($"COM method '{name}' returned no string.");
    }

    internal IReadOnlyList<NativeComDispatch> EnumerateDispatchProperty(string name)
    {
        using var value = Invoke(name, DispatchPropertyGet, []);
        var unknown = value.TakeUnknown(name);
        nint enumerator = 0;
        try
        {
            enumerator = QueryInterface(unknown, EnumVariantInterfaceId);
        }
        finally
        {
            Release(unknown);
        }

        var items = new List<NativeComDispatch>();
        try
        {
            while (true)
            {
                NativeVariant item = default;
                uint fetched = 0;
                var vtable = *(nint**)enumerator;
                var next = (delegate* unmanaged[Stdcall]<nint, uint, NativeVariant*, uint*, int>)
                    vtable[3];
                var result = next(enumerator, 1, &item, &fetched);
                if (result == 1 && fetched == 0)
                {
                    break;
                }
                ThrowForResult(result, "COM enumeration failed.");
                if (fetched != 1)
                {
                    VariantClear(&item);
                    throw new InvalidDataException("COM enumeration returned an invalid count.");
                }
                using var itemValue = new NativeComValue(item);
                items.Add(itemValue.TakeDispatch(name));
            }
            return items;
        }
        catch
        {
            foreach (var item in items)
            {
                item.Dispose();
            }
            throw;
        }
        finally
        {
            Release(enumerator);
        }
    }

    public void Dispose()
    {
        var pointer = Interlocked.Exchange(ref _pointer, 0);
        if (pointer != 0)
        {
            Release(pointer);
        }
    }

    private NativeComValue Invoke(string name, ushort flags, IReadOnlyList<object> arguments)
    {
        ObjectDisposedException.ThrowIf(_pointer == 0, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        ArgumentNullException.ThrowIfNull(arguments);
        var dispatchId = GetDispatchId(name);
        NativeVariant* variants = stackalloc NativeVariant[arguments.Count];
        for (var index = 0; index < arguments.Count; index++)
        {
            variants[arguments.Count - index - 1] = CreateArgument(arguments[index]);
        }
        var namedId = DispatchPropertyPutId;
        var parameters = new DispatchParameters
        {
            Arguments = variants,
            ArgumentCount = (uint)arguments.Count,
            NamedArgumentIds = flags == DispatchPropertyPut ? &namedId : null,
            NamedArgumentCount = flags == DispatchPropertyPut ? 1u : 0u
        };
        NativeVariant result = default;
        NativeExceptionInformation exceptionInformation = default;
        uint argumentError = 0;
        var empty = Guid.Empty;
        try
        {
            var vtable = *(nint**)_pointer;
            var invoke = (delegate* unmanaged[Stdcall]<
                nint,
                int,
                Guid*,
                uint,
                ushort,
                DispatchParameters*,
                NativeVariant*,
                NativeExceptionInformation*,
                uint*,
                int>)vtable[6];
            var hresult = invoke(
                _pointer,
                dispatchId,
                &empty,
                LocaleInvariant,
                flags,
                &parameters,
                &result,
                &exceptionInformation,
                &argumentError);
            ThrowForDispatchResult(
                hresult,
                $"COM member '{name}' failed.",
                &exceptionInformation);
            return new NativeComValue(result);
        }
        catch
        {
            VariantClear(&result);
            throw;
        }
        finally
        {
            FreeExceptionInformation(&exceptionInformation);
            for (var index = 0; index < arguments.Count; index++)
            {
                FreeArgument(variants + index);
            }
        }
    }

    private int GetDispatchId(string name)
    {
        var empty = Guid.Empty;
        var dispatchId = 0;
        fixed (char* namePointer = name)
        {
            var names = namePointer;
            var vtable = *(nint**)_pointer;
            var getIds = (delegate* unmanaged[Stdcall]<
                nint,
                Guid*,
                char**,
                uint,
                uint,
                int*,
                int>)vtable[5];
            var result = getIds(
                _pointer,
                &empty,
                &names,
                1,
                LocaleInvariant,
                &dispatchId);
            ThrowForResult(result, $"COM member '{name}' was not found.");
        }
        return dispatchId;
    }

    private static NativeVariant CreateArgument(object value)
    {
        ArgumentNullException.ThrowIfNull(value);
        return value switch
        {
            string text => new NativeVariant
            {
                Type = VariantBstr,
                Pointer = Marshal.StringToBSTR(text)
            },
            bool boolean => new NativeVariant
            {
                Type = VariantBoolean,
                Boolean = boolean ? (short)-1 : (short)0
            },
            int integer => new NativeVariant
            {
                Type = VariantInt32,
                Int32 = integer
            },
            NativeComDispatch dispatch when dispatch._pointer != 0 => new NativeVariant
            {
                Type = VariantDispatch,
                Pointer = dispatch._pointer
            },
            NativeComMissing => new NativeVariant
            {
                Type = VariantError,
                Int32 = ParameterNotFound
            },
            _ => throw new ArgumentException(
                $"Unsupported native COM argument type: {value.GetType().FullName}",
                nameof(value))
        };
    }

    private static void FreeArgument(NativeVariant* value)
    {
        if (value->Type == VariantBstr && value->Pointer != 0)
        {
            Marshal.FreeBSTR(value->Pointer);
        }
        *value = default;
    }

    private static nint QueryInterface(nint pointer, Guid interfaceId)
    {
        nint resultPointer = 0;
        var vtable = *(nint**)pointer;
        var query = (delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)vtable[0];
        var result = query(pointer, &interfaceId, &resultPointer);
        ThrowForResult(result, "COM interface is unavailable.");
        return resultPointer;
    }

    private static void Release(nint pointer)
    {
        if (pointer == 0)
        {
            return;
        }
        var vtable = *(nint**)pointer;
        var release = (delegate* unmanaged[Stdcall]<nint, uint>)vtable[2];
        _ = release(pointer);
    }

    private static void EnsureComApartment()
    {
        if (ComApartment.Initialized)
        {
            return;
        }
        var result = CoInitializeEx(0, 0);
        if (result < 0 && result != ChangedApartmentMode)
        {
            ThrowForResult(result, "COM apartment initialization failed.");
        }
        ComApartment.Initialized = true;
    }

    private static void ThrowForResult(int result, string message)
    {
        if (result < 0)
        {
            throw new COMException(message, result);
        }
    }

    private static void ThrowForDispatchResult(
        int result,
        string message,
        NativeExceptionInformation* exceptionInformation)
    {
        if (result != DispatchException)
        {
            ThrowForResult(result, message);
            return;
        }

        if (exceptionInformation->DeferredFillIn != 0)
        {
            var fillIn = (delegate* unmanaged[Stdcall]<NativeExceptionInformation*, int>)
                exceptionInformation->DeferredFillIn;
            ThrowForResult(
                fillIn(exceptionInformation),
                $"{message} Deferred COM exception information could not be loaded.");
        }

        var normalizedResult = exceptionInformation->Scode < 0
            ? exceptionInformation->Scode
            : exceptionInformation->Code != 0
                ? unchecked((int)(ControlFacilityError | exceptionInformation->Code))
                : result;
        ThrowForResult(normalizedResult, message);
    }

    private static void FreeExceptionInformation(
        NativeExceptionInformation* exceptionInformation)
    {
        foreach (var value in new[]
                 {
                     exceptionInformation->Source,
                     exceptionInformation->Description,
                     exceptionInformation->HelpFile
                 })
        {
            if (value != 0)
            {
                Marshal.FreeBSTR(value);
            }
        }
        *exceptionInformation = default;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DispatchParameters
    {
        internal NativeVariant* Arguments;
        internal int* NamedArgumentIds;
        internal uint ArgumentCount;
        internal uint NamedArgumentCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeExceptionInformation
    {
        internal ushort Code;
        internal ushort Reserved;
        internal nint Source;
        internal nint Description;
        internal nint HelpFile;
        internal uint HelpContext;
        internal nint ReservedPointer;
        internal nint DeferredFillIn;
        internal int Scode;
    }

    [StructLayout(LayoutKind.Explicit, Size = 16)]
    private struct NativeVariant
    {
        [FieldOffset(0)] internal ushort Type;
        [FieldOffset(8)] internal short Boolean;
        [FieldOffset(8)] internal int Int32;
        [FieldOffset(8)] internal uint UInt32;
        [FieldOffset(8)] internal nint Pointer;
    }

    private sealed class NativeComValue : IDisposable
    {
        private NativeVariant _value;

        internal NativeComValue(NativeVariant value) => _value = value;

        internal NativeComDispatch TakeDispatch(string member)
        {
            if (_value.Type == VariantDispatch && _value.Pointer != 0)
            {
                var pointer = _value.Pointer;
                _value = default;
                return new NativeComDispatch(pointer);
            }
            if (_value.Type == VariantUnknown && _value.Pointer != 0)
            {
                var pointer = QueryInterface(_value.Pointer, DispatchInterfaceId);
                return new NativeComDispatch(pointer);
            }
            throw new InvalidDataException($"COM member '{member}' did not return IDispatch.");
        }

        internal nint TakeUnknown(string member)
        {
            if (_value.Type is VariantUnknown or VariantDispatch && _value.Pointer != 0)
            {
                var pointer = _value.Pointer;
                _value = default;
                return pointer;
            }
            throw new InvalidDataException($"COM member '{member}' did not return IUnknown.");
        }

        internal string? TakeOptionalString(string member)
        {
            if (_value.Type is VariantEmpty or VariantNull)
            {
                return null;
            }
            if (_value.Type != VariantBstr)
            {
                throw new InvalidDataException($"COM member '{member}' did not return a string.");
            }
            return _value.Pointer == 0 ? null : Marshal.PtrToStringBSTR(_value.Pointer);
        }

        internal int TakeInt32(string member) => _value.Type switch
        {
            VariantInt16 => (short)_value.Int32,
            VariantInt32 or VariantInt => _value.Int32,
            VariantUInt16 => (ushort)_value.UInt32,
            VariantUInt32 or VariantUInt when _value.UInt32 <= int.MaxValue => (int)_value.UInt32,
            _ => throw new InvalidDataException($"COM member '{member}' did not return Int32.")
        };

        internal bool TakeBoolean(string member)
        {
            if (_value.Type != VariantBoolean || _value.Boolean is not (0 or -1))
            {
                throw new InvalidDataException($"COM member '{member}' did not return VARIANT_BOOL.");
            }
            return _value.Boolean == -1;
        }

        internal IReadOnlyList<string> TakeStringArray(string member)
        {
            if (_value.Type is VariantEmpty or VariantNull)
            {
                return [];
            }
            if ((_value.Type & VariantArray) == 0 || _value.Pointer == 0)
            {
                throw new InvalidDataException($"COM member '{member}' did not return a SAFEARRAY.");
            }
            if (SafeArrayGetDim(_value.Pointer) != 1)
            {
                throw new InvalidDataException($"COM member '{member}' returned a multidimensional SAFEARRAY.");
            }
            ThrowForResult(
                SafeArrayGetLBound(_value.Pointer, 1, out var lower),
                "SAFEARRAY lower bound is unavailable.");
            ThrowForResult(
                SafeArrayGetUBound(_value.Pointer, 1, out var upper),
                "SAFEARRAY upper bound is unavailable.");
            var elementType = (ushort)(_value.Type & ~VariantArray);
            if (elementType == VariantEmpty)
            {
                ThrowForResult(
                    SafeArrayGetVartype(_value.Pointer, out elementType),
                    "SAFEARRAY element type is unavailable.");
            }
            var result = new List<string>();
            for (var index = lower; index <= upper; index++)
            {
                if (elementType == VariantBstr)
                {
                    nint textPointer = 0;
                    ThrowForResult(
                        SafeArrayGetElement(_value.Pointer, &index, &textPointer),
                        "SAFEARRAY string element is unavailable.");
                    try
                    {
                        result.Add(Marshal.PtrToStringBSTR(textPointer) ??
                            throw new InvalidDataException("SAFEARRAY contains a null string."));
                    }
                    finally
                    {
                        if (textPointer != 0)
                        {
                            Marshal.FreeBSTR(textPointer);
                        }
                    }
                    continue;
                }
                if (elementType == VariantVariant)
                {
                    NativeVariant element = default;
                    ThrowForResult(
                        SafeArrayGetElement(_value.Pointer, &index, &element),
                        "SAFEARRAY VARIANT element is unavailable.");
                    using var wrapped = new NativeComValue(element);
                    result.Add(wrapped.TakeOptionalString(member) ??
                        throw new InvalidDataException("SAFEARRAY contains a null string."));
                    continue;
                }
                throw new InvalidDataException(
                    $"COM member '{member}' returned an unsupported SAFEARRAY element type.");
            }
            return result.OrderBy(item => item, StringComparer.Ordinal).ToArray();
        }

        internal void RequireEmpty(string member)
        {
            if (_value.Type is not (VariantEmpty or VariantNull))
            {
                throw new InvalidDataException($"COM property '{member}' returned an unexpected value.");
            }
        }

        public void Dispose()
        {
            fixed (NativeVariant* pointer = &_value)
            {
                VariantClear(pointer);
            }
            _value = default;
        }
    }

    internal sealed class NativeComMissing
    {
        internal static readonly NativeComMissing Value = new();
        private NativeComMissing()
        {
        }
    }

    private static class ComApartment
    {
        [ThreadStatic]
        internal static bool Initialized;
    }

    [DllImport("ole32.dll")]
    private static extern int CoInitializeEx(nint reserved, uint concurrencyModel);

    [DllImport("ole32.dll")]
    private static extern int CoCreateInstance(
        Guid* classId,
        nint outer,
        uint context,
        Guid* interfaceId,
        nint* instance);

    [DllImport("oleaut32.dll")]
    private static extern int VariantClear(NativeVariant* variant);

    [DllImport("oleaut32.dll")]
    private static extern uint SafeArrayGetDim(nint safeArray);

    [DllImport("oleaut32.dll")]
    private static extern int SafeArrayGetLBound(nint safeArray, uint dimension, out int lowerBound);

    [DllImport("oleaut32.dll")]
    private static extern int SafeArrayGetUBound(nint safeArray, uint dimension, out int upperBound);

    [DllImport("oleaut32.dll")]
    private static extern int SafeArrayGetVartype(nint safeArray, out ushort variantType);

    [DllImport("oleaut32.dll")]
    private static extern int SafeArrayGetElement(nint safeArray, int* indices, void* value);
}
