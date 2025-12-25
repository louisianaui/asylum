--// loadstring(game:HttpGet('https://raw.githubusercontent.com/louisianaui/asylum/refs/heads/main/automop.lua'))()

-- AutoMop with Correct Pathfinding Order - FIXED

-- Services
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local LocalPlayer = Players.LocalPlayer

-- Load Rayfield UI
local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

-- State variables
local isCleaning = false
local totalCleaned = 0
local espEnabled = false
local espUpdateConnection
local spillHighlights = {}
local currentPath
local isPathfinding = false
local lastPosition = Vector3.zero  -- ADDED: Initialize lastPosition

-- Configuration
local HOLD_DURATION = 3.5  -- Hold E for 2 seconds
local MAX_DISTANCE = 6     -- Must be within 5 studs to trigger prompt
local ESP_MAX_DISTANCE = 128
local ESP_UPDATE_INTERVAL = 0.5
local CLEAN_RANGE = 8
local STUCK_CHECK_INTERVAL = 1.0  -- ADDED: Stuck check interval
local STUCK_THRESHOLD = 2.0       -- ADDED: Stuck threshold
local WAYPOINT_TOLERANCE = 4      -- ADDED: Waypoint tolerance

-- Function to find proximity prompt in a spill model
local function FindSpillProximityPrompt(spillModel)
    if not spillModel then return nil end
    
    if spillModel:FindFirstChild("Root") then
        local prompt = spillModel.Root:FindFirstChildWhichIsA("ProximityPrompt")
        if prompt then return prompt end
    end
    
    for _, child in pairs(spillModel:GetDescendants()) do
        if child:IsA("ProximityPrompt") then
            return child
        end
    end
    
    return nil
end

-- Function to hold proximity prompt for required duration
local function HoldProximityPrompt(prompt)
    if not prompt then return false end
    
    local success = false
    
    -- Begin hold
    pcall(function()
        prompt:InputHoldBegin()
    end)
    
    -- Hold for required duration
    local startTime = tick()
    while tick() - startTime < HOLD_DURATION do
        if not prompt or not prompt.Parent then
            break
        end
        RunService.Heartbeat:Wait()
    end
    
    -- End hold
    pcall(function()
        prompt:InputHoldEnd()
        success = true
    end)
    
    return success
end

-- Function to clean a spill using its proximity prompt
local function CleanSpill(spillModel)
    if not spillModel or not spillModel.Parent then
        return false, "Spill model not found"
    end
    
    local prompt = FindSpillProximityPrompt(spillModel)
    if not prompt then
        return false, "No proximity prompt found"
    end
    
    -- Hold the proximity prompt
    print(string.format("🧹 Holding E on %s for %.1f seconds...", spillModel.Name, HOLD_DURATION))
    local success = HoldProximityPrompt(prompt)
    
    if success then
        -- Wait to see if spill gets cleaned
        wait(0.5)
        
        -- Check if spill still exists
        if not spillModel or not spillModel.Parent then
            totalCleaned = totalCleaned + 1
            print("✅ Cleaned successfully!")
            return true, "Cleaned successfully"
        else
            return false, "Spill not cleaned after hold"
        end
    else
        return false, "Failed to hold proximity prompt"
    end
end

-- === ORIGINAL PATHFINDING FUNCTIONS === --

-- Function to get the closest spill
local function FindNearestSpill()
    local spillsFolder = Workspace:FindFirstChild("Ignored")
    if not spillsFolder then return nil, 0 end
    
    spillsFolder = spillsFolder:FindFirstChild("Spills")
    if not spillsFolder then return nil, 0 end
    
    local character = LocalPlayer.Character
    if not character or not character:FindFirstChild("HumanoidRootPart") then return nil, 0 end
    
    local playerPos = character.HumanoidRootPart.Position
    local nearestDistance = math.huge
    local nearestSpill = nil
    
    for _, spillModel in pairs(spillsFolder:GetChildren()) do
        if spillModel:IsA("Model") and spillModel:FindFirstChild("Root") then
            local rootPart = spillModel.Root
            if rootPart:IsA("BasePart") then
                local distance = (rootPart.Position - playerPos).Magnitude
                if distance < nearestDistance then
                    nearestDistance = distance
                    nearestSpill = spillModel
                end
            end
        end
    end
    
    return nearestSpill, nearestDistance
end

-- Function to compute and follow path (ORIGINAL VERSION)
local function ComputeAndFollowPath(destination)
    local character = LocalPlayer.Character
    if not character then return false end
    
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    
    if not humanoid or not rootPart then return false end
    
    -- Create path
    local path = PathfindingService:CreatePath({
        AgentRadius = 1.5,
        AgentHeight = 5,
        AgentCanJump = true,
        AgentCanClimb = true,
        WaypointSpacing = 3
    })
    
    -- Compute path
    local success, errorMessage = pcall(function()
        path:ComputeAsync(rootPart.Position, destination)
    end)
    
    if not success then
        print("Path error:", errorMessage)
        return false
    end
    
    if path.Status == Enum.PathStatus.Success then
        local waypoints = path:GetWaypoints()
        print("✅ Path found! Waypoints:", #waypoints)
        
        currentPath = path
        
        -- Follow waypoints
        for i, waypoint in ipairs(waypoints) do
            if not isCleaning then break end
            
            local targetPos = waypoint.Position
            
            -- Handle jumps
            if waypoint.Action == Enum.PathWaypointAction.Jump then
                humanoid.Jump = true
                wait(0.2)
            end
            
            -- Move to waypoint
            humanoid:MoveTo(targetPos)
            
            -- Wait for waypoint completion
            local waypointReached = false
            local attempts = 0
            local startTime = tick()
            lastPosition = rootPart.Position
            
            while isCleaning and not waypointReached and attempts < 30 do
                local distance = (rootPart.Position - targetPos).Magnitude
                
                if distance <= WAYPOINT_TOLERANCE then
                    waypointReached = true
                    break
                end
                
                -- Stuck detection
                if tick() - startTime > STUCK_CHECK_INTERVAL then
                    local movedDistance = (rootPart.Position - lastPosition).Magnitude
                    
                    if movedDistance < STUCK_THRESHOLD then
                        print("⚠️ Stuck detected, attempting recovery...")
                        humanoid.Jump = true
                        startTime = tick()
                        lastPosition = rootPart.Position
                    end
                end
                
                RunService.Heartbeat:Wait()
                attempts = attempts + 1
            end
            
            if not waypointReached then
                print("⚠️ Could not reach waypoint", i)
                break
            end
        end
        
        return true
    else
        print("❌ No path found:", path.Status)
        return false
    end
end

-- ESP Functions (simplified)
local function UpdateSpillHighlight(spillModel, distance)
    if spillHighlights[spillModel] then
        local highlightData = spillHighlights[spillModel]
        
        if highlightData.Billboard and highlightData.Billboard:FindFirstChild("DistanceText") then
            highlightData.Billboard.DistanceText.Text = string.format("%s\n%.1f studs", spillModel.Name, distance)
            highlightData.Highlight.FillColor = distance <= CLEAN_RANGE and Color3.fromRGB(0, 255, 0) or Color3.fromRGB(255, 200, 0)
        end
        return
    end
    
    local highlight = Instance.new("Highlight")
    highlight.Name = "SpillESP_" .. spillModel.Name
    highlight.Adornee = spillModel.Root
    highlight.FillColor = distance <= CLEAN_RANGE and Color3.fromRGB(0, 255, 0) or Color3.fromRGB(255, 200, 0)
    highlight.FillTransparency = 0.6
    highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
    highlight.OutlineTransparency = 0
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Enabled = espEnabled
    highlight.Parent = Workspace
    
    local billboard = Instance.new("BillboardGui")
    billboard.Name = "DistanceLabel"
    billboard.Size = UDim2.new(0, 150, 0, 50)
    billboard.StudsOffset = Vector3.new(0, 4, 0)
    billboard.AlwaysOnTop = true
    billboard.MaxDistance = ESP_MAX_DISTANCE
    billboard.Adornee = spillModel.Root
    billboard.Parent = spillModel.Root
    
    local label = Instance.new("TextLabel")
    label.Name = "DistanceText"
    label.Text = string.format("%s\n%.1f studs", spillModel.Name, distance)
    label.Size = UDim2.new(1, 0, 1, 0)
    label.BackgroundTransparency = 1
    label.TextColor3 = Color3.fromRGB(255, 255, 255)
    label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    label.TextStrokeTransparency = 0
    label.TextScaled = true
    label.Font = Enum.Font.GothamBold
    label.Visible = espEnabled
    label.Parent = billboard
    
    spillHighlights[spillModel] = {
        Highlight = highlight,
        Billboard = billboard
    }
end

local function UpdateESP()
    if not espEnabled then return end
    
    local spillsFolder = Workspace:FindFirstChild("Ignored")
    if not spillsFolder then return end
    
    spillsFolder = spillsFolder:FindFirstChild("Spills")
    if not spillsFolder then return end
    
    local character = LocalPlayer.Character
    local playerPos = character and character:FindFirstChild("HumanoidRootPart") and character.HumanoidRootPart.Position
    
    local currentSpills = {}
    
    for _, spillModel in pairs(spillsFolder:GetChildren()) do
        if spillModel:IsA("Model") and spillModel:FindFirstChild("Root") then
            currentSpills[spillModel] = true
            
            local distance = ESP_MAX_DISTANCE + 1
            if playerPos then
                distance = (spillModel.Root.Position - playerPos).Magnitude
            end
            
            if distance <= ESP_MAX_DISTANCE then
                UpdateSpillHighlight(spillModel, distance)
            else
                if spillHighlights[spillModel] then
                    local highlightData = spillHighlights[spillModel]
                    if highlightData.Highlight then highlightData.Highlight:Destroy() end
                    if highlightData.Billboard then highlightData.Billboard:Destroy() end
                    spillHighlights[spillModel] = nil
                end
            end
        end
    end
    
    for spillModel in pairs(spillHighlights) do
        if not currentSpills[spillModel] then
            if spillHighlights[spillModel] then
                local highlightData = spillHighlights[spillModel]
                if highlightData.Highlight then highlightData.Highlight:Destroy() end
                if highlightData.Billboard then highlightData.Billboard:Destroy() end
            end
            spillHighlights[spillModel] = nil
        end
    end
end

local function ToggleESP(enabled)
    espEnabled = enabled
    
    for spillModel, highlightData in pairs(spillHighlights) do
        if highlightData.Highlight then
            highlightData.Highlight.Enabled = enabled
        end
        if highlightData.Billboard and highlightData.Billboard:FindFirstChild("DistanceText") then
            highlightData.Billboard.DistanceText.Visible = enabled
        end
    end
    
    if enabled then
        if espUpdateConnection then
            espUpdateConnection:Disconnect()
        end
        
        espUpdateConnection = RunService.Heartbeat:Connect(function()
            UpdateESP()
        end)
        
        UpdateESP()
        return "ESP Enabled"
    else
        if espUpdateConnection then
            espUpdateConnection:Disconnect()
            espUpdateConnection = nil
        end
        return "ESP Disabled"
    end
end

-- === MAIN CLEANING LOGIC WITH CORRECT ORDER - FIXED === --

local function StartCleaning()
    if isCleaning then
        return "Already cleaning!"
    end
    
    isCleaning = true
    
    task.spawn(function()
        while isCleaning do
            -- Find nearest spill
            local nearestSpill, distance = FindNearestSpill()
            
            -- Check if we found a spill
            if nearestSpill == nil then
                print("🔍 No spills found")
                wait(2)
                -- Just continue the loop to check again
            else
                -- We have a valid spill, process it
                local spillName = nearestSpill.Name
                local targetPosition = nearestSpill.Root.Position
                local character = LocalPlayer.Character
                
                -- Make sure character exists
                if character and character:FindFirstChild("HumanoidRootPart") then
                    local rootPart = character.HumanoidRootPart
                    
                    print(string.format("🎯 Target: %s (%.1f studs away)", spillName, distance))
                    
                    -- STEP 1: Pathfind FIRST if too far
                    if distance > MAX_DISTANCE then
                        print("🗺️ Pathfinding to spill...")
                        
                        -- Compute and follow path
                        local pathSuccess = ComputeAndFollowPath(targetPosition)
                        
                        if pathSuccess then
                            -- Recheck distance after pathfinding
                            distance = (rootPart.Position - targetPosition).Magnitude
                            print(string.format("✅ Reached area, now %.1f studs away", distance))
                        else
                            print("❌ Pathfinding failed")
                        end
                    end
                    
                    -- STEP 2: Only after pathfinding/walking, check if we can clean
                    if distance <= MAX_DISTANCE then
                        -- Check if spill has a proximity prompt
                        local prompt = FindSpillProximityPrompt(nearestSpill)
                        
                        if prompt then
                            print("🤖 Attempting to clean...")
                            local cleaned, message = CleanSpill(nearestSpill)
                            
                            if cleaned then
                                print(string.format("✅ Cleaned %s!", spillName))
                            else
                                print(string.format("❌ Failed: %s", message))
                            end
                        else
                            print("❌ No proximity prompt found on spill")
                        end
                    else
                        print(string.format("📏 Still too far (%.1f studs)", distance))
                    end
                else
                    print("❌ Character not ready")
                end
                
                wait(1)  -- Wait before next spill
            end
            
            -- Small delay to prevent CPU overload
            wait(0.1)
        end
    end)
    
    return "Started cleaning!"
end

local function StopCleaning()
    if not isCleaning then
        return "Not currently cleaning"
    end
    
    isCleaning = false
    
    -- Stop character movement
    local character = LocalPlayer.Character
    if character then
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            humanoid:MoveTo(character.HumanoidRootPart.Position)
        end
    end
    
    return "Stopped cleaning"
end

-- === RAYFIELD UI === --
local Window = Rayfield:CreateWindow({
    Name = "🧹 AutoMop - Fixed Pathfinding",
    LoadingTitle = "AutoMop Pro",
    LoadingSubtitle = "Pathfind First, Then Clean",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "AutoMopPro",
        FileName = "Settings"
    }
})

local MainTab = Window:CreateTab("Main", 4483362458)

local statusText = "Ready"
local statsText = string.format("Total Cleaned: %d", totalCleaned)
local espStatusText = "ESP: Off"

local StatusLabel = MainTab:CreateParagraph({Title = "Status", Content = statusText})
local StatsLabel = MainTab:CreateParagraph({Title = "Statistics", Content = statsText})
local ESPStatusLabel = MainTab:CreateParagraph({Title = "ESP", Content = espStatusText})

local function UpdateLabels()
    StatusLabel:Set({Title = "Status", Content = statusText})
    StatsLabel:Set({Title = "Statistics", Content = string.format("Total Cleaned: %d", totalCleaned)})
    ESPStatusLabel:Set({Title = "ESP", Content = espStatusText})
end

MainTab:CreateSection("Controls")

MainTab:CreateButton({
    Name = "▶️ Start Auto Cleaning",
    Callback = function()
        statusText = StartCleaning()
        UpdateLabels()
    end
})

MainTab:CreateButton({
    Name = "⏹️ Stop Auto Cleaning",
    Callback = function()
        statusText = StopCleaning()
        UpdateLabels()
    end
})

MainTab:CreateButton({
    Name = "🧹 Clean Closest Spill",
    Callback = function()
        local nearestSpill, distance = FindNearestSpill()
        
        if nearestSpill then
            statusText = string.format("Cleaning %s...", nearestSpill.Name)
            UpdateLabels()
            
            local cleaned, message = CleanSpill(nearestSpill)
            
            if cleaned then
                statusText = string.format("✅ Cleaned %s!", nearestSpill.Name)
            else
                statusText = string.format("❌ Failed: %s", message)
            end
        else
            statusText = "No spills found"
        end
        
        UpdateLabels()
    end
})

MainTab:CreateSection("ESP")

MainTab:CreateToggle({
    Name = "Enable Spill ESP",
    CurrentValue = espEnabled,
    Callback = function(value)
        espStatusText = ToggleESP(value)
        UpdateLabels()
    end
})

-- Settings Tab
local SettingsTab = Window:CreateTab("Settings", 4483362458)

SettingsTab:CreateSection("Cleaning Settings")

-- Stats update loop
task.spawn(function()
    while true do
        UpdateLabels()
        task.wait(0.5)
    end
end)

print("========================================")
print("🧹 AutoMop - Fixed Order")
print("========================================")
print("Now pathfinds FIRST, then cleans!")
print("Order: Find spill → Pathfind → Get close → Hold E")
print("========================================")

statusText = "✅ Ready - Pathfind First, Then Clean!"
UpdateLabels()
