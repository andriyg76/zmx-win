# Shared helpers for the Windows integration suite (Pester 5). The Windows counterpart of test_helper.bash:
# every test gets its own ZMX_DIR, and the sessions it leaves are killed after it.
#
# ZMX_TEST_EXE   the zmx.exe under test (default zig-out\bin\zmx.exe)
# ZMX_TEST_SHELL the SHELL the sessions run (default: unset, so zmx picks PowerShell itself)

$script:RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:ZmxExe = if ($env:ZMX_TEST_EXE) { $env:ZMX_TEST_EXE } else { Join-Path $script:RepoDir 'zig-out\bin\zmx.exe' }
if (-not (Test-Path $script:ZmxExe)) { throw "zmx.exe not found at $script:ZmxExe; run 'zig build' first" }

function Get-ZmxShellKind {
    if ($env:ZMX_TEST_SHELL -and [IO.Path]::GetFileNameWithoutExtension($env:ZMX_TEST_SHELL) -eq 'cmd') { 'cmd' } else { 'powershell' }
}

function New-ZmxSandbox {
    # RUNNER_TEMP on CI: the runner's %TEMP% is an 8.3 short path, which cwd assertions would have to expand.
    $base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
    $script:ZmxDir = Join-Path $base("zmx-it-" + [Guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Path $script:ZmxDir | Out-Null
}

function Remove-ZmxSandbox {
    if (-not $script:ZmxDir) { return }
    $listed = Invoke-ZmxProcess -Arguments @('list')
    $names = Invoke-ZmxProcess -Arguments @('list', '--short')
    $sessions = @($names.Output -split "`n" | Where-Object { $_ })
    if ($sessions) { Invoke-ZmxProcess -Arguments (@('kill', '--force') + $sessions) | Out-Null }
    # A daemon that ignored kill would outlive the test and hold the sandbox open.
    foreach ($m in [regex]::Matches($listed.Output, 'pid=(\d+)')) {
        Stop-Process -Id ([int]$m.Groups[1].Value) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force $script:ZmxDir -ErrorAction SilentlyContinue
    $script:ZmxDir = $null
}

# Runs zmx.exe with the sandbox environment. Each argument reaches zmx as one argv entry.
function Invoke-ZmxProcess {
    param(
        [string[]]$Arguments = @(),
        [object]$Stdin,
        [int]$TimeoutSeconds = 15,
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = $script:RepoDir
    )
    $psi = [Diagnostics.ProcessStartInfo]::new($script:ZmxExe)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # Always a pipe: run and send read a missing command from stdin, so an inherited console would block them.
    $psi.RedirectStandardInput = $true
    $psi.WorkingDirectory = $WorkingDirectory
    foreach ($k in @($psi.Environment.Keys)) { if ($k -like 'ZMX_*') { $psi.Environment.Remove($k) | Out-Null } }
    $psi.Environment['ZMX_DIR'] = $script:ZmxDir
    if ($env:ZMX_TEST_SHELL) { $psi.Environment['SHELL'] = $env:ZMX_TEST_SHELL } else { $psi.Environment.Remove('SHELL') | Out-Null }
    foreach ($k in $Environment.Keys) {
        if ($null -eq $Environment[$k]) { $psi.Environment.Remove($k) | Out-Null } else { $psi.Environment[$k] = $Environment[$k] }
    }

    $p = [Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    if ($PSBoundParameters.ContainsKey('Stdin')) {
        # assigned per branch: an `if` expression would unroll an empty byte[] to $null
        if ($Stdin -is [string]) { $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Stdin) } else { $bytes = [byte[]]$Stdin }
        if ($bytes.Length) { $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length) }
    }
    $p.StandardInput.Close()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        $p.Kill($true)
        throw "zmx $($Arguments -join ' ') did not exit within ${TimeoutSeconds}s"
    }
    # A daemon that inherited the client's pipes would keep them open after the client exits.
    if (-not [Threading.Tasks.Task]::WaitAll(@($stdout, $stderr), 5000)) {
        throw "zmx $($Arguments -join ' ') exited but its output pipes stayed open"
    }
    [pscustomobject]@{
        Code   = $p.ExitCode
        Stdout = $stdout.Result
        Stderr = $stderr.Result
        Output = ($stdout.Result + $stderr.Result) -replace "`r`n", "`n"
    }
}

# `zmx run t -d echo hi` reads as written: a simple function keeps -d and --help in $args for zmx.
function zmx { Invoke-ZmxProcess -Arguments ([string[]]$args) }

function Wait-Until {
    param([scriptblock]$Condition, [string]$Message, [int]$TimeoutSeconds = 10)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out after ${TimeoutSeconds}s: $Message"
}

function Get-ZmxSessionNames { @((zmx list --short).Output -split "`n" | Where-Object { $_ }) }

function Wait-ZmxSession([string]$Name, [int]$TimeoutSeconds = 10) {
    Wait-Until { (Get-ZmxSessionNames) -contains $Name } "session '$Name' to appear" $TimeoutSeconds
}

function Wait-ZmxOutput([string]$Name, [string]$Marker, [int]$TimeoutSeconds = 10) {
    Wait-Until { (zmx history $Name).Output.Contains($Marker) } "'$Marker' in the history of '$Name'" $TimeoutSeconds
}

function Get-ZmxSessionLine([string]$Name) {
    (zmx list).Output -split "`n" | Where-Object { $_ -match "name=$([regex]::Escape($Name))\t" } | Select-Object -First 1
}

function Get-ZmxField([string]$Name, [string]$Field) {
    $line = Get-ZmxSessionLine $Name
    if ($line -match "(?:^|\t)$Field=([^\t]*)") { $Matches[1] }
}

function Get-ZmxCount([string]$Name, [string]$Needle) {
    ([regex]::Matches((zmx history $Name).Output, [regex]::Escape($Needle))).Count
}

# The words of a command that prints $Left$Right, assembled at runtime so that the marker shows up in history only
# as program output, never in the echoed command line. Words, because `zmx run` quotes an argument with a space.
function Get-ZmxEchoSplit([string]$Left, [string]$Right) {
    if ((Get-ZmxShellKind) -eq 'cmd') { @('set', "zx=$Left&&", 'call', 'echo', "%zx%$Right") } else { @('Write-Output', "('$Left'+'$Right')") }
}

# A client that speaks the attach handshake over the session's AF_UNIX socket and holds it open, standing in for
# `zmx attach`, which needs a console. Dispose the returned socket to detach.
function Connect-ZmxSession([string]$Name, [uint16]$Rows = 24, [uint16]$Cols = 80) {
    $s = [Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::Unix, [Net.Sockets.SocketType]::Stream, [Net.Sockets.ProtocolType]::Unspecified)
    $s.Connect([Net.Sockets.UnixDomainSocketEndPoint]::new("$script:ZmxDir/$Name"))
    $payload = [BitConverter]::GetBytes($Rows) + [BitConverter]::GetBytes($Cols) + [byte[]]::new(4)  # ipc.Resize
    $header = [byte[]](7, 1, 0, 0) + [BitConverter]::GetBytes([uint32]$payload.Length)                # ipc.Header, tag Init
    $s.Send([byte[]]($header + $payload)) | Out-Null
    $s
}

# every test file dot-sources this, and a type is added once per PowerShell session
if (-not ('ZmxConPty' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'ZmxConPty.cs') }

# The shell a terminal pane runs: ZMX_TEST_SHELL, else the PowerShell zmx picks itself.
function Get-ZmxPaneShell { if ($env:ZMX_TEST_SHELL) { $env:ZMX_TEST_SHELL } else { 'powershell.exe' } }

# `zmx attach <name> <command...>` in a process of its own under a pseudo console, as agterm-win starts a Live pane:
# it creates the session with that command, or attaches to the one already there. Dispose it to end the client.
function Start-ZmxAttach([string]$Name, [string[]]$Command = @(), [int16]$Rows = 24, [int16]$Cols = 80) {
    $environment = @{}
    foreach ($e in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        if ($e.Key -notlike 'ZMX_*' -and $e.Key -ne 'SHELL') { $environment[$e.Key] = $e.Value }
    }
    $environment['ZMX_DIR'] = $script:ZmxDir
    $environment['ZMX_NO_DETACH_KEY'] = '1'
    if ($env:ZMX_TEST_SHELL) { $environment['SHELL'] = $env:ZMX_TEST_SHELL }
    $line = (@($script:ZmxExe, 'attach', $Name) + $Command | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    [ZmxConPty]::new($line, $environment, $script:RepoDir, $Rows, $Cols)
}

# The processes the session's daemon started, conhost aside: the shell it runs.
function Get-ZmxDaemonChildren([int]$DaemonId) {
    @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$DaemonId" | Where-Object { $_.Name -notin 'conhost.exe', 'OpenConsole.exe' })
}
