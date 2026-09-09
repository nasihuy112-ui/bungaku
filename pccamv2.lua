require 'widgets'
local imgui = require 'mimgui'
local ffi = require 'ffi'
local bit = require 'bit'
local hook = require 'monethook'
local memory = require 'memory'
local SAMemory = require 'SAMemory'
local inicfg = require 'inicfg'

local cast = ffi.cast

SAMemory.require('CCamera')
local camera = SAMemory.camera
local gta = ffi.load('GTASA')

ffi.cdef([[
    void* _ZN7CCamera7ProcessEv(void* this);
    void _ZN4CCam20Process_FollowPed_SAERK7CVectorfffb(void* this);
    void _ZN4CCam20Process_FollowCar_SAERK7CVectorfffb(void* this);
]])

local function symAddr(fn)
    local a = tonumber(cast('uintptr_t', cast('void*', fn)))
    return bit.band(a, bit.bnot(1))
end

local FOLLOWPED = symAddr(gta._ZN4CCam20Process_FollowPed_SAERK7CVectorfffb)
local FOLLOWCAR = symAddr(gta._ZN4CCam20Process_FollowCar_SAERK7CVectorfffb)

local PATCHES = {
    { addr = FOLLOWPED + 0x0c68 },
    { addr = FOLLOWPED + 0x1340 },
    { addr = FOLLOWCAR + 0x1822 },
    { addr = FOLLOWCAR + 0x1528 },
}

local function applyNoop(state)
    for _, p in ipairs(PATCHES) do
        local ptr = ffi.cast('uint8_t*', p.addr)
        memory.unprotect(tonumber(ffi.cast('uintptr_t', ptr)), 4)
        if state then
            ptr[0], ptr[1], ptr[2], ptr[3] = 0x00, 0xBF, 0x00, 0xBF
        else
            ptr[0], ptr[1], ptr[2], ptr[3] = 0xF6, 0xD6, 0x00, 0x00
        end
    end
end

local defaultConfig = {
    [1] = {
        onfootSens = 3.0,
        onfootSmooth = 12.0,
        vehicleSens = 3.0,
        vehicleSmooth = 12.0,
    }
}

local config = inicfg.load(defaultConfig, "pccam")
local cfg = config[1]

local onfootSens = imgui.new.float(cfg.onfootSens)
local onfootSmooth = imgui.new.float(cfg.onfootSmooth)
local vehicleSens = imgui.new.float(cfg.vehicleSens)
local vehicleSmooth = imgui.new.float(cfg.vehicleSmooth)

local function saveConfig()
    cfg.onfootSens = onfootSens[0]
    cfg.onfootSmooth = onfootSmooth[0]
    cfg.vehicleSens = vehicleSens[0]
    cfg.vehicleSmooth = vehicleSmooth[0]
    inicfg.save(config, "pccam")
end

local lastTick = os.clock()

local function normalize(a)
    while a > math.pi do a = a - 2 * math.pi end
    while a < -math.pi do a = a + 2 * math.pi end
    return a
end

local function getDT()
    local now = os.clock()
    local dt = now - lastTick
    lastTick = now
    if dt <= 0 or dt > 0.1 then dt = 0.016 end
    return dt
end

local function getActiveCam()
    local idx = tonumber(cast('uint8_t', camera.nActiveCam))
    if idx < 0 or idx > 2 then return nil end
    return camera.aCams[idx]
end

local currentPhi, currentTheta = 0.0, 0.0
local onfootInitialized = false

local smoothH, smoothV = 0.0, 0.0
local currentCamH, currentCamV = 0.0, 0.0
local vehicleFirstInit = true

local function handleOnFoot(cam, dt)
    local camMode = cam.nMode
    local aiming = camMode == 7 or camMode == 8 or camMode == 51 or camMode == 53
    if aiming then
        onfootInitialized = false
        return
    end

    local s = onfootSens[0] / 1000
    local spd = onfootSmooth[0]

    local pressed, x, y = isWidgetPressedEx(0xAF, 0)
    x = tonumber(x) or 0
    y = tonumber(y) or 0

    if pressed then
        if not onfootInitialized then
            currentPhi, currentTheta = cam.fHorizontalAngle, cam.fVerticalAngle
            onfootInitialized = true
        end
        currentPhi   = normalize(currentPhi - x * s)
        currentTheta = currentTheta - y * s
    end

    if onfootInitialized then
        cam.fHorizontalAngle = currentPhi
        cam.fVerticalAngle   = currentTheta
    end
end

local function handleVehicle(cam, dt)
    if vehicleFirstInit then
        smoothH = cam.fHorizontalAngle
        smoothV = cam.fVerticalAngle
        currentCamH = smoothH
        currentCamV = smoothV
        vehicleFirstInit = false
    end

    local pressed, dx, dy = isWidgetPressedEx(0xAF, 0)
    dx, dy = tonumber(dx) or 0, tonumber(dy) or 0

    local sensMult = 0.0005
    local vsens = vehicleSens[0]
    local vspeed = vehicleSmooth[0]

    if pressed then
        smoothH = normalize(smoothH - dx * vsens * sensMult)
        smoothV = smoothV - dy * vsens * sensMult
    end

    local minV, maxV = -1.45, 1.45
    if smoothV > maxV then smoothV = maxV end
    if smoothV < minV then smoothV = minV end

    local lerp = 1 - math.exp(-vspeed * dt)
    currentCamH = normalize(currentCamH + normalize(smoothH - currentCamH) * lerp)
    currentCamV = currentCamV + (smoothV - currentCamV) * lerp

    if currentCamV > maxV then currentCamV = maxV end
    if currentCamV < minV then currentCamV = minV end

    cam.fAlphaSpeed, cam.fBetaSpeed = 0, 0
    cam.fHorizontalAngle = currentCamH
    cam.fVerticalAngle   = currentCamV
    cam.fIdealAlpha = currentCamH
    cam.fTrueAlpha  = currentCamH
    cam.fTrueBeta   = currentCamV
end

local cameraProcessHook
cameraProcessHook = hook.new(
    "void*(*)(void*)",
    function(this)
        local ret = cameraProcessHook(this)

        local cam = getActiveCam()
        if not cam then return ret end

        local dt = getDT()

        if not doesCharExist(PLAYER_PED) then
            onfootInitialized = false
            vehicleFirstInit = true
            return ret
        end

        if isCharInAnyCar(PLAYER_PED) then
            onfootInitialized = false
            handleVehicle(cam, dt)
        else
            vehicleFirstInit = true
            handleOnFoot(cam, dt)
        end

        return ret
    end,
    cast(
        "uintptr_t",
        cast(
            "void*",
            gta._ZN7CCamera7ProcessEv
        )
    )
)

applyNoop(true)

function main()
    wait(-1)
end

addEventHandler('onScriptTerminate', function(scr)
    if scr == script.this then
        saveConfig()
        applyNoop(false)
    end
end)

function darkgreentheme()
    local style = imgui.GetStyle()
    local colors = style.Colors
    local clr = imgui.Col
    local dpi = MONET_DPI_SCALE

    style.Alpha = 1
    style.WindowPadding = imgui.ImVec2(9 * dpi, 9 * dpi)
    style.WindowRounding = 15 * dpi
    style.WindowTitleAlign = imgui.ImVec2(0.5, 0.5)
end

local mainGui = { state = false }
local isOpen = imgui.new.bool(false)

imgui.OnFrame(function()
    return mainGui.state
end, function()
darkgreentheme()
    isOpen[0] = true
    imgui.Begin("Deprau", isOpen, imgui.WindowFlags.AlwaysAutoResize)

    imgui.Text("On Foot")
    imgui.SliderFloat("Sens##onfoot", onfootSens, 0.0, 5.0, "%.2f")
    imgui.SliderFloat("Smooth##onfoot", onfootSmooth, 0.0, 20.0, "%.2f")
    
    imgui.Text("Vehicle")
    imgui.SliderFloat("Sens##vehicle", vehicleSens, 0.0, 5.0, "%.2f")
    imgui.SliderFloat("Smooth##vehicle", vehicleSmooth, 0.0, 20.0, "%.2f")

    if imgui.Button("Save", imgui.ImVec2(100, 30)) then
        saveConfig()
    end

    imgui.End()

    if not isOpen[0] then
        mainGui.state = false
    end
end)

sampRegisterChatCommand("pcm", function()
    mainGui.state = not mainGui.state
end)
