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

# ZMX_TEST_ARTIFACTS, when set (CI uploads it), keeps what a test leaves for diagnosis: one folder per test, with
# `zmx list`, the processes the sandbox's sessions run, and the files a test saves itself.
function Get-ZmxArtifactDir {
    if (-not $env:ZMX_TEST_ARTIFACTS) { return }
    $test = if ($____Pester -and $____Pester.CurrentTest) { $____Pester.CurrentTest.ExpandedPath } else { 'unknown' }
    $dir = Join-Path $env:ZMX_TEST_ARTIFACTS (($test -replace '[^\w.-]+', '_').Trim('_'))
    New-Item -ItemType Directory -Force $dir | Out-Null
    $dir
}

function Save-ZmxArtifact([string]$Name, [string]$Text) {
    $dir = Get-ZmxArtifactDir
    if ($dir) { [IO.File]::WriteAllText((Join-Path $dir $Name), $Text) }
}

function Remove-ZmxSandbox {
    if (-not $script:ZmxDir) { return }
    $listed = Invoke-ZmxProcess -Arguments @('list')
    Save-ZmxArtifact 'list.txt' $listed.Output
    Save-ZmxArtifact 'processes.txt' (Get-CimInstance Win32_Process | Where-Object { $_.Name -in 'zmx.exe', 'cmd.exe', 'powershell.exe', 'pwsh.exe', 'conhost.exe', 'OpenConsole.exe' } |
        Format-Table ProcessId, ParentProcessId, Name, CommandLine -AutoSize -Wrap | Out-String -Width 400)
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
