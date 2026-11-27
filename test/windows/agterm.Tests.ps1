# The agterm patches the port carries (scripts/zmx-patches in agterm), as agterm-win uses them on Windows:
# 0005 creates a session without attaching, and 0013 holds its command until a terminal attaches.

BeforeAll {
    . (Join-Path $PSScriptRoot 'ZmxTestHelper.ps1')
    # a command that leaves a file behind, which shows whether it ran
    function Get-TouchCommand([string]$Path) { @('cmd.exe', '/c', 'type', 'nul', '>', $Path) }
}

Describe 'attach --detached (0005)' {
    BeforeEach { New-ZmxSandbox }
    AfterEach { Remove-ZmxSandbox }

    It 'creates the session and returns without attaching' {
        $ran = Join-Path $script:ZmxDir 'ran'
        # /k keeps cmd, and with it the session, running after the touch
        $r = Invoke-ZmxProcess -Arguments @('attach', '--detached', 't-detached', 'cmd.exe', '/k', 'type', 'nul', '>', $ran)
        $r.Code | Should -Be 0
        Wait-ZmxSession t-detached
        Get-ZmxField t-detached clients | Should -Be '0'
        try {
            Wait-Until { Test-Path $ran } 'the command to run'
        } finally {
            Save-ZmxArtifact 'history.txt' (zmx history t-detached).Output
            Save-ZmxArtifact 'create.txt' $r.Output
        }
    }

    It 'refuses a session that exists' {
        (Invoke-ZmxProcess -Arguments @('attach', '--detached', 't-detached-twice', 'cmd.exe')).Code | Should -Be 0
        Wait-ZmxSession t-detached-twice
        $r = Invoke-ZmxProcess -Arguments @('attach', '--detached', 't-detached-twice', 'cmd.exe')
        $r.Code | Should -Not -Be 0
        $r.Output | Should -BeLike '*exists*'
    }
}

Describe 'ZMX_HOLD_UNTIL_ATTACH (0013)' {
    BeforeEach { New-ZmxSandbox; $script:Ran = Join-Path $script:ZmxDir 'ran' }
    AfterEach { Remove-ZmxSandbox }

    It 'runs the command only once a terminal attaches' {
        $r = Invoke-ZmxProcess -Arguments (@('attach', '--detached', 't-hold') + (Get-TouchCommand $script:Ran)) -Environment @{ ZMX_HOLD_UNTIL_ATTACH = '30' }
        $r.Code | Should -Be 0
        Wait-ZmxSession t-hold
        Start-Sleep -Seconds 2
        Test-Path $script:Ran | Should -BeFalse

        $client = Connect-ZmxSession t-hold
        try {
            Wait-Until { Test-Path $script:Ran } 'the attach to release the command'
        } finally {
            $client.Dispose()
        }
    }

    It 'runs the command at its bound when nothing attaches' {
        Invoke-ZmxProcess -Arguments (@('attach', '--detached', 't-hold-bound') + (Get-TouchCommand $script:Ran)) -Environment @{ ZMX_HOLD_UNTIL_ATTACH = '2' } | Out-Null
        Wait-ZmxSession t-hold-bound
        Wait-Until { Test-Path $script:Ran } 'the bound to release the command' 15
    }

    It 'never runs the command of a session killed before it attaches' {
        Invoke-ZmxProcess -Arguments (@('attach', '--detached', 't-hold-kill') + (Get-TouchCommand $script:Ran)) -Environment @{ ZMX_HOLD_UNTIL_ATTACH = '30' } | Out-Null
        Wait-ZmxSession t-hold-kill
        (zmx kill t-hold-kill).Code | Should -Be 0
        Start-Sleep -Seconds 2
        Test-Path $script:Ran | Should -BeFalse
    }

    It 'rejects a hold that is not whole seconds above zero' {
        foreach ($bad in '0', 'abc') {
            $r = Invoke-ZmxProcess -Arguments @('attach', '--detached', 't-hold-bad', 'cmd.exe') -Environment @{ ZMX_HOLD_UNTIL_ATTACH = $bad }
            $r.Code | Should -Not -Be 0
            $r.Output | Should -BeLike '*invalid ZMX_HOLD_UNTIL_ATTACH*'
        }
        Get-ZmxSessionNames | Should -BeNullOrEmpty
    }

    It 'does not pass the variable to the command' {
        $seen = Join-Path $script:ZmxDir 'seen'
        Invoke-ZmxProcess -Arguments @('attach', '--detached', 't-hold-env', 'cmd.exe', '/c', 'set', 'ZMX_HOLD', '>', $seen) -Environment @{ ZMX_HOLD_UNTIL_ATTACH = '1' } | Out-Null
        Wait-ZmxSession t-hold-env
        Wait-Until { (Test-Path $seen) -and (Get-Item $seen).Length -ge 0 } 'the command to run' 15
        Start-Sleep -Milliseconds 500
        Get-Content $seen -Raw | Should -Not -BeLike '*ZMX_HOLD_UNTIL_ATTACH=*'
    }
}
