# Behavior specific to the Windows port: argument quoting for cmd and PowerShell, drive-letter cwds in OSC 7 form,
# and re-attach over the session's AF_UNIX socket.

BeforeAll { . (Join-Path $PSScriptRoot 'ZmxTestHelper.ps1') }

Describe 'run argument quoting' {
    BeforeEach { New-ZmxSandbox }
    AfterEach { Remove-ZmxSandbox }

    It 'keeps an argument with spaces as one argument' {
        zmx run t-quote -d echo 'two  spaces' | Out-Null
        Wait-ZmxSession t-quote
        # Once in the echoed command line, once more as the command's output.
        Wait-Until { (Get-ZmxCount t-quote 'two  spaces') -ge 2 } "'two  spaces' printed as one argument"
    }

    It 'passes an argument without spaces verbatim' {
        Invoke-ZmxProcess -Arguments (@('run', 't-verbatim', '-d') + (Get-ZmxEchoSplit 'verbatim-' 'marker')) | Out-Null
        Wait-ZmxOutput t-verbatim 'verbatim-marker'
    }
}

Describe 'cwd' {
    BeforeEach {
        New-ZmxSandbox
        $script:SpacedDir = Join-Path $script:ZmxDir 'zmx spaced dir'
        New-Item -ItemType Directory $script:SpacedDir | Out-Null
    }
    AfterEach { Remove-ZmxSandbox }

    It 'list reports a drive-letter cwd as an OSC 7 URI with the host' {
        # `zmx __daemon` is not handed the client's cwd; only a shell that reports its own (PowerShell) fills it in.
        if ((Get-ZmxShellKind) -eq 'cmd') { Set-ItResult -Skipped -Because 'the daemon learns no cwd from the client yet' }
        Invoke-ZmxProcess -Arguments @('run', 't-cwd-uri', '-d', 'echo', 'hi') -WorkingDirectory $script:SpacedDir | Out-Null
        Wait-ZmxSession t-cwd-uri
        # Decoded before the compare: whether the reported URI escapes the spaces is a separate question.
        $uri = 'file://' + [Environment]::MachineName + '/' + ($script:SpacedDir -replace '\\', '/')
        Wait-Until { (Get-ZmxField t-cwd-uri cwd) } 'the session to report a cwd'
        [Uri]::UnescapeDataString((Get-ZmxField t-cwd-uri cwd)) | Should -Be $uri
    }

    It 'a new session starts in a cwd whose name needed escaping' {
        $print = if ((Get-ZmxShellKind) -eq 'cmd') { 'cd' } else { '(Get-Location).Path' }
        Invoke-ZmxProcess -Arguments @('run', 't-cwd-chdir', '-d', $print) -WorkingDirectory $script:SpacedDir | Out-Null
        Wait-ZmxOutput t-cwd-chdir 'zmx spaced dir'
    }

    # Not reflected in `list` yet: the OSC 7 a session command writes does not reach the daemon through ConPTY.
    It 'an OSC 7 from the session replaces the cwd, remote host included' -Skip {
        if ((Get-ZmxShellKind) -eq 'cmd') { Set-ItResult -Skipped -Because 'cmd cannot emit an escape sequence from a typed line' }
        zmx run t-cwd-osc7 -d "[Console]::Write([char]27+']7;file://some-remote-box/home/me'+[char]7)" | Out-Null
        Wait-ZmxSession t-cwd-osc7
        Wait-Until { (Get-ZmxField t-cwd-osc7 cwd) -eq 'file://some-remote-box/home/me' } 'the cwd to follow the OSC 7'
    }
}

Describe 'attach and detach' {
    BeforeEach { New-ZmxSandbox }
    AfterEach { Remove-ZmxSandbox }

    It 'counts an attached client and keeps the session after it detaches' {
        zmx run t-attach -d echo ready | Out-Null
        Wait-ZmxOutput t-attach ready

        $client = Connect-ZmxSession t-attach
        try {
            Wait-Until { (Get-ZmxField t-attach clients) -eq '1' } 'the client to be counted'
        } finally {
            $client.Dispose()
        }
        Wait-Until { (Get-ZmxField t-attach clients) -eq '0' } 'the client to be dropped'
        Get-ZmxSessionNames | Should -Contain 't-attach'
    }

    It 'keeps running commands across re-attaches at the same and a new size' {
        zmx run t-reattach -d echo ready | Out-Null
        Wait-ZmxOutput t-reattach ready

        foreach ($size in @(24, 80), @(24, 80), @(40, 120)) {
            $client = Connect-ZmxSession t-reattach -Rows $size[0] -Cols $size[1]
            Start-Sleep -Milliseconds 300
            $client.Dispose()
        }
        Invoke-ZmxProcess -Arguments (@('run', 't-reattach', '-d') + (Get-ZmxEchoSplit 'after-' 'reattach')) | Out-Null
        Wait-ZmxOutput t-reattach 'after-reattach'
    }
}

Describe 'labels' {
    BeforeEach { New-ZmxSandbox }
    AfterEach { Remove-ZmxSandbox }

    It 'set, get and clear a label' {
        zmx run t-label -d echo hi | Out-Null
        Wait-ZmxSession t-label

        (zmx set t-label project=zmx).Code | Should -Be 0
        (zmx get t-label project).Output.Trim() | Should -Be 'zmx'
        Get-ZmxSessionLine t-label | Should -BeLike '*project=zmx*'

        (zmx clear t-label).Code | Should -Be 0
        Get-ZmxSessionLine t-label | Should -Not -BeLike '*project=zmx*'
    }
}
