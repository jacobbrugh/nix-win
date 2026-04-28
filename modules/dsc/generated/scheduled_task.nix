# Generated from DSC resource schema — do not edit manually.
# Source: DSC_ScheduledTask.schema.mof
# Regenerate: nix build .#packages.x86_64-linux.generate-dsc-modules
{
  lib,
  config,
  ...
}:
let
  cfg = config.win.dsc;
in
{
  options.win.dsc.scheduledTasks = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          TaskPath = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The path to the task - defaults to the root directory.";
          };
          Description = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The task description.";
          };
          ActionExecutable = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The path to the .exe for this task.";
          };
          ActionArguments = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The arguments to pass the executable.";
          };
          ActionWorkingPath = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The working path to specify for the executable.";
          };
          ScheduleType = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Once"
                  "Daily"
                  "Weekly"
                  "AtStartup"
                  "AtLogon"
                  "OnIdle"
                  "OnEvent"
                  "AtCreation"
                  "OnSessionState"
                ]
              )
            );
            default = null;
            description = "When should the task be executed.";
          };
          RepeatInterval = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "How many units (minutes, hours, days) between each run of this task?";
          };
          StartTime = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The date and time of day this task should start at, or activate on, represented as a string for local conversion to DateTime format - defaults to 1st January 1980 at 12:00 AM.";
          };
          SynchronizeAcrossTimeZone = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Enable the scheduled task option to synchronize across time zones. This is enabled by including the timezone offset in the scheduled task trigger. Defaults to false which does not include the timezone offset.";
          };
          Ensure = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Present"
                  "Absent"
                ]
              )
            );
            default = null;
            description = "Present if the task should exist, Absent if it should be removed.";
          };
          Enable = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "True if the task should be enabled, false if it should be disabled.";
          };
          BuiltInAccount = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "SYSTEM"
                  "LOCAL SERVICE"
                  "NETWORK SERVICE"
                ]
              )
            );
            default = null;
            description = "Run the task as one of the built in service accounts. When set ExecuteAsCredential will be ignored and LogonType will be set to 'ServiceAccount'.";
          };
          ExecuteAsCredential = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.submodule {
                  options = {
                    UserName = lib.mkOption {
                      type = (lib.types.nullOr lib.types.str);
                      default = null;
                      description = "The username to run the task as.";
                    };
                    Password = lib.mkOption {
                      type = (lib.types.nullOr lib.types.str);
                      default = null;
                      description = "The password for the user account.";
                    };
                  };
                }
              )
            );
            default = null;
            description = "The credential this task should execute as. If not specified defaults to running as the local system account.";
          };
          ExecuteAsGMSA = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The gMSA (Group Managed Service Account) this task should execute as. Cannot be used in combination with ExecuteAsCredential or BuiltInAccount.";
          };
          DaysInterval = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "Specifies the interval between the days in the schedule. An interval of 1 produces a daily schedule. An interval of 2 produces an every-other day schedule. Can only be used in combination with ScheduleType Daily.";
          };
          RandomDelay = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies a random amount of time to delay the start time of the trigger. The delay time is a random time between the time the task triggers and the time that you specify in this setting. Can only be used in combination with ScheduleType Once, Daily and Weekly.";
          };
          RepetitionDuration = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies how long the repetition pattern repeats after the task starts. May be set to `Indefinitely` to specify an indefinite duration.";
          };
          StopAtDurationEnd = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates that Task Scheduler stops all running tasks at the end of the repetition duration. Defaults to $false.";
          };
          TriggerExecutionTimeLimit = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the amount of time for the trigger that Task Scheduler is allowed to complete the task.";
          };
          DaysOfWeek = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Specifies an array of the days of the week on which Task Scheduler runs the task. Can only be used in combination with ScheduleType Weekly.";
          };
          WeeksInterval = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "Specifies the interval between the weeks in the schedule. An interval of 1 produces a weekly schedule. An interval of 2 produces an every-other week schedule. Can only be used in combination with ScheduleType Weekly.";
          };
          User = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the identifier of a user that will trigger the task to start. Can only be used in combination with ScheduleType AtLogon and OnSessionState.";
          };
          DisallowDemandStart = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether the task is prohibited to run on demand or not. Defaults to $false.";
          };
          DisallowHardTerminate = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether the task is prohibited to be terminated or not. Defaults to $false.";
          };
          Compatibility = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "AT"
                  "V1"
                  "Vista"
                  "Win7"
                  "Win8"
                ]
              )
            );
            default = null;
            description = "The task compatibility level. Defaults to Vista.";
          };
          AllowStartIfOnBatteries = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether the task should start if the machine is on batteries or not. Defaults to $false.";
          };
          Hidden = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates that the task is hidden in the Task Scheduler UI.";
          };
          RunOnlyIfIdle = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates that Task Scheduler runs the task only when the computer is idle.";
          };
          IdleWaitTimeout = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the amount of time that Task Scheduler waits for an idle condition to occur.";
          };
          NetworkName = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the name of a network profile that Task Scheduler uses to determine if the task can run. The Task Scheduler UI uses this setting for display purposes. Specify a network name if you specify the RunOnlyIfNetworkAvailable parameter.";
          };
          DisallowStartOnRemoteAppSession = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates that the task does not start if the task is triggered to run in a Remote Applications Integrated Locally (RAIL) session.";
          };
          StartWhenAvailable = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates that Task Scheduler can start the task at any time after its scheduled time has passed.";
          };
          DontStopIfGoingOnBatteries = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates that the task does not stop if the computer switches to battery power.";
          };
          WakeToRun = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates that Task Scheduler wakes the computer before it runs the task.";
          };
          IdleDuration = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the amount of time that the computer must be in an idle state before Task Scheduler runs the task.";
          };
          RestartOnIdle = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates that Task Scheduler restarts the task when the computer cycles into an idle condition more than once.";
          };
          DontStopOnIdleEnd = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates that Task Scheduler does not terminate the task if the idle condition ends before the task is completed.";
          };
          ExecutionTimeLimit = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the amount of time that Task Scheduler is allowed to complete the task.";
          };
          MultipleInstances = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "IgnoreNew"
                  "Parallel"
                  "Queue"
                  "StopExisting"
                ]
              )
            );
            default = null;
            description = "Specifies the policy that defines how Task Scheduler handles multiple instances of the task.";
          };
          Priority = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "Specifies the priority level of the task. Priority must be an integer from 0 (highest priority) to 10 (lowest priority). The default value is 7. Priority levels 7 and 8 are used for background tasks. Priority levels 4, 5, and 6 are used for interactive tasks.";
          };
          RestartCount = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "Specifies the number of times that Task Scheduler attempts to restart the task.";
          };
          RestartInterval = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the amount of time that Task Scheduler attempts to restart the task.";
          };
          RunOnlyIfNetworkAvailable = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates that Task Scheduler runs the task only when a network is available. Task Scheduler uses the NetworkID parameter and NetworkName parameter that you specify in this cmdlet to determine if the network is available.";
          };
          RunLevel = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Limited"
                  "Highest"
                ]
              )
            );
            default = null;
            description = "Specifies the level of user rights that Task Scheduler uses to run the tasks that are associated with the principal. Defaults to 'Limited'.";
          };
          LogonType = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Group"
                  "Interactive"
                  "InteractiveOrPassword"
                  "None"
                  "Password"
                  "S4U"
                  "ServiceAccount"
                ]
              )
            );
            default = null;
            description = "Specifies the security logon method that Task Scheduler uses to run the tasks that are associated with the principal.";
          };
          EventSubscription = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the EventSubscription in XML. This can be easily generated using the Windows Eventlog Viewer. For the query schema please check: https://docs.microsoft.com/en-us/windows/desktop/WES/queryschema-schema. Can only be used in combination with ScheduleType OnEvent.";
          };
          EventValueQueries = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Specifies the EventValueQueries. Receives a hashtable where the key is a property value for an event and the value is an XPath event query. For more detailed syntax check: https://learn.microsoft.com/en-us/windows/win32/taskschd/eventtrigger-valuequeries. Can only be used in combination with ScheduleType OnEvent.";
          };
          Delay = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies a delay to the start of the trigger. The delay is a static delay before the task is executed. Can only be used in combination with ScheduleType AtLogon, AtStartup, OnEvent, AtCreation and OnSessionState.";
          };
          StateChange = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "OnConnectionFromLocalComputer"
                  "OnDisconnectFromLocalComputer"
                  "OnConnectionFromRemoteComputer"
                  "OnDisconnectFromRemoteComputer"
                  "OnWorkstationLock"
                  "OnWorkstationUnlock"
                ]
              )
            );
            default = null;
            description = "Specifies the kind of session state change that would trigger a task launch. Can only be used in combination with ScheduleType OnSessionState.";
          };
          dependsOn = lib.mkOption {
            type = (lib.types.listOf lib.types.str);
            default = [ ];
            description = "Defines a list of DSC resource instances that DSC must successfully process before processing this instance. Each value for this property must be the `resourceID()` lookup for another instance in the configuration. Multiple instances can depend on the same instance, but every dependency for an instance must be unique in that instance's `dependsOn` property.";
          };
        };
      }
    );
    default = { };
    description = "";
  };

  config.win.dsc.nativeResourcesList = lib.mkIf cfg.enable (
    lib.mapAttrsToList (
      rname: props:
      {
        name = rname;
        type = "Microsoft.Windows/WindowsPowerShell";
        properties.resources = [
          {
            name = "${rname} Inner";
            type = "ComputerManagementDsc/ScheduledTask";
            properties = lib.filterAttrs (_: v: v != null) {
              TaskName = rname;
              inherit (props)
                TaskPath
                Description
                ActionExecutable
                ActionArguments
                ActionWorkingPath
                ScheduleType
                RepeatInterval
                StartTime
                SynchronizeAcrossTimeZone
                Ensure
                Enable
                BuiltInAccount
                ExecuteAsGMSA
                DaysInterval
                RandomDelay
                RepetitionDuration
                StopAtDurationEnd
                TriggerExecutionTimeLimit
                DaysOfWeek
                WeeksInterval
                User
                DisallowDemandStart
                DisallowHardTerminate
                Compatibility
                AllowStartIfOnBatteries
                Hidden
                RunOnlyIfIdle
                IdleWaitTimeout
                NetworkName
                DisallowStartOnRemoteAppSession
                StartWhenAvailable
                DontStopIfGoingOnBatteries
                WakeToRun
                IdleDuration
                RestartOnIdle
                DontStopOnIdleEnd
                ExecutionTimeLimit
                MultipleInstances
                Priority
                RestartCount
                RestartInterval
                RunOnlyIfNetworkAvailable
                RunLevel
                LogonType
                EventSubscription
                EventValueQueries
                Delay
                StateChange
                ;
              ExecuteAsCredential =
                if props.ExecuteAsCredential != null then
                  lib.filterAttrs (_: v: v != null) props.ExecuteAsCredential
                else
                  null;
            };
          }
        ];
      }
      // (lib.optionalAttrs (props.dependsOn != [ ]) { inherit (props) dependsOn; })
    ) cfg.scheduledTasks
  );
}
