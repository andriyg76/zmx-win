# Session lifecycle on Windows against real daemons and ConPTY: the counterpart of test/session.bats.
# `-d` comes after the session name (zmx run <name> -d <cmd>), because a blocking run waits for its command.

BeforeAll { . (Join-Path $PSScriptRoot 'ZmxTestHelper.ps1') }

Describe 'run' {
    BeforeEach { New-ZmxSandbox }
    AfterEach { Remove-ZmxSandbox }

    It 'creates a session' {
        $r = zmx run t-create -d echo hello
        $r.Code | Should -Be 0
        $r.Output | Should -BeLike '*session "t-create" created*'
        Wait-ZmxSession t-create
        Get-ZmxSessionNames | Should -Be @('t-create')
    }

    It 'sends a command to an existing session' {
        zmx run t-send -d echo first | Out-Null
        Wait-ZmxSession t-send

        $r = zmx run t-send -d echo second
        $r.Code | Should -Be 0
        $r.Output | Should -BeLike '*command sent*'
        $r.Output | Should -Not -BeLike '*created*'
        Wait-ZmxOutput t-send second
    }

    It 'blocks until the command completes and reports its exit code' {
        $ok = Invoke-ZmxProcess -Arguments @('run', 't-block', 'cmd', '/c', 'exit 0') -TimeoutSeconds 30
        $ok.Code | Should -Be 0
        $ok.Output | Should -BeLike '*session "t-block" created*'

        $failed = Invoke-ZmxProcess -Arguments @('run', 't-block', 'cmd', '/c', 'exit 3') -TimeoutSeconds 30
        $failed.Code | Should -Be 3
    }

    It 'passes a -d after the command to the command' {
        $r = Invoke-ZmxProcess -Arguments @('run', 't-dash-d', 'cmd', '/c', 'echo', 'arg=-d') -TimeoutSeconds 30
        $r.Code | Should -Be 0
        $r.Output | Should -Not -BeLike '*command sent*'
        Wait-ZmxOutput t-dash-d 'arg=-d'
    }

    It 'requires a command' {
        (zmx run t-nocmd).Code | Should -Not -Be 0
        Get-ZmxSessionNames | Should -BeNullOrEmpty
    }

    It 'does not truncate history when a long command line creates the session' {
        zmx run t-long -d echo ('1234567890' * 13) | Out-Null
        Wait-ZmxOutput t-long '12345678901234567890'
        (zmx history t-long).Output | Should -Not -BeLike '*<1234567890*'
    }
}

Describe 'list' {
    BeforeEach { New-ZmxSandbox }
    AfterEach { Remove-ZmxSandbox }

    It 'reports no sessions in an empty dir' {
        foreach ($cmd in 'list', 'ls') {
            $r = zmx $cmd
            $r.Code | Should -Be 0
            $r.Output | Should -BeLike '*no sessions found*'
        }
        (zmx list --short).Output | Should -BeNullOrEmpty
    }

    It 'shows session details' {
        zmx run t-list -d echo hello | Out-Null
        Wait-ZmxSession t-list
        Get-ZmxField t-list pid | Should -Match '^\d+$'
        Get-ZmxField t-list clients | Should -Be '0'
    }

    It '--short lists every session by name' {
        zmx run t-short-a -d echo a | Out-Null
        zmx run t-short-b -d echo b | Out-Null
        Wait-ZmxSession t-short-a
        Wait-ZmxSession t-short-b
        Get-ZmxSessionNames | Sort-Object | Should -Be @('t-short-a', 't-short-b')
    }

    It 'keeps sessions of one ZMX_DIR invisible to another' {
        zmx run t-isolated -d echo hi | Out-Null
        Wait-ZmxSession t-isolated

        $other = Join-Path $script:ZmxDir 'other'
        New-Item -ItemType Directory $other | Out-Null
        $r = Invoke-ZmxProcess -Arguments @('list', '--short') -Environment @{ ZMX_DIR = $other }
        $r.Code | Should -Be 0
        $r.Output | Should -BeNullOrEmpty
    }
}

Describe 'kill' {
    BeforeEach { New-ZmxSandbox }
    AfterEach { Remove-ZmxSandbox }

    It 'removes a session and ends its daemon' {
        zmx run t-kill -d echo hi | Out-Null
        Wait-ZmxSession t-kill
        $daemon = [int](Get-ZmxField t-kill pid)

        $r = zmx kill t-kill
        $r.Code | Should -Be 0
        $r.Output | Should -BeLike '*killed session t-kill*'
        Get-ZmxSessionNames | Should -Not -Contain 't-kill'
        Wait-Until { -not (Get-Process -Id $daemon -ErrorAction SilentlyContinue) } "daemon $daemon to exit"
    }

    It 'kills several sessions at once' {
        zmx run kill-a -d echo a | Out-Null
        zmx run kill-b -d echo b | Out-Null
        Wait-ZmxSession kill-a
        Wait-ZmxSession kill-b

        $r = zmx kill kill-a kill-b
        $r.Code | Should -Be 0
        $r.Output | Should -BeLike '*killed session kill-a*'
        $r.Output | Should -BeLike '*killed session kill-b*'
        Get-ZmxSessionNames | Should -BeNullOrEmpty
    }

    It '--force cleans up after a daemon that died' {
        zmx run t-force -d echo hi | Out-Null
        Wait-ZmxSession t-force
        $daemon = [int](Get-ZmxField t-force pid)
        Stop-Process -Id $daemon -Force
        Wait-Until { -not (Get-Process -Id $daemon -ErrorAction SilentlyContinue) } "daemon $daemon to exit"

        (zmx kill --force t-force).Code | Should -Be 0
        Get-ZmxSessionNames | Should -Not -Contain 't-force'
    }

    It 'survives creating and killing sessions in a row' {
        foreach ($i in 1..5) {
            zmx run "churn-$i" -d echo "iteration $i" | Out-Null
            Wait-ZmxSession "churn-$i"
            (zmx kill "churn-$i").Code | Should -Be 0
        }
        Get-ZmxSessionNames | Should -BeNullOrEmpty
    }
}

Describe 'history, wait, send and print' {
    BeforeEach { New-ZmxSandbox }
    AfterEach { Remove-ZmxSandbox }

    It 'history captures session output' {
        Invoke-ZmxProcess -Arguments (@('run', 't-hist', '-d') + (Get-ZmxEchoSplit 'pester-marker-' 'xyzzy')) | Out-Null
        Wait-ZmxOutput t-hist 'pester-marker-xyzzy'
        (zmx history t-hist).Code | Should -Be 0
    }

    It 'wait returns once the command completes' {
        zmx run t-wait -d echo done | Out-Null
        Wait-ZmxSession t-wait
        (Invoke-ZmxProcess -Arguments @('wait', 't-wait') -TimeoutSeconds 20).Code | Should -Be 0
    }

    It 'send types piped stdin into the session' {
        zmx run t-send-pipe -d echo ready | Out-Null
        Wait-ZmxOutput t-send-pipe ready

        $r = Invoke-ZmxProcess -Arguments @('send', 't-send-pipe') -Stdin (((Get-ZmxEchoSplit 'piped-marker-' 'xyz789') -join ' ') + "`r")
        $r.Code | Should -Be 0
        Wait-ZmxOutput t-send-pipe 'piped-marker-xyz789'
    }

    It 'send without a text argument fails' {
        zmx run t-send-notext -d echo hi | Out-Null
        Wait-ZmxSession t-send-notext
        (zmx send t-send-notext).Code | Should -Not -Be 0
    }

    It 'print puts text into the terminal state' {
        zmx run t-print -d echo ready | Out-Null
        Wait-ZmxOutput t-print ready

        $r = Invoke-ZmxProcess -Arguments @('print', 't-print') -Stdin "`r`npester-print-marker-abc123`r`n"
        $r.Code | Should -Be 0
        Wait-ZmxOutput t-print 'pester-print-marker-abc123'
    }

    # The daemon types a POSIX `printf | base64 -d` pipeline into the shell, which PowerShell and cmd lack.
    It 'write delivers a file larger than the console input buffer whole' -Skip {
        $src = Join-Path $script:ZmxDir 'src.bin'
        $dst = Join-Path $script:ZmxDir 'dst.bin'
        $bytes = [byte[]]::new(400000)
        [Random]::new(7).NextBytes($bytes)
        [IO.File]::WriteAllBytes($src, $bytes)

        zmx run t-write -d echo write-ready | Out-Null
        Wait-ZmxOutput t-write write-ready
        $r = Invoke-ZmxProcess -Arguments @('write', 't-write', $dst) -Stdin $bytes -TimeoutSeconds 30
        $r.Code | Should -Be 0
        Wait-Until { (Test-Path $dst) -and (Get-FileHash $dst).Hash -eq (Get-FileHash $src).Hash } 'the written file to match' 30
    }
}
