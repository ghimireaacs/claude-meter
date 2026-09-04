--!nonstrict
-- Click panel: the coloured half of the widget.
--
-- A tooltip takes key/value strings and paints them with the theme, so severity
-- there is a filling disc at best. Here every window gets a real gauge, tinted
-- by the palette the capsule uses, plus the pace and the wall-clock reset.
--
-- Self-contained on purpose: it runs the CLI itself rather than subscribing to
-- the capsule, so the panel works whether or not a capsule is on a bar. The
-- CLI's cache is what keeps the extra call cheap.

local PALETTES = {
    mocha = { ok = "#a6e3a1", warning = "#fab387", critical = "#f38ba8",
              calm = "#cdd6f4", muted = "#a6adc8", track = "#585b70", accent = "#cba6f7" },
    macchiato = { ok = "#a6da95", warning = "#f5a97f", critical = "#ed8796",
                  calm = "#cad3f5", muted = "#b8c0e0", track = "#5b6078", accent = "#c6a0f6" },
    frappe = { ok = "#a6d189", warning = "#ef9f76", critical = "#e78284",
               calm = "#c6d0f5", muted = "#b5bfe2", track = "#626880", accent = "#ca9ee6" },
    latte = { ok = "#40a02b", warning = "#fe640b", critical = "#d20f39",
              calm = "#4c4f69", muted = "#6c6f85", track = "#9ca0b0", accent = "#8839ef" },
    theme = { ok = "on_surface", warning = "tertiary", critical = "error",
              calm = "on_surface", muted = "on_surface_variant",
              track = "on_surface/0.16", accent = "primary" },
}

-- The palette is a widget setting, since a capsule is where it is seen; the
-- panel reads the plugin-level default so both halves match out of the box.
local palette = PALETTES[tostring(noctalia.getConfig("palette") or "mocha")] or PALETTES.mocha

local LABELS = {
    five_hour = "Session",
    seven_day = "Weekly",
    seven_day_opus = "Opus",
    seven_day_sonnet = "Sonnet",
    seven_day_oauth_apps = "Apps",
}

local BAR_WIDTH = 288

local report = nil
local failure = ""
local polling = false

-- ── Data ──────────────────────────────────────────────────────────────────────

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

local BINARY = resolveBinary()

local render  -- forward declaration: the poll callback draws.

local function poll(force)
    if polling then return end
    polling = true
    render()

    local command = BINARY .. " --report" .. (force and " --refresh" or "")
    local started = noctalia.runAsync(command, function(result)
        polling = false
        if result == nil or result.timedOut then
            failure = result == nil and "spawn_failed" or "timed_out"
        elseif result.exitCode == 127 then
            failure = "not_installed"
        else
            local decoded = noctalia.json.decode(result.stdout or "")
            if type(decoded) == "table" and type(decoded.metrics) == "table" then
                report = decoded
                local err = type(decoded.error) == "table" and tostring(decoded.error.code or "") or ""
                failure = (#decoded.metrics > 0 and decoded.stale ~= true) and "" or err
            else
                failure = "failed"
            end
        end
        render()
    end, 30000)

    if not started then
        polling = false
        failure = "spawn_failed"
        render()
    end
end

local function metrics()
    if type(report) ~= "table" or type(report.metrics) ~= "table" then return {} end
    return report.metrics
end

local function severityColor(metric)
    local severity = tostring(metric.severity or "ok")
    if severity == "critical" then return palette.critical end
    if severity == "warning" then return palette.warning end
    return palette.calm
end

local function fillColor(metric)
    return tostring(metric.severity or "ok") == "ok" and palette.accent or severityColor(metric)
end

-- Counted from the read rather than from the value the CLI shipped, so a panel
-- left open keeps counting down.
local function secondsLeft(metric)
    local left = tonumber(metric.resets_in)
    if left == nil then return nil end
    local fetched = tonumber(report ~= nil and report.fetched_at or nil)
    if fetched ~= nil then
        left = left - math.floor(noctalia.nowMs() / 1000 - fetched)
    end
    return math.max(0, left)
end

local function countdown(metric)
    local left = secondsLeft(metric)
    if left == nil or left <= 0 then return "" end
    local days = math.floor(left / 86400)
    local hours = math.floor((left % 86400) / 3600)
    local minutes = math.floor((left % 3600) / 60)
    local seconds = left % 60
    if days > 0 then return string.format("%dd %dh", days, hours) end
    if hours > 0 then return string.format("%dh %02dm", hours, minutes) end
    return string.format("%dm %02ds", minutes, seconds)
end

local function paceDelta(metric)
    local elapsed = tonumber(metric.elapsed_percent)
    if elapsed == nil or elapsed < 0 or elapsed > 100 then return nil end
    return (tonumber(metric.percent) or 0) - elapsed
end

local function errorText()
    if failure == "not_installed" then return "claude-meter was not found on PATH" end
    if failure == "no_credentials" then return "No Claude credentials — run claude and log in" end
    if failure == "rate_limited" then return "Rate limited — the endpoint wants 5 minutes between reads" end
    if failure == "refresh_failed" then return "Token refresh was rejected — log in with claude again" end
    if failure == "network" then return "Network unreachable" end
    if failure == "timed_out" then return "claude-meter timed out" end
    if failure == "spawn_failed" then return "claude-meter could not be started" end
    if failure == "" then return "" end
    return failure
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

local function windowCard(metric)
    local percent = math.max(0, math.min(100, tonumber(metric.percent) or 0))
    local id = tostring(metric.id or "")
    local tint = severityColor(metric)

    local heading = {
        ui.label({ text = LABELS[id] or tostring(metric.label or id), fontSize = 13,
                   fontWeight = "semibold", color = palette.calm }),
        ui.spacer({ flexGrow = 1 }),
    }

    -- Pace beside the reading: how far ahead of the clock the spend is, which is
    -- the number the percentage alone cannot give.
    local delta = paceDelta(metric)
    if delta ~= nil and math.abs(delta) >= 10 then
        local ahead = delta > 0
        heading[#heading + 1] = ui.glyph({
            name = ahead and "arrow-up" or "arrow-down", size = 12,
            color = ahead and palette.warning or palette.muted,
        })
        heading[#heading + 1] = ui.label({
            text = tostring(math.floor(math.abs(delta) + 0.5)),
            fontSize = 11, color = ahead and palette.warning or palette.muted,
        })
    end
    heading[#heading + 1] = ui.label({ text = string.format("%d%%", percent), fontSize = 14,
                                       fontWeight = "bold", color = tint })

    -- Quota above, window elapsed below: a fill longer than the thin bar is
    -- spend running ahead of time, without a word of text.
    local gauge = {
        ui.progress({ progress = percent / 100, fill = fillColor(metric), track = palette.track,
                      radius = 4, width = BAR_WIDTH, height = 7 }),
    }
    local elapsed = tonumber(metric.elapsed_percent)
    if elapsed ~= nil and elapsed >= 0 and elapsed <= 100 then
        gauge[2] = ui.progress({ progress = elapsed / 100, fill = palette.muted,
                                 track = palette.track, radius = 2, width = BAR_WIDTH, height = 3 })
    end

    local footer = {}
    local left = countdown(metric)
    if left ~= "" then
        footer[#footer + 1] = ui.glyph({ name = "clock", size = 12, color = palette.muted })
        footer[#footer + 1] = ui.label({ text = left, fontSize = 11, color = palette.muted })
    end
    footer[#footer + 1] = ui.spacer({ flexGrow = 1 })
    local when = tostring(metric.resets_label or "")
    if when ~= "" then
        footer[#footer + 1] = ui.label({ text = when, fontSize = 11, color = palette.muted })
    end

    return ui.column({ gap = 6 }, {
        ui.row({ gap = 6, align = "center" }, heading),
        ui.column({ gap = 2 }, gauge),
        ui.row({ gap = 5, align = "center" }, footer),
    })
end

function render()
    local header = {
        ui.glyph({ name = "brain", size = 18, color = palette.accent }),
        ui.label({ text = "Claude usage", fontSize = 15, fontWeight = "bold", color = palette.calm }),
        ui.spacer({ flexGrow = 1 }),
    }
    local plan = type(report) == "table" and tostring(report.plan or "") or ""
    if plan ~= "" then
        header[#header + 1] = ui.label({ text = plan, fontSize = 11, color = palette.muted })
    end
    header[#header + 1] = ui.button({
        glyph = polling and "loader-2" or "refresh",
        variant = "ghost", controlSize = "sm",
        tooltip = polling and "Reading…" or "Refresh now",
        enabled = not polling,
        onClick = function() poll(true) end,
    })

    local body = { ui.row({ gap = 8, align = "center" }, header) }

    for _, metric in ipairs(metrics()) do
        body[#body + 1] = windowCard(metric)
    end

    if failure ~= "" then
        body[#body + 1] = ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "alert-circle", size = 13, color = palette.critical }),
            ui.label({ text = errorText(), fontSize = 11, color = palette.critical, maxLines = 2 }),
        })
    elseif type(report) == "table" and report.stale == true then
        body[#body + 1] = ui.label({ text = "Showing the last good read", fontSize = 11,
                                     color = palette.warning })
    elseif #metrics() == 0 then
        body[#body + 1] = ui.label({ text = "Waiting for the first read", fontSize = 11,
                                     color = palette.muted })
    end

    panel.render(ui.column({ gap = 14, padding = 16 }, body))
end

-- ── Wiring ────────────────────────────────────────────────────────────────────

function onOpen(_context)
    -- Every open asks for numbers; the CLI answers from its cache unless the
    -- cache has aged out, so this costs a request only when one was due.
    poll(false)
    -- Second ticks so the session countdown moves while the panel is watched.
    panel.setWantsSecondTicks(true)
    render()
end

function update()
    render()
end

function onClose()
    panel.setWantsSecondTicks(false)
end

render()
