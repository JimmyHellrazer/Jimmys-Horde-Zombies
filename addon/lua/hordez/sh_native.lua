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

local mapBsp, mapBspTried = nil, false
local BSP_LUMPS = { 1, 5, 6, 10, 14, 17, 18, 19 }

local function ReadLumpHeader(f, ver, index)
    f:Seek(8 + index * 16)
    if ver == 21 then
        local lver = f:ReadLong()
        local ofs = f:ReadLong()
        local len = f:ReadLong()
        local uncomp = f:ReadLong()
        return ofs, len, lver, uncomp
    end

    local ofs = f:ReadLong()
    local len = f:ReadLong()
    local lver = f:ReadLong()
    local uncomp = f:ReadLong()

    return ofs, len, lver, uncomp
end

function HZ.GetMapBsp()
    if mapBsp then return mapBsp end
    if mapBspTried then return nil end
    if not (HZ.NativeOn() and HZ.NativeLib.BspLoadLumps) then return nil end

    mapBspTried = true
    local f = file.Open("maps/" .. game.GetMap() .. ".bsp", "rb", "GAME")
    if not f then return nil end

    local ident = f:ReadLong()
    local ver = f:ReadLong()
    if ident ~= 0x50534256 or ver < 19 or ver > 21 then
        f:Close()
        return nil
    end

    local blobs, leafVer = {}, 1
    for i = 1, #BSP_LUMPS do
        local idx = BSP_LUMPS[i]
        local ofs, len, lver, uncomp = ReadLumpHeader(f, ver, idx)
        if uncomp ~= 0 or ofs < 0 or len < 0 or len > 32 * 1024 * 1024 then
            f:Close()
            return nil
        end

        if idx == 10 then leafVer = lver end
        if len == 0 then
            blobs[i] = ""
        else
            f:Seek(ofs)
            blobs[i] = f:Read(len) or ""
        end
    end

    f:Close()
    local ok, id = pcall(HZ.NativeLib.BspLoadLumps,
        blobs[1], blobs[2], blobs[3], blobs[4], leafVer, blobs[5], blobs[6], blobs[7], blobs[8])

    if ok and id then mapBsp = id end

    return mapBsp
end

hook.Add("ShutDown", "hordez_native_bsp", function()
    if mapBsp and HZ.NativeLib and HZ.NativeLib.BspFree then
        HZ.NativeLib.BspFree(mapBsp)
        mapBsp = nil
    end
end)

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
