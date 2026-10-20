$null  = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]
$tnm   = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

# Minutes before start at which to notify
$leads = 10, 2

# Log every check window (set to $false once things work)
$debug = $true

$log = Join-Path $PSScriptRoot 'notify-meetings.log'
function Write-Log($msg) { "$(Get-Date -Format s)  $msg" | Out-File $log -Append -Encoding utf8 }

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
Write-Log "Started (PID $PID, user $env:USERNAME, elevated=$elevated)"

# Attach to an already-running classic Outlook only; never launch one.
# New-Object binds to the running instance via COM (doesn't depend on the ROT,
# which Outlook doesn't always register in), so only call it if OUTLOOK.EXE is up.
function Get-CalendarFolder {
  if (-not (Get-Process OUTLOOK -ErrorAction SilentlyContinue)) {
    Write-Log 'Outlook not running'
    return $null
  }
  try {
    $folder = (New-Object -ComObject Outlook.Application).GetNamespace('MAPI').GetDefaultFolder(9)
    Write-Log 'Attached to Outlook'
    return $folder
  } catch { Write-Log "Attach failed: $($_.Exception.Message)"; return $null }
}

$cal = $null
try {
  while ($true) {
    if (-not $cal) { $cal = Get-CalendarFolder }

    if ($cal) {
      try {
        # Fresh Items each tick: a long-held recurrence-expanded Items
        # collection doesn't reliably pick up events added after it was created.
        $items = $cal.Items
        $items.IncludeRecurrences = $true
        $items.Sort('[Start]')

        foreach ($lead in $leads) {
          $from = (Get-Date).AddMinutes($lead).ToString('g')
          $to   = (Get-Date).AddMinutes($lead + 1).ToString('g')
          $n = 0

          foreach ($m in $items.Restrict("[Start] >= '$from' AND [Start] < '$to'")) {
            $n++
            $subject = [Security.SecurityElement]::Escape($m.Subject)
            $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
            $xml.LoadXml(@"
<toast scenario="reminder">
  <visual><binding template="ToastGeneric">
    <text>$subject</text>
    <text>Starts in $lead minutes (at $($m.Start.ToString('t')))</text>
  </binding></visual>
  <actions><action activationType="system" arguments="dismiss" content=""/></actions>
</toast>
"@)
            $tnm::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
            Write-Log "Toast: $($m.Subject) ($lead min)"
          }
          if ($debug) { Write-Log "Checked [$from, $to): $n match(es)" }
        }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($items)
      } catch {   # Outlook closed/restarted: re-attach next tick
        Write-Log "Error: $($_.Exception.Message)"
        $cal = $null
      }
    }

    # Sleep to the top of the next minute so windows don't overlap or skip
    Start-Sleep -Seconds (60 - (Get-Date).Second)
  }
} finally {
  if ($cal) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($cal) }
}
