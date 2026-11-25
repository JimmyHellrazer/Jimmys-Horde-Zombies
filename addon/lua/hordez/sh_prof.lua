HZ.Prof = HZ.Prof or {}
local Prof = HZ.Prof

local SysTime = SysTime
local max = math.max

local cvProf = HZ.CV.profile
HZ.ProfOn = cvProf and cvProf:GetBool() or false

local cur = {}
local totals = {}
local snap = {}
local peaks = {}
local spikes = {}
local lastFlush = SysTime()
local startedAt = SysTime()
local WINDOW = 0.25
local SPIKE_MS = 4

function HZ.ProfAdd(name, dt)
    local ms = dt * 1000
    local entry = cur[name]
    if not entry then
        entry = { sum = ms, max = ms, n = 1 }
        cur[name] = entry
    else
        entry.sum = entry.sum + ms
        if ms > entry.max then entry.max = ms end
        entry.n = entry.n + 1
    end

    local tot = totals[name]
    if not tot then
        totals[name] = { sum = ms, n = 1 }
    else
        tot.sum = tot.sum + ms
        tot.n = tot.n + 1
    end

    if ms > (peaks[name] or 0) then peaks[name] = ms end
    if ms >= SPIKE_MS then spikes[name] = (spikes[name] or 0) + 1 end
end

function Prof.Reset()
    cur, totals, snap, peaks, spikes = {}, {}, {}, {}, {}
    Prof.svSnap, Prof.svCounts = {}, nil
    Prof.framePeak = 0
    Prof.frameSpikes = 0
    startedAt = SysTime()
    lastFlush = startedAt
end

local function FlushWindow(now)
    local span = max(now - lastFlush, 0.001)
    lastFlush = now
    local out = {}
    for name, entry in pairs(cur) do
        out[name] = {
            rate = entry.sum / span,
            avg = entry.sum / entry.n,
            winMax = entry.max,
            peak = peaks[name] or entry.max,
            cps = entry.n / span,
            spikes = spikes[name] or 0,
        }
    end

    for name, pk in pairs(peaks) do
        if not out[name] then
            out[name] = { rate = 0, avg = 0, winMax = 0, peak = pk, cps = 0, spikes = spikes[name] or 0 }
        end
    end

    cur = {}
    snap = out

    return out
end

local function BuildReport(title, tbl, elapsed)
    local rows = {}
    for name, tot in pairs(tbl) do
        rows[#rows + 1] = {
            name = name,
            rate = tot.sum / elapsed,
            avg = tot.sum / tot.n,
            peak = peaks[name] or 0,
            cps = tot.n / elapsed,
            total = tot.sum,
            n = tot.n,
            spikes = spikes[name] or 0,
        }
    end

    table.sort(rows, function(a, b) return a.total > b.total end)
    local lines = {
        ("[hordez] %s profile (%.1fs)"):format(title, elapsed),
        ("%-20s %8s %8s %8s %8s %7s %s"):format("section", "ms/s", "avg ms", "peak ms", "total ms", "calls/s", ">4ms"),
    }

    for i = 1, #rows do
        local r = rows[i]
        lines[#lines + 1] = ("%-20s %8.2f %8.3f %8.2f %8.1f %7.0f %d"):format(
            r.name, r.rate, r.avg, r.peak, r.total, r.cps, r.spikes
        )
    end

    if #rows == 0 then lines[#lines + 1] = "(no samples recorded)" end

    return table.concat(lines, "\n")
end

if SERVER then
    util.AddNetworkString("hz_prof")
    util.AddNetworkString("hz_prof_cmd")

    local function PrintServerReport(ply)
        local elapsed = max(SysTime() - startedAt, 0.001)
        local extra = ("real=%d virtual=%d"):format(HZ.Count or 0, HZ.VCount or 0)
        local report = BuildReport("SERVER (" .. extra .. ")", totals, elapsed)
        print(report)
        if IsValid(ply) then
            for line in report:gmatch("[^\n]+") do ply:PrintMessage(HUD_PRINTCONSOLE, line) end
        end
    end

    cvars.AddChangeCallback("hz_profile", function(_, _, new)
        local on = tobool(new)
        if HZ.ProfOn and not on and next(totals) then PrintServerReport() end
        HZ.ProfOn = on
        if on then Prof.Reset() end
    end, "hordez_prof")

    timer.Create("hordez_prof_sv", WINDOW, 0, function()
        if not HZ.ProfOn then return end

        local out = FlushWindow(SysTime())
        local keys = {}
        for name in pairs(out) do keys[#keys + 1] = name end
        table.sort(keys)

        net.Start("hz_prof", true)
        net.WriteUInt(HZ.Count or 0, 16)
        net.WriteUInt(HZ.VCount or 0, 16)
        net.WriteUInt(#keys, 8)
        for i = 1, #keys do
            local name = keys[i]
            local row = out[name]
            net.WriteString(name)
            net.WriteFloat(row.rate)
            net.WriteFloat(row.avg)
            net.WriteFloat(row.peak)
            net.WriteFloat(row.cps)
        end

        net.Broadcast()
    end)

    net.Receive("hz_prof_cmd", function(_, ply)
        if IsValid(ply) and not ply:IsAdmin() then return end

        local action = net.ReadUInt(2)
        if action == 1 then
            Prof.Reset()
        elseif action == 2 then
            PrintServerReport(ply)
        end
    end)

    return
end

Prof.svSnap = Prof.svSnap or {}
Prof.framePeak = 0
Prof.frameSpikes = 0

local function PrintClientReport()
    local elapsed = max(SysTime() - startedAt, 0.001)
    local cStats = HZ.ProfClientStats and HZ.ProfClientStats() or nil
    local extra = ("ents=%d framePeak=%.1fms spikes>16ms=%d"):format(
        #HZ.ClientZombies, Prof.framePeak, Prof.frameSpikes
    )
    if cStats then
        extra = extra .. (" rags=%d(pool=%d) dying=%d(pool=%d)"):format(
            cStats.rags, cStats.ragPool, cStats.dying, cStats.csmPool
        )
    end

    print(BuildReport("CLIENT (" .. extra .. ")", totals, elapsed))
end

cvars.AddChangeCallback("hz_profile", function(_, _, new)
    local on = tobool(new)
    if HZ.ProfOn and not on and next(totals) then PrintClientReport() end
    HZ.ProfOn = on
    if on then Prof.Reset() end
end, "hordez_prof")

net.Receive("hz_prof", function()
    local real = net.ReadUInt(16)
    local virt = net.ReadUInt(16)
    local count = net.ReadUInt(8)
    local data = {}
    for _ = 1, count do
        local name = net.ReadString()
        data[name] = {
            rate = net.ReadFloat(),
            avg = net.ReadFloat(),
            peak = net.ReadFloat(),
            cps = net.ReadFloat(),
        }
    end

    Prof.svCounts = { real = real, virt = virt }
    Prof.svSnap = data
end)

concommand.Add("hz_profile_reset", function()
    Prof.Reset()
    net.Start("hz_prof_cmd")
    net.WriteUInt(1, 2)
    net.SendToServer()
    print("[hordez] profiler reset")
end)

concommand.Add("hz_profile_dump", function()
    PrintClientReport()
    net.Start("hz_prof_cmd")
    net.WriteUInt(2, 2)
    net.SendToServer()
end)

surface.CreateFont("hz_prof_font", {
    font = "DejaVu Sans Mono",
    size = 14,
    weight = 500,
    antialias = true,
})

local COL_BG = Color(12, 14, 18, 215)
local COL_HDR = Color(255, 190, 90)
local COL_SEC = Color(140, 200, 255)
local COL_DIM = Color(170, 175, 185)
local COL_OK = Color(130, 230, 140)
local COL_WARN = Color(255, 210, 90)
local COL_HOT = Color(255, 95, 85)

local function PeakColor(ms)
    if ms >= 4 then return COL_HOT end
    if ms >= 1 then return COL_WARN end

    return COL_OK
end

local function SortedRows(tbl)
    local rows = {}
    for name, row in pairs(tbl) do rows[#rows + 1] = { name = name, r = row } end
    table.sort(rows, function(a, b) return a.r.rate > b.r.rate end)

    return rows
end

local lastFrame = SysTime()
local smoothFt = 0

hook.Add("HUDPaint", "hordez_prof", function()
    if not HZ.ProfOn then return end

    local now = SysTime()
    local ft = (now - lastFrame) * 1000
    lastFrame = now
    if ft < 500 then
        smoothFt = smoothFt == 0 and ft or smoothFt * 0.9 + ft * 0.1
        if ft > Prof.framePeak then Prof.framePeak = ft end
        if ft > 16.7 then Prof.frameSpikes = Prof.frameSpikes + 1 end
    end

    if now - lastFlush >= WINDOW then FlushWindow(now) end

    local svRows = SortedRows(Prof.svSnap)
    local clRows = SortedRows(snap)
    local lineH = 16
    local lines = 4 + (#svRows > 0 and (#svRows + 2) or 0) + (#clRows > 0 and (#clRows + 2) or 0)
    local pad = 10
    local w = 440
    local h = pad * 2 + lines * lineH
    local x, y = 16, 16

    surface.SetDrawColor(COL_BG)
    surface.DrawRect(x, y, w, h)

    local cy = y + pad
    local fps = smoothFt > 0 and math.floor(1000 / smoothFt + 0.5) or 0
    draw.SimpleText(
        ("HORDEZ PROFILER   %d FPS  (%.1f ms | peak %.1f ms)"):format(fps, smoothFt, Prof.framePeak),
        "hz_prof_font", x + pad, cy, COL_HDR
    )
    cy = cy + lineH

    local svC = Prof.svCounts
    local cStats = HZ.ProfClientStats and HZ.ProfClientStats() or nil
    local countLine = ("SV: %d real, %d virt   CL: %d ents"):format(
        svC and svC.real or 0, svC and svC.virt or 0, #HZ.ClientZombies
    )
    if cStats then
        countLine = countLine .. ("  rags %d/%d  dying %d/%d"):format(
            cStats.rags, cStats.ragPool, cStats.dying, cStats.csmPool
        )
    end

    draw.SimpleText(countLine, "hz_prof_font", x + pad, cy, COL_DIM)
    cy = cy + lineH + 4

    local function DrawSection(title, rows)
        if #rows == 0 then return end

        draw.SimpleText(("%-18s %7s %7s %7s %7s"):format(title, "ms/s", "avg", "peak", "calls/s"),
            "hz_prof_font", x + pad, cy, COL_SEC)
        cy = cy + lineH
        for i = 1, #rows do
            local item = rows[i]
            local r = item.r
            draw.SimpleText(
                ("%-18s %7.2f %7.3f %7.2f %7.0f"):format(item.name, r.rate, r.avg, r.peak, r.cps),
                "hz_prof_font", x + pad, cy, PeakColor(r.peak)
            )
            cy = cy + lineH
        end

        cy = cy + lineH
    end

    DrawSection("SERVER", svRows)
    DrawSection("CLIENT", clRows)
end)
