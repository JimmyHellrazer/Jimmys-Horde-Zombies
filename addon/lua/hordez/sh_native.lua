local function LoadNative()
    if not util.IsBinaryModuleInstalled("num") then return nil end

    local ok, err = pcall(require, "num")
    if ok and istable(num) and num.Crowd then return num end

    print("[hordez] num module failed to load: " .. tostring(err))

    return nil
end

HZ.NativeLib = HZ.NativeLib or LoadNative()

function HZ.NativeOn()
    return HZ.NativeLib ~= nil and HZ.CV.native:GetBool()
end

if SERVER then
    local function Announce()
        SetGlobal2Bool("hz_native", HZ.NativeLib ~= nil)
    end

    Announce()
    hook.Add("InitPostEntity", "hordez_native", Announce)
else
    HZ.DX12 = render.GetDXLevel() == 120

    function HZ.ServerNative()
        return GetGlobal2Bool("hz_native", false)
    end
end
