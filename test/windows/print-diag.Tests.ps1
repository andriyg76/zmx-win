BeforeAll { . "$PSScriptRoot\ZmxTestHelper.ps1" }

# Temporary diagnostics for https://github.com/andriyg76/zmx-win/issues/4. Not for merging.
Describe 'print diagnostics (#4)' {
    BeforeEach { New-ZmxSandbox }
    AfterEach { Remove-ZmxSandbox }

    It 'records what happens to printed text' {
        function Show([string]$s) {
            ($s -replace "`e", '\e' -replace "`r", '\r' -replace "`n", "\n`n" -replace "`a", '\a' -replace "`b", '\b')
        }
        $lost = 0
        for ($i = 1; $i -le 20; $i++) {
            $name = "t-diag-$i"
            $marker = "diag-marker-$i-q"
            zmx run $name -d echo ready | Out-Null
            Wait-ZmxSession $name

            # tail is a read-only client: it gets every PTY read and the print payload, in the daemon's order
            $psi = [Diagnostics.ProcessStartInfo]::new($script:ZmxExe)
            $psi.ArgumentList.Add('tail'); $psi.ArgumentList.Add($name)
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
            $psi.Environment['ZMX_DIR'] = $script:ZmxDir
            if ($env:ZMX_TEST_SHELL) { $psi.Environment['SHELL'] = $env:ZMX_TEST_SHELL }
            $tail = [Diagnostics.Process]::Start($psi)
            $tailOut = $tail.StandardOutput.ReadToEndAsync()
            Wait-ZmxOutput $name ready 20
            $before = (zmx history --vt $name).Output

            $t0 = [DateTime]::UtcNow
            (Invoke-ZmxProcess -Arguments @('print', $name) -Stdin "`r`n$marker`r`n").Code | Should -Be 0
            $snaps = [ordered]@{}
            foreach ($ms in 0, 100, 500, 2000, 6000) {
                $wait = $ms - ([DateTime]::UtcNow - $t0).TotalMilliseconds
                if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
                $snaps["$ms"] = (zmx history --vt $name).Output
            }
            $tail.Kill($true); [void]$tailOut.Wait(5000)
            $seen = ($snaps.Keys | ForEach-Object { if ($snaps[$_].Contains($marker)) { "$_=Y" } else { "$_=n" } }) -join ' '
            Write-Host "iteration $i : $seen"
            if (-not $snaps['6000'].Contains($marker)) {
                $lost++
                Write-Host "===== LOST in iteration $i ====="
                Write-Host "--- history --vt before print ---`n$(Show $before)"
                foreach ($k in $snaps.Keys) { Write-Host "--- history --vt at +${k}ms ---`n$(Show $snaps[$k])" }
                Write-Host "--- raw tail stream ---`n$(Show $tailOut.Result)"
            }
            zmx kill --force $name | Out-Null
        }
        Write-Host "lost $lost of 20"
        $lost | Should -Be 0
    }
}
