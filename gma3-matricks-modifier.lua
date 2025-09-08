-- MAtricks Modifier Plugin
-- Purpose: On-screen editor for MAtricks on Selection or a named pool item.
-- Usage: See setup notes below; trigger via macro then call this plugin.

local pluginName, componentName, signalTable, myHandle = select(1, ...)

--[[
MAtricks Modifier Plugin - Setup

1. Create a new macro with these two lines:
For a specific MAtricks pool item:
SetUserVariable "MatricksModGroup" "The Name of My Matricks pool item"
Call Plugin "Matricks Modifier"

OR

For Selection mode (to modify MAtricks for the current selection):
SetUserVariable "MatricksModGroup" "Selection"
Call Plugin "Matricks Modifier"

2. Repeat for each Matricks pool item you want to modify, or create a separate macro for Selection mode.
]]

-- Global variables
local presets = {}
local storeMode = false
local storeButton = nil

-- Helper Functions

-- 2.3 palette and color helper
local colors = {
    red = "8.11",
    green = "9.4",
    black = "7.0",
    grey = "7.3",
    darkgrey = "7.4"
}
local function setBackcolor(obj, color)
    if not obj or not color then return end
    obj.Backcolor = color
    obj.BackColor = color
end

-- Shared property lists
local dimensionsList = { 'X', 'Y', 'Z' }
local scalarSuffixes = { 'block', 'shuffle', 'group', 'shift', 'wings', 'width' }
local rangeProps = { 'fade', 'delay', 'phase', 'speed' }
local NUM_PRESETS = 6 -- change here to control number of preset slots

-- Returns configured preset slot count (UserVar overrides NUM_PRESETS)
local function getPresetCount()
    local raw = GetVar(UserVars(), 'MatricksPresetSlots')
    local v = tonumber(raw and tostring(raw) or nil)
    if v then
        v = math.max(1, math.floor(v))
        return v
    end
    return NUM_PRESETS
end

-- Recall behavior: clear (reset) before applying preset
local function getClearOnRecall()
    local raw = GetVar(UserVars(), 'MatricksClearOnRecall')
    return (tonumber(raw and tostring(raw) or '1') or 1) ~= 0
end

-- Read/Write helpers (speed uses Value role, others Display)
local function readProp(matricks, prop)
    local role = prop:match('^speed') and Enums.Roles.Value or Enums.Roles.Display
    return matricks:Get(prop, role)
end

-- Speed reader: Value role first; fallback to parsing Display (e.g. "60.00 BPM" or "Stop")
local function readSpeedValue(matricks, prop)
    local v = matricks:Get(prop, Enums.Roles.Value)
    if type(v) == 'number' then return v end
    local s = tostring(matricks:Get(prop, Enums.Roles.Display) or '')
    local num = tonumber((s:match('^%s*([%-%d%.]+)')))
    if num then return num end
    if s:lower():find('stop', 1, true) then return 0 end
    return nil
end

-- setMatricksProperty: sets property; speed uses direct assignment, others use Set()
local function setMatricksProperty(matricks, prop, value)
    if not matricks or value == nil then return end
    if tostring(prop):match('^speed') then
        matricks[prop] = value
    else
        matricks:Set(prop, value)
    end
end

-- create_ui_object: appends a UI element and applies properties; returns element, row proxy, col proxy
local function create_ui_object(parent, class, properties)
    local element = parent:Append(class)
    for k, v in pairs(properties or {}) do
        element[k] = v
    end
    return element, element[1], element[2]
end

-- getMatricksTarget: resolves MAtricks object for Selection or a named pool item
local function getMatricksTarget(matricksItem, isSelectionMode)
    if isSelectionMode then return Selection() end
    local dp = DataPool()
    if not dp or not dp.Matricks then return nil end
    return dp.Matricks[tostring(matricksItem)]
end

-- resetMatricks: resets MAtricks for Selection or the specific pool item
local function resetMatricks(matricksItem, isSelectionMode)
    if isSelectionMode then
        Cmd('Reset Selection MAtricks')
    else
        Cmd(string.format('Reset MAtricks "%s"', matricksItem))
    end
end

-- round2: rounds a number to two decimals
local function round2(num)
    return math.floor((tonumber(num) or 0) * 100 + 0.5) / 100
end

-- normalizePhase: normalizes a phase value to [-720, 720) keeping decimals
local function normalizePhase(value)
    -- Accept numbers or strings like "32.00" or "-45.25"; fall back safely
    local numValue = tonumber(value)
    if not numValue then
        local s = tostring(value or "0")
        -- optional sign, digits, optional decimal part
        numValue = tonumber(s:match("%-?%d+%.?%d*")) or 0
    end
    -- Preserve exact endpoints
    if numValue == 720 or numValue == -720 then return numValue end
    -- True modular wrap preserving decimals
    local v = ((numValue % 1440) + 1440) % 1440
    if v >= 720 then v = v - 1440 end
    return round2(v)
end

-- getDisplayAndOverlay: current display and overlay (safe)
local function getDisplayAndOverlay()
    local display = GetFocusDisplay()
    if not display and GetDisplayByIndex then
        display = GetDisplayByIndex(1)
    end
    if not display or not display.ScreenOverlay then return nil, nil end
    return display, display.ScreenOverlay
end

-- Simple JSON encoder
local function simpleJsonEncode(t)
    if t == nil then return "null" end
    local function escapeStr(s)
        return string.gsub(s, "[%c\\\"]", {
            ["\t"] = "\\t",
            ["\n"] = "\\n",
            ["\r"] = "\\r",
            ["\""] = "\\\"",
            ["\\"] = "\\\\"
        })
    end
    local chunks = {}
    if type(t) == "table" then
        table.insert(chunks, "{")
        for k, v in pairs(t) do
            if type(k) ~= "number" then
                table.insert(chunks, string.format("\"%s\":", escapeStr(tostring(k))))
            end
            table.insert(chunks, simpleJsonEncode(v))
            table.insert(chunks, ",")
        end
        if #chunks > 1 then
            chunks[#chunks] = "}"
        else
            chunks[1] = "{}"
        end
    elseif type(t) == "string" then
        table.insert(chunks, string.format("\"%s\"", escapeStr(t)))
    elseif type(t) == "number" or type(t) == "boolean" then
        table.insert(chunks, tostring(t))
    else
        table.insert(chunks, "null")
    end
    return table.concat(chunks)
end

-- Simple JSON decoder
local function simpleJsonDecode(str)
    local function parseValue(str)
        str = str:match("^%s*(.-)%s*$")
        if str:sub(1, 1) == "{" and str:sub(-1) == "}" then
            local tbl = {}
            for k, v in str:gmatch('"([^"]+)":([^,}]+)') do
                k = k:match("^%s*(.-)%s*$")
                v = v:match("^%s*(.-)%s*$")
                if v == "null" or v == "None" then
                    tbl[k] = nil
                elseif v == "true" then
                    tbl[k] = true
                elseif v == "false" then
                    tbl[k] = false
                elseif v:match('^".*"$') then
                    tbl[k] = v:sub(2, -2)
                else
                    tbl[k] = tonumber(v) or parseValue(v)
                end
            end
            return tbl
        elseif str:sub(1, 1) == "[" and str:sub(-1) == "]" then
            local tbl = {}
            for v in str:sub(2, -2):gmatch("([^,]+)") do
                table.insert(tbl, parseValue(v))
            end
            return tbl
        elseif str == "null" or str == "None" then
            return nil
        elseif str == "true" then
            return true
        elseif str == "false" then
            return false
        elseif str:match('^".*"$') then
            return str:sub(2, -2)
        else
            return tonumber(str) or str
        end
    end
    return parseValue(str)
end

-- Preset Management Functions

-- Save preset to UserVar
local function savePresetToUserVar(presetNumber, presetData)
    local presetJson = simpleJsonEncode(presetData)
    SetVar(UserVars(), "MatricksPreset" .. presetNumber, presetJson)
end

-- Load preset from UserVar
local function loadPresetFromUserVar(presetNumber)
    if not presetNumber then
        return {}
    end
    local presetJson = GetVar(UserVars(), "MatricksPreset" .. tostring(presetNumber))
    if presetJson then
        local success, loadedPreset = pcall(simpleJsonDecode, presetJson)
        if success and type(loadedPreset) == "table" then
            return loadedPreset
        end
    end
    return {}
end

-- Load all presets from UserVars
local function loadPresetsFromUserVars()
    presets = {}
    for i = 1, getPresetCount() do
        presets[i] = loadPresetFromUserVar(i)
    end
end

-- Check if a preset has content
local function presetHasContent(presetNumber)
    -- Define default values for properties that don't use 'None' as their empty/default state in presets
    local nonStandardDefaults = {
        InvertStyle = "Pan",        -- Default is Pan
        PhaserTransform = "None"    -- Default is None
    }

    if not presetNumber then
        return false -- Grey for non-existent preset
    end
    local presetData = loadPresetFromUserVar(presetNumber)
    if not presetData or next(presetData) == nil then
        return false -- Grey for empty preset table (no keys)
    end

    local hasActiveOrNonDefaultContent = false
    for prop, value in pairs(presetData) do
        if nonStandardDefaults[prop] ~= nil then -- Check if it's InvertStyle or PhaserTransform
            if value ~= nonStandardDefaults[prop] then
                hasActiveOrNonDefaultContent = true -- Value is different from its known default
                break
            end
        else -- For all other properties (X, Y, Z, Block, etc.)
            if tostring(prop):match('^speed') then
                local n = tonumber(value)
                if n and n ~= 0 then
                    hasActiveOrNonDefaultContent = true
                    break
                end
            elseif value ~= 'None' and value ~= nil then
                hasActiveOrNonDefaultContent = true -- Value is not 'None' and not nil
                break
            end
        end
    end

    if hasActiveOrNonDefaultContent then
        return true -- Green: at least one value is actively set or non-default
    else
        return 'onlyNull' -- Grey: all values are effectively 'None'/nil or known defaults
    end
end

-- Capture and store initial MAtricks values
local function captureAndStoreInitialValues(matricksItem, isSelectionMode)
    local matricks = getMatricksTarget(matricksItem, isSelectionMode)
    if not matricks then return end

    local initialValues = {}
    for _, dim_name in ipairs(dimensionsList) do
        -- Dimension on/off value
        local dimVal = readProp(matricks, dim_name)
        initialValues[dim_name] = dimVal ~= nil and tonumber(dimVal) or 'None'

        -- Scalar props
        for _, suf in ipairs(scalarSuffixes) do
            local fullProp = dim_name .. suf
            local v = readProp(matricks, fullProp)
            initialValues[fullProp] = v ~= nil and tonumber(v) or 'None'
        end

        -- Ranged props (from/to)
        for _, base in ipairs(rangeProps) do
            local fromProp = base .. 'from' .. dim_name
            local toProp = base .. 'to' .. dim_name
            local fv = readProp(matricks, fromProp)
            local tv = readProp(matricks, toProp)
            initialValues[fromProp] = fv ~= nil and tonumber(fv) or 'None'
            initialValues[toProp] = tv ~= nil and tonumber(tv) or 'None'
        end
    end

    -- General properties
    initialValues["InvertStyle"] = matricks:Get("InvertStyle", Enums.Roles.Display)
    initialValues["PhaserTransform"] = matricks:Get("PhaserTransform", Enums.Roles.Display)

    SetVar(UserVars(), "MatricksInitialValues", simpleJsonEncode(initialValues))
end

-- Store a preset
local function storePreset(presetNumber, isSelectionMode)
    local matricksItem = GetVar(UserVars(), "MatricksModGroup")
    local matricks = getMatricksTarget(matricksItem, isSelectionMode)
    if not matricks then return end

    local presetData = {}
    for _, dim_name in ipairs(dimensionsList) do
        local dimVal = readProp(matricks, dim_name)
        if dimVal ~= nil then presetData[dim_name] = tonumber(dimVal) or dimVal end

        for _, suf in ipairs(scalarSuffixes) do
            local fullProp = dim_name .. suf
            local v = readProp(matricks, fullProp)
            if v ~= nil then presetData[fullProp] = tonumber(v) or v end
        end

        for _, base in ipairs(rangeProps) do
            local fromProp = base .. 'from' .. dim_name
            local toProp = base .. 'to' .. dim_name
            local fv, tv
            if base == 'speed' then
                fv = readSpeedValue(matricks, fromProp)
                tv = readSpeedValue(matricks, toProp)
            else
                fv = readProp(matricks, fromProp)
                tv = readProp(matricks, toProp)
            end
            if fv ~= nil then presetData[fromProp] = tonumber(fv) or fv end
            if tv ~= nil then presetData[toProp] = tonumber(tv) or tv end
        end
    end

    presetData["InvertStyle"] = matricks:Get("InvertStyle", Enums.Roles.Display)
    presetData["PhaserTransform"] = matricks:Get("PhaserTransform", Enums.Roles.Display)

    presets[presetNumber] = presetData
    savePresetToUserVar(presetNumber, presetData)
    -- If the stored preset is empty or only defaults, clear its custom name
    local status = presetHasContent(presetNumber)
    if status ~= true then
        SetVar(UserVars(), 'MatricksPresetName' .. presetNumber, '')
    end
end

-- Recall a preset
local function recallPreset(presetNumber, isSelectionMode)
    local matricksItem = GetVar(UserVars(), "MatricksModGroup")
    local matricks = getMatricksTarget(matricksItem, isSelectionMode)
    if not matricks then return end

    local presetData = presets[presetNumber]
    if presetData and next(presetData) ~= nil then
        if getClearOnRecall() then
            resetMatricks(matricksItem, isSelectionMode)
        end
        for prop, value in pairs(presetData) do
            if value ~= 'None' and value ~= nil then
                setMatricksProperty(matricks, prop, value)
            end
        end
    end
end

-- Debounce time for preset repaint (labels + colors)
local lastPresetPaintTime = 0
local function updatePresetButtons(overlay)
    if not overlay then return end
    local frame = overlay:FindRecursive("MAtricksModifierWindow", 'BaseInput')
    if not frame then return end
    if Time then
        local now = Time()
        if (now - (lastPresetPaintTime or 0)) < 0.05 then return end
        lastPresetPaintTime = now
    end

    -- Cache statuses and names once
    local statusCache, nameCache = {}, {}
    for j = 1, getPresetCount() do
        statusCache[j] = presetHasContent(j)
        local nm = GetVar(UserVars(), 'MatricksPresetName' .. j)
        nameCache[j] = (nm and nm ~= '') and tostring(nm) or nil
    end

    for i = 1, #dimensionsList do
        local grid = frame:FindRecursive('value' .. i, 'UILayoutGrid')
        if grid then
            local presetGrid = grid:FindRecursive("PresetGrid", 'UILayoutGrid')
            if presetGrid then
                for j = 1, getPresetCount() do
                    local button = presetGrid:FindRecursive("PresetButton" .. j, 'Button')
                    if button then
                        local contentStatus = statusCache[j]
                        setBackcolor(button, contentStatus == true and colors.green or colors.darkgrey)
                        local nm = nameCache[j]
                        button.Text = nm or tostring(j)
                    end
                end
            end
        end
    end
end

-- Main function to create the fader dialog
local function CreateFaderDialog()
    local matricksItem = GetVar(UserVars(), "MatricksModGroup")
    local isSelectionMode = matricksItem == "Selection"

    if not matricksItem then return end

    loadPresetsFromUserVars()
    captureAndStoreInitialValues(matricksItem, isSelectionMode)

    -- Seed randomness once per dialog
    if Time then
        math.randomseed(math.floor(Time() * 1000))
    end

    local target = getMatricksTarget(matricksItem, isSelectionMode)
    if not target then return end

    local display, screenOverlay = getDisplayAndOverlay()
    if not screenOverlay then return end

    local dialogWidth = math.floor(display.W * 0.7)
    local dialogHeight = math.floor(display.H * 0.9)

    -- Create a fresh window root
    local dialog, dialog_rows = create_ui_object(screenOverlay, 'BaseInput', {
        Name = "MAtricksModifierWindow",
        H = dialogHeight,
        W = dialogWidth,
        Columns = 1,
        Rows = 2,
        AutoClose = "No",
        CloseOnEscape = "Yes"
    })
    dialog_rows[1].SizePolicy, dialog_rows[1].Size = 'Fixed', 60
    dialog_rows[2].SizePolicy = 'Stretch'

    -- Add Resize Corner
    create_ui_object(dialog, 'ResizeCorner', {
        Anchors = "0,1",
        AlignmentH = "Right",
        AlignmentV = "Bottom"
    })

    -- Create title bar
    local title_bar, _, title_bar_columns = create_ui_object(dialog, 'TitleBar', {
        Columns = 2,
        Rows = 1,
        Texture = 'corner2',
        Anchors = '0,0,0,0'
    })
    title_bar_columns[2].SizePolicy, title_bar_columns[2].Size = 'Fixed', '50'

    create_ui_object(title_bar, 'TitleButton', {
        Texture = 'corner1',
        Text = 'MAtricks Modifier',
        Anchors = '0,0'
    })
    create_ui_object(title_bar, 'CloseButton', {
        Anchors = '1,0',
        Texture = 'corner2',
        Focus = 'Never',
        PluginComponent = myHandle,
        Clicked = 'OkButtonClicked'
    })

    -- Create dialog frame
    local dlg_frame, _, dlg_frame_columns = create_ui_object(dialog, 'DialogFrame', {
        Name = 'dlg_frame',
        H = '100%',
        W = '100%',
        Columns = 2,
        Rows = 1,
        Anchors = '0,1,0,1'
    })
    dlg_frame_columns[1].SizePolicy, dlg_frame_columns[1].Size = 'Stretch', 13
    dlg_frame_columns[2].SizePolicy, dlg_frame_columns[2].Size = 'Stretch', 87

    -- Create a vertical grid for the left column:
    local left_col_grid = create_ui_object(dlg_frame, 'UILayoutGrid', {
        Columns = 1,
        Rows = 8,
        Anchors = '0,0,0,0',
        Margin = '0,0,0,0'
    })
    left_col_grid[1][1].SizePolicy, left_col_grid[1][1].Size = 'Fixed', 300 -- UITab
    left_col_grid[1][2].SizePolicy, left_col_grid[1][2].Size = 'Fixed', 30 -- Spacer
    left_col_grid[1][3].SizePolicy, left_col_grid[1][3].Size = 'Stretch', 1 -- Invert Style
    left_col_grid[1][4].SizePolicy, left_col_grid[1][4].Size = 'Stretch', 1 -- Transform
    left_col_grid[1][5].SizePolicy, left_col_grid[1][5].Size = 'Fixed', 30  -- Spacer between Transform and Fade
    left_col_grid[1][6].SizePolicy, left_col_grid[1][6].Size = 'Stretch', 1  -- Fade toggle
    left_col_grid[1][7].SizePolicy, left_col_grid[1][7].Size = 'Stretch', 1  -- Fade time label
    left_col_grid[1][8].SizePolicy, left_col_grid[1][8].Size = 'Stretch', 1  -- Fade +/-

    -- Create UI tab in row 1
    local ui_tab = create_ui_object(left_col_grid, 'UITab', {
        H = '100%',
        W = '100%',
        Name = 'my_tabs',
        Type = 'Vertical',
        Texture = 'corner5',
        ItemSize = 100,
        TabChanged = 'tab_changed',
        PluginComponent = myHandle,
        Anchors = '0,0,0,0'
    })

    -- Create Invert Style SwipeButton in row 3
    create_ui_object(left_col_grid, 'SwipeButton', {
        Text = "Invert Style",
        Texture = 'corner15',
        Font = "Medium20",
        Target = target,
        PluginComponent = myHandle,
        Property = "InvertStyle",
        Margin = '0,0,0,0',
        Anchors = '0,2,0,2'
    })
    -- Create Transform SwipeButton in row 4
    create_ui_object(left_col_grid, 'SwipeButton', {
        Text = "Transform",
        Texture = 'corner15',
        Font = "Medium20",
        Target = target,
        PluginComponent = myHandle,
        Property = "PhaserTransform",
        Margin = '0,0,0,0',
        Anchors = '0,3,0,3'
    })

    -- Fade state (load from UserVars)
    local fadeEnabled = (tonumber(GetVar(UserVars(), 'MatricksFadeEnabled') or '1') or 1) ~= 0
    local fadeSeconds = tonumber(GetVar(UserVars(), 'MatricksFadeSeconds') or '3') or 3

    -- Preset naming mode (double-click Store)
    local namingMode = false
    local lastStoreClickTime = 0
    local doubleClickWindow = 0.4

    -- Store button state helper
    local function setStoreButtonState()
        if not storeButton then return end
        if namingMode then
            storeButton.Text = 'Name Preset'
            setBackcolor(storeButton, colors.green)
            return
        end
        if storeMode then
            storeButton.Text = 'Cancel Store'
            setBackcolor(storeButton, colors.green)
        else
            storeButton.Text = 'Store'
            setBackcolor(storeButton, colors.grey)
        end
    end

    -- Helpers to refresh UI controls (use direct refs when possible)
    local fadeToggleBtnRef, fadeTimeLabelRef
    local function refreshFadeControls()
        if fadeToggleBtnRef then
            fadeToggleBtnRef.Text = fadeEnabled and 'Phase\nFade: On' or 'Phase\nFade: Off'
            setBackcolor(fadeToggleBtnRef, fadeEnabled and colors.green or colors.grey)
        else
            local frame = screenOverlay and screenOverlay:FindRecursive('dlg_frame', 'DialogFrame')
            if frame then
                local btn = frame:FindRecursive('FadeToggleBtn', 'Button')
                if btn then
                    btn.Text = fadeEnabled and 'Phase\nFade: On' or 'Phase\nFade: Off'
                    setBackcolor(btn, fadeEnabled and colors.green or colors.grey)
                end
            end
        end
        if fadeTimeLabelRef then
            fadeTimeLabelRef.Text = string.format('Time: %.2fs', fadeSeconds)
        else
            local frame = screenOverlay and screenOverlay:FindRecursive('dlg_frame', 'DialogFrame')
            if frame then
                local lbl = frame:FindRecursive('FadeTimeLabel', 'UIObject')
                if lbl then lbl.Text = string.format('Time: %.2fs', fadeSeconds) end
            end
        end
    end

    -- Fade toggle button in row 5
    fadeToggleBtnRef = create_ui_object(left_col_grid, 'Button', {
        Name = 'FadeToggleBtn',
        Text = fadeEnabled and 'Fade\nPhase: On' or 'Fade\nPhase: Off',
        Texture = 'corner15',
        Font = 'Medium20',
        PluginComponent = myHandle,
        Clicked = 'ToggleFadeSwaps',
        Anchors = '0,5,0,5',
        Focus = 'Never'
    })
    setBackcolor(fadeToggleBtnRef, fadeEnabled and colors.green or colors.grey)

    -- Fade time display row 6
    fadeTimeLabelRef = create_ui_object(left_col_grid, 'UIObject', {
        Name = 'FadeTimeLabel',
        Text = string.format('Time: %.2fs', fadeSeconds),
        Texture = 'corner15',
        Font = 'Medium20',
        Anchors = '0,6,0,6'
    })
    -- Fade time control grid in row 7
    local fadeTimeGrid, ftRows, ftCols = create_ui_object(left_col_grid, 'UILayoutGrid', {
        Columns = 2,
        Rows = 1,
        Anchors = '0,7,0,7',
        Margin = '0,0,0,0'
    })
    ftCols[1].SizePolicy, ftCols[1].Size = 'Stretch', 1
    ftCols[2].SizePolicy, ftCols[2].Size = 'Stretch', 1
    create_ui_object(fadeTimeGrid, 'Button', {
        Text = '-0.5s',
        Texture = 'corner15',
        Font = 'Medium20',
        Focus = 'Never',
        PluginComponent = myHandle,
        Clicked = 'DecFadeTime',
        Anchors = '0,0'
    })
    create_ui_object(fadeTimeGrid, 'Button', {
        Text = '+0.5s',
        Texture = 'corner15',
        Font = 'Medium20',
        Focus = 'Never',
        PluginComponent = myHandle,
        Clicked = 'IncFadeTime',
        Anchors = '1,0'
    })
    -- Initialize fade controls text/colors
    refreshFadeControls()

    -- Create dialog container
    local dialog_container = create_ui_object(dlg_frame, 'DialogContainer', {
        Name = 'tab_contents',
        Anchors = '1,0,1,0'
    })

    -- Helper function to linearly interpolate
    local function lerp(a, b, t)
        return (a or 0) + ((b or 0) - (a or 0)) * t
    end

    -- Track active tweens per dim/property to avoid overlapping writes
    local activeTweens = {}
    local function tweenKey(dim, property)
        return tostring(dim or '') .. ':' .. tostring(property or '')
    end

    -- Helper function to swap 'from' and 'to' values, optionally with fadeSeconds
    local function swapValues(dim, property, fadeSeconds)
        local matricks = target
        local fromProp = property .. 'from' .. dim
        local toProp = property .. 'to' .. dim

        local fromValue, toValue
        if property == 'phase' then
            fromValue = normalizePhase(readProp(matricks, fromProp))
            toValue = normalizePhase(readProp(matricks, toProp))
        else
            fromValue = tonumber(readProp(matricks, fromProp)) or 0
            toValue = tonumber(readProp(matricks, toProp)) or 0
        end
        local targetFrom = toValue
        local targetTo = fromValue

        if property == 'phase' then
            targetFrom = normalizePhase(targetFrom)
            targetTo = normalizePhase(targetTo)
        end

        local duration = tonumber(fadeSeconds) or 0
        -- cancel any existing tween for the same key
        local key = tweenKey(dim, property)
        if activeTweens[key] then activeTweens[key].stop = true end

        if duration <= 0 or not Time then
            if property == 'speed' then
                -- Swap using raw numeric Values; do NOT coerce nil to 0 (Stop)
                local rawFrom = matricks:Get(fromProp, Enums.Roles.Value)
                local rawTo = matricks:Get(toProp, Enums.Roles.Value)
                if type(rawFrom) ~= 'number' or type(rawTo) ~= 'number' then return end
                setMatricksProperty(matricks, fromProp, rawTo)
                setMatricksProperty(matricks, toProp, rawFrom)
            else
                setMatricksProperty(matricks, fromProp, round2(targetFrom))
                setMatricksProperty(matricks, toProp, round2(targetTo))
            end
            return
        end

        local startTime = Time()
        local state = { stop = false }
        activeTweens[key] = state
        while true do
            if state.stop then break end
            local elapsed = Time() - startTime
            local t = elapsed / duration
            if t >= 1 then break end
            local curFrom = lerp(fromValue, targetFrom, t)
            local curTo = lerp(toValue, targetTo, t)
            if property == 'phase' then
                curFrom = normalizePhase(curFrom)
                curTo = normalizePhase(curTo)
            end
            setMatricksProperty(matricks, fromProp, round2(curFrom))
            setMatricksProperty(matricks, toProp, round2(curTo))
            if coroutine and coroutine.yield then coroutine.yield(0.02) end
        end
        if not activeTweens[key] or not activeTweens[key].stop then
            setMatricksProperty(matricks, fromProp, round2(targetFrom))
            setMatricksProperty(matricks, toProp, round2(targetTo))
        end
        activeTweens[key] = nil
    end

    for i, dim in ipairs(dimensionsList) do
        -- Create grid for each dimension
        local grid = create_ui_object(dialog_container, 'UILayoutGrid', {
            Margin = '10,10,10,10',
            Rows = 4,
            Columns = 1,
            Name = 'value' .. i,
            Anchors = '0,0,1,1',
            Visible = (i == 1)
        })

        grid[1][1].SizePolicy, grid[1][1].Size = 'Fixed', 60
        local headerObj = create_ui_object(grid, 'Button', {
            Text = isSelectionMode and string.format("Selection (%s)", dim)
                or string.format("MAtrick: %s (%s)", matricksItem, dim),
            Texture = 'corner15',
            Font = "Medium20",
            Margin = '15,5,15,0',
            Anchors = '0,0,0,0',
            Backcolor = isSelectionMode and colors.red or colors.green,
            Clicked = "HeaderClicked" .. dim,
            Focus = 'Never',
            PluginComponent = myHandle
        })
        setBackcolor(headerObj, headerObj.Backcolor)

        grid[1][2].SizePolicy, grid[1][2].Size = 'Stretch', 78
        local faderGrid = create_ui_object(grid, 'UILayoutGrid', {
            Columns = 3,
            Rows = 8,
            Margin = '10,5,10,5',
            Anchors = '0,1,0,1'
        })

        faderGrid[2][1].SizePolicy, faderGrid[2][1].Size = 'Stretch', 1
        faderGrid[2][2].SizePolicy, faderGrid[2][2].Size = 'Stretch', 1
        faderGrid[2][3].SizePolicy, faderGrid[2][3].Size = 'Fixed', 100

        -- Create faders for each property
        local faderProperties = {
            { Text = dim, Property = dim, Usedefaultvalue = 'Yes' },
            { Text = dim .. ' Block', Property = dim .. 'block', Usedefaultvalue = 'Yes' },
            { Text = dim .. ' Shuffle', Property = dim .. 'shuffle', Usedefaultvalue = 'Yes' },
            { Text = dim .. ' Group', Property = dim .. 'group', Usedefaultvalue = 'Yes' },
            { Text = dim .. ' Shift', Property = dim .. 'shift', Usedefaultvalue = 'Yes' },
            { Text = dim .. ' Wings', Property = dim .. 'wings', Usedefaultvalue = 'Yes' },
            { Text = dim .. ' Width', Property = dim .. 'width', Usedefaultvalue = 'Yes' },
            { Text = dim .. ' Fade From', Property = 'fadefrom' .. dim },
            { Text = dim .. ' Fade To', Property = 'fadeto' .. dim },
            { Text = dim .. ' Delay From', Property = 'delayfrom' .. dim },
            { Text = dim .. ' Delay To', Property = 'delayto' .. dim },
            { Text = dim .. ' Speed From', Property = 'speedfrom' .. dim },
            { Text = dim .. ' Speed To', Property = 'speedto' .. dim },
            { Text = dim .. ' Phase From', Property = 'phasefrom' .. dim, Forcefastfade = 'Yes' },
            { Text = dim .. ' Phase To', Property = 'phaseto' .. dim, Forcefastfade = 'Yes' }
        }

        local currentRow = 0
        -- The 1st property (X) spans two columns
        local xPropInfo = faderProperties[1]
        create_ui_object(faderGrid, 'ValueFadeControl', {
            Text = xPropInfo.Text,
            Texture = 'corner15',
            Property = xPropInfo.Property,
            Usedefaultvalue = xPropInfo.Usedefaultvalue,
            Forcefastfade = xPropInfo.Forcefastfade,
            Target = target,
            Margin = '5,5,5,5',
            Anchors = string.format("0,%d,1,%d", currentRow, currentRow)
        })
        currentRow = currentRow + 1

        -- Next 6 properties (Block to Width - indices 2 to 7) are paired in two columns
        for j = 2, 7, 2 do -- Iterate j = 2, 4, 6
            local prop1Info = faderProperties[j]
            local prop2Info = faderProperties[j + 1]

            create_ui_object(faderGrid, 'ValueFadeControl', {
                Text = prop1Info.Text,
                Texture = 'corner15',
                Property = prop1Info.Property,
                Usedefaultvalue = prop1Info.Usedefaultvalue,
                Forcefastfade = prop1Info.Forcefastfade,
                Target = target,
                Margin = '5,5,5,5',
                Anchors = string.format("0,%d", currentRow)
            })
            create_ui_object(faderGrid, 'ValueFadeControl', {
                Text = prop2Info.Text,
                Texture = 'corner15',
                Property = prop2Info.Property,
                Usedefaultvalue = prop2Info.Usedefaultvalue,
                Forcefastfade = prop2Info.Forcefastfade,
                Target = target,
                Margin = '5,5,5,5',
                Anchors = string.format("1,%d", currentRow)
            })
            currentRow = currentRow + 1
        end

        -- Next 8 properties (Fade, Delay, Speed, Phase From/To - indices 8 to 15) are paired
        for j = 8, #faderProperties, 2 do -- Iterate j = 8, 10, 12, 14
            local fromPropInfo = faderProperties[j]
            local toPropInfo = faderProperties[j + 1]

            create_ui_object(faderGrid, 'ValueFadeControl', {
                Text = fromPropInfo.Text,
                Texture = 'corner15',
                Property = fromPropInfo.Property,
                Usedefaultvalue = fromPropInfo.Usedefaultvalue,
                Forcefastfade = fromPropInfo.Forcefastfade,
                Target = target,
                Margin = '5,5,5,5',
                Anchors = string.format("0,%d", currentRow)
            })
            create_ui_object(faderGrid, 'ValueFadeControl', {
                Text = toPropInfo.Text,
                Texture = 'corner15',
                Property = toPropInfo.Property,
                Usedefaultvalue = toPropInfo.Usedefaultvalue,
                Forcefastfade = toPropInfo.Forcefastfade,
                Target = target,
                Margin = '5,5,5,5',
                Anchors = string.format("1,%d", currentRow)
            })
            currentRow = currentRow + 1
        end

        -- Add Shuffle and Swap buttons to the third column
        local buttons = {
            { Text = "Random\nShuffle", Clicked = "onRandomShuffleClicked" .. dim, Row = 1 },
            { Text = "No\nShuffle", Clicked = "onNoShuffleClicked" .. dim, Row = 2 },
            { Text = "Swap", Clicked = "SwapFade" .. dim, Row = 4 },
            { Text = "Swap", Clicked = "SwapDelay" .. dim, Row = 5 },
            { Text = "Swap", Clicked = "SwapSpeed" .. dim, Row = 6 },
            { Text = "Swap", Clicked = "SwapPhase" .. dim, Row = 7 }
        }
        for _, buttonInfo in ipairs(buttons) do
            create_ui_object(faderGrid, 'Button', {
                Text = buttonInfo.Text,
                Font = "Medium20",
                Texture = 'corner15',
                PluginComponent = myHandle,
                Clicked = buttonInfo.Clicked,
                Margin = '5,5,5,5',
                Anchors = string.format("2,%d", buttonInfo.Row),
                Focus = 'Never'
            })
        end

        -- Create bottom button grid
        grid[1][3].SizePolicy, grid[1][3].Size = 'Stretch', 7
        local bottomButtonGrid = create_ui_object(grid, 'UILayoutGrid', {
            Columns = 4,
            Rows = 1,
            Margin = '10,0,10,0',
            Anchors = '0,2,0,2'
        })

        local buttonProperties = {
            { Text = "Ok", Clicked = "OkButtonClicked", Anchors = '0,0', Backcolor = colors.green },
            { Text = "Reset", Clicked = "ResetButtonClicked", Anchors = '1,0' },
            { Text = "Restore", Clicked = "RestoreButtonClicked", Anchors = '2,0' },
            { Text = getClearOnRecall() and "Clear On" or "Clear Off", Clicked = "ToggleClearOnRecall", Anchors = '3,0' }
        }

        for _, prop in ipairs(buttonProperties) do
            local btn = create_ui_object(bottomButtonGrid, 'Button', {
                Text = prop.Text,
                Font = "Medium20",
                Texture = 'corner15',
                PluginComponent = myHandle,
                Clicked = prop.Clicked,
                Margin = '5,0,5,0',
                Anchors = prop.Anchors,
                Focus = 'Never'
            })
            if prop.Backcolor then setBackcolor(btn, prop.Backcolor) end
        end

        -- Create preset button grid (2 rows, columns based on NUM_PRESETS)
        grid[1][4].SizePolicy, grid[1][4].Size = 'Stretch', 15
        local presetCols = math.max(1, math.ceil(getPresetCount() / 2))
        local presetGrid = create_ui_object(grid, 'UILayoutGrid', {
            Columns = presetCols + 1, -- extra column for Store
            Rows = 2,
            Margin = '10,5,10,0',
            Anchors = '0,3,0,3',
            Name = "PresetGrid"
        })

        for j = 1, getPresetCount() do
            local initialName = GetVar(UserVars(), 'MatricksPresetName' .. j)
            local btnText = (initialName and initialName ~= '') and tostring(initialName) or tostring(j)
            create_ui_object(presetGrid, 'Button', {
                Text = btnText,
                Font = "Medium20",
                Texture = 'corner15',
                PluginComponent = myHandle,
                Clicked = "PresetClicked" .. j,
                Margin = '5,5,5,5',
                Anchors = string.format("%d,%d", (j - 1) % presetCols, math.floor((j - 1) / presetCols)),
                Focus = 'Never',
                Name = "PresetButton" .. j
            })
        end

        -- Add Store as the last column spanning both rows
        storeButton = create_ui_object(presetGrid, 'Button', {
            Text = "Store",
            Font = "Medium20",
            Texture = 'corner15',
            PluginComponent = myHandle,
            Clicked = "StoreButtonClicked",
            Margin = '5,5,5,5',
            Anchors = string.format("%d,0,%d,1", presetCols, presetCols)
        })
    end

    -- Initialize UI tab
    ui_tab:WaitInit()
    for i, dim in ipairs(dimensionsList) do
        ui_tab:AddListStringItem(dim, 'value' .. i)
    end
    ui_tab[1]:WaitChildren(#dimensionsList)
    for _, button in ipairs(ui_tab[1]:UIChildren()) do
        button.Focus = 'Never'
    end
    -- Paint preset buttons once after build for consistent colors/labels
    updatePresetButtons(screenOverlay)

    -- Tab changed callback
    function signalTable.tab_changed(caller)
        local overlay = caller and caller:GetOverlay()
        local frame = overlay and overlay:FindRecursive('dlg_frame', 'DialogFrame')
        if not frame then return end
        for i = 1, caller:GetListItemsCount() do
            local name = caller:GetListItemValueStr(i)
            local obj = frame:FindRecursive(name, 'UILayoutGrid')
            if obj then obj.Visible = (name == caller.SelectedItemValueStr) end
        end
        updatePresetButtons(overlay)
    end

    -- Button callbacks for each dimension
    for _, dim in ipairs(dimensionsList) do
        -- Random Shuffle button callback
        signalTable["onRandomShuffleClicked" .. dim] = function(caller)
            local randomValue = math.floor(math.random() * 10000)
            SetVar(UserVars(), 'RND', tostring(randomValue))
            local matricks = target
            matricks[dim .. 'shuffle'] = GetVar(UserVars(), 'RND')
        end

        -- No Shuffle button callback
        signalTable["onNoShuffleClicked" .. dim] = function(caller)
            local matricks = target
            matricks[dim .. 'shuffle'] = 0
        end

        -- Swap buttons callbacks for Fade, Delay, and Speed
        for _, prop in ipairs({ 'Fade', 'Delay', 'Speed' }) do
            signalTable["Swap" .. prop .. dim] = function(caller)
                local dur
                if prop == 'Speed' then
                    dur = 0
                else
                    -- read toggle/time
                    dur = 0
                end
                swapValues(dim, string.lower(prop), dur)
            end
        end

        -- Swap Phase button callback
        signalTable["SwapPhase" .. dim] = function(caller)
            local dur = (fadeEnabled and (fadeSeconds or 0)) or 0
            swapValues(dim, 'phase', dur)
        end
        -- Header clicked → prompt for preset slot count
        signalTable["HeaderClicked" .. dim] = function(caller)
            local before = getPresetCount()
            local current = tostring(before)
            local val = TextInput and TextInput('Preset slots', current) or current
            if not val then return end
            local num = tonumber(val)
            if not num then return end
            num = math.max(1, math.floor(num))
            if num == before then return end
            SetVar(UserVars(), 'MatricksPresetSlots', tostring(num))
            -- Rebuild UI to apply new layout
            if screenOverlay then screenOverlay:ClearUIChildren() end
            CreateFaderDialog()
        end
    end

    -- Ok button callback - close dialog and clear overlay
    signalTable.OkButtonClicked = function(caller)
        if screenOverlay then screenOverlay:ClearUIChildren() end
    end

    -- Fade control callbacks
    signalTable.ToggleFadeSwaps = function(caller)
        fadeEnabled = not fadeEnabled
        SetVar(UserVars(), 'MatricksFadeEnabled', fadeEnabled and '1' or '0')
        refreshFadeControls()
    end

    signalTable.DecFadeTime = function(caller)
        fadeSeconds = math.max(0.0, (fadeSeconds or 0) - 0.5)
        SetVar(UserVars(), 'MatricksFadeSeconds', tostring(fadeSeconds))
        refreshFadeControls()
    end

    signalTable.IncFadeTime = function(caller)
        fadeSeconds = math.min(30.0, (fadeSeconds or 0) + 0.5)
        SetVar(UserVars(), 'MatricksFadeSeconds', tostring(fadeSeconds))
        refreshFadeControls()
    end

    -- Toggle clear-on-recall
    signalTable.ToggleClearOnRecall = function(caller)
        local newState = not getClearOnRecall()
        SetVar(UserVars(), 'MatricksClearOnRecall', newState and '1' or '0')
        caller.Text = newState and 'Clear On' or 'Clear Off'
    end

    -- Reset button callback
    signalTable.ResetButtonClicked = function(caller)
        local undo = CreateUndo and CreateUndo('MAtricks Modifier') or nil
        resetMatricks(matricksItem, isSelectionMode)
        -- Ensure InvertStyle returns to Pan after reset
        local matricks = target
        if matricks then setMatricksProperty(matricks, 'InvertStyle', 'Pan') end
        if undo and CloseUndo then CloseUndo(undo) end
        updatePresetButtons(screenOverlay)
    end

    -- Restore button callback
    signalTable.RestoreButtonClicked = function(caller)
        local matricks = target
        if not matricks then return end

        -- First, reset the MAtricks
        local undo = CreateUndo and CreateUndo('MAtricks Modifier') or nil
        resetMatricks(matricksItem, isSelectionMode)

        -- Then, apply the stored initial values
        local initialValues = simpleJsonDecode(GetVar(UserVars(), "MatricksInitialValues"))
        if type(initialValues) == "table" then
            for prop, value in pairs(initialValues) do
                if value ~= 'None' and value ~= nil then
                    setMatricksProperty(matricks, prop, value)
                end
            end
        end
        if undo and CloseUndo then CloseUndo(undo) end
        updatePresetButtons(screenOverlay)
    end

    -- Store button callback with double-click to enter naming mode
    signalTable.StoreButtonClicked = function(caller)
        local now = Time and Time() or os.clock()
        -- If already in naming mode and this is a single click, cancel naming mode
        if namingMode and ((now - (lastStoreClickTime or 0)) > (doubleClickWindow or 0.4)) then
            namingMode = false
            storeMode = false
            caller.Text = 'Store'
            setBackcolor(caller, colors.grey)
            storeButton = caller
            lastStoreClickTime = now
            return
        end
        -- Double-click toggles naming mode
        if (now - (lastStoreClickTime or 0)) <= (doubleClickWindow or 0.4) then
            namingMode = not namingMode
            lastStoreClickTime = 0
            if namingMode then
                storeMode = false
                caller.Text = 'Name Preset'
                setBackcolor(caller, colors.green)
            else
                caller.Text = 'Store'
                setBackcolor(caller, colors.grey)
            end
            storeButton = caller
            return
        end
        -- Single click toggles store mode (normal behavior)
        lastStoreClickTime = now
        storeMode = not storeMode
        setBackcolor(caller, storeMode and colors.green or colors.grey)
        caller.Text = storeMode and "Cancel Store" or (namingMode and 'Name Preset' or 'Store')
        storeButton = caller  -- Save reference to the store button
    end

    -- Preset button callbacks (store/recall or name when namingMode)
    for j = 1, getPresetCount() do
        signalTable["PresetClicked" .. j] = function(caller)
            if namingMode then
                local current = GetVar(UserVars(), 'MatricksPresetName' .. j) or ''
                local newName = TextInput and TextInput('Preset Name', current) or current
                if newName ~= nil then
                    newName = tostring(newName)
                    -- empty clears name
                    SetVar(UserVars(), 'MatricksPresetName' .. j, newName)
                    updatePresetButtons(screenOverlay)
                    -- Exit naming mode after successful set
                    namingMode = false
                    storeMode = false
                    if storeButton then
                        storeButton.Text = 'Store'
                        setBackcolor(storeButton, colors.grey)
                    end
                end
            elseif storeMode then
                storePreset(j, isSelectionMode)
                storeMode = false
                if storeButton then
                    setBackcolor(storeButton, colors.grey)  -- Reset color for normal mode
                    storeButton.Text = namingMode and 'Name Preset' or 'Store'
                end
                -- Update preset colors and labels (in case name cleared)
                updatePresetButtons(screenOverlay)
            else
                recallPreset(j, isSelectionMode)
            end
        end
    end
end

return CreateFaderDialog