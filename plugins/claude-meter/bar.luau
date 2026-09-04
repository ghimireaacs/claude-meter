--!nonstrict
-- Bar capsule: runs `claude-meter --report` on a timer and draws one window.
--
-- The CLI caches on disk, so the poll interval here is how often a capsule asks,
-- not how often the endpoint is hit. Two capsules on the same interval cost one
-- request between them.

local metricId = tostring(noctalia.getConfig("metric") or "auto")
local showGlyph = noctalia.getConfig("show_glyph") ~= false
local showLabel = noctalia.getConfig("show_label") == true
local showCountdown = noctalia.getConfig("show_countdown") ~= false
local colorByUsage = noctalia.getConfig("color_by_usage") ~= false

local COMMAND = "claude-meter --report --metric " .. metricId
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

local function countdown(metric)
    local left = secondsLeft(metric)
    if left == nil or left <= 0 then return "" end
    local days = math.floor(left / 86400)
    local hours = math.floor((left % 86400) / 3600)
    local minutes = math.floor((left % 3600) / 60)
    if days > 0 then return string.format("%dd %dh", days, hours) end
    if hours > 0 then return string.format("%dh %dm", hours, minutes) end
    return string.format("%dm", minutes)
end

local function severityColor(metric)
    if not colorByUsage then return "on_surface" end
    local severity = tostring(metric.severity or "ok")
    if severity == "critical" then return "error" end
    if severity == "warning" then return "tertiary" end
    return "on_surface"
end

local function errorText()
    if failure == "" then return "" end
    if failure == "not_installed" then return "claude-meter is not on PATH" end
    if failure == "no_credentials" then return "No Claude credentials — run `claude` and log in" end
    if failure == "rate_limited" then return "Rate limited — raise the refresh interval" end
    if failure == "network" then return "Network unreachable" end
    if failure == "timed_out" then return "claude-meter timed out" end
    return failure
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

local function tooltipRows()
    local rows = {}
    if failure ~= "" then
        rows[#rows + 1] = { key = "Claude Meter", value = errorText() }
        if report == nil then return rows end
    end
    if type(report) == "table" and tostring(report.plan or "") ~= "" then
        rows[#rows + 1] = { key = "Plan", value = tostring(report.plan) }
    end
    for _, metric in ipairs(metrics()) do
        local value = tostring(metric.percent or 0) .. "%"
        local left = countdown(metric)
        if left ~= "" then value = value .. " · resets in " .. left end
        local elapsed = tonumber(metric.elapsed_percent)
        -- Usage against time spent: 60% burned 20% into the window is the number
        -- worth knowing, and it costs one subtraction to say.
        if elapsed ~= nil and elapsed >= 0 and elapsed <= 100 then
            local delta = (tonumber(metric.percent) or 0) - elapsed
            if delta >= 10 then
                value = value .. " · ahead of pace"
            elseif delta <= -10 then
                value = value .. " · behind pace"
            end
        end
        rows[#rows + 1] = { key = tostring(metric.label or metric.id or "?"), value = value }
    end
    if type(report) == "table" and report.stale == true then
        rows[#rows + 1] = { key = "Updated", value = "stale — last read failed" }
    end
    if #rows == 0 then
        rows[1] = { key = "Claude Meter", value = "Waiting for the first read" }
    end
    return rows
end

local function render()
    local metric = chosen()
    local children = {}

    if showGlyph then
        children[#children + 1] = ui.glyph({
            name = "brain",
            size = 13,
            color = metric ~= nil and severityColor(metric)
                or (failure ~= "" and "error" or "on_surface_variant"),
        })
    end

    if metric ~= nil then
        if showLabel then
            children[#children + 1] = ui.label({
                text = tostring(metric.label or ""),
                fontSize = 10,
                color = "on_surface_variant",
                maxLines = 1,
            })
        end
        children[#children + 1] = ui.label({
            text = tostring(metric.percent or 0) .. "%",
            fontSize = 12,
            color = severityColor(metric),
            maxLines = 1,
        })
        local left = showCountdown and countdown(metric) or ""
        if left ~= "" then
            children[#children + 1] = ui.label({
                text = left,
                fontSize = 10,
                color = "on_surface_variant",
                maxLines = 1,
            })
        end
        -- A stale reading keeps its numbers and says so, rather than blanking
        -- the capsule over one failed poll.
        if type(report) == "table" and report.stale == true then
            children[#children + 1] = ui.label({ text = "!", fontSize = 10, color = "tertiary" })
        end
    elseif #children == 0 then
        children[1] = ui.glyph({
            name = "brain",
            size = 13,
            color = failure ~= "" and "error" or "on_surface_variant",
        })
    end

    barWidget.render(ui.row({ gap = 5, align = "center" }, children))
    barWidget.setTooltip(tooltipRows())
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

-- A click asks for a read now; the CLI's own floor keeps a rapid click from
-- reaching the endpoint every time.
function onClick()
    poll(true)
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
