param([string]$Action)
# NV-DB-Unlock v1.2 - https://github.com/hawk1ngyang/NV-DB-Unlock
# All messages ASCII on purpose (cmd/PowerShell 5.1 codepage safety).
$ErrorActionPreference = 'Continue'
$dir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$dump     = Join-Path $dir 'tools\acpidump.exe'
$guidFile = Join-Path $dir 'oc_guid.txt'
$bcdBak   = Join-Path $dir 'bcd_backup'
$latin1   = [Text.Encoding]::GetEncoding(28591)
# Tables that may contain personal data (MSDM = Windows product key). Never scanned or exported.
$PRIVATE  = @('msdm.dat','slic.dat')

# Mandatory System Restore point. Returns $true only if a NEW restore point is confirmed.
function New-RestorePointChecked([string]$desc) {
  try {
    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
    # Windows allows only 1 restore point per 24h by default; lift that limit for this call.
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    New-ItemProperty -Path $k -Name 'SystemRestorePointCreationFrequency' -PropertyType DWord -Value 0 -Force | Out-Null
    $before = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue).Count
    Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    $rp = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue)
    if ($rp.Count -gt $before -and $rp[-1].Description -eq $desc) {
      Write-Host ("      restore point #{0} '{1}' created" -f $rp[-1].SequenceNumber, $desc) -ForegroundColor Green
      return $true
    }
    throw 'restore point was not created (System Protection disabled or no shadow storage?)'
  } catch {
    Write-Host ('ERROR: cannot create System Restore point: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host '       Fix: Start > "Create a restore point" > select C: > Configure > Turn on system protection (5%), then retry.' -ForegroundColor Red
    return $false
  }
}

# Called when a restore point could not be created. User may force-continue at own risk.
function Confirm-NoRestorePoint([string]$step) {
  Write-Host ''
  Write-Host '==================== WARNING / 警告 ====================' -ForegroundColor Yellow
  Write-Host '无法创建系统还原点。你可以选择强制继续，但后果由你自己承担，作者不负任何责任。' -ForegroundColor Yellow
  Write-Host ''
  Write-Host '强制继续可能的后果：' -ForegroundColor Yellow
  Write-Host '  1. 出问题时无法用“系统还原”一键回到修改前的状态。'
  Write-Host '  2. 如果开机异常（卡在 OpenCore、黑屏、找不到启动项），只能手动修复：'
  Write-Host '     开机按启动菜单键选 Windows Boot Manager -> 管理员运行 9_uninstall.bat；'
  Write-Host '     或进入 Windows 恢复环境 -> 命令提示符执行  bcdboot C:\Windows'
  Write-Host '  3. 如果以上手动修复都失败，可能需要重装 Windows，未备份的数据可能丢失。'
  Write-Host '  4. 功耗提高可能导致温度升高、电池在高负载下放电，后果自负。'
  Write-Host ''
  Write-Host 'Could not create a System Restore point. You may force-continue AT YOUR OWN RISK.' -ForegroundColor Yellow
  Write-Host 'Without it you cannot roll back with System Restore; boot problems must be fixed manually' -ForegroundColor Yellow
  Write-Host '(boot menu -> Windows Boot Manager -> 9_uninstall.bat, or WinRE: bcdboot C:\Windows),' -ForegroundColor Yellow
  Write-Host 'and in the worst case Windows may need to be reinstalled. The author accepts no liability.' -ForegroundColor Yellow
  Write-Host '=========================================================' -ForegroundColor Yellow
  $a = Read-Host '确认风险并强制继续请输入大写 YES（其他任意输入 = 取消） / Type YES to force-continue'
  if ($a -ceq 'YES') {
    $log = Join-Path $dir 'forced_without_restore_point.txt'
    Add-Content -Path $log -Value ((Get-Date -Format 's') + "  user forced '$step' without a restore point")
    Write-Host '      forced by user, continuing without restore point' -ForegroundColor Yellow
    return $true
  }
  return $false
}

function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Mount-Esp { mountvol S: /D 2>$null | Out-Null; mountvol S: /S; if (-not (Test-Path 'S:\EFI')) { throw 'Mount EFI partition failed' } }
function Unmount-Esp { mountvol S: /D 2>$null | Out-Null }
function Is-NameChar([byte]$c, [bool]$first) {
  if ($c -eq 0x5F -or ($c -ge 0x41 -and $c -le 0x5A)) { return $true }
  if (-not $first -and $c -ge 0x30 -and $c -le 0x39) { return $true }
  return $false
}

function Dump-Acpi([string]$target) {
  New-Item -ItemType Directory -Force $target | Out-Null
  Remove-Item "$target\*.dat" -ErrorAction SilentlyContinue
  Push-Location $target; & $dump -b 2>&1 | Out-Null; Pop-Location
  foreach ($p in $PRIVATE) { Remove-Item (Join-Path $target $p) -ErrorAction SilentlyContinue }
}

# Classify every "TPPA" store found in DSDT/SSDTs.
#   Name    : 70 <NameSeg> 'TPPA'           (TPPA = <variable>)
#   Word    : 70 0B xx xx 'TPPA'            (TPPA = constant)
#   Patched : 70 0B 00 08 'TPPA'            (0x0800 = 256W; 0x0400 from v1.0 also accepted)
#   Field   : 8B .. 0A 19 'TPPA'            (CreateWordField(buf, 0x19, TPPA) -> TPP offset field of NVPCF table)
function Scan-Acpi {
  $v = Join-Path $dir 'scan'
  Dump-Acpi $v
  $r = @{ Name = 0; Word = 0; Patched = 0; Field = 0; Npcf = $false; Lines = @() }
  foreach ($f in Get-ChildItem "$v\*.dat") {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    if ($b.Length -lt 36) { continue }
    $sig = $latin1.GetString($b, 0, 4)
    if ($sig -ne 'DSDT' -and $sig -ne 'SSDT') { continue }
    $id = $latin1.GetString($b, 16, 8).Trim([char]0, ' ')
    $s  = $latin1.GetString($b)
    if ($s.Contains('NVDA0820')) { $r.Npcf = $true; $r.Lines += "  NPCF device (NVDA0820) in $($f.Name) [$id]" }
    $i = $s.IndexOf('TPPA', [StringComparison]::Ordinal)
    while ($i -ge 0) {
      $kind = $null
      if ($i -ge 4 -and $b[$i-4] -eq 0x70 -and $b[$i-3] -eq 0x0B -and $b[$i-2] -eq 0x00 -and ($b[$i-1] -eq 0x08 -or $b[$i-1] -eq 0x04)) { $r.Patched++; $kind = ('patched 0x{0:X2}00' -f $b[$i-1]) }
      elseif ($i -ge 4 -and $b[$i-4] -eq 0x70 -and $b[$i-3] -eq 0x0B) { $r.Word++; $kind = ('const 0x{0:X2}{1:X2}' -f $b[$i-1], $b[$i-2]) }
      elseif ($i -ge 5 -and $b[$i-5] -eq 0x70 -and (Is-NameChar $b[$i-4] $true) -and (Is-NameChar $b[$i-3] $false) -and (Is-NameChar $b[$i-2] $false) -and (Is-NameChar $b[$i-1] $false)) { $r.Name++; $kind = 'from ' + $latin1.GetString($b, $i-4, 4) }
      elseif ($i -ge 7 -and $b[$i-1] -eq 0x19 -and $b[$i-2] -eq 0x0A -and $b[$i-7] -eq 0x8B) { $r.Field++; $kind = 'field @0x19' }
      if ($kind) { $r.Lines += "  TPPA ($kind) at 0x$('{0:X}' -f $i) in $($f.Name) [$id]" }
      $i = $s.IndexOf('TPPA', $i + 4, [StringComparison]::Ordinal)
    }
  }
  Remove-Item $v -Recurse -Force -ErrorAction SilentlyContinue
  $r.Patchable = $r.Name + $r.Word
  return $r
}

function Show-Check($s) {
  $s.Lines | ForEach-Object { Write-Host $_ }
  if ($s.Patched -gt 0) { Write-Host 'ALREADY PATCHED (this boot went through OpenCore).' -ForegroundColor Green; return 'patched' }
  if (-not $s.Npcf) { Write-Host 'NOT COMPATIBLE: no NVPCF device (NVDA0820). This laptop has no Dynamic Boost 2.0.' -ForegroundColor Red; return 'no' }
  if ($s.Patchable -eq 1 -and $s.Field -ge 1) { Write-Host 'COMPATIBLE: NVPCF TPP store found exactly once. Safe to install.' -ForegroundColor Green; return 'ok' }
  if ($s.Patchable -gt 1) { Write-Host "UNSURE: $($s.Patchable) candidate stores found. Do NOT install. Run 4_export_acpi.bat and open an issue." -ForegroundColor Yellow; return 'unsure' }
  Write-Host 'NOT SUPPORTED YET: NVPCF exists but the BIOS code is written differently.' -ForegroundColor Yellow
  Write-Host 'Run 4_export_acpi.bat and attach the zip to a GitHub issue so a patch can be made for your model.' -ForegroundColor Yellow
  return 'no'
}

switch ($Action) {
 'check' { Show-Check (Scan-Acpi) | Out-Null }
 'install' {
  if (-not (Test-Admin)) { Write-Host 'ERROR: right-click the .bat -> Run as administrator' -ForegroundColor Red; break }
  try { if (Confirm-SecureBootUEFI) { Write-Host 'ERROR: Secure Boot is ON. Disable it in BIOS first.' -ForegroundColor Red; break } } catch {}
  $c = Show-Check (Scan-Acpi)
  if ($c -ne 'ok' -and $c -ne 'patched') { Write-Host 'Aborted, nothing changed.' -ForegroundColor Red; break }
  Write-Host '[0/4] System Restore point (mandatory) + BCD backup'
  if (-not (New-RestorePointChecked 'Before NV-DB-Unlock install')) {
    if (-not (Confirm-NoRestorePoint 'install')) { Write-Host 'Aborted, nothing changed.' -ForegroundColor Red; break }
  }
  if (-not (Test-Path $bcdBak)) { bcdedit /export $bcdBak | Out-Null }
  if (-not (Test-Path $bcdBak)) { Write-Host 'ERROR: BCD backup failed. Aborted, nothing changed.' -ForegroundColor Red; break }
  Write-Host '      BCD backup saved: bcd_backup'
  Write-Host '[1/4] Suspend BitLocker (ignore if not encrypted)'
  manage-bde -protectors -disable C: -RebootCount 3 | Out-Null
  Write-Host '[2/4] Copy OpenCore to EFI partition'
  try { Mount-Esp; robocopy (Join-Path $dir 'EFI\OC') 'S:\EFI\OC' /E /NFL /NDL /NJH /NJS | Out-Null; if (-not (Test-Path 'S:\EFI\OC\OpenCore.efi')) { throw 'copy failed' }; Write-Host '      OK' }
  catch { Write-Host ('ERROR: ' + $_) -ForegroundColor Red; Unmount-Esp; break }
  Unmount-Esp
  Write-Host '[3/4] Create boot entry (one-time)'
  $g = $null
  if (Test-Path $guidFile) { $g = (Get-Content $guidFile -Raw).Trim(); if (((bcdedit /enum $g) -join ' ') -notmatch 'OpenCore') { $g = $null } }
  if (-not $g) {
    $o = (bcdedit /copy '{bootmgr}' /d 'OpenCore NV-DB-Unlock') -join ' '
    if ($o -match '\{[0-9a-fA-F-]{36}\}') { $g = $matches[0] } else { Write-Host ('ERROR: ' + $o) -ForegroundColor Red; break }
    Set-Content -Path $guidFile -Value $g
  }
  bcdedit /set $g path '\EFI\OC\OpenCore.efi' | Out-Null
  bcdedit /set '{fwbootmgr}' bootsequence $g | Out-Null
  if (((bcdedit /enum '{fwbootmgr}') -join "`n") -match [regex]::Escape($g)) { Write-Host "      entry $g set as next boot" -ForegroundColor Green } else { Write-Host 'ERROR: bootsequence not set' -ForegroundColor Red; break }
  Write-Host '[4/4] DONE. Reboot now. Boot goes through OpenCore silently (hold Esc at power-on to show its menu).' -ForegroundColor Green
  Write-Host '      If it hangs: hold power button, power on again -> normal boot.'
 }
 'verify' {
  $s = Scan-Acpi
  if ($s.Patched -gt 0) { Write-Host 'PATCHED: NVPCF TPP unlocked (booted via OpenCore)' -ForegroundColor Green }
  else { Write-Host 'NOT PATCHED: this boot did not go through OpenCore (or BIOS changed)' -ForegroundColor Red }
 }
 'permanent' {
  if (-not (Test-Admin)) { Write-Host 'ERROR: Run as administrator' -ForegroundColor Red; break }
  if (-not (Test-Path $guidFile)) { Write-Host 'ERROR: run 1_install_test.bat first' -ForegroundColor Red; break }
  if ((Scan-Acpi).Patched -eq 0) { Write-Host 'ERROR: not patched in this boot. Reboot via OpenCore and run 2_verify.bat first.' -ForegroundColor Red; break }
  if (-not (New-RestorePointChecked 'Before NV-DB-Unlock make permanent')) {
    if (-not (Confirm-NoRestorePoint 'make permanent')) { Write-Host 'Aborted, nothing changed.' -ForegroundColor Red; break }
  }
  $g = (Get-Content $guidFile -Raw).Trim()
  bcdedit /set '{fwbootmgr}' displayorder $g /addfirst
  Write-Host 'OpenCore is now the default boot entry.' -ForegroundColor Green
 }
 'uninstall' {
  if (-not (Test-Admin)) { Write-Host 'ERROR: Run as administrator' -ForegroundColor Red; break }
  manage-bde -protectors -disable C: -RebootCount 2 | Out-Null
  if (Test-Path $guidFile) { $g = (Get-Content $guidFile -Raw).Trim(); bcdedit /delete $g | Out-Null; Remove-Item $guidFile }
  try { Mount-Esp; Remove-Item 'S:\EFI\OC' -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  Unmount-Esp
  # Make sure Windows Boot Manager is first again
  bcdedit /set '{fwbootmgr}' displayorder '{bootmgr}' /addfirst | Out-Null
  Write-Host 'OpenCore removed. Windows Boot Manager is the first boot entry again.' -ForegroundColor Green
  if (Test-Path $bcdBak) { Write-Host ('If boot still looks wrong, restore the full backup with:  bcdedit /import "' + $bcdBak + '"') }
 }
 'export' {
  $v = Join-Path $dir 'acpi_export'
  Dump-Acpi $v
  & {
   'NV-DB-Unlock compatibility report'
   'Model : ' + (Get-CimInstance Win32_ComputerSystem).Model
   'Maker : ' + (Get-CimInstance Win32_ComputerSystem).Manufacturer
   'BIOS  : ' + (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion
   nvidia-smi --query-gpu=name,driver_version,enforced.power.limit,power.default_limit,power.max_limit --format=csv
  } *>&1 | Out-File (Join-Path $v 'info.txt') -Encoding utf8
  $zip = Join-Path $dir 'acpi_for_issue.zip'
  Remove-Item $zip -ErrorAction SilentlyContinue
  Compress-Archive -Path "$v\*" -DestinationPath $zip
  Remove-Item $v -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "Saved: $zip" -ForegroundColor Green
  Write-Host 'MSDM (Windows key) table is excluded. No serial numbers are included.'
  Write-Host 'Attach this zip to: https://github.com/hawk1ngyang/NV-DB-Unlock/issues'
 }
 'diag' {
  $out = Join-Path $dir 'diag.txt'
  & {
   nvidia-smi -q -d POWER,PERFORMANCE
   nvidia-smi --query-gpu=name,driver_version,vbios_version,enforced.power.limit,power.default_limit,power.max_limit,power.draw --format=csv
   pnputil /enum-drivers | Select-String -Context 1,6 -Pattern 'nvpcf' | ForEach-Object { $_.ToString() }
  } *>&1 | Out-File -FilePath $out -Encoding utf8
  Write-Host "Saved: $out" -ForegroundColor Green
 }
 default { Write-Host 'Usage: oc.ps1 check|install|verify|permanent|uninstall|export|diag' }
}
