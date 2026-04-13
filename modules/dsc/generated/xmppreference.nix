# Generated from DSC resource schema — do not edit manually.
# Source: xalzbz0qhg4yjw75rd4lahy90bwxq970-MSFT_WindowsDefender.schema.mof
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
  options.win.dsc.defender = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          ExclusionPath = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Specifies an array of file paths to exclude from scheduled and real-time scanning. You can specify a folder to exclude all the files under the folder.";
          };
          ExclusionExtension = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Specifies an array of file name extensions, such as obj or lib, to exclude from scheduled, custom, and real-time scanning.";
          };
          ExclusionProcess = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Specifies an array of processes, as paths to process images. The cmdlet excludes any files opened by the processes that you specify from scheduled and real-time scanning. Specifying this parameter excludes files opened by executable programs only. The cmdlet does not exclude the processes themselves. To exclude a process, specify it by using the ExclusionPath parameter.";
          };
          RealTimeScanDirection = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Both"
                  "Incoming"
                  "Outcoming"
                ]
              )
            );
            default = null;
            description = "Specifies scanning configuration for incoming and outgoing files on NTFS volumes. Specify a value for this parameter to enhance performance on servers which have a large number of file transfers, but need scanning for either incoming or outgoing files. Evaluate this configuration based on the server role. For non-NTFS volumes, Windows Defender performs full monitoring of file and program activity.";
          };
          QuarantinePurgeItemsAfterDelay = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "Specifies the number of days to keep items in the Quarantine folder. If you specify a value of zero or do not specify a value for this parameter, items stay in the Quarantine folder indefinitely.";
          };
          RemediationScheduleDay = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Everyday"
                  "Never"
                  "Monday"
                  "Tuesday"
                  "Wednesday"
                  "Thursday"
                  "Friday"
                  "Saturday"
                  "Sunday"
                ]
              )
            );
            default = null;
            description = "Specifies the day of the week on which to perform a scheduled full scan in order to complete remediation. Alternatively, specify everyday for this full scan or never. The default value is Never. If you specify a value of Never or do not specify a value, Windows Defender performs a scheduled full scan to complete remediation by using a default frequency.";
          };
          RemediationScheduleTime = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the time of day, as the number of minutes after midnight, to perform a scheduled scan. The time refers to the local time on the computer. If you do not specify a value for this parameter, a scheduled scan runs at the default time of two hours after midnight.";
          };
          ReportingAdditionalActionTimeOut = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "Specifies the number of minutes before a detection in the additional action state changes to the cleared state.";
          };
          ReportingNonCriticalTimeOut = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "Specifies the number of minutes before a detection in the non-critically failed state changes to the cleared state.";
          };
          ReportingCriticalFailureTimeOut = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "Specifies the number of minutes before a detection in the critically failed state changes to either the additional action state or the cleared state.";
          };
          ScanAvgCPULoadFactor = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "Specifies the maxium percentage CPU usage for a scan. The acceptable values for this parameter are: integers from 5 through 100, and the value 0, which disables CPU throttling. Windows Defender does not exceed the percentage of CPU usage that you specify. The default value is 50.";
          };
          CheckForSignaturesBeforeRunningScan = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether to check for new virus and spyware definitions before Windows Defender runs a scan. If you specify a value of $True, Windows Defender checks for new definitions. If you specify $False or do not specify a value, the scan begins with existing definitions. This value applies to scheduled scans and to scans that you start from the command line, but it does not affect scans that yo...";
          };
          ScanPurgeItemsAfterDelay = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "Specifies the number of days to keep items in the scan history folder. After this time, Windows Defender removes the items. If you specify a value of zero, Windows Defender does not remove items. If you do not specify a value, Windows Defender removes items from the scan history folder after the default length of time, which is 30 days.";
          };
          ScanOnlyIfIdleEnabled = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether to start scheduled scans only when the computer is not in use. If you specify a value of $True or do not specify a value, Windows Defender runs schedules scans when the computer is on, but not in use.";
          };
          ScanParameters = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "FullSCan"
                  "QuickScan"
                ]
              )
            );
            default = null;
            description = "Specifies the scan type to use during a scheduled scan. If you do not specify this parameter, Windows Defender uses the default value of quick scan.";
          };
          ScanScheduleDay = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Everyday"
                  "Never"
                  "Monday"
                  "Tuesday"
                  "Wednesday"
                  "Thursday"
                  "Friday"
                  "Saturday"
                  "Sunday"
                ]
              )
            );
            default = null;
            description = "Specifies the day of the week on which to perform a scheduled scan. Alternatively, specify everyday for a scheduled scan or never. If you specify a value of Never or do not specify a value, Windows Defender performs a scheduled scan by using a default frequency.";
          };
          ScanScheduleQuickScanTime = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the time of day, as the number of minutes after midnight, to perform a scheduled quick scan. The time refers to the local time on the computer. If you do not specify a value for this parameter, a scheduled quick scan runs at the time specified by the ScanScheduleTime parameter. That parameter has a default time of two hours after midnight.";
          };
          ScanScheduleTime = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the time of day, as the number of minutes after midnight, to perform a scheduled scan. The time refers to the local time on the computer. If you do not specify a value for this parameter, a scheduled scan runs at a default time of two hours after midnight.";
          };
          SignatureFirstAuGracePeriod = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "Specifies a grace period, in minutes, for the definition. If a definition successfully updates within this period, Windows Defender abandons any service initiated updates. This parameter overrides the value of the CheckForSignaturesBeforeRunningScan parameter.";
          };
          SignatureAuGracePeriod = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "Specifies a grace period, in minutes, for the definition. If a definition successfully updates within this period, Windows Defender abandons any service initiated updates.";
          };
          SignatureDefinitionUpdateFileSharesSources = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies file-share sources for definition updates. Specify sources as a bracketed sequence of Universal Naming Convention (UNC) locations, separated by the pipeline symbol. If you specify a value for this parameter, Windows Defender attempts to connect to the shares in the order that you specify. After Windows Defender updates a definition, it stops attempting to connect to shares on the list...";
          };
          SignatureDisableUpdateOnStartupWithoutEngine = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether to initiate definition updates even if no antimalware engine is present. If you specify a value of $True or do not specify a value, Windows Defender initiates definition updates on startup. If you specify a value of $False, and if no antimalware engine is present, Windows Defender does not initiate definition updates on startup.";
          };
          SignatureFallbackOrder = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the order in which to contact different definition update sources. Specify the types of update sources in the order in which you want Windows Defender to contact them, enclosed in braces and separated by the pipeline symbol.";
          };
          SignatureScheduleDay = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Everyday"
                  "Never"
                  "Monday"
                  "Tuesday"
                  "Wednesday"
                  "Thursday"
                  "Friday"
                  "Saturday"
                  "Sunday"
                ]
              )
            );
            default = null;
            description = "Specifies the day of the week on which to check for definition updates. Alternatively, specify everyday for a scheduled scan or never. If you specify a value of Never or do not specify a value, Windows Defender checks for definition updates by using a default frequency.";
          };
          SignatureScheduleTime = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the time of day, as the number of minutes after midnight, to check for definition updates. The time refers to the local time on the computer. If you do not specify a value for this parameter, Windows Defender checks for definition updates at the default time of 15 minutes before the scheduled scan time.";
          };
          SignatureUpdateCatchupInterval = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "Specifies the number of days after which Windows Defender requires a catch-up definition update. If you do not specify a value for this parameter, Windows Defender requires a catch-up definition update after the default value of one day.";
          };
          SignatureUpdateInterval = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "Specifies the interval, in hours, at which to check for definition updates. The acceptable values for this parameter are: integers from 1 through 24. If you do not specify a value for this parameter, Windows Defender checks at the default interval. You can use this parameter instead of the SignatureScheduleDay parameter and SignatureScheduleTime parameter.";
          };
          MAPSReporting = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Advanced"
                  "Basic"
                  "Disabled"
                ]
              )
            );
            default = null;
            description = "Specifies the type of membership in Microsoft Active Protection Service. Microsoft Active Protection Service is an online community that helps you choose how to respond to potential threats. The community also helps prevent the spread of new malicious software. If you join this community, you can choose to automatically send basic or additional information about detected software. Additional in...";
          };
          DisablePrivacyMode = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether to disable privacy mode. Privacy mode prevents users, other than administrators, from displaying threat history.";
          };
          RandomizeScheduleTaskTimes = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether to select a random time for the scheduled start and scheduled update for definitions. If you specify a value of $True or do not specify a value, scheduled tasks begin within 30 minutes, before or after, the scheduled time. If you randomize the start times, it can distribute the impact of scanning. For example, if several virtual machines share the same host, randomized start t...";
          };
          DisableBehaviorMonitoring = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether to enable behavior monitoring. If you specify a value of $True or do not specify a value, Windows Defender enables behavior monitoring";
          };
          DisableIntrusionPreventionSystem = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether to configure network protection against exploitation of known vulnerabilities. If you specify a value of $True or do not specify a value, network protection is enabled";
          };
          DisableIOAVProtection = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether Windows Defender scans all downloaded files and attachments. If you specify a value of $True or do not specify a value, scanning downloaded files and attachments is enabled.";
          };
          DisableRealtimeMonitoring = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether to use real-time protection. If you specify a value of $True or do not specify a value, Windows Defender uses real-time protection. We recommend that you enable Windows Defender to use real-time protection.";
          };
          DisableScriptScanning = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Specifies whether to disable the scanning of scripts during malware scans.";
          };
          DisableArchiveScanning = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether to scan archive files, such as .zip and .cab files, for malicious and unwanted software. If you specify a value of $True or do not specify a value, Windows Defender scans archive files.";
          };
          DisableAutoExclusions = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether to disable the Automatic Exclusions feature for the server.";
          };
          DisableCatchupFullScan = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether Windows Defender runs catch-up scans for scheduled full scans. A computer can miss a scheduled scan, usually because the computer is turned off at the scheduled time. If you specify a value of $True, after the computer misses two scheduled full scans, Windows Defender runs a catch-up scan the next time someone logs on to the computer. If you specify a value of $False or do not...";
          };
          DisableCatchupQuickScan = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether Windows Defender runs catch-up scans for scheduled quick scans. A computer can miss a scheduled scan, usually because the computer is off at the scheduled time. If you specify a value of $True, after the computer misses two scheduled quick scans, Windows Defender runs a catch-up scan the next time someone logs onto the computer. If you specify a value of $False or do not speci...";
          };
          DisableEmailScanning = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether Windows Defender parses the mailbox and mail files, according to their specific format, in order to analyze mail bodies and attachments. Windows Defender supports several formats, including .pst, .dbx, .mbx, .mime, and .binhex. If you specify a value of $True, Windows Defender performs email scanning. If you specify a value of $False or do not specify a value, Windows Defender...";
          };
          DisableRemovableDriveScanning = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether to scan for malicious and unwanted software in removable drives, such as flash drives, during a full scan. If you specify a value of $True, Windows Defender scans removable drives during any type of scan. If you specify a value of $False or do not specify a value, Windows Defender does not scan removable drives during a full scan. Windows Defender can still scan removable driv...";
          };
          DisableRestorePoint = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether to disable scanning of restore points.";
          };
          DisableScanningMappedNetworkDrivesForFullScan = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether to scan mapped network drives. If you specify a value of $True, Windows Defender scans mapped network drives. If you specify a value of $False or do not specify a value, Windows Defender does not scan mapped network drives.";
          };
          DisableScanningNetworkFiles = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether to scan for network files. If you specify a value of $True, Windows Defender scans network files. If you specify a value of $False or do not specify a value, Windows Defender does not scan network files. We do not recommend that you scan network files.";
          };
          UILockdown = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether to disable UI lockdown mode. If you specify a value of $True, Windows Defender disables UI lockdown mode. If you specify $False or do not specify a value, UI lockdown mode is enabled.";
          };
          ThreatIDDefaultAction_Ids = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.int));
            default = null;
            description = "Specifies an array of the actions to take for the IDs specified by using the ThreatIDDefaultAction_Ids parameter.";
          };
          ThreatIDDefaultAction_Actions = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.listOf (
                  lib.types.enum [
                    "Allow"
                    "Block"
                    "Clean"
                    "NoAction"
                    "Quarantine"
                    "Remove"
                    "UserDefined"
                  ]
                )
              )
            );
            default = null;
            description = "Specifies which automatic remediation action to take for an unknonwn level threat.";
          };
          UnknownThreatDefaultAction = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Allow"
                  "Block"
                  "Clean"
                  "NoAction"
                  "Quarantine"
                  "Remove"
                  "UserDefined"
                ]
              )
            );
            default = null;
            description = "Specifies which automatic remediation action to take for a low level threat.";
          };
          LowThreatDefaultAction = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Allow"
                  "Block"
                  "Clean"
                  "NoAction"
                  "Quarantine"
                  "Remove"
                  "UserDefined"
                ]
              )
            );
            default = null;
            description = "Specifies which automatic remediation action to take for a low level threat.";
          };
          ModerateThreatDefaultAction = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Allow"
                  "Block"
                  "Clean"
                  "NoAction"
                  "Quarantine"
                  "Remove"
                  "UserDefined"
                ]
              )
            );
            default = null;
            description = "Specifies which automatic remediation action to take for a moderate level threat.";
          };
          HighThreatDefaultAction = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Allow"
                  "Block"
                  "Clean"
                  "NoAction"
                  "Quarantine"
                  "Remove"
                  "UserDefined"
                ]
              )
            );
            default = null;
            description = "Specifies which automatic remediation action to take for a high level threat.";
          };
          SevereThreatDefaultAction = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Allow"
                  "Block"
                  "Clean"
                  "NoAction"
                  "Quarantine"
                  "Remove"
                  "UserDefined"
                ]
              )
            );
            default = null;
            description = "Specifies which automatic remediation action to take for a severe level threat.";
          };
          SubmitSamplesConsent = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "None"
                  "Always"
                  "Never"
                ]
              )
            );
            default = null;
            description = "Specifies how Windows Defender checks for user consent for certain samples. If consent has previously been granted, Windows Defender submits the samples. Otherwise, if the MAPSReporting parameter does not have a value of Disabled, Windows Defender prompts the user for consent.";
          };
          DisableBlockAtFirstSeen = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether to disable 'Block at First Sight' feature.";
          };
          CloudBlockLevel = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Default"
                  "High"
                  "HighPlus"
                  "ZeroTolerance"
                ]
              )
            );
            default = null;
            description = "Select cloud protection level.";
          };
          CloudExtendedTimeout = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "Specifies time in seconds for extended cloud check feature.";
          };
          EnableNetworkProtection = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Disabled"
                  "Enabled"
                  "AuditMode"
                ]
              )
            );
            default = null;
            description = "Specifies how Windows Defender prevent users and apps from accessing dangerous websites.";
          };
          EnableControlledFolderAccess = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Disabled"
                  "Enabled"
                  "AuditMode"
                ]
              )
            );
            default = null;
            description = "Configure the Controlled folder access feature.";
          };
          AttackSurfaceReductionOnlyExclusions = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Specifies an array of file/folder paths to exclude from Attack Surface Reduction Rules(ASR) feature.";
          };
          ControlledFolderAccessAllowedApplications = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Specifies an array of application file paths to add to allowed list for guard my folders feature.";
          };
          ControlledFolderAccessProtectedFolders = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Specifies an array of folder paths to add to guarded list for guard my folders feature.";
          };
          AttackSurfaceReductionRules_Ids = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Specifies an array of Attack Surface Reduction Rule(ASR) Ids. The rule Ids need to be in the same order as their respective actions specified in the AttackSurfaceReductionRules_Actions property.";
          };
          AttackSurfaceReductionRules_Actions = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.listOf (
                  lib.types.enum [
                    "Disabled"
                    "Enabled"
                    "AuditMode"
                  ]
                )
              )
            );
            default = null;
            description = "Configure Attack Surface Reduction Rule(ASR) actions. The actions need to be in the same order as their respective rule Ids specified in the AttackSurfaceReductionRules_Ids property.";
          };
        };
      }
    );
    default = { };
    description = "";
  };

  config.win.dsc.nativeResourcesList = lib.mkIf cfg.enable (
    lib.mapAttrsToList (rname: props: {
      name = rname;
      type = "Microsoft.Windows/WindowsPowerShell";
      properties.resources = [
        {
          name = "${rname} Inner";
          type = "WindowsDefender/WindowsDefender";
          properties = lib.filterAttrs (_: v: v != null) {
            IsSingleInstance = rname;
            inherit (props)
              ExclusionPath
              ExclusionExtension
              ExclusionProcess
              RealTimeScanDirection
              QuarantinePurgeItemsAfterDelay
              RemediationScheduleDay
              RemediationScheduleTime
              ReportingAdditionalActionTimeOut
              ReportingNonCriticalTimeOut
              ReportingCriticalFailureTimeOut
              ScanAvgCPULoadFactor
              CheckForSignaturesBeforeRunningScan
              ScanPurgeItemsAfterDelay
              ScanOnlyIfIdleEnabled
              ScanParameters
              ScanScheduleDay
              ScanScheduleQuickScanTime
              ScanScheduleTime
              SignatureFirstAuGracePeriod
              SignatureAuGracePeriod
              SignatureDefinitionUpdateFileSharesSources
              SignatureDisableUpdateOnStartupWithoutEngine
              SignatureFallbackOrder
              SignatureScheduleDay
              SignatureScheduleTime
              SignatureUpdateCatchupInterval
              SignatureUpdateInterval
              MAPSReporting
              DisablePrivacyMode
              RandomizeScheduleTaskTimes
              DisableBehaviorMonitoring
              DisableIntrusionPreventionSystem
              DisableIOAVProtection
              DisableRealtimeMonitoring
              DisableScriptScanning
              DisableArchiveScanning
              DisableAutoExclusions
              DisableCatchupFullScan
              DisableCatchupQuickScan
              DisableEmailScanning
              DisableRemovableDriveScanning
              DisableRestorePoint
              DisableScanningMappedNetworkDrivesForFullScan
              DisableScanningNetworkFiles
              UILockdown
              ThreatIDDefaultAction_Ids
              ThreatIDDefaultAction_Actions
              UnknownThreatDefaultAction
              LowThreatDefaultAction
              ModerateThreatDefaultAction
              HighThreatDefaultAction
              SevereThreatDefaultAction
              SubmitSamplesConsent
              DisableBlockAtFirstSeen
              CloudBlockLevel
              CloudExtendedTimeout
              EnableNetworkProtection
              EnableControlledFolderAccess
              AttackSurfaceReductionOnlyExclusions
              ControlledFolderAccessAllowedApplications
              ControlledFolderAccessProtectedFolders
              AttackSurfaceReductionRules_Ids
              AttackSurfaceReductionRules_Actions
              ;
          };
        }
      ];
    }) cfg.defender
  );
}
