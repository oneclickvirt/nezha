param(
    [string]$server,
    [string]$key,
    [string]$tls
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "PowerShell 5 or newer is required. Current version: $($PSVersionTable.PSVersion.Major)" -BackgroundColor DarkRed -ForegroundColor White
    exit 1
}

$agentRepo = 'nezhahq/agent'
$apiUrls = @(
    'https://api.github.com',
    'https://githubapi.spiritlhl.workers.dev',
    'https://githubapi.spiritlhl.top'
)
$cdnUrls = @(
    'https://cdn0.spiritlhl.top/',
    'http://cdn3.spiritlhl.net/',
    'http://cdn1.spiritlhl.net/',
    'http://cdn2.spiritlhl.net/'
)
$jsdelivrUrls = @(
    'https://cdn.jsdelivr.net/gh/nezhahq/agent/',
    'https://fastly.jsdelivr.net/gh/nezhahq/agent/',
    'https://gcore.jsdelivr.net/gh/nezhahq/agent/'
)

function Get-AgentArchiveName {
    if ([System.Environment]::Is64BitOperatingSystem) {
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
            return 'nezha-agent_windows_arm64.zip'
        }
        return 'nezha-agent_windows_amd64.zip'
    }
    return 'nezha-agent_windows_386.zip'
}

function Get-LatestVersion {
    if ($env:INSTALL_VERSION) {
        return $env:INSTALL_VERSION
    }

    foreach ($api in $apiUrls) {
        try {
            $response = Invoke-RestMethod -Uri "$api/repos/$agentRepo/releases/latest" -Headers @{ 'User-Agent' = 'oneclickvirt-nezha-installer' } -TimeoutSec 20
            if ($response.tag_name) {
                return $response.tag_name
            }
        }
        catch {
        }
    }

    foreach ($url in $jsdelivrUrls) {
        try {
            $content = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10).Content
            $match = [regex]::Match($content, [regex]::Escape($agentRepo) + '@([^''"" <]+)')
            if ($match.Success) {
                return $match.Groups[1].Value
            }
        }
        catch {
        }
    }

    throw 'Unable to determine the latest agent version.'
}

function Download-FirstAvailable {
    param(
        [string[]]$Urls,
        [string]$OutputPath
    )

    foreach ($url in $Urls) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $OutputPath -UseBasicParsing -TimeoutSec 120
            if ((Test-Path $OutputPath) -and ((Get-Item $OutputPath).Length -gt 0)) {
                return
            }
        }
        catch {
        }
    }

    throw 'Failed to download the agent archive from all configured sources.'
}

if (-not $server) {
    $server = Read-Host 'Dashboard gRPC host:port'
}
if (-not $key) {
    $key = Read-Host 'Agent secret'
}
if (-not $server -or -not $key) {
    Write-Host 'Dashboard gRPC host:port and agent secret are required.' -BackgroundColor DarkRed -ForegroundColor White
    exit 1
}

$file = Get-AgentArchiveName
$version = Get-LatestVersion
$directUrl = "https://github.com/$agentRepo/releases/download/$version/$file"
$downloadUrls = @()
foreach ($cdn in $cdnUrls) {
    $downloadUrls += "$cdn$directUrl"
}
$downloadUrls += $directUrl

if (Test-Path 'C:\nezha\nezha-agent.exe') {
    & 'C:\nezha\nezha-agent.exe' service uninstall | Out-Null
    Remove-Item 'C:\nezha' -Recurse -Force
}

$zipPath = Join-Path $env:TEMP 'nezha-agent.zip'
$extractPath = Join-Path $env:TEMP 'nezha-agent'
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }

Download-FirstAvailable -Urls $downloadUrls -OutputPath $zipPath
Expand-Archive $zipPath -DestinationPath $extractPath -Force

if (!(Test-Path 'C:\nezha')) {
    New-Item -Path 'C:\nezha' -ItemType Directory | Out-Null
}

Move-Item -Path (Join-Path $extractPath 'nezha-agent.exe') -Destination 'C:\nezha\nezha-agent.exe' -Force
Remove-Item $zipPath -Force
Remove-Item $extractPath -Recurse -Force

$installArgs = @('service', 'install', '-s', $server, '-p', $key)
if ($tls) {
    $installArgs += $tls
}
& 'C:\nezha\nezha-agent.exe' @installArgs

Write-Host "Agent installed successfully from official $agentRepo release $version." -BackgroundColor DarkGreen -ForegroundColor White