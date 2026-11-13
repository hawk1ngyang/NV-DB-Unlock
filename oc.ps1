param([string]$Action)
# NV-DB-Unlock v1.4 - https://github.com/hawk1ngyang/NV-DB-Unlock
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

# Robust boolean result: PowerShell functions return every uncaptured output; take only the last value.
function Ok($x) { $a = @($x); return ($a.Count -gt 0 -and $a[-1] -eq $true) }
# ---- Secure Boot mode support ----
# OK to proceed if Secure Boot is off, OR (on AND EFI\OC\keys\ISK.cer is enrolled in the firmware db).
function Test-SecureBootReady {
  $on = $false
  try { $on = [bool](Confirm-SecureBootUEFI) } catch { $on = $false }
  if (-not $on) { return 'off' }
  $cer = Join-Path $dir 'EFI\OC\keys\ISK.cer'
  if (-not (Test-Path $cer)) { return 'on-unsigned' }
  try {
    $db = (Get-SecureBootUEFI -Name db).Bytes
    $c  = [IO.File]::ReadAllBytes($cer)
    $hay = $latin1.GetString($db); $needle = $latin1.GetString($c)
    if ($hay.Contains($needle)) { return 'on-enrolled' }
  } catch {}
  return 'on-not-enrolled'
}

function Test-BitLockerOn {
  try { $v = Get-CimInstance -Namespace 'root\cimv2\security\microsoftvolumeencryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$($env:SystemDrive)'" -ErrorAction Stop
        return ($v -and $v.ProtectionStatus -eq 1) } catch { return $false }
}
function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Mount-Esp { mountvol S: /D 2>$null | Out-Null; mountvol S: /S; if (-not (Test-Path 'S:\EFI')) { throw 'Mount EFI partition failed' } }
function Unmount-Esp { mountvol S: /D 2>$null | Out-Null }
function Is-NameChar([byte]$c, [bool]$first) {
  if ($c -eq 0x5F -or ($c -ge 0x41 -and $c -le 0x5A)) { return $true }
  if (-not $first -and $c -ge 0x30 -and $c -le 0x39) { return $true }
  return $false
}

# Find the AML Method (opcode 0x14 + PkgLength + NameString) that encloses byte offset $pos. Returns @(start,end) or $null.
function Get-MethodRange([byte[]]$b, [int]$pos) {
  $lo = [Math]::Max(0, $pos - 0x10000)
  for ($k = $pos - 1; $k -ge $lo; $k--) {
    if ($b[$k] -ne 0x14 -or $k + 6 -ge $b.Length) { continue }
    $lead = $b[$k+1]; $n = $lead -shr 6
    if ($n -eq 0) { $len = $lead -band 0x3F } else { $len = $lead -band 0x0F; for ($j = 0; $j -lt $n; $j++) { $len = $len -bor ([int]$b[$k+2+$j] -shl (4 + 8*$j)) } }
    $end = $k + 1 + $len; $q = $k + 2 + $n
    while ($q -lt $b.Length -and ($b[$q] -eq 0x5C -or $b[$q] -eq 0x5E)) { $q++ }
    if ($q + 3 -ge $b.Length) { continue }
    if ($end -gt $pos -and $end -le $b.Length -and (Is-NameChar $b[$q] $true) -and (Is-NameChar $b[$q+1] $false) -and (Is-NameChar $b[$q+2] $false) -and (Is-NameChar $b[$q+3] $false)) { return ,@($k, $end) }
  }
  return $null
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
  $r = @{ Name = 0; Word = 0; Patched = 0; Field = 0; Npcf = $false; Lines = @(); SameMethod = $false }
  $stores = @(); $fields = @()
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
      if ($kind -and $kind -eq 'field @0x19') { $fields += ,@($f.Name, (Get-MethodRange $b $i)) }
      elseif ($kind -and $kind -notlike 'patched*') { $stores += ,@($f.Name, $i) }
      if ($kind) { $r.Lines += "  TPPA ($kind) at 0x$('{0:X}' -f $i) in $($f.Name) [$id]" }
      $i = $s.IndexOf('TPPA', $i + 4, [StringComparison]::Ordinal)
    }
  }
  # Several stores are accepted only if there is exactly ONE TPPA field (offset 0x19) and every store sits
  # inside the same AML method as that field (e.g. one branch per performance mode in the NVPCF _DSM).
  if ($fields.Count -eq 1 -and $fields[0][1] -and $stores.Count -ge 1) {
    $ok = $true
    foreach ($st in $stores) {
      if ($st[0] -ne $fields[0][0] -or $st[1] -lt $fields[0][1][0] -or $st[1] -ge $fields[0][1][1]) { $ok = $false }
    }
    $r.SameMethod = $ok
  }
  Remove-Item $v -Recurse -Force -ErrorAction SilentlyContinue
  $r.Patchable = $r.Name + $r.Word
  return $r
}

function Show-Check($s) {
  $s.Lines | ForEach-Object { Write-Host $_ }
  if ($s.Patched -gt 0 -and $s.Patchable -gt 0) { Write-Host "PARTIALLY PATCHED: $($s.Patched) patched, $($s.Patchable) not. Run diag.bat and open an issue." -ForegroundColor Yellow; return 'unsure' }
  if ($s.Patched -gt 0) { Write-Host "ALREADY PATCHED (this boot went through OpenCore, $($s.Patched) store(s))." -ForegroundColor Green; return 'patched' }
  if (-not $s.Npcf) { Write-Host 'NOT COMPATIBLE: no NVPCF device (NVDA0820). This laptop has no Dynamic Boost 2.0.' -ForegroundColor Red; return 'no' }
  if ($s.Patchable -eq 1 -and $s.Field -ge 1) { Write-Host 'COMPATIBLE: NVPCF TPP store found exactly once. Safe to install.' -ForegroundColor Green; return 'ok' }
  if ($s.Patchable -gt 1 -and $s.Field -eq 1 -and $s.SameMethod) { Write-Host "COMPATIBLE: $($s.Patchable) TPP stores (one per power mode), all inside the NVPCF method of the single TPP field. All will be set to 256W. Safe to install." -ForegroundColor Green; return 'ok' }
  if ($s.Patchable -gt 1) { Write-Host "UNSURE: $($s.Patchable) candidate stores found. Do NOT install. Run 4_export_acpi.bat and open an issue." -ForegroundColor Yellow; return 'unsure' }
  Write-Host 'NOT SUPPORTED YET: NVPCF exists but the BIOS code is written differently.' -ForegroundColor Yellow
  Write-Host 'Run 4_export_acpi.bat and attach the zip to a GitHub issue so a patch can be made for your model.' -ForegroundColor Yellow
  return 'no'
}

function Invoke-Install {
  if (-not (Test-Admin)) { Write-Host 'ERROR: right-click the .bat -> Run as administrator' -ForegroundColor Red; return $false }
  if (Test-BitLockerOn) { Write-Host 'ERROR: BitLocker / Device Encryption is ON for the system drive. Changing the boot path would trigger the BitLocker recovery screen. Turn it off first (Settings > Privacy & security > Device encryption, or Control Panel > BitLocker > Turn off), wait until decryption finishes, then run again.' -ForegroundColor Red; return $false }
  $sb = Test-SecureBootReady
  if ($sb -eq 'on-unsigned' -or $sb -eq 'on-not-enrolled') { Write-Host 'ERROR: Secure Boot is ON but the OpenCore signing certificate is not enrolled in the firmware db. Disable Secure Boot, or run 5_secure_boot.bat and enroll EFI\OC\keys\ISK.cer (see README: Secure Boot mode).' -ForegroundColor Red; return $false }
  if ($sb -eq 'on-enrolled') { Write-Host '      Secure Boot ON with enrolled NV-DB-Unlock key: OK' -ForegroundColor Green }
  $c = Show-Check (Scan-Acpi)
  if ($c -ne 'ok' -and $c -ne 'patched') { Write-Host 'Aborted, nothing changed.' -ForegroundColor Red; return $false }
  Write-Host '[0/4] System Restore point (mandatory) + BCD backup'
  if (-not (New-RestorePointChecked 'Before NV-DB-Unlock install')) {
    if (-not (Confirm-NoRestorePoint 'install')) { Write-Host 'Aborted, nothing changed.' -ForegroundColor Red; return $false }
  }
  if (-not (Test-Path $bcdBak)) { bcdedit /export $bcdBak | Out-Null }
  if (-not (Test-Path $bcdBak)) { Write-Host 'ERROR: BCD backup failed. Aborted, nothing changed.' -ForegroundColor Red; return $false }
  Write-Host '      BCD backup saved: bcd_backup'
  Write-Host '[1/4] Suspend BitLocker (ignore if not encrypted)'
  manage-bde -protectors -disable C: -RebootCount 3 | Out-Null
  Write-Host '[2/4] Copy OpenCore to EFI partition'
  try { Mount-Esp; robocopy (Join-Path $dir 'EFI\OC') 'S:\EFI\OC' /E /NFL /NDL /NJH /NJS | Out-Null; if (-not (Test-Path 'S:\EFI\OC\OpenCore.efi')) { throw 'copy failed' }; Write-Host '      OK' }
  catch { Write-Host ('ERROR: ' + $_) -ForegroundColor Red; Unmount-Esp; return $false }
  Unmount-Esp
  Write-Host '[3/4] Create boot entry (one-time)'
  $g = $null
  if (Test-Path $guidFile) { $g = (Get-Content $guidFile -Raw).Trim(); if (((bcdedit /enum $g) -join ' ') -notmatch 'OpenCore') { $g = $null } }
  if (-not $g) {
    $o = (bcdedit /copy '{bootmgr}' /d 'OpenCore NV-DB-Unlock') -join ' '
    if ($o -match '\{[0-9a-fA-F-]{36}\}') { $g = $matches[0] } else { Write-Host ('ERROR: ' + $o) -ForegroundColor Red; return $false }
    Set-Content -Path $guidFile -Value $g
  }
  bcdedit /set $g path '\EFI\OC\OpenCore.efi' | Out-Null
  # OpenCore boots the first valid entry of the firmware BootOrder (skipping itself). Make sure that is Windows Boot Manager,
  # otherwise OpenCore may pick another disk / USB / vendor entry, fail, and show its black menu.
  bcdedit /set '{fwbootmgr}' displayorder '{bootmgr}' /addfirst | Out-Null
  bcdedit /set '{fwbootmgr}' bootsequence $g | Out-Null
  if (((bcdedit /enum '{fwbootmgr}') -join "`n") -match [regex]::Escape($g)) { Write-Host "      entry $g set as next boot" -ForegroundColor Green } else { Write-Host 'ERROR: bootsequence not set' -ForegroundColor Red; return $false }
  Write-Host '[4/4] DONE. Reboot now. Boot goes through OpenCore silently (hold Esc at power-on to show its menu).' -ForegroundColor Green
  Write-Host '      If it hangs: hold power button, power on again -> normal boot.'
  return $true
}

# Optional Secure Boot mode: create a PER-MACHINE signing key (non-exportable, kept in the Windows cert store),
# sign OpenCore.efi with it and export the public certificate for the user to append to the firmware db.
function Invoke-SecureSign {
  if (-not (Test-Admin)) { Write-Host 'ERROR: Run as administrator' -ForegroundColor Red; return $false }
  $efi = Join-Path $dir 'EFI\OC\OpenCore.efi'
  $kd  = Join-Path $dir 'EFI\OC\keys'; New-Item -ItemType Directory -Force -Path $kd | Out-Null
  $tpFile = Join-Path $kd 'thumbprint.txt'; $cer = Join-Path $kd 'ISK.cer'
  $cert = $null
  if (Test-Path $tpFile) { $tp = (Get-Content $tpFile -Raw).Trim(); $cert = Get-Item ('Cert:\LocalMachine\My\' + $tp) -ErrorAction SilentlyContinue }
  if (-not $cert) {
    Write-Host '[1/4] Creating your personal signing key (RSA-2048, stays on this PC, cannot be exported)'
    $cert = New-SelfSignedCertificate -Subject ('CN=NV-DB-Unlock ISK (' + $env:COMPUTERNAME + ')') -Type CodeSigningCert `
      -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeyExportPolicy NonExportable `
      -CertStoreLocation 'Cert:\LocalMachine\My' -NotAfter (Get-Date).AddYears(20)
    if (-not $cert) { Write-Host 'ERROR: key creation failed' -ForegroundColor Red; return $false }
    Set-Content -Path $tpFile -Value $cert.Thumbprint
  } else { Write-Host '[1/4] Reusing your existing signing key' }
  Write-Host ('      key: ' + $cert.Subject + '  thumbprint ' + $cert.Thumbprint)
  Write-Host '[2/4] Signing OpenCore.efi'
  $tmp = Join-Path $env:TEMP 'nvdb_oc_sign.exe'   # .exe name so Windows picks the PE signer
  Copy-Item $efi $tmp -Force
  Set-AuthenticodeSignature -FilePath $tmp -Certificate $cert -HashAlgorithm SHA256 | Out-Null
  $sig = Get-AuthenticodeSignature -FilePath $tmp
  if (-not $sig.SignerCertificate -or $sig.SignerCertificate.Thumbprint -ne $cert.Thumbprint) { Write-Host 'ERROR: signing failed' -ForegroundColor Red; Remove-Item $tmp -Force; return $false }
  Copy-Item $tmp $efi -Force; Remove-Item $tmp -Force
  Write-Host '      OK' -ForegroundColor Green
  Write-Host '[3/4] Exporting public certificate EFI\OC\keys\ISK.cer'
  Export-Certificate -Cert $cert -FilePath $cer -Type CERT | Out-Null
  Write-Host '[4/4] Updating EFI partition (if OpenCore is installed)'
  try { Mount-Esp; if (Test-Path 'S:\EFI\OC') { robocopy (Join-Path $dir 'EFI\OC') 'S:\EFI\OC' /E /NFL /NDL /NJH /NJS | Out-Null; Write-Host '      EFI partition updated' } else { Write-Host '      not installed yet - run setup.bat (with Secure Boot still OFF) next' } } catch { Write-Host ('      ' + $_) }
  Unmount-Esp
  Write-Host ''
  Write-Host 'NEXT (in BIOS, see README "Secure Boot mode"):' -ForegroundColor Cyan
  Write-Host '  1. Copy EFI\OC\keys\ISK.cer to a FAT32 USB stick.'
  Write-Host '  2. BIOS > Secure Boot > Key Management > Authorized Signatures (db) > APPEND > ISK.cer'
  Write-Host '     (APPEND only! Never Set/Update/Delete.)'
  Write-Host '  3. Secure Boot Control = Enabled, save (F10). Then run 0_check: expect "Secure Boot: on-enrolled".'
  return $true
}

function Invoke-Permanent {
  if (-not (Test-Admin)) { Write-Host 'ERROR: Run as administrator' -ForegroundColor Red; return $false }
  if (-not (Test-Path $guidFile)) { Write-Host 'ERROR: run 1_install_test.bat first' -ForegroundColor Red; return $false }
  if ((Scan-Acpi).Patched -eq 0) { Write-Host 'ERROR: not patched in this boot. Reboot via OpenCore and run 2_verify.bat first.' -ForegroundColor Red; return $false }
  if (-not (New-RestorePointChecked 'Before NV-DB-Unlock make permanent')) {
    if (-not (Confirm-NoRestorePoint 'make permanent')) { Write-Host 'Aborted, nothing changed.' -ForegroundColor Red; return $false }
  }
  $g = (Get-Content $guidFile -Raw).Trim()
  bcdedit /set '{fwbootmgr}' displayorder '{bootmgr}' /addfirst | Out-Null   # Windows Boot Manager right after OpenCore
  bcdedit /set '{fwbootmgr}' displayorder $g /addfirst | Out-Null
  Write-Host 'OpenCore is now the default boot entry.' -ForegroundColor Green
  return $true
}

$TaskName = 'NV-DB-Unlock-Continue'
function Test-PermanentFirst {
  if (-not (Test-Path $guidFile)) { return $false }
  $g = (Get-Content $guidFile -Raw).Trim()
  $tok = @([regex]::Matches(((bcdedit /enum '{fwbootmgr}') -join "`n"), '\{[^}]+\}') | ForEach-Object { $_.Value })
  return ($tok.Count -gt 1 -and $tok[1] -eq $g)
}
function Ask-YesNo([string]$q) {
  $a = Read-Host ($q + ' [Y/N]')
  return ($a -match '^(y|yes)$')
}
function Register-Continue {
  $ps  = Join-Path $dir 'oc.ps1'
  $usr = "$env:USERDOMAIN\$env:USERNAME"
  $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $ps + '" setup-continue')
  $trg = New-ScheduledTaskTrigger -AtLogOn -User $usr
  $trg.Delay = 'PT15S'
  $pri = New-ScheduledTaskPrincipal -UserId $usr -LogonType Interactive -RunLevel Highest
  Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Principal $pri -Force | Out-Null
}
function Unregister-Continue { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }

switch ($Action) {
 'check' { Show-Check (Scan-Acpi) | Out-Null; Write-Host ('Secure Boot: ' + (Test-SecureBootReady)); Write-Host ('BitLocker on system drive: ' + $(if (Test-BitLockerOn) {'ON (turn off before install)'} else {'off'})) }
 'install' { Invoke-Install | Out-Null }
 'securesign' { Invoke-SecureSign | Out-Null }
 'setup' {
  if (-not (Test-Admin)) { Write-Host 'ERROR: run setup.bat (it asks for administrator rights itself)' -ForegroundColor Red; break }
  Write-Host '===== NV-DB-Unlock 一键安装向导 =====' -ForegroundColor Cyan
  $s = Scan-Acpi
  if ($s.Patched -gt 0) {
    if (Ok (Test-PermanentFirst)) { Write-Host '已安装并已设为永久，本次开机补丁已生效，无需任何操作。' -ForegroundColor Green; break }
    if (Test-Path $guidFile) {
      Write-Host '补丁本次已生效，但还没有设为永久（重启后会失效）。' -ForegroundColor Yellow
      if (Ok (Ask-YesNo '现在设为永久吗？')) { if (Ok (Invoke-Permanent)) { Write-Host '完成！以后每次开机都会自动生效。' -ForegroundColor Green } }
      break
    }
    Write-Host '本次开机补丁已生效（由其他位置的安装引导）。' -ForegroundColor Green; break
  }
  $c = Show-Check $s
  if ($c -ne 'ok') { Write-Host '本机不兼容，向导结束，没有做任何修改。' -ForegroundColor Red; break }
  Write-Host ''
  Write-Host '向导将依次：创建还原点 -> 备份启动配置 -> 安装 OpenCore（仅下一次启动生效）-> 重启。'
  Write-Host '重启后会自动弹出验证结果，确认生效后再询问是否设为永久。'
  Write-Host '如果重启卡住或黑屏：长按电源键关机再开机，即恢复原来的启动，什么都不会变。' -ForegroundColor Yellow
  if (-not (Ok (Ask-YesNo '开始安装吗？'))) { Write-Host '已取消，没有做任何修改。'; break }
  if (-not (Ok (Invoke-Install))) { Write-Host '安装未完成，向导结束。' -ForegroundColor Red; break }
  try { Register-Continue; Write-Host '      已设置：重启登录后自动继续验证' -ForegroundColor Green }
  catch { Write-Host ('      自动继续设置失败，重启后请手动运行 setup.bat：' + $_.Exception.Message) -ForegroundColor Yellow }
  if (Ok (Ask-YesNo '现在重启吗？（请先保存其他程序的工作）')) { shutdown /r /t 5 /c 'NV-DB-Unlock: rebooting through OpenCore' }
  else { Write-Host '稍后手动重启即可，重启登录后会自动继续。' }
 }
 'setup-continue' {
  Unregister-Continue
  Write-Host '===== NV-DB-Unlock 安装向导（重启后验证）=====' -ForegroundColor Cyan
  $s = Scan-Acpi
  if ($s.Patched -gt 0) {
    Write-Host '验证通过：本次开机已经过 OpenCore，补丁已生效（TPP = 256W）。' -ForegroundColor Green
    if (Ok (Test-PermanentFirst)) { Write-Host '已是永久启动，全部完成。' -ForegroundColor Green }
    elseif (Ok (Ask-YesNo '设为永久（以后每次开机都自动生效）吗？')) {
      if (Ok (Invoke-Permanent)) { Write-Host '全部完成！以后每次开机都会自动生效。' -ForegroundColor Green }
    } else { Write-Host '未设为永久：下次重启将恢复原厂启动。想设为永久时再运行 setup.bat。' }
  } else {
    Write-Host '验证未通过：本次开机没有经过 OpenCore，补丁未生效。系统保持原样，没有永久修改。' -ForegroundColor Red
    Write-Host '常见原因：安全启动仍开着 / 开机时手动选择了其他启动项。确认后可重新运行 setup.bat。'
  }
  Read-Host '按 Enter 关闭' | Out-Null
 }
 'verify' {
  $s = Scan-Acpi
  if ($s.Patched -gt 0) { Write-Host 'PATCHED: NVPCF TPP unlocked (booted via OpenCore)' -ForegroundColor Green }
  else { Write-Host 'NOT PATCHED: this boot did not go through OpenCore (or BIOS changed)' -ForegroundColor Red }
 }
 'permanent' { Invoke-Permanent | Out-Null }
 'uninstall' {
  if (-not (Test-Admin)) { Write-Host 'ERROR: Run as administrator' -ForegroundColor Red; break }
  Unregister-ScheduledTask -TaskName 'NV-DB-Unlock-Continue' -Confirm:$false -ErrorAction SilentlyContinue
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
   '==== boot ===='
   'LastBoot : ' + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
   'GUID file: ' + $(if (Test-Path $guidFile) { (Get-Content $guidFile -Raw).Trim() } else { '(none)' })
   'Patched  : ' + (Scan-Acpi).Patched
   '==== bcdedit fwbootmgr ===='
   bcdedit /enum '{fwbootmgr}'
   '==== bcdedit firmware ===='
   bcdedit /enum firmware
   '==== recent updates ===='
   Get-HotFix | Sort-Object InstalledOn -Descending -ErrorAction SilentlyContinue | Select-Object -First 5 | Format-Table -AutoSize HotFixID,InstalledOn,Description | Out-String
   '==== boot events (Kernel-Boot / Kernel-General, last 2 days) ===='
   Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-General'; Id=12,13; StartTime=(Get-Date).AddDays(-2)} -ErrorAction SilentlyContinue | Select-Object -First 10 | Format-Table -AutoSize TimeCreated,Id | Out-String
   '==== gpu ===='
   nvidia-smi -q -d POWER,PERFORMANCE
   nvidia-smi --query-gpu=name,driver_version,vbios_version,enforced.power.limit,power.default_limit,power.max_limit,power.draw --format=csv
   pnputil /enum-drivers | Select-String -Context 1,6 -Pattern 'nvpcf' | ForEach-Object { $_.ToString() }
  } *>&1 | Out-File -FilePath $out -Encoding utf8
  Write-Host "Saved: $out" -ForegroundColor Green
 }
 default { Write-Host 'Usage: oc.ps1 setup|check|install|verify|permanent|securesign|uninstall|export|diag' }
}
