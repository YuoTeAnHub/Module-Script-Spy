if _G.ModuleSpy_Unload then
    pcall(_G.ModuleSpy_Unload)
end

local function CleanupOld()
    local targets = {}
    if gethui then table.insert(targets, gethui()) end
    local okCore, core = pcall(game.GetService, game, "CoreGui")
    if okCore and core then table.insert(targets, core) end
    local lp = game:GetService("Players").LocalPlayer
    if lp then
        local pg = lp:FindFirstChildOfClass("PlayerGui")
        if pg then table.insert(targets, pg) end
    end
    for _, container in ipairs(targets) do
        for _, g in ipairs(container:GetChildren()) do
            if g.Name == "ReGui" or g.Name == "HiddenUI" then
                pcall(function()
                    for _, ch in ipairs(g:GetChildren()) do
                        if ch.Name == "ReGui" then ch:Destroy() end
                    end
                end)
            end
        end
    end
end
CleanupOld()

local ReGui = loadstring(game:HttpGet("https://raw.githubusercontent.com/YuoTeAnHub/Dear-ReGui/refs/heads/main/ReGui.lua"))()
local prefabs = game:GetObjects("rbxassetid://" .. ReGui.PrefabsId)[1]
ReGui:Init({ Prefabs = prefabs })

pcall(function()
    local ThemeCode = Font.fromEnum(Enum.Font.Code)
    for _, themeName in ipairs({ "DarkTheme", "LightTheme", "ImGuiTheme" }) do
        local theme = ReGui.ThemeConfigs and ReGui.ThemeConfigs[themeName]
        if theme and theme.Values then
            theme.Values.TextFont = ThemeCode
            theme.Values.TextSize = 13
        end
    end
end)

_G.ModuleSpy_Running = true
_G.ModuleSpy_Unload  = function()
    _G.ModuleSpy_Running = false
    CleanupOld()
end

local Players = game:GetService("Players")

local ServiceNames = {
    "Workspace", "Players", "Lighting", "ReplicatedFirst",
    "ReplicatedStorage", "StarterGui", "StarterPack", "StarterPlayer",
}

local LEFT_W = 170

local CurrentModule = nil
local CurrentConfig = nil
local LoopEnabled          = false
local AutoRefreshEnabled   = false
local AutoRefreshInterval  = 1
local RebuildTree
local HighlightLP   = false
local DumperMode    = false
local ScriptType    = "Module Script"
local ApplyButton
local EnabledCheckbox
local DumpFilenames = {}
local BuildHeader
local DumpModule
local IsDumpingAll = false
local DumperInterval = 0.5
local editMethod    = "Default"
local SearchText    = ""

local SelectableByModule = {}
local TreeNodeByService  = {}
local ModulesByService   = {}
local SelectedSel        = nil
local CodeFontFace = Font.fromEnum(Enum.Font.Code)
local GREEN = Color3.fromRGB(120, 220, 130)
local RED   = Color3.fromRGB(230, 90,  90)
local DEFAULT_TEXT = Color3.fromRGB(220, 220, 220)

local function SafeSet(inst, prop, value)
    pcall(function() inst[prop] = value end)
end

local function SafeDescendants(inst)
    local ok, list = pcall(function() return inst:GetDescendants() end)
    if ok and type(list) == "table" then return list end
    return {}
end

local function IsLocalPlayerRelated(m)
    if not m then return false end
    local lp = Players.LocalPlayer
    if lp and m:IsDescendantOf(lp) then return true end
    for _, sName in ipairs({ "StarterPlayer", "StarterGui", "StarterPack" }) do
        local ok, svc = pcall(game.GetService, game, sName)
        if ok and svc and m:IsDescendantOf(svc) then return true end
    end
    return false
end

local function ColorForModule(m)
    if HighlightLP and IsLocalPlayerRelated(m) then return GREEN end
    return DEFAULT_TEXT
end

local function ReadSource(m)
    if not m then return "" end
    local ok, s = pcall(function() return m.Source end)
    if ok and s and #s > 0 then return s end
    if decompile then
        local ok2, s2 = pcall(decompile, m)
        if ok2 and s2 and #s2 > 0 then return s2 end
    end
    return ""
end

local function TryRequire(m)
    local ok, ret = pcall(require, m)
    if ok then return ret end
    return nil
end

local function CollectModules(root)
    local list = {}
    local wantClass = ScriptType == "Local Script" and "LocalScript" or "ModuleScript"
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA(wantClass) then table.insert(list, d) end
    end
    table.sort(list, function(a, b) return a.Name:lower() < b.Name:lower() end)
    return list
end

local function unfreeze(t)
    if type(t) ~= "table" then return end
    if setreadonly then pcall(setreadonly, t, false) end
    if make_writeable then pcall(make_writeable, t) end
end

local function tableMatchesSignature(t, ref)
    if type(t) ~= "table" or rawequal(t, ref) then return false end
    local refCount, shared = 0, false
    for k, v in pairs(ref) do
        refCount = refCount + 1
        local tv = rawget(t, k)
        if tv == nil and v ~= nil then return false end
        if rawequal(tv, v) then shared = true end
    end
    if refCount == 0 then return false end
    local tCount = 0
    for _ in pairs(t) do tCount = tCount + 1 end
    return shared and tCount == refCount
end

local gcMatchCache = setmetatable({}, { __mode = "k" })
local function getGcMatches(ref)
    if type(ref) ~= "table" or not getgc then return {} end
    if gcMatchCache[ref] then return gcMatchCache[ref] end
    local matches = {}
    local ok, objs = pcall(getgc, true)
    if ok and type(objs) == "table" then
        for _, t in ipairs(objs) do
            if type(t) == "table" and tableMatchesSignature(t, ref) then
                matches[#matches + 1] = t
            end
        end
    end
    gcMatchCache[ref] = matches
    return matches
end

local function applyTableEdit(tbl, key, value)
    if editMethod == "Rawset" then
        local ok = pcall(rawset, tbl, key, value)
        if not ok then pcall(function() tbl[key] = value end) end
    else
        if editMethod ~= "Default" then unfreeze(tbl) end
        local ok = pcall(function() tbl[key] = value end)
        if not ok then pcall(rawset, tbl, key, value) end
        if editMethod == "GC Scan" then
            for _, t in ipairs(getGcMatches(tbl)) do
                unfreeze(t)
                if not pcall(function() t[key] = value end) then
                    pcall(rawset, t, key, value)
                end
            end
        end
    end
end

local function verifyEdits(tbl, expected)
    task.wait(0.05)
    for k, v in pairs(expected) do
        local okRead, cur = pcall(function() return tbl[k] end)
        if not okRead then return false end
        if v == nil then
            if cur ~= nil then return false end
        else
            if not rawequal(cur, v) then return false end
        end
    end
    return true
end

local Window = ReGui:Window({
    Title    = "Module Spy",
    Size     = UDim2.fromOffset(640, 420),
    NoSelect = true,
    NoScroll = true,
})

local Layout = Window:List({
    UiPadding      = 2,
    HorizontalFlex = Enum.UIFlexAlignment.Fill,
    VerticalFlex   = Enum.UIFlexAlignment.Fill,
    FillDirection  = Enum.FillDirection.Vertical,
    Fill           = true,
})

local ServicesList = Layout:Canvas({
    Scroll        = true,
    UiPadding     = 1,
    AutomaticSize = Enum.AutomaticSize.None,
    FlexMode      = Enum.UIFlexMode.None,
    Size          = UDim2.new(0, LEFT_W, 1, 0),
})

local function ApplySearch()
    local q = SearchText:lower()
    for m, sel in pairs(SelectableByModule) do
        local visible = q == "" or m.Name:lower():find(q, 1, true) ~= nil
        pcall(function() sel.Visible = visible end)
    end
end

local SearchBox = ServicesList:InputText({
    Placeholder   = "Search...",
    Label         = "",
    Value         = "",
    Size          = UDim2.new(1, 0, 0, 20),
    AutomaticSize = Enum.AutomaticSize.None,
    FlexMode      = Enum.UIFlexMode.None,
    Callback      = function(_, v)
        SearchText = tostring(v or "")
        ApplySearch()
    end,
})

local Tabs = Layout:TabSelector({
    NoAnimation = true,
    Size        = UDim2.new(1, -LEFT_W, 1, 0),
})

local EditorTab  = Tabs:CreateTab({ Name = "Editor" })
local OptionsTab = Tabs:CreateTab({ Name = "Options" })

local Editor = EditorTab:CodeEditor({
    Fill     = true,
    Editable = true,
    Text     = "",
    FontSize = 13,
    FontFace = CodeFontFace,
})

local function GetEditorText()
    if Editor.GetText then return Editor:GetText() end
    return Editor.Text or ""
end
local function SetEditorText(t)
    if Editor.SetText then Editor:SetText(t) else Editor.Text = t end
end

local Controls = EditorTab:Row()

local StatusLabel
local statusToken = 0

local function ClearStatus()
    if StatusLabel then
        pcall(function() StatusLabel.Text = "" end)
    end
end

local function SetStatus(text, color)
    if not StatusLabel then return end
    statusToken = statusToken + 1
    local myToken = statusToken
    pcall(function() StatusLabel.Text = text end)
    pcall(function() StatusLabel.TextColor3 = color end)
    if text == "Changed" or text == "Copied" or text == "Dumped" then
        task.delay(1, function()
            if statusToken == myToken then
                ClearStatus()
            end
        end)
    end
end

local function applyModuleSource()
    if not CurrentModule or type(CurrentConfig) ~= "table" then
        SetStatus("Error: Can't Change", RED)
        return
    end

    local src = GetEditorText()
    src = src:gsub("^%-%- Path:[^\n]*\n", "", 1)

    local fn, loadErr = loadstring(src, CurrentModule.Name)
    if not fn then
        warn("[ModuleSpy] loadstring:", loadErr)
        SetStatus("Error: Can't Change", RED)
        return
    end

    pcall(function()
        local env = setmetatable({ script = CurrentModule }, { __index = getfenv() })
        setfenv(fn, env)
    end)

    local ok, ret = pcall(fn)
    if not ok then
        warn("[ModuleSpy] run:", ret)
        SetStatus("Error: Can't Change", RED)
        return
    end
    if type(ret) ~= "table" then
        SetStatus("Error: Can't Change", RED)
        return
    end

    if editMethod == "Force Writable" then
        unfreeze(CurrentConfig)
    end

    local snap = {}
    for k, v in pairs(CurrentConfig) do snap[k] = v end

    local expected = {}
    for k in pairs(snap) do
        if ret[k] == nil then
            applyTableEdit(CurrentConfig, k, nil)
            expected[k] = nil
        end
    end
    for k, v in pairs(ret) do
        applyTableEdit(CurrentConfig, k, v)
        expected[k] = v
    end

    task.spawn(function()
        if verifyEdits(CurrentConfig, expected) then
            SetStatus("Changed", GREEN)
        else
            SetStatus("Error: Can't Change", RED)
        end
    end)
end

Controls:Button({
    Text     = "Refresh",
    Callback = function() RebuildTree() end,
})

Controls:Button({
    Text = "Copy",
    Callback = function()
        if not CurrentModule then return end
        if not setclipboard then
            SetStatus("Error: Can't Change", RED)
            return
        end
        local src = ReadSource(CurrentModule)
        if src == "" then
            SetStatus("Error: Can't Change", RED)
            return
        end
        local full = BuildHeader(CurrentModule) .. "\n" .. src
        local ok = pcall(setclipboard, full)
        if ok then
            SetStatus("Copied", GREEN)
        else
            SetStatus("Error: Can't Change", RED)
        end
    end,
})

ApplyButton = Controls:Button({
    Text     = "Apply",
    Callback = applyModuleSource,
})

DumpModule = function(m)
    if not m then return false, "no module" end
    if not writefile then return false, "no writefile" end
    return pcall(function()
        if makefolder and not (isfolder and isfolder("Module Spy")) then
            pcall(makefolder, "Module Spy")
        end
        local sub = m:IsA("LocalScript") and "Local Scripts" or "Module Scripts"
        local folder = "Module Spy/" .. sub
        if makefolder and not (isfolder and isfolder(folder)) then
            pcall(makefolder, folder)
        end
        local src = ReadSource(m)
        if src == "" then error("empty source") end
        local modulePath = m:GetFullName()
        local safeName = m.Name:gsub("[^%w%-%._]", "_")
        local filename = DumpFilenames[modulePath]
        if not filename then
            for _ = 1, 999 do
                local id = string.format("%03d", math.random(0, 999))
                local candidate = folder .. "/" .. safeName .. "_" .. id .. "_Dumped.txt"
                local exists = false
                if isfile then pcall(function() exists = isfile(candidate) end) end
                if not exists then
                    filename = candidate
                    break
                end
            end
            if not filename then
                filename = folder .. "/" .. safeName .. "_" .. tostring(os.time()) .. "_Dumped.txt"
            end
            DumpFilenames[modulePath] = filename
        end
        local full = BuildHeader(m) .. "\n" .. src
        writefile(filename, full)
    end)
end

Controls:Button({
    Text     = "Dump",
    Callback = function()
        if not CurrentModule then
            SetStatus("Error: Can't Change", RED)
            return
        end
        local ok, err = DumpModule(CurrentModule)
        if ok then
            SetStatus("Dumped", GREEN)
        else
            warn("[ModuleSpy] dump:", err)
            SetStatus("Error: Can't Change", RED)
        end
    end,
})

Controls:Checkbox({
    Label    = "Loop",
    Value    = false,
    Callback = function(_, v) LoopEnabled = v end,
})

EnabledCheckbox = Controls:Checkbox({
    Label    = "Enabled",
    Value    = false,
    Callback = function(_, v)
        if not CurrentModule then return end
        if not CurrentModule:IsA("LocalScript") then return end
        local ok = pcall(function() CurrentModule.Enabled = v end)
        if ok then
            SetStatus("Changed", GREEN)
        else
            SetStatus("Error: Can't Change", RED)
        end
    end,
})
pcall(function() EnabledCheckbox.Visible = false end)

StatusLabel = Controls:Label({ Text = "", TextColor3 = GREEN, FontFace = CodeFontFace })

BuildHeader = function(m)
    local isLocal = m:IsA("LocalScript")
    local lines = {
        "-- Path: " .. m:GetFullName(),
        "-- Script Type: " .. (isLocal and "Local" or "Module"),
    }
    if isLocal then
        local enabled = false
        pcall(function() enabled = m.Enabled end)
        lines[#lines + 1] = "-- Enabled?: " .. (enabled and "Yes" or "No")
    end
    return table.concat(lines, "\n")
end

local function RichTextFor(m)
    if HighlightLP and IsLocalPlayerRelated(m) then
        return string.format('<font color="rgb(120,220,130)">%s</font>', m.Name)
    end
    return m.Name
end

local function RetintOne(m, sel)
    local text = RichTextFor(m)
    pcall(function() sel.Text = text end)
    for _, key in ipairs({ "Frame", "Gui" }) do
        local ok, node = pcall(function() return sel[key] end)
        if ok and typeof(node) == "Instance" then
            pcall(function() node.RichText = true end)
            pcall(function() node.Text = text end)
            for _, d in ipairs(SafeDescendants(node)) do
                if d:IsA("TextLabel") or d:IsA("TextButton") then
                    pcall(function() d.RichText = true end)
                    pcall(function() d.Text = text end)
                end
            end
        end
    end
end

local function RetintAll()
    for m, sel in pairs(SelectableByModule) do
        RetintOne(m, sel)
    end
end

OptionsTab:Checkbox({
    Label    = "Local Player Highlight",
    Value    = false,
    Callback = function(_, v)
        HighlightLP = v
        RetintAll()
    end,
})

OptionsTab:Checkbox({
    Label    = "Dumper Mode",
    Value    = false,
    Callback = function(_, v) DumperMode = v end,
})

OptionsTab:Checkbox({
    Label    = "Auto-Refresh",
    Value    = false,
    Callback = function(_, v) AutoRefreshEnabled = v end,
})

OptionsTab:Combo({
    Label    = "Interval",
    Selected = 2,
    Items    = { "0.5 Seconds", "1 Seconds", "2 Seconds", "3 Seconds", "4 Seconds", "5 Seconds", "6 Seconds", "7 Seconds", "8 Seconds", "9 Seconds", "10 Seconds", "11 Seconds", "12 Seconds", "13 Seconds", "14 Seconds", "15 Seconds" },
    Callback = function(_, item)
        local n = tonumber((tostring(item):gsub(" Seconds", "")))
        if n then AutoRefreshInterval = n end
    end,
})

OptionsTab:Combo({
    Label    = "Edit Method",
    Selected = 1,
    Items    = { "Default", "Rawset", "Force Writable", "GC Scan" },
    Callback = function(_, item)
        editMethod = tostring(item)
    end,
})

local function ApplyScriptType()
    local isLocal = ScriptType == "Local Script"
    if ApplyButton then pcall(function() ApplyButton.Visible = not isLocal end) end
    if EnabledCheckbox then pcall(function() EnabledCheckbox.Visible = isLocal end) end
end

OptionsTab:Combo({
    Label    = "Script Type",
    Selected = 2,
    Items    = { "Local Script", "Module Script" },
    Callback = function(_, item)
        ScriptType = tostring(item)
        ApplyScriptType()
        if RebuildTree then RebuildTree() end
    end,
})

OptionsTab:Combo({
    Label    = "Dumper Interval",
    Selected = 2,
    Items    = { "1 Seconds", "0.5 Seconds", "0.1 Seconds", "0.05 Seconds" },
    Callback = function(_, item)
        local n = tonumber((tostring(item):gsub(" Seconds", "")))
        if n then DumperInterval = n end
    end,
})

local DumpAllRow = OptionsTab:Row()
local DumpAllStatus
DumpAllRow:Button({
    Text     = "Dump All",
    Callback = function()
        if IsDumpingAll then return end
        IsDumpingAll = true
        task.spawn(function()
            local mods = {}
            for _, name in ipairs(ServiceNames) do
                local list = ModulesByService[name]
                if list then
                    for _, m in ipairs(list) do
                        mods[#mods + 1] = m
                    end
                end
            end
            local total = #mods
            if total == 0 then
                if DumpAllStatus then pcall(function() DumpAllStatus.Text = "Nothing to dump" end) end
                IsDumpingAll = false
                return
            end
            local success = 0
            for i, m in ipairs(mods) do
                local nm = m.Name
                local ok, err = DumpModule(m)
                if ok then
                    success = success + 1
                    if DumpAllStatus then
                        pcall(function()
                            DumpAllStatus.Text = string.format('%d/%d Dumped "%s"', i, total, nm)
                            DumpAllStatus.TextColor3 = GREEN
                        end)
                    end
                else
                    if DumpAllStatus then
                        pcall(function()
                            DumpAllStatus.Text = string.format('%d/%d Can\'t Dump "%s" Skipped', i, total, nm)
                            DumpAllStatus.TextColor3 = RED
                        end)
                    end
                end
                if i < total then task.wait(DumperInterval) end
            end
            if DumpAllStatus then
                pcall(function()
                    DumpAllStatus.Text = string.format("Dumped %d/%d", success, total)
                    DumpAllStatus.TextColor3 = GREEN
                end)
            end
            IsDumpingAll = false
        end)
    end,
})
DumpAllStatus = DumpAllRow:Label({ Text = "", TextColor3 = GREEN, FontFace = CodeFontFace })

local OpenToken = 0

local function StreamEditorText(text, token)
    if Editor.ClearText then
        pcall(function() Editor:ClearText() end)
    else
        SetEditorText("")
    end
    local CHUNK = 40
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    local i = 1
    while i <= #lines do
        if token ~= OpenToken then return end
        local buf = {}
        for j = i, math.min(i + CHUNK - 1, #lines) do
            buf[#buf + 1] = lines[j]
        end
        i = i + CHUNK
        local piece = table.concat(buf, "\n") .. (i <= #lines and "\n" or "")
        if Editor.AppendText then
            pcall(function() Editor:AppendText(piece) end)
        else
            local cur = GetEditorText()
            SetEditorText(cur .. piece)
        end
        task.wait()
    end
end

local function OpenModule(m, sel)
    OpenToken = OpenToken + 1
    local myToken = OpenToken
    CurrentModule = m
    CurrentConfig = TryRequire(m)
    ClearStatus()
    if SelectedSel and SelectedSel ~= sel then
        pcall(function() SelectedSel:SetSelected(false) end)
    end
    SelectedSel = sel
    if sel then
        pcall(function() sel:SetSelected(true) end)
    end
    if EnabledCheckbox and m:IsA("LocalScript") then
        local isEnabled = false
        pcall(function() isEnabled = m.Enabled end)
        pcall(function() EnabledCheckbox:SetValue(isEnabled, true) end)
    end
    if DumperMode then
        if Editor.ClearText then pcall(function() Editor:ClearText() end) end
        SetEditorText(BuildHeader(m))
        return
    end
    task.spawn(function()
        local ok, err = pcall(function()
            local src  = ReadSource(m)
            StreamEditorText(BuildHeader(m) .. "\n" .. src, myToken)
        end)
        if not ok then warn("[ModuleSpy]", err) end
    end)
end

local RebuildToken = 0

RebuildTree = function()
    RebuildToken = RebuildToken + 1
    local myToken = RebuildToken
    for _, node in pairs(TreeNodeByService) do
        pcall(function() node:Remove() end)
    end
    SelectableByModule = {}
    TreeNodeByService  = {}
    ModulesByService   = {}
    SelectedSel = nil
    for _, name in ipairs(ServiceNames) do
        if myToken ~= RebuildToken then return end
        local ok, svc = pcall(game.GetService, game, name)
        if ok and svc then
            local node = ServicesList:TreeNode({
                Title     = name,
                Collapsed = true,
            })
            TreeNodeByService[name] = node
            task.spawn(function()
                local mods = CollectModules(svc)
                if myToken ~= RebuildToken then return end
                ModulesByService[name] = mods
                if #mods == 0 then
                    node:Label({ Text = "Empty", FontFace = CodeFontFace })
                    return
                end
                for i, m in ipairs(mods) do
                    if myToken ~= RebuildToken then return end
                    local sel
                    sel = node:Selectable({
                        Text       = RichTextFor(m),
                        RichText   = true,
                        FontFace   = CodeFontFace,
                        Callback   = function() OpenModule(m, sel) end,
                    })
                    SelectableByModule[m] = sel
                    RetintOne(m, sel)
                    if i % 15 == 0 then
                        task.wait()
                    end
                end
                if SearchText ~= "" then ApplySearch() end
            end)
        end
    end
end

RebuildTree()

task.spawn(function()
    while _G.ModuleSpy_Running do
        task.wait(0.5)
        if LoopEnabled and CurrentModule then
            local ok, err = pcall(applyModuleSource)
            if not ok then warn("[ModuleSpy]", err) end
        end
    end
end)

task.spawn(function()
    while _G.ModuleSpy_Running do
        local interval = AutoRefreshInterval or 1
        if interval < 0.5 then interval = 0.5 end
        task.wait(interval)
        if AutoRefreshEnabled then
            local ok, err = pcall(RebuildTree)
            if not ok then warn("[ModuleSpy]", err) end
        end
    end
end)
