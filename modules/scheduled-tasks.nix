# scheduledTasks — Windows Task Scheduler entries, converged natively.
#
# This replaces ComputerManagementDsc/ScheduledTask, which cost a full Windows
# PowerShell 5.1 adapter spawn per task (measured at 2.02 s each, ~18 s for
# eleven) and — worse — silently failed: on a real host every `Daily` and `Once`
# task was reported in-desired-state while not existing at all, because the
# 64 KB result document nobody reads was the only place a discrepancy could
# have shown up.
#
# Option names follow launchd/systemd where the concept genuinely corresponds,
# per the usual "dedupe against the platform that already models this" rule:
#
#   nix-darwin launchd            systemd                   here
#   ------------------------------------------------------------------
#   serviceConfig.ProgramArguments  ExecStart               command/arguments
#   serviceConfig.RunAtLoad         (unit wants + WantedBy) runAtLogon
#   serviceConfig.StartInterval     timerConfig.OnUnitActiveSec  startInterval
#   serviceConfig.StartCalendarInterval  timerConfig.OnCalendar  startCalendar
#   (none)                        restartTriggers          restartTriggers
#
# Genuinely Windows-only concepts (there is no honest launchd/systemd analogue)
# are quarantined under `principal` and `multipleInstances` rather than forced
# into a shared name that would mislead.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.scheduledTasks;

  enabled = lib.filterAttrs (_: t: t.enable) cfg;

  # A fixed past instant for interval triggers. Task Scheduler models "every N
  # seconds forever" as a one-shot trigger with a repetition attached, so it
  # needs a start boundary; any past timestamp behaves identically.
  intervalEpoch = "2024-01-01T00:00:00";

  tasksJson = pkgs.writeText "scheduled-tasks.json" (
    builtins.toJSON (
      lib.mapAttrsToList (name: t: {
        inherit name;
        inherit (t)
          description
          command
          arguments
          workingDirectory
          runAtLogon
          runAtUnlock
          startInterval
          multipleInstances
          executionTimeLimit
          ;
        startCalendar = t.startCalendar;
        # A digest, not the strings: the artifact only has to tell the next
        # generation whether they changed.
        restartStamp =
          if t.restartTriggers == [ ] then
            null
          else
            builtins.hashString "sha256" (lib.concatStringsSep "\n" t.restartTriggers);
        principal = {
          inherit (t.principal)
            userName
            builtInAccount
            logonType
            runLevel
            ;
        };
        intervalStart = intervalEpoch;
      }) enabled
    )
  );
in
{
  options.scheduledTasks = lib.mkOption {
    default = { };
    description = ''
      Windows Task Scheduler tasks, keyed by task name.
    '';
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, config, ... }:
        {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to register this task.";
            };

            description = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Human-readable description stored on the task.";
            };

            command = lib.mkOption {
              type = lib.types.str;
              description = "Executable to run.";
              example = "powershell.exe";
            };

            arguments = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = ''
                Arguments, as a single string. Task Scheduler stores the
                argument list as one string rather than launchd's argv array,
                so this is deliberately not a `listOf str` — splitting and
                re-joining would only invent a quoting convention that does not
                match what the scheduler actually stores.
              '';
            };

            workingDirectory = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Working directory for the action.";
            };

            runAtLogon = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Trigger the task when the user logs on.";
            };

            runAtUnlock = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Also trigger the task when the user unlocks the session (Task
                Scheduler's SessionUnlock session-state-change trigger, for
                `principal.userName` when set). It is added beside the task's
                one schedule trigger, not instead of it.

                This is the second chance a GUI process needs when its logon
                launch lands in a locked session — a session locked at logon
                has no foreground window to hand over, so a program that
                insists on one (komorebi's AllowSetForegroundWindow check)
                exits, and nothing else would start it again.
              '';
            };

            executionTimeLimit = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "PT0S";
              description = ''
                How long an instance may run before Task Scheduler stops it,
                as an ISO 8601 duration. `null` keeps Windows' default of 72
                hours; `"PT0S"` means no limit.

                A long-running task wants `"PT0S"`: the stop kills only the
                process the task launched, so a child tree (the pwsh under a
                `conhost --headless` action, say) survives it, the instance
                counts as finished, and the next trigger starts a second copy
                beside the first. An on-demand start (Start-ScheduledTask) is
                never limited.
              '';
            };

            restartTriggers = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                Same idea as systemd's `restartTriggers`: when any of these
                strings differs from the previous generation's (typically the
                store paths or generated text the running process loaded),
                activation stops the task's running instances, kills each
                instance's whole process tree, and starts the task again. A
                task whose definition is re-registered is restarted the same
                way.

                Without it, a long-running task keeps its old payload until it
                next exits: an unchanged registration leaves a running instance
                alone, and stopping a task leaves the children of its action
                process running.
              '';
            };

            startInterval = lib.mkOption {
              type = lib.types.nullOr lib.types.ints.positive;
              default = null;
              description = ''
                Run every this many seconds, indefinitely. Same meaning as
                nix-darwin's `launchd.agents.<n>.serviceConfig.StartInterval`.

                Task Scheduler has no native "every N seconds" trigger, so this
                is realised as a one-shot trigger at a fixed past instant with a
                repetition interval attached — the encoding the Windows UI calls
                "Repeat task every ...". Its floor is one minute; anything
                shorter has to be a loop inside the script itself.
              '';
            };

            startCalendar = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.submodule {
                  options = {
                    hour = lib.mkOption {
                      type = lib.types.ints.between 0 23;
                      description = "Hour of day (0-23).";
                    };
                    minute = lib.mkOption {
                      type = lib.types.ints.between 0 59;
                      default = 0;
                      description = "Minute of hour (0-59).";
                    };
                  };
                }
              );
              default = null;
              description = ''
                Run daily at this time. Field names and bounds are taken from
                nix-darwin's `StartCalendarInterval` entries.
              '';
            };

            multipleInstances = lib.mkOption {
              type = lib.types.enum [
                "Parallel"
                "Queue"
                "IgnoreNew"
                "StopExisting"
              ];
              default = "Queue";
              description = ''
                What Task Scheduler does when the task triggers while a previous
                instance is still running. Windows-only; neither launchd nor
                systemd models this the same way.
              '';
            };

            principal = {
              userName = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Account the task runs as. Mutually exclusive with
                  `builtInAccount`.

                  No password is needed or accepted: the task is registered with
                  a logon type that does not store one.
                '';
              };

              builtInAccount = lib.mkOption {
                type = lib.types.nullOr (
                  lib.types.enum [
                    "SYSTEM"
                    "LOCALSERVICE"
                    "NETWORKSERVICE"
                  ]
                );
                default = null;
                description = "Built-in account to run as. Mutually exclusive with `userName`.";
              };

              logonType = lib.mkOption {
                type = lib.types.enum [
                  "None"
                  "Password"
                  "S4U"
                  "Interactive"
                  "Group"
                  "ServiceAccount"
                  "InteractiveOrPassword"
                ];
                default = "Interactive";
                description = ''
                  How the task obtains its security context. `Interactive` runs
                  in the logged-on user's desktop session — which is what makes
                  Task Scheduler usable as a cross-session launcher for GUI
                  processes. `ServiceAccount` goes with `builtInAccount`.
                '';
              };

              runLevel = lib.mkOption {
                type = lib.types.enum [
                  "Limited"
                  "Highest"
                ];
                default = "Limited";
                description = "Whether the task runs elevated.";
              };
            };
          };

          config = {
            # Give every task a usable default name in assertions.
            _module.args.taskName = name;
          };
        }
      )
    );
  };

  # Unconditional: the artifact is what the NEXT generation diffs against to
  # find tasks that left the configuration, and the step has to run for the
  # generation that removed the last task. nix-darwin's launchd step is
  # unconditional for the same reason.
  config = {
    assertions = lib.flatten (
      lib.mapAttrsToList (name: t: [
        {
          assertion =
            (lib.count (x: x) [
              t.runAtLogon
              (t.startInterval != null)
              (t.startCalendar != null)
            ]) == 1;
          message =
            "scheduledTasks.\"${name}\": set exactly one of runAtLogon, "
            + "startInterval or startCalendar.";
        }
        {
          assertion = !(t.principal.userName != null && t.principal.builtInAccount != null);
          message =
            "scheduledTasks.\"${name}\": principal.userName and "
            + "principal.builtInAccount are mutually exclusive.";
        }
        {
          assertion =
            t.executionTimeLimit == null
            || builtins.match "P([0-9]+D)?(T([0-9]+H)?([0-9]+M)?([0-9]+S)?)?" t.executionTimeLimit != null
              && !(builtins.elem t.executionTimeLimit [
                "P"
                "PT"
              ]);
          message =
            "scheduledTasks.\"${name}\": executionTimeLimit \"${toString t.executionTimeLimit}\" is not "
            + "an ISO 8601 duration of days, hours, minutes and seconds (e.g. \"PT0S\", \"PT72H\").";
        }
        {
          assertion = t.startInterval == null || t.startInterval >= 60;
          message =
            "scheduledTasks.\"${name}\": startInterval is ${toString t.startInterval}s, but "
            + "Task Scheduler's repetition floor is 60s. Use 60 and loop inside the script "
            + "for a finer cadence.";
        }
      ]) enabled
    );

    system.build.scheduledTasks = tasksJson;

    system.activationScripts.scheduledTasks = {
      deps = [ "files" ];
      text = ''
        $stDeclared = @(Get-NixWinArtifact -Root $env:NIX_WIN_STORE_PATH -RelPath 'scheduled-tasks', 'tasks.json')
        $stGone = @(Get-NixWinRemoved -RelPath 'scheduled-tasks', 'tasks.json' -Declared $stDeclared)
        if ($stDeclared.Count -gt 0 -or $stGone.Count -gt 0) {
            Write-Host "nix-win: converging scheduled tasks..." -ForegroundColor Cyan
        }

        # Tasks the previous generation declared and this one does not: stop
        # and unregister, as nix-darwin unloads a launchd daemon that left the
        # configuration. -TaskPath '\' because tasks are registered in the
        # root folder and a bare -TaskName matches in every folder.
        foreach ($stOld in $stGone) {
            # $stGoneName, not $name: the scriptblocks run inside
            # Invoke-NixWinRemoval, whose own parameters would shadow it.
            $stGoneName = [string]$stOld.name
            Invoke-NixWinRemoval -Label "task $stGoneName" -Present {
                $null -ne (Get-ScheduledTask -TaskPath '\' -TaskName $stGoneName -ErrorAction SilentlyContinue)
            } -Remove {
                Stop-ScheduledTask -TaskPath '\' -TaskName $stGoneName -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskPath '\' -TaskName $stGoneName -Confirm:$false -ErrorAction Stop
            }
        }

        # ONE bulk query for every task on the machine. Filtered per-task
        # lookups cost a full CIM round trip each (measured at 4.87 s for nine
        # tasks); the unfiltered enumeration is a single round trip regardless
        # of size — 0.75 s for all 206 tasks here — so it is both simpler and
        # far cheaper. Get-ScheduledTaskInfo is deliberately NOT called: no
        # declared field needs it, and it is another round trip per task.
        $stAll = @{}
        if ($stDeclared.Count -gt 0) {
            foreach ($t in (Get-ScheduledTask)) { $stAll[$t.TaskName] = $t }
        }

        # Stop a task's running instances and kill each one's whole process
        # tree. Stop-ScheduledTask (and a re-registration) ends only the
        # process the task launched; its children keep running. EnginePID is
        # that launched process. A child is any process whose parent id names a
        # tree member and which started after it, so a stranger holding a
        # recycled parent id is left alone.
        function Stop-NixWinTaskTree([string]$TaskName) {
            $sched = New-Object -ComObject Schedule.Service
            $sched.Connect()
            $roots = @()
            try {
                $roots = @(foreach ($i in @($sched.GetFolder('\').GetTask($TaskName).GetInstances(0))) { [int]$i.EnginePID })
            } catch { return }
            $procs = @{}
            $kids = @{}
            foreach ($p in @(Get-CimInstance Win32_Process)) {
                $procs[[int]$p.ProcessId] = $p
                $ppid = [int]$p.ParentProcessId
                if (-not $kids.ContainsKey($ppid)) { $kids[$ppid] = [System.Collections.Generic.List[int]]::new() }
                $kids[$ppid].Add([int]$p.ProcessId)
            }
            $tree = [System.Collections.Generic.List[int]]::new()
            $queue = [System.Collections.Generic.Queue[int]]::new()
            foreach ($r in $roots) { if ($r -gt 0 -and $procs.ContainsKey($r)) { $queue.Enqueue($r) } }
            while ($queue.Count -gt 0) {
                $x = $queue.Dequeue()
                if ($tree.Contains($x)) { continue }
                $tree.Add($x)
                if (-not $kids.ContainsKey($x)) { continue }
                foreach ($c in $kids[$x]) {
                    if ($c -eq $x -or -not $procs.ContainsKey($c)) { continue }
                    if ($procs[$c].CreationDate -lt $procs[$x].CreationDate) { continue }
                    $queue.Enqueue($c)
                }
            }
            Stop-ScheduledTask -TaskPath '\' -TaskName $TaskName -ErrorAction SilentlyContinue
            foreach ($x in $tree) {
                Write-Host "  task $TaskName`: stopping pid $x ($($procs[$x].Name))" -ForegroundColor DarkGray
                Stop-Process -Id $x -Force -ErrorAction SilentlyContinue
            }
        }

        # restartTriggers: which tasks' payload changed since the generation
        # being replaced. A previous generation without the stamp (older
        # nix-win) counts as changed; no previous generation at all counts as
        # unknown and restarts nothing.
        $stOldStamp = @{}
        $stHaveOld = -not [string]::IsNullOrEmpty($env:NIX_WIN_OLD_STORE_PATH)
        if ($stHaveOld) {
            foreach ($o in @(Get-NixWinArtifact -Root $env:NIX_WIN_OLD_STORE_PATH -RelPath 'scheduled-tasks', 'tasks.json')) {
                $oProp = $o.PSObject.Properties['restartStamp']
                $stOldStamp[[string]$o.name] = if ($null -ne $oProp) { [string]$oProp.Value } else { "" }
            }
        }
        $stRestart = @{}
        foreach ($d in $stDeclared) {
            $dProp = $d.PSObject.Properties['restartStamp']
            if ($null -eq $dProp -or $null -eq $dProp.Value) { continue }
            $wantStamp = [string]$dProp.Value
            if ($stHaveOld -and $stOldStamp.ContainsKey([string]$d.name) -and $stOldStamp[[string]$d.name] -ne $wantStamp) {
                $stRestart[[string]$d.name] = $true
            }
        }
        # Kill first, so a re-registration below cannot orphan the old tree.
        foreach ($rn in @($stRestart.Keys)) {
            Write-Host "  task $rn`: restart triggers changed; stopping the running instance" -ForegroundColor DarkGray
            Stop-NixWinTaskTree $rn
        }

        foreach ($d in $stDeclared) {
            # $taskName, NOT $name: these scriptblocks run inside
            # Invoke-NixWinItem, whose own [string]$Name parameter shadows any
            # `$name` here (PowerShell variable names are case-insensitive).
            # It happens to hold the same value in this step, but relying on
            # that is a trap the services and firewall steps actually fell into.
            $taskName = $d.name
            Invoke-NixWinItem -Name $taskName -Test {
                if (-not $stAll.ContainsKey($taskName)) { return $false }
                $live = $stAll[$taskName]

                # Compare ONLY the fields we declare, against the live CIM
                # object. Do NOT diff the registration XML: Task Scheduler adds
                # a <URI>, id="Author", Context="Author" and a whole default
                # <Settings> block we never asked for, so a document comparison
                # reports "changed" forever and re-registers every task on every
                # switch — which for these tasks means killing the running
                # keep-alives.
                if ($live.Actions.Count -lt 1) { return $false }
                $a = $live.Actions[0]
                if ("$($a.Execute)" -ne "$($d.command)") { return $false }
                if ("$($a.Arguments)" -ne "$($d.arguments)") { return $false }
                if ($null -ne $d.workingDirectory -and
                    "$($a.WorkingDirectory)" -ne "$($d.workingDirectory)") { return $false }

                # Description comes back as an empty string when unset, so
                # normalise before comparing against a declared null.
                $wantDesc = if ($null -eq $d.description) { "" } else { $d.description }
                if ("$($live.Description)" -ne $wantDesc) { return $false }

                $p = $live.Principal
                if ($null -ne $d.principal.userName) {
                    # The live value may be the bare name or DOMAIN\name.
                    $liveUser = "$($p.UserId)"
                    $wantUser = "$($d.principal.userName)"
                    if ($liveUser -ne $wantUser -and
                        $liveUser -notlike "*\$wantUser") { return $false }
                }
                if ($null -ne $d.principal.builtInAccount) {
                    # Windows stores these as a SID or a well-known name
                    # depending on how they were registered, so accept either.
                    $liveUser = "$($p.UserId)"
                    $want = switch ($d.principal.builtInAccount) {
                        'SYSTEM'         { @('SYSTEM', 'S-1-5-18', 'NT AUTHORITY\SYSTEM') }
                        'LOCALSERVICE'   { @('LOCAL SERVICE', 'S-1-5-19', 'NT AUTHORITY\LOCAL SERVICE') }
                        'NETWORKSERVICE' { @('NETWORK SERVICE', 'S-1-5-20', 'NT AUTHORITY\NETWORK SERVICE') }
                    }
                    if ($want -notcontains $liveUser) { return $false }
                }
                if ("$($p.LogonType)" -ne "$($d.principal.logonType)") { return $false }
                if ("$($p.RunLevel)" -ne "$($d.principal.runLevel)") { return $false }
                if ("$($live.Settings.MultipleInstances)" -ne "$($d.multipleInstances)") { return $false }
                # Parsed, not string-compared: PT72H and P3D are the same limit.
                if ($null -ne $d.executionTimeLimit) {
                    try {
                        $wantLimit = [System.Xml.XmlConvert]::ToTimeSpan("$($d.executionTimeLimit)")
                        $gotLimit = [System.Xml.XmlConvert]::ToTimeSpan("$($live.Settings.ExecutionTimeLimit)")
                    } catch { return $false }
                    if ($gotLimit -ne $wantLimit) { return $false }
                }

                # The schedule trigger first, then the unlock trigger if declared.
                $wantTriggers = if ($d.runAtUnlock) { 2 } else { 1 }
                if ($live.Triggers.Count -ne $wantTriggers) { return $false }
                if ($d.runAtUnlock) {
                    $u = $live.Triggers[1]
                    if ("$($u.CimClass.CimClassName)" -ne 'MSFT_TaskSessionStateChangeTrigger') { return $false }
                    if ([int]$u.StateChange -ne 8) { return $false }
                }
                $tr = $live.Triggers[0]
                $trClass = "$($tr.CimClass.CimClassName)"
                if ($d.runAtLogon) {
                    if ($trClass -ne 'MSFT_TaskLogonTrigger') { return $false }
                } elseif ($null -ne $d.startCalendar) {
                    if ($trClass -ne 'MSFT_TaskDailyTrigger') { return $false }
                    # Only the time-of-day is declared, so compare only that —
                    # but parse rather than string-match. Task Scheduler returns
                    # a registered trigger's StartBoundary in local form with an
                    # offset (2026-08-15T21:00:00-04:00) while a freshly
                    # constructed one normalises to UTC (2026-08-16T01:00:00Z).
                    # A substring test on "21:00:00" happens to pass against the
                    # first and fails against the second, and would flip with
                    # daylight saving — re-registering the task on every switch,
                    # which for a keep-alive task means killing it.
                    $sb = $null
                    try { $sb = [DateTimeOffset]::Parse("$($tr.StartBoundary)") } catch { return $false }
                    $local = $sb.LocalDateTime
                    if ($local.Hour -ne $d.startCalendar.hour) { return $false }
                    if ($local.Minute -ne $d.startCalendar.minute) { return $false }
                } elseif ($null -ne $d.startInterval) {
                    if ($trClass -ne 'MSFT_TaskTimeTrigger') { return $false }
                    if ($null -eq $tr.Repetition) { return $false }
                    $want = [TimeSpan]::FromSeconds($d.startInterval)
                    $got = $null
                    try { $got = [System.Xml.XmlConvert]::ToTimeSpan("$($tr.Repetition.Interval)") } catch { return $false }
                    if ($got -ne $want) { return $false }
                }
                return $true
            } -Set {
                $action = if ([string]::IsNullOrEmpty($d.arguments)) {
                    New-ScheduledTaskAction -Execute $d.command
                } elseif ($null -ne $d.workingDirectory) {
                    New-ScheduledTaskAction -Execute $d.command -Argument $d.arguments -WorkingDirectory $d.workingDirectory
                } else {
                    New-ScheduledTaskAction -Execute $d.command -Argument $d.arguments
                }

                if ($d.runAtLogon) {
                    $trigger = if ($null -ne $d.principal.userName) {
                        New-ScheduledTaskTrigger -AtLogOn -User $d.principal.userName
                    } else {
                        New-ScheduledTaskTrigger -AtLogOn
                    }
                } elseif ($null -ne $d.startCalendar) {
                    $at = Get-Date -Hour $d.startCalendar.hour -Minute $d.startCalendar.minute -Second 0
                    $trigger = New-ScheduledTaskTrigger -Daily -At $at
                } else {
                    # Once + repetition = "every N seconds, forever".
                    $trigger = New-ScheduledTaskTrigger -Once -At ([DateTime]::Parse($d.intervalStart)) `
                        -RepetitionInterval ([TimeSpan]::FromSeconds($d.startInterval))
                }

                $principal = if ($null -ne $d.principal.builtInAccount) {
                    New-ScheduledTaskPrincipal -UserId $d.principal.builtInAccount `
                        -LogonType $d.principal.logonType -RunLevel $d.principal.runLevel
                } elseif ($null -ne $d.principal.userName) {
                    New-ScheduledTaskPrincipal -UserId $d.principal.userName `
                        -LogonType $d.principal.logonType -RunLevel $d.principal.runLevel
                } else {
                    New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' `
                        -RunLevel $d.principal.runLevel
                }

                $triggers = @($trigger)
                if ($d.runAtUnlock) {
                    # New-ScheduledTaskTrigger has no session-state triggers;
                    # build the CIM instance directly. StateChange 8 is
                    # TASK_SESSION_UNLOCK.
                    $unlockClass = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskSessionStateChangeTrigger'
                    $unlock = New-CimInstance -CimClass $unlockClass -ClientOnly
                    $unlock.StateChange = 8
                    $unlock.Enabled = $true
                    if ($null -ne $d.principal.userName) { $unlock.UserId = $d.principal.userName }
                    $triggers += $unlock
                }

                $settingsArgs = @{ MultipleInstances = $d.multipleInstances }
                if ($null -ne $d.executionTimeLimit) {
                    $settingsArgs.ExecutionTimeLimit = [System.Xml.XmlConvert]::ToTimeSpan("$($d.executionTimeLimit)")
                }
                $settings = New-ScheduledTaskSettingsSet @settingsArgs

                # A task with restartTriggers is replaced whole: its running
                # tree goes before the re-registration and it is started again
                # after it.
                $dStamp = $d.PSObject.Properties['restartStamp']
                if ($null -ne $dStamp -and $null -ne $dStamp.Value -and $stAll.ContainsKey($taskName)) {
                    Stop-NixWinTaskTree $taskName
                    $stRestart[$taskName] = $true
                }

                $register = @{
                    TaskName  = $taskName
                    Action    = $action
                    Trigger   = $triggers
                    Principal = $principal
                    Settings  = $settings
                    Force     = $true
                }
                if ($null -ne $d.description) { $register.Description = $d.description }
                $null = Register-ScheduledTask @register
            }
        }

        foreach ($rn in @($stRestart.Keys)) {
            Write-Host "  task $rn`: starting" -ForegroundColor DarkGray
            Start-ScheduledTask -TaskPath '\' -TaskName $rn
        }
      '';
    };
  };
}
