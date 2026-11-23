# CLI argument validation on Windows: the counterpart of test/cli.bats.

BeforeAll { . (Join-Path $PSScriptRoot 'ZmxTestHelper.ps1') }

Describe 'invalid commands exit non-zero' {
    BeforeEach { New-ZmxSandbox }
    AfterEach { Remove-ZmxSandbox }

    It 'unknown command <_>' -ForEach @('foo', 'not-a-real-command') {
        $r = zmx $_
        $r.Code | Should -Not -Be 0
        $r.Output | Should -BeLike '*unknown command*'
    }

    It 'completions with an unknown shell' {
        $r = zmx completions foo
        $r.Code | Should -Not -Be 0
        $r.Output | Should -BeLike '*unknown shell*'
    }

    It 'completions without a shell' {
        $r = zmx completions
        $r.Code | Should -Not -Be 0
        $r.Output | Should -BeLike '*shell argument*'
    }

    It '<_> without a session name' -ForEach @('kill', 'wait', 'tail', 'send', 'print', 'write', 'history', 'get', 'set', 'clear', 'print-env') {
        $r = Invoke-ZmxProcess -Arguments @($_) -Environment @{ ZMX_SESSION = $null }
        $r.Code | Should -Not -Be 0
        $r.Output | Should -BeLike '*session name required*'
    }

    It 'detach outside a session' {
        $r = zmx detach
        $r.Code | Should -Not -Be 0
        $r.Output | Should -BeLike '*not inside a zmx session*'
    }

    It 'write without a file path' {
        $r = zmx write dummy_session
        $r.Code | Should -Not -Be 0
        $r.Output | Should -BeLike '*file path required*'
    }

    It 'attach with --labels and no value' {
        $r = zmx attach --labels
        $r.Code | Should -Not -Be 0
        $r.Output | Should -BeLike '*--labels requires*'
    }
}

Describe 'valid commands exit zero' {
    BeforeEach { New-ZmxSandbox }
    AfterEach { Remove-ZmxSandbox }

    It 'help' { (zmx help).Code | Should -Be 0 }

    It 'version reports the sandbox socket dir' {
        $r = zmx version
        $r.Code | Should -Be 0
        $r.Output | Should -BeLike "*socket_dir*$script:ZmxDir*"
    }

    It 'completions <_>' -ForEach @('bash', 'zsh', 'fish') {
        (zmx completions $_).Code | Should -Be 0
    }

    It '<_> --help and -h print usage without creating a session' -ForEach @('attach', 'run', 'send', 'print', 'write', 'kill', 'wait', 'tail', 'history', 'list', 'completions') {
        foreach ($flag in '--help', '-h') {
            $r = zmx $_ $flag
            $r.Code | Should -Be 0
            $r.Output | Should -BeLike '*Usage:*'
        }
        Get-ZmxSessionNames | Should -BeNullOrEmpty
    }
}
