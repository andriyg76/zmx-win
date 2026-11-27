# `zmx attach` from real consoles, as agterm-win runs a Live pane: the first attach creates the session with the pane's
# shell, and after that client is gone, an attach from another process finds the same daemon and shell and joins it.

BeforeAll { . (Join-Path $PSScriptRoot 'ZmxTestHelper.ps1') }

Describe 'attach from another process' {
    BeforeEach { New-ZmxSandbox; $script:Clients = @() }
    AfterEach {
        foreach ($c in $script:Clients) { $c.Dispose() }
        Remove-ZmxSandbox
    }

    It 'finds the shell an earlier attach started and attaches to it' {
        $shell = Get-ZmxPaneShell
        $first = Start-ZmxAttach t-pane @($shell)
        $script:Clients += $first
        Wait-ZmxSession t-pane 20
        Wait-Until { (Get-ZmxField t-pane clients) -eq '1' } 'the first client to attach'
        $daemon = [int](Get-ZmxField t-pane pid)
        Wait-Until { (Get-ZmxDaemonChildren $daemon).Count -eq 1 } "the daemon to start $shell" 20
        $pane = (Get-ZmxDaemonChildren $daemon)[0]
        $pane.Name | Should -Be ([IO.Path]::GetFileName($shell))

        $first.Write(((Get-ZmxEchoSplit 'first-' 'client') -join ' ') + "`r")
        Wait-ZmxOutput t-pane 'first-client' 20

        $first.Dispose()
        Wait-Until { (Get-ZmxField t-pane clients) -eq '0' } 'the first client to be dropped'
        Get-Process -Id $pane.ProcessId -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty

        # the same line again: a session already there ignores the command and only attaches
        $second = Start-ZmxAttach t-pane @($shell)
        $script:Clients += $second
        $second.Process.Id | Should -Not -Be $first.Process.Id
        Wait-Until { (Get-ZmxField t-pane clients) -eq '1' } 'the second client to attach'
        Get-ZmxSessionNames | Should -Be @('t-pane')
        [int](Get-ZmxField t-pane pid) | Should -Be $daemon
        (Get-ZmxDaemonChildren $daemon).ProcessId | Should -Be @($pane.ProcessId)

        # the replayed screen reaches the second client, and what it types runs in that shell
        Wait-Until { $second.Output.Contains('first-client') } 'the earlier output on the second client'
        $second.Write(((Get-ZmxEchoSplit 'second-' 'client') -join ' ') + "`r")
        Wait-Until { $second.Output.Contains('second-client') } 'the second client to see its own command' 20
        Wait-ZmxOutput t-pane 'second-client'
    }
}
