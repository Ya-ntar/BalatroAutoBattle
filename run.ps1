param(
    [ValidateSet('basic', 'discard')]
    [string] $Strategy = 'basic'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Strategy = $Strategy.ToLowerInvariant()

$workspaceRootPath = Split-Path -Parent $PSScriptRoot
$gameSourceDirectoryPath = Join-Path $workspaceRootPath 'balatro-src-reverse-engineering'
$loveExecutablePath = Join-Path $workspaceRootPath 'lovec.exe'
$autobattleModuleDirectoryPath = Join-Path $PSScriptRoot 'autobattle'
$gameDirectoryNames = 'engine', 'functions', 'localization', 'resources'
$requiredFilePaths = @($loveExecutablePath, (Join-Path $autobattleModuleDirectoryPath "strategies/$Strategy.lua"))
foreach ($gameFileName in 'main.lua', 'conf.lua', 'version.jkr') {
    $requiredFilePaths += Join-Path $gameSourceDirectoryPath $gameFileName
}
foreach ($requiredFilePath in $requiredFilePaths) {
    if (-not (Test-Path -LiteralPath $requiredFilePath -PathType Leaf)) {
        throw "Required file not found: $requiredFilePath"
    }
}
foreach ($gameDirectoryName in $gameDirectoryNames) {
    $gameDirectoryPath = Join-Path $gameSourceDirectoryPath $gameDirectoryName
    if (-not (Test-Path -LiteralPath $gameDirectoryPath -PathType Container)) {
        throw "Required directory not found: $gameDirectoryPath"
    }
}

$stagingDirectoryPath = Join-Path (Join-Path $PSScriptRoot '.run') ([System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingDirectoryPath -Force | Out-Null
Get-ChildItem -LiteralPath $gameSourceDirectoryPath -Filter '*.lua' -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $stagingDirectoryPath
}
Copy-Item -LiteralPath (Join-Path $gameSourceDirectoryPath 'version.jkr') -Destination $stagingDirectoryPath
foreach ($gameDirectoryName in $gameDirectoryNames) {
    Copy-Item -LiteralPath (Join-Path $gameSourceDirectoryPath $gameDirectoryName) -Destination $stagingDirectoryPath -Recurse
}
Copy-Item -LiteralPath $autobattleModuleDirectoryPath -Destination $stagingDirectoryPath -Recurse

$configHookLua = @'
local original_configure = love.conf
function love.conf(love_config)
    original_configure(love_config)
    love_config.identity = "balatro-autobattle-local"
end
'@

$mainHookLua = @'
G.F_SKIP_TUTORIAL = true
local original_splash_screen = G.splash_screen
function G:splash_screen(...)
    self.FUNCS.tutorial_controller()
    return original_splash_screen(self, ...)
end

local autobattle_controller = require("autobattle.controller").new(
    require("autobattle.game_adapter.init").new(G),
    require("autobattle.strategies.__STRATEGY__").decide,
    {step_delay_seconds = 0.15, action_timeout_seconds = 15},
    function(status_code, status_detail)
        print("[autobattle] " .. status_code .. (status_detail and (": " .. tostring(status_detail)) or ""))
    end
)

local original_update = love.update
function love.update(delta_seconds)
    original_update(delta_seconds)
    autobattle_controller.update(delta_seconds)
end

local original_keypressed = love.keypressed
function love.keypressed(key_name, scancode, is_repeat)
    if key_name == "f8" then
        if not is_repeat then autobattle_controller.toggle() end
        return
    end
    return original_keypressed(key_name, scancode, is_repeat)
end
'@

[System.IO.File]::AppendAllText((Join-Path $stagingDirectoryPath 'conf.lua'), "`n`n" + $configHookLua + "`n")
[System.IO.File]::AppendAllText((Join-Path $stagingDirectoryPath 'main.lua'), "`n`n" + $mainHookLua.Replace('__STRATEGY__', $Strategy) + "`n")

Write-Host "Starting Balatro AutoBattle from $stagingDirectoryPath with strategy '$Strategy'. Press F8 to toggle."
& $loveExecutablePath $stagingDirectoryPath
exit $LASTEXITCODE
