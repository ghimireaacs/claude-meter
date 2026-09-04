--!nonstrict
-- Bar capsule: runs `claude-meter --report` on a timer and draws one window.
--
-- The CLI caches on disk, so the poll interval here is how often a capsule asks,
-- not how often the endpoint is hit. Two capsules on the same interval cost one
-- request between them.

local metricId = tostring(noctalia.getConfig("metric") or "auto")
local showGlyph = noctalia.getConfig("show_glyph") ~= false
local showGauge = noctalia.getConfig("show_gauge") ~= false
local showCountdown = noctalia.getConfig("show_countdown") ~= false
local colorByUsage = noctalia.getConfig("color_by_usage") ~= false

-- Catppuccin by name, or the shell's own semantic roles. Hex is accepted
-- wherever a role token is, so a flavour is a lookup rather than a code path.
local PALETTES = {
    mocha = { ok = "#a6e3a1", warning = "#fab387", critical = "#f38ba8",
              calm = "#cdd6f4", muted = "#a6adc8", track = "#585b70", accent = "#cba6f7" },
    macchiato = { ok = "#a6da95", warning = "#f5a97f", critical = "#ed8796",
                  calm = "#cad3f5", muted = "#b8c0e0", track = "#5b6078", accent = "#c6a0f6" },
    frappe = { ok = "#a6d189", warning = "#ef9f76", critical = "#e78284",
               calm = "#c6d0f5", muted = "#b5bfe2", track = "#626880", accent = "#ca9ee6" },
    latte = { ok = "#40a02b", warning = "#fe640b", critical = "#d20f39",
              calm = "#4c4f69", muted = "#6c6f85", track = "#9ca0b0", accent = "#8839ef" },
    -- The shell's roles, so the capsule re-tints itself with the active theme.
    theme = { ok = "on_surface", warning = "tertiary", critical = "error",
              calm = "on_surface", muted = "on_surface_variant",
              track = "on_surface/0.16", accent = "primary" },
}

local palette = PALETTES[tostring(noctalia.getConfig("palette") or "mocha")] or PALETTES.mocha

-- Noctalia inherits the compositor's environment, which on most session
-- managers does not carry ~/.local/bin. Fall back to the install path the
-- installer uses before giving up on a "not on PATH" error.
local function resolveBinary()
    local configured = tostring(noctalia.getConfig("binary") or ""):match("^%s*(.-)%s*$")
    if configured == "" then configured = "claude-meter" end
    if noctalia.commandExists(configured) then return configured end
    if configured:find("/") == nil then
        local fallback = noctalia.expandPath("~/.local/bin/" .. configured)
        if noctalia.commandExists(fallback) then return fallback end
    end
    return configured
end

local COMMAND = resolveBinary() .. " --report --metric " .. metricId
local TIMEOUT_MS = 30000

local report = nil
local failure = ""
local inFlight = false
-- Redrawn between polls so the countdown ticks down without a spawn.
local TICK_MS = 30000

local function intervalMs()
    local minutes = tonumber(noctalia.getConfig("refresh_minutes")) or 5
    if minutes < 5 then minutes = 5 end
    return math.floor(minutes * 60 * 1000)
end

-- ── Report helpers ────────────────────────────────────────────────────────────

local function metrics()
    if type(report) ~= "table" or type(report.metrics) ~= "table" then return {} end
    return report.metrics
end

-- "auto" follows whichever window is closest to running out, which is the one a
-- glance at the bar is asking about.
local function chosen()
    local best = nil
    for _, metric in ipairs(metrics()) do
        if type(metric) == "table" then
            if metricId ~= "auto" then
                if metric.id == metricId then return metric end
            elseif best == nil or (tonumber(metric.percent) or 0) > (tonumber(best.percent) or 0) then
                best = metric
            end
        end
    end
    return best
end

-- The CLI stamps the read, so the countdown it shipped is corrected by the age
-- of the report rather than frozen at its value.
local function secondsLeft(metric)
    local left = tonumber(metric.resets_in)
    if left == nil then return nil end
    local fetched = tonumber(report ~= nil and report.fetched_at or nil)
    if fetched ~= nil then
        left = left - math.floor(noctalia.nowMs() / 1000 - fetched)
    end
    if left < 0 then return 0 end
    return left
end

-- Two units on the bar ("4d 7h") is the string that overflowed a capsule, so
-- the bar gets the largest unit alone and the tooltip keeps the precision.
local function countdown(metric, long)
    local left = secondsLeft(metric)
    if left == nil or left <= 0 then return "" end
    local days = math.floor(left / 86400)
    local hours = math.floor((left % 86400) / 3600)
    local minutes = math.floor((left % 3600) / 60)
    if long then
        if days > 0 then return string.format("%dd %dh", days, hours) end
        if hours > 0 then return string.format("%dh %dm", hours, minutes) end
        return string.format("%dm", minutes)
    end
    if days > 0 then return string.format("%dd", days) end
    if hours > 0 then return string.format("%dh", hours) end
    return string.format("%dm", minutes)
end

local function severityColor(metric)
    if not colorByUsage then return palette.calm end
    local severity = tostring(metric.severity or "ok")
    if severity == "critical" then return palette.critical end
    if severity == "warning" then return palette.warning end
    -- Quiet usage reads as text, not as a green alarm; the gauge carries the
    -- colour that matters.
    return palette.calm
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

-- Two stacked bars: usage on top, how far into the window we are underneath.
-- A fill running past the thin one is spend ahead of the clock, which is the
-- pace note without a word of text.
local function gauge(metric, tint)
    local percent = math.max(0, math.min(100, tonumber(metric.percent) or 0))
    -- The fill is the accent while usage is quiet and the severity colour once
    -- it is not, so the bar answers before the number is read.
    local fill = tostring(metric.severity or "ok") == "ok" and palette.accent or tint
    local bars = {
        ui.progress({ progress = percent / 100, fill = fill, track = palette.track,
                      radius = 3, width = 26, height = 4 }),
    }
    local elapsed = tonumber(metric.elapsed_percent)
    if elapsed ~= nil and elapsed >= 0 and elapsed <= 100 then
        bars[2] = ui.progress({ progress = elapsed / 100, fill = palette.muted,
                                track = palette.track, radius = 1, width = 26, height = 2 })
    end
    return ui.column({ gap = 1, align = "center" }, bars)
end

local function render()
    local metric = chosen()
    local children = {}

    if showGlyph then
        children[#children + 1] = ui.glyph({
            name = "brain",
            size = 13,
            color = metric ~= nil and severityColor(metric)
                or (failure ~= "" and palette.critical or palette.muted),
        })
    end

    if metric ~= nil then
        if showGauge then
            children[#children + 1] = gauge(metric, severityColor(metric))
        end
        -- Fixed width, right-aligned: the capsule is as wide at 7% as at 100%
        -- and stops nudging the widgets beside it once per read.
        children[#children + 1] = ui.label({
            text = tostring(metric.percent or 0) .. "%",
            fontSize = 11,
            fontWeight = "semibold",
            color = severityColor(metric),
            maxLines = 1,
            width = 30,
            textAlign = "end",
        })
        local left = showCountdown and countdown(metric) or ""
        if left ~= "" then
            children[#children + 1] = ui.label({
                text = left,
                fontSize = 10,
                color = palette.muted,
                maxLines = 1,
                width = 22,
                textAlign = "end",
            })
        end
        -- A stale reading keeps its numbers and marks them. A glyph, not a "!",
        -- so the row width does not change when it appears.
        if type(report) == "table" and report.stale == true then
            children[#children + 1] = ui.glyph({ name = "clock-exclamation", size = 11,
                                                 color = palette.warning })
        end
    elseif #children == 0 then
        children[1] = ui.glyph({
            name = "brain",
            size = 13,
            color = failure ~= "" and palette.critical or palette.muted,
        })
    end

    -- No tooltip: hover offered theme-painted key/value strings, and the panel
    -- says the same thing in colour on a click.
    barWidget.render(ui.row({ gap = 4, align = "center" }, children))
end

-- ── Polling ───────────────────────────────────────────────────────────────────

local function poll(force)
    if inFlight then return end
    inFlight = true
    local command = force and (COMMAND .. " --refresh") or COMMAND

    local started = noctalia.runAsync(command, function(result)
        inFlight = false
        if result == nil or result.timedOut then
            failure = result == nil and "spawn_failed" or "timed_out"
            render()
            return
        end
        if result.exitCode == 127 then
            failure = "not_installed"
            render()
            return
        end

        local decoded = noctalia.json.decode(result.stdout or "")
        if type(decoded) == "table" and type(decoded.metrics) == "table" then
            report = decoded
            -- The CLI reports its own trouble inside a report it still filled
            -- in from cache; that error names the capsule's state better than
            -- the exit code does.
            local err = type(decoded.error) == "table" and tostring(decoded.error.code or "") or ""
            failure = (#decoded.metrics > 0 and decoded.stale ~= true) and "" or err
        else
            failure = "failed"
        end
        render()
    end, TIMEOUT_MS)

    if not started then
        inFlight = false
        failure = "spawn_failed"
        render()
    end
end

-- A click opens the panel, which asks for its own read on the way up. The
-- capsule still refreshes on its timer, so a bar with no panel open stays live.
function onClick()
    noctalia.togglePanel("ghimireaacs/claude-meter:panel")
end

function onConfigChanged()
    poll(false)
end

local lastPoll = 0

function update()
    local now = noctalia.nowMs()
    if now - lastPoll >= intervalMs() then
        lastPoll = now
        poll(false)
    else
        render()
    end
end

noctalia.setUpdateInterval(TICK_MS)
lastPoll = noctalia.nowMs()
poll(false)
render()
