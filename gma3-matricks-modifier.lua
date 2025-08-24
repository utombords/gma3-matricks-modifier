            -- MAtricks Modifier Plugin
            -- Purpose: On-screen editor for MAtricks on Selection or a named pool item.
            -- Usage: See setup notes below; trigger via macro then call this plugin.

            local pluginName, componentName, signalTable, myHandle = select(1,...)

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

            -- create_ui_object: appends a UI element and applies properties; returns element, row proxy, col proxy
            local function create_ui_object(parent, class, properties)
                local element = parent:Append(class)
                for k, v in pairs(properties or {}) do element[k] = v end
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
            local function resetMatricks(matricksItem, isSelectionMode, undoHandle)
                if isSelectionMode then
                    Cmd('Reset Selection MAtricks')
                else
                    Cmd(string.format('Reset MAtricks "%s"', matricksItem))
                end
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

            -- round2: rounds a number to two decimals
            local function round2(num)
                return math.floor((tonumber(num) or 0) * 100 + 0.5) / 100
            end

            -- normalizePhase: normalizes a phase value to [-720, 720)
            local function normalizePhase(value)
                local numValue = tonumber(tostring(value or 0):match("-%d+") or "0")
                return math.floor(((numValue + 720) % 1440) - 720 + 0.5)
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
                local function escapeStr(s) return string.gsub(s, "[%c\\\"]", {["\t"]="\\t",["\n"]="\\n",["\r"]="\\r",["\""]="\\\"",["\\"]="\\\\"}) end
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
                    if str:sub(1,1) == "{" and str:sub(-1) == "}" then
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
                    elseif str:sub(1,1) == "[" and str:sub(-1) == "]" then
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
                for i = 1, 6 do
                    presets[i] = loadPresetFromUserVar(i)
                end
            end

            -- Check if a preset has content
            local function presetHasContent(presetNumber)
                -- Define default values for properties that don't use 'None' as their empty/default state in presets
                local nonStandardDefaults = {
                    InvertStyle = "Pan",        -- Default is Pan
                    PhaserTransform = "None"  -- Default is None
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
                        if value ~= 'None' and value ~= nil then
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
                for _, dim_name in ipairs({'X', 'Y', 'Z'}) do
                    -- Capture the dimension-specific property (X, Y, or Z itself)
                    local dim_specific_value = matricks:Get(dim_name, Enums.Roles.Display)
                    initialValues[dim_name] = dim_specific_value ~= nil and tonumber(dim_specific_value) or 'None'

                    for _, prop_suffix in ipairs({'block', 'shuffle', 'group', 'shift', 'wings', 'width'}) do
                        local fullProp = dim_name .. prop_suffix
                        local value = matricks:Get(fullProp, Enums.Roles.Display)
                        initialValues[fullProp] = value ~= nil and tonumber(value) or 'None'
                    end
                    for _, prop_base in ipairs({'fade', 'delay', 'phase', 'speed'}) do
                        local fromProp = prop_base .. 'from' .. dim_name
                        local toProp = prop_base .. 'to' .. dim_name
                        local fromValue, toValue
                        if prop_base == 'speed' then
                            fromValue = matricks:Get(fromProp, Enums.Roles.Value)
                            toValue = matricks:Get(toProp, Enums.Roles.Value)
                        else
                            fromValue = matricks:Get(fromProp, Enums.Roles.Display)
                            toValue = matricks:Get(toProp, Enums.Roles.Display)
                        end
                        initialValues[fromProp] = fromValue ~= nil and tonumber(fromValue) or 'None'
                        initialValues[toProp] = toValue ~= nil and tonumber(toValue) or 'None'
                    end
                end

                -- Capture general properties
                initialValues["InvertStyle"] = matricks:Get("InvertStyle", Enums.Roles.Display)
                initialValues["PhaserTransform"] = matricks:Get("PhaserTransform", Enums.Roles.Display)

                local jsonString = simpleJsonEncode(initialValues)
                SetVar(UserVars(), "MatricksInitialValues", jsonString)
            end

            -- Store a preset
            local function storePreset(presetNumber, isSelectionMode)
                local matricksItem = GetVar(UserVars(), "MatricksModGroup")
                local matricks = getMatricksTarget(matricksItem, isSelectionMode)
                if not matricks then return end
                
                local presetData = {}
                for _, dim_name in ipairs({'X', 'Y', 'Z'}) do
                    -- Store the dimension-specific property (X, Y, or Z itself)
                    local dim_specific_value = matricks:Get(dim_name, Enums.Roles.Display)
                    if dim_specific_value ~= nil then
                        presetData[dim_name] = tonumber(dim_specific_value) or dim_specific_value
                    end

                    for _, prop_suffix in ipairs({'block', 'shuffle', 'group', 'shift', 'wings', 'width'}) do
                        local fullProp = dim_name .. prop_suffix
                        local value = matricks:Get(fullProp, Enums.Roles.Display)
                        if value ~= nil then
                            presetData[fullProp] = tonumber(value) or value
                        end
                    end
                    for _, prop_base in ipairs({'fade', 'delay', 'phase', 'speed'}) do
                        local fromProp = prop_base .. 'from' .. dim_name
                        local toProp = prop_base .. 'to' .. dim_name
                        local fromValue, toValue
                        if prop_base == 'speed' then
                            fromValue = matricks:Get(fromProp, Enums.Roles.Value)
                            toValue = matricks:Get(toProp, Enums.Roles.Value)
                        else
                            fromValue = matricks:Get(fromProp, Enums.Roles.Display)
                            toValue = matricks:Get(toProp, Enums.Roles.Display)
                        end
                        if fromValue ~= nil then
                            presetData[fromProp] = tonumber(fromValue) or fromValue
                        end
                        if toValue ~= nil then
                            presetData[toProp] = tonumber(toValue) or toValue
                        end
                    end
                end

                -- Store general properties
                presetData["InvertStyle"] = matricks:Get("InvertStyle", Enums.Roles.Display)
                presetData["PhaserTransform"] = matricks:Get("PhaserTransform", Enums.Roles.Display)

                presets[presetNumber] = presetData
                savePresetToUserVar(presetNumber, presetData)
            end

            -- Recall a preset
            local function recallPreset(presetNumber, isSelectionMode)
                local matricksItem = GetVar(UserVars(), "MatricksModGroup")
                local matricks = getMatricksTarget(matricksItem, isSelectionMode)
                if not matricks then return end
                
                local presetData = presets[presetNumber]
                if presetData and next(presetData) ~= nil then
                    resetMatricks(matricksItem, isSelectionMode)
                    
                    for prop, value in pairs(presetData) do
                        if value ~= 'None' and value ~= nil then setMatricksProperty(matricks, prop, value) end
                    end
                end
            end

            -- Update preset button colors
            local function updatePresetButtonColors(overlay)
                if not overlay then return end
                local frame = overlay:FindRecursive("MAtricksModifierWindow", 'BaseInput')
                if frame then
                    for _, dim in ipairs({'X', 'Y', 'Z'}) do
                        local grid = frame:FindRecursive('value' .. (dim == 'X' and '1' or dim == 'Y' and '2' or '3'), 'UILayoutGrid')
                        if grid then
                            local presetGrid = grid:FindRecursive("PresetGrid", 'UILayoutGrid')
                            if presetGrid then
                                for j = 1, 6 do
                                    local button = presetGrid:FindRecursive("PresetButton" .. j, 'Button')
                                    if button then
                                        local contentStatus = presetHasContent(j)
                                        if contentStatus == true then
                                            button.Backcolor = "15.9"  -- Color for presets containing non-null information
                                        elseif contentStatus == 'onlyNull' then
                                            button.Backcolor = "15.1"  -- Color for presets containing only null values
                                        else
                                            button.Backcolor = "15.1"  -- Color for empty presets
                                        end
                                    end
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

                local dialogWidth, dialogHeight = math.floor(display.W * 0.7), math.floor(display.H * 0.9)

                -- Create a fresh window root
                local dialog, dialog_rows = create_ui_object(screenOverlay, 'BaseInput', {
                    Name = "MAtricksModifierWindow", H = dialogHeight, W = dialogWidth,
                    Columns = 1, Rows = 2, AutoClose = "No", CloseOnEscape = "Yes"
                })
                dialog_rows[1].SizePolicy, dialog_rows[1].Size = 'Fixed', 60
                dialog_rows[2].SizePolicy = 'Stretch'

                -- Add Resize Corner
                local resizer = create_ui_object(dialog, 'ResizeCorner', {
                    Anchors = "0,1",
                    AlignmentH = "Right",
                    AlignmentV = "Bottom"
                })
                -- Create title bar
                local title_bar, _, title_bar_columns = create_ui_object(dialog, 'TitleBar', {
                    Columns = 2, Rows = 1, Texture = 'corner2', Anchors = '0,0,0,0'
                })
                title_bar_columns[2].SizePolicy, title_bar_columns[2].Size = 'Fixed', '50'

                create_ui_object(title_bar, 'TitleButton', {Texture = 'corner1', Text = 'MAtricks Modifier', Anchors = '0,0'})
                create_ui_object(title_bar, 'CloseButton', {Anchors = '1,0', Texture = 'corner2', Focus = 'Never', PluginComponent = myHandle, Clicked = 'OkButtonClicked'})

                -- Create dialog frame
                local dlg_frame, dlg_frame_rows, dlg_frame_columns = create_ui_object(dialog, 'DialogFrame', {
                    Name = 'dlg_frame', H = '100%', W = '100%', Columns = 2, Rows = 1, Anchors = '0,1,0,1'
                })
                dlg_frame_columns[1].SizePolicy, dlg_frame_columns[1].Size = 'Fixed', 100
                dlg_frame_columns[2].SizePolicy = 'Stretch'

                -- Create a vertical grid for the left column: row 1 = UITab, row 2 = Spacer, row 3 = Invert Style, row 4 = Transform
                local left_col_grid = create_ui_object(dlg_frame, 'UILayoutGrid', {
                    Columns = 1, Rows = 4, Anchors = '0,0,0,1', Margin = '0,0,0,0'
                })
                left_col_grid[1][1].SizePolicy, left_col_grid[1][1].Size = 'Fixed', 300 -- UITab
                left_col_grid[1][2].SizePolicy, left_col_grid[1][2].Size = 'Fixed', 100 -- Spacer
                left_col_grid[1][3].SizePolicy, left_col_grid[1][3].Size = 'Fixed', 100 -- Invert Style
                left_col_grid[1][4].SizePolicy, left_col_grid[1][4].Size = 'Fixed', 100 -- Transform

                -- Create UI tab in row 1
                local ui_tab = create_ui_object(left_col_grid, 'UITab', {
                    H = '100%', W = 100, Name = 'my_tabs', Type = 'Vertical', Texture = 'corner5',
                    ItemSize = 100, TabChanged = 'tab_changed', PluginComponent = myHandle, Anchors = '0,0,0,0' -- Anchored to its grid cell (row index 0)
                })

                -- Create Invert Style SwipeButton in row 3
                create_ui_object(left_col_grid, 'SwipeButton', {
                    Text = "Invert Style", Texture = 'corner15', Font = "Medium20",
                    Target = target,
                    PluginComponent = myHandle,
                    Property = "InvertStyle",
                    Margin = '0,0,0,0', Anchors = '0,2,0,2'
                })
                -- Create Transform SwipeButton in row 4
                create_ui_object(left_col_grid, 'SwipeButton', {
                    Text = "Transform", Texture = 'corner15', Font = "Medium20",
                    Target = target,
                    PluginComponent = myHandle,
                    Property = "PhaserTransform",
                    Margin = '0,0,0,0', Anchors = '0,3,0,3'
                })

                -- Create dialog container
                local dialog_container = create_ui_object(dlg_frame, 'DialogContainer', {Name = 'tab_contents', Anchors = '1,0,1,0'})

                -- Helper function to swap 'from' and 'to' values
                local function swapValues(dim, property)
                    local matricks = target
                    local fromProp = property..'from'..dim
                    local toProp = property..'to'..dim
                    
                    local fromValue, toValue
                    if property == 'speed' then
                        fromValue = matricks:Get(fromProp, Enums.Roles.Value)
                        toValue = matricks:Get(toProp, Enums.Roles.Value)
                    else
                        fromValue = matricks:Get(fromProp, Enums.Roles.Display)
                        toValue = matricks:Get(toProp, Enums.Roles.Display)
                    end
                    
                    if property == 'speed' then
                        matricks[fromProp] = toValue
                        matricks[toProp] = fromValue
                    else
                        matricks:Set(fromProp, round2(toValue))
                        matricks:Set(toProp, round2(fromValue))
                    end
                end

                local dimensions = {'X', 'Y', 'Z'}
                for i, dim in ipairs(dimensions) do
                    -- Create grid for each dimension
                    local grid = create_ui_object(dialog_container, 'UILayoutGrid', {
                        Margin = '10,10,10,10', Rows = 4, Columns = 1, Name = 'value'..i,
                        Anchors = '0,0,1,1', Visible = (i == 1)
                    })

                    grid[1][1].SizePolicy, grid[1][1].Size = 'Fixed', 60
                    create_ui_object(grid, 'UIObject', {
                        Text = isSelectionMode and string.format("Selection (%s)", dim) or string.format("MAtrick: %s (%s)", matricksItem, dim),
                        Texture = 'corner15', Font = "Medium20", Margin = '15,5,15,0',
                        Anchors = '0,0,0,0', Backcolor = isSelectionMode and "15.9" or "15.10",
                    })

                    grid[1][2].SizePolicy = 'Stretch'
                    local faderGrid = create_ui_object(grid, 'UILayoutGrid', {
                        Columns = 3, Rows = 8, Margin = '10,5,10,5', Anchors = '0,1,0,1'
                    })
                    
                    faderGrid[2][1].SizePolicy, faderGrid[2][1].Size = 'Stretch', 1
                    faderGrid[2][2].SizePolicy, faderGrid[2][2].Size = 'Stretch', 1
                    faderGrid[2][3].SizePolicy, faderGrid[2][3].Size = 'Fixed', 100

                    -- Create faders for each property
                    local faderProperties = {
                        {Text = dim, Property = dim, Usedefaultvalue = 'Yes'},
                        {Text = dim .. ' Block', Property = dim .. 'block', Usedefaultvalue = 'Yes'},
                        {Text = dim .. ' Shuffle', Property = dim .. 'shuffle', Usedefaultvalue = 'Yes'},
                        {Text = dim .. ' Group', Property = dim .. 'group', Usedefaultvalue = 'Yes'},
                        {Text = dim .. ' Shift', Property = dim .. 'shift', Usedefaultvalue = 'Yes'},
                        {Text = dim .. ' Wings', Property = dim .. 'wings', Usedefaultvalue = 'Yes'},
                        {Text = dim .. ' Width', Property = dim .. 'width', Usedefaultvalue = 'Yes'},
                        {Text = dim .. ' Fade From', Property = 'fadefrom'..dim},
                        {Text = dim .. ' Fade To', Property = 'fadeto'..dim},
                        {Text = dim .. ' Delay From', Property = 'delayfrom'..dim},
                        {Text = dim .. ' Delay To', Property = 'delayto'..dim},
                        {Text = dim .. ' Speed From', Property = 'speedfrom'..dim},
                        {Text = dim .. ' Speed To', Property = 'speedto'..dim},
                        {Text = dim .. ' Phase From', Property = 'phasefrom'..dim, Forcefastfade = 'Yes'},
                        {Text = dim .. ' Phase To', Property = 'phaseto'..dim, Forcefastfade = 'Yes'}
                    }

                    local currentRow = 0
                    -- The 1st property (X) spans two columns
                    local xPropInfo = faderProperties[1]
                    create_ui_object(faderGrid, 'ValueFadeControl', {
                        Text = xPropInfo.Text, Texture = 'corner15', Property = xPropInfo.Property,
                        Usedefaultvalue = xPropInfo.Usedefaultvalue, Forcefastfade = xPropInfo.Forcefastfade,
                        Target = target,
                        Margin = '5,5,5,5', Anchors = string.format("0,%d,1,%d", currentRow, currentRow)
                    })
                    currentRow = currentRow + 1

                    -- Next 6 properties (Block to Width - indices 2 to 7) are paired in two columns
                    for j = 2, 7, 2 do -- Iterate j = 2, 4, 6
                        local prop1Info = faderProperties[j]
                        local prop2Info = faderProperties[j+1]

                        create_ui_object(faderGrid, 'ValueFadeControl', {
                            Text = prop1Info.Text, Texture = 'corner15', Property = prop1Info.Property,
                            Usedefaultvalue = prop1Info.Usedefaultvalue, Forcefastfade = prop1Info.Forcefastfade,
                            Target = target,
                            Margin = '5,5,5,5', Anchors = string.format("0,%d", currentRow)
                        })
                        create_ui_object(faderGrid, 'ValueFadeControl', {
                            Text = prop2Info.Text, Texture = 'corner15', Property = prop2Info.Property,
                            Usedefaultvalue = prop2Info.Usedefaultvalue, Forcefastfade = prop2Info.Forcefastfade,
                            Target = target,
                            Margin = '5,5,5,5', Anchors = string.format("1,%d", currentRow)
                        })
                        currentRow = currentRow + 1
                    end

                    -- Next 8 properties (Fade, Delay, Speed, Phase From/To - indices 8 to 15) are paired
                    for j = 8, #faderProperties, 2 do -- Iterate j = 8, 10, 12, 14
                        local fromPropInfo = faderProperties[j]
                        local toPropInfo = faderProperties[j+1]

                        create_ui_object(faderGrid, 'ValueFadeControl', {
                            Text = fromPropInfo.Text, Texture = 'corner15', Property = fromPropInfo.Property,
                            Usedefaultvalue = fromPropInfo.Usedefaultvalue, Forcefastfade = fromPropInfo.Forcefastfade,
                            Target = target,
                            Margin = '5,5,5,5', Anchors = string.format("0,%d", currentRow)
                        })
                        create_ui_object(faderGrid, 'ValueFadeControl', {
                            Text = toPropInfo.Text, Texture = 'corner15', Property = toPropInfo.Property,
                            Usedefaultvalue = toPropInfo.Usedefaultvalue, Forcefastfade = toPropInfo.Forcefastfade,
                            Target = target,
                            Margin = '5,5,5,5', Anchors = string.format("1,%d", currentRow)
                        })
                        currentRow = currentRow + 1
                    end

                    -- Add Shuffle and Swap buttons to the third column
                    local buttons = {
                        {Text = "Random\nShuffle", Clicked = "onRandomShuffleClicked"..dim, Row = 1},
                        {Text = "No\nShuffle", Clicked = "onNoShuffleClicked"..dim, Row = 2},
                        {Text = "Swap", Clicked = "SwapFade"..dim, Row = 4},
                        {Text = "Swap", Clicked = "SwapDelay"..dim, Row = 5},
                        {Text = "Swap", Clicked = "SwapSpeed"..dim, Row = 6},
                        {Text = "Swap", Clicked = "SwapPhase"..dim, Row = 7}
                    }
                    for _, buttonInfo in ipairs(buttons) do
                        create_ui_object(faderGrid, 'Button', {
                            Text = buttonInfo.Text, Font = "Medium20", Texture = 'corner15',
                            PluginComponent = myHandle, Clicked = buttonInfo.Clicked,
                            Margin = '5,5,5,5', Anchors = string.format("2,%d", buttonInfo.Row), Focus = 'Never'
                        })
                    end

                    -- Create bottom button grid
                    grid[1][3].SizePolicy, grid[1][3].Size = 'Fixed', 50
                    local bottomButtonGrid = create_ui_object(grid, 'UILayoutGrid', {
                        Columns = 3, Rows = 1, Margin = '10,0,10,0', Anchors = '0,2,0,2'
                    })

                    local buttonProperties = {
                        {Text = "Ok", Clicked = "OkButtonClicked", Anchors = '0,0', Backcolor = "15.10"},
                        {Text = "Reset", Clicked = "ResetButtonClicked", Anchors = '1,0'},
                        {Text = "Restore", Clicked = "RestoreButtonClicked", Anchors = '2,0'}
                    }

                    for _, prop in ipairs(buttonProperties) do
                        create_ui_object(bottomButtonGrid, 'Button', {
                            Text = prop.Text, Font = "Medium20", Texture = 'corner15',
                            PluginComponent = myHandle, Clicked = prop.Clicked,
                            Margin = '5,0,5,0', Anchors = prop.Anchors, Focus = 'Never',
                            Backcolor = prop.Backcolor
                        })
                    end

                    -- Create preset button grid
                    grid[1][4].SizePolicy, grid[1][4].Size = 'Fixed', 100
                    local presetGrid = create_ui_object(grid, 'UILayoutGrid', {
                        Columns = 4, Rows = 2, Margin = '10,5,10,0', Anchors = '0,3,0,3',
                        Name = "PresetGrid"
                    })

                    for j = 1, 6 do
                        local button = create_ui_object(presetGrid, 'Button', {
                            Text = " " .. j, Font = "Medium20", Texture = 'corner15',
                            PluginComponent = myHandle, Clicked = "PresetClicked" .. j,
                            Margin = '5,5,5,5', Anchors = string.format("%d,%d", (j-1)%3, math.floor((j-1)/3)), Focus = 'Never',
                            Name = "PresetButton" .. j
                        })
                        
                        -- Set button color based on preset content
                        local contentStatus = presetHasContent(j)
                        if contentStatus == true then
                            button.Backcolor = "15.9"  -- Color for presets containing non-null information
                        elseif contentStatus == 'onlyNull' then
                            button.Backcolor = "15.1"  -- Color for presets containing only null values
                        end
                    end

                    -- Add a single Store button
                    storeButton = create_ui_object(presetGrid, 'Button', {
                        Text = "Store", Font = "Medium20", Texture = 'corner15',
                        PluginComponent = myHandle, Clicked = "StoreButtonClicked",
                        Margin = '5,5,5,5', Anchors = "3,0,3,1"
                    })
                end

                -- Initialize UI tab
                ui_tab:WaitInit()
                for i, dim in ipairs(dimensions) do
                    ui_tab:AddListStringItem(dim, 'value'..i)
                end
                ui_tab[1]:WaitChildren(#dimensions)
                for _, button in ipairs(ui_tab[1]:UIChildren()) do
                    button.Focus = 'Never'
                end

                -- Tab changed callback
                function signalTable.tab_changed(caller)
                    local frame = caller:GetOverlay().dlg_frame
                    for i=1, caller:GetListItemsCount() do
                        local name = caller:GetListItemValueStr(i)
                        local obj = frame:FindRecursive(name, 'UILayoutGrid')
                        obj.Visible = (name == caller.SelectedItemValueStr)
                    end
                    updatePresetButtonColors(screenOverlay)
                end

                -- Button callbacks for each dimension
                for _, dim in ipairs(dimensions) do
                    -- Random Shuffle button callback
                    signalTable["onRandomShuffleClicked"..dim] = function(caller)
                        local randomValue = math.floor(math.random() * 10000)
                        SetVar(UserVars(), 'RND', tostring(randomValue))
                        local matricks = target
                        matricks[dim .. 'shuffle'] = GetVar(UserVars(), 'RND')
                    end

                    -- No Shuffle button callback
                    signalTable["onNoShuffleClicked"..dim] = function(caller)
                        local matricks = target
                        matricks[dim .. 'shuffle'] = 0
                    end

                    -- Swap buttons callbacks for Fade, Delay, and Speed
                    for _, prop in ipairs({'Fade', 'Delay', 'Speed'}) do
                        signalTable["Swap"..prop..dim] = function(caller) swapValues(dim, string.lower(prop)) end
                    end

                    -- Swap Phase button callback
                    signalTable["SwapPhase"..dim] = function(caller)
                        local matricks = target
                        local fromValue = matricks:Get('phasefrom'..dim, Enums.Roles.Display)
                        local toValue = matricks:Get('phaseto'..dim, Enums.Roles.Display)

                        local normalizedTo = normalizePhase(toValue)
                        local normalizedFrom = normalizePhase(fromValue)

                        matricks:Set('phasefrom'..dim, normalizedTo)
                        matricks:Set('phaseto'..dim, normalizedFrom)
                    end
                end

                -- Ok button callback - close dialog and clear overlay
                signalTable.OkButtonClicked = function(caller)
                    local display, overlay = getDisplayAndOverlay()
                    if overlay then overlay:ClearUIChildren() end
                end

                -- Reset button callback
                signalTable.ResetButtonClicked = function(caller)
                    local undo = CreateUndo and CreateUndo('MAtricks Modifier') or nil
                    resetMatricks(matricksItem, isSelectionMode)
                    if undo and CloseUndo then CloseUndo(undo) end
                    updatePresetButtonColors(screenOverlay)
                end

                -- Restore button callback
                signalTable.RestoreButtonClicked = function(caller)
                    local matricksItem = GetVar(UserVars(), "MatricksModGroup")
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
                    updatePresetButtonColors(screenOverlay)
                end

                -- Store button callback
                signalTable.StoreButtonClicked = function(caller)
                    storeMode = not storeMode
                    caller.Backcolor = storeMode and "15.10" or "15.1"
                    caller.Text = storeMode and "Cancel Store" or "Store"
                    storeButton = caller  -- Save reference to the store button
                end

                -- Preset button callbacks
                for j = 1, 6 do
                    signalTable["PresetClicked" .. j] = function(caller)
                        if storeMode then
                            storePreset(j, isSelectionMode)
                            storeMode = false
                            if storeButton then
                                storeButton.Backcolor = "15.1"  -- Reset color for normal mode
                                storeButton.Text = "Store"
                            end
                            updatePresetButtonColors(screenOverlay)
                        else
                            recallPreset(j, isSelectionMode)
                        end
                    end
                end
            end

            return CreateFaderDialog