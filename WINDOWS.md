# zmx-win

zmx-win is a fork of [neurosnap/zmx](https://github.com/neurosnap/zmx) that runs zmx on Windows. It is maintained
for [agterm-win](https://github.com/andriyg76/agterm-win), the Windows port of
[agterm](https://github.com/umputun/agterm), which ships this zmx as its session daemon.

The `windows` branch is upstream zmx v1.0.1 (`a35f00a`) plus two series of commits on top of it. Upstream files
change only where Windows needs it, so a later upstream release can be rebased in.

It is not a vanilla port of upstream zmx: it is zmx as agterm ships it.

- **agterm's patches included.** The same zmx patch series agterm applies on macOS and Linux is built in
  ([table below](#agterms-zmx-patches)): explicit leadership, detached create, hold until attach, output drained
  on exit, reclaiming a dropped lead, and more. A session behaves as an agterm Live session does on a Mac.
- **Tested on Windows.** A [Pester](https://pester.dev/) integration suite runs every release build on
  windows-2022, windows-2025 and windows-11-arm, with PowerShell and cmd as the session shell. It drives real
  ConPTY sessions through create, attach from a second process, detach and re-attach at a new size, `run`, `send`,
  `print`, `write`, `history`, `wait`, `kill`, labels, cwd tracking over OSC 7, argument quoting, and agterm's
  detached-create and hold-until-attach patches ([Tests and releases](#tests-and-releases)).

## Use zmx-win on its own

zmx-win works without agterm-win in any Windows terminal, Windows Terminal included.

1. Download `zmx-x64.exe` or `zmx-arm64.exe` from the [latest release](https://github.com/andriyg76/zmx-win/releases/latest) and check it against `zmx.sha256`.
2. Rename it to `zmx.exe` and put it in a folder on your `PATH`.
3. Start or reattach a session:

```powershell
zmx attach work            # PowerShell, the default shell
zmx attach build cmd.exe   # any other command
zmx list                   # sessions and their clients
zmx detach                 # detach every client; closing the window detaches too
zmx history work           # the session's scrollback as text
zmx kill build
```

The session keeps running after you detach or close the window, and `zmx attach` with the same name brings its screen back.
`zmx version` prints the socket and log folders. The commands are upstream's; [zmx.sh](https://zmx.sh) documents them.
For persistent sessions in a sidebar terminal with a control API, use [agterm-win](https://github.com/andriyg76/agterm-win), which bundles this zmx.

## agterm's zmx patches

agterm builds zmx from upstream with the patches in its
[`scripts/zmx-patches`](https://github.com/umputun/agterm/tree/master/scripts/zmx-patches), whose README explains
each one. This fork carries the same series as `agterm: NNNN-name` commits, so the Windows build behaves as agterm's
macOS and Linux builds do and nothing is applied over it.

| Patch | What it adds |
|---|---|
| 0001 explicit-leadership | a terminal decides which client leads a session (`ZMX_MANAGED`); `zmx screen` and `zmx type` |
| 0003 atomic-socket-publish | a session socket gets its name only once it listens |
| 0004 managed-exit-keeps-screen | a managed client's exit keeps the screen instead of a full reset |
| 0005 detached-create | `attach --detached NAME [command...]` creates a session without attaching; `ZMX_EXIT_FILE` |
| 0006 single-da-answer | a DA query is answered once, not by both the daemon and the terminal |
| 0007 drain-output-on-exit | a session's last output reaches its clients when the shell exits |
| 0008 reclaim-dropped-lead | an attach takes back a lead it lost with its connection |
| 0009 legacy-ipc | the client still reaches daemons of agterm's zmx 0.8.1 |
| 0010 caller-owned-socket-path | backport of upstream `f5d604e`, a shutdown abort under Zig 0.17 |
| 0011 init-keeps-frame-boundary | a client's first Init never splits a half-sent frame |
| 0012 bounded-signal-cleanup | an attach stopped by a signal exits while nothing reads its terminal |
| 0013 hold-until-attach | `ZMX_HOLD_UNTIL_ATTACH=<seconds>` holds a detached create's command until a terminal attaches |

## The Windows port

Windows has no fork, pty or Unix signals, so the port replaces them:

- A session runs its command in a ConPTY pseudo console, inside a job object that ends everything it started.
- The client starts the daemon as a new process, `zmx __daemon NAME ROWS COLS task|session HOLD -- ARGV...`,
  in place of the double fork.
- Sessions talk over Windows' AF_UNIX sockets, in `ZMX_DIR` as on other systems.
- The default shell is PowerShell. `zmx run` and `zmx write` work in PowerShell and cmd sessions, with each
  shell's own syntax for the exit marker.
- A Windows cwd travels as an OSC 7 URI in the form Windows terminals use; only drive-letter paths are converted.
- Daemons log to `%LOCALAPPDATA%\zmx\logs`, whatever `ZMX_DIR` is.
- `src/win` holds the Windows code: the Win32 API, the pseudo console, and the POSIX and stdio shims the rest of
  zmx is written against.

## Tests and releases

- `windows.yml` runs the unit tests and the [Pester](https://pester.dev/) integration suite in `test/windows` on
  windows-2022, windows-2025 and windows-11-arm, with PowerShell and with cmd as the session shell.
  `CONTRIBUTING.md` says how to run them locally.
- `windows-release.yml`, run by hand, builds zmx for x64 and arm64 at a commit, tests each build, and publishes
  release `v<upstream>.<build>` with `zmx-x64.exe`, `zmx-arm64.exe`, `zmx.sha256` and `LICENSE`. `<upstream>` is
  the zmx version in `build.zig.zon`, and `<build>` counts this fork's releases of it from 1.
- agterm-win's `fetch-zmx.ps1` downloads a release and checks it against the sha256 pinned there, not the release's
  own `zmx.sha256`.
