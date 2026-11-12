param([string]$Action)
# ROG-DB-Unlock - https://github.com/hawk1ngyang/ROG-DB-Unlock
# All messages ASCII on purpose (cmd/PowerShell 5.1 codepage safety).
$ErrorActionPreference = 'Continue'
$dir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$dump     = Join-Path $dir 'tools\acpidump.exe'
$guidFile = Join-Path $dir 'oc_guid.txt'
$bcdBak   = Join-Path $dir 'bcd_backup'
# AML: Store(ATPP, TPPA)  /  patched: Store(0x0400, TPPA); Noop
$PAT_ORIG    = [byte[]](0x70,0x41,0x54,0x50,0x50,0x54,0x50,0x50,0x41)
$PAT_PATCHED = [byte[]](0x70,0x0B,0x00,0x04,0x54,0x50,0x50,0x41,0xA3)

function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Mount-Esp { mountvol S: /D 2>$null | Out-Null; mountvol S: /S; if (-not (Test-Path 'S:\EFI')) { throw 'Mount EFI partition failed' } }
function Unmount-Esp { mountvol S: /D 2>$null | Out-Null }

function Find-Bytes([byte[]]$b, [byte[]]$p) {
  $n = 0
  for ($i = 0; $i -le $b.Length - $p.Length; $i++) {
    $ok = $true
    for ($j = 0; $j -lt $p.Length; $j++) { if ($b[$i+$j] -ne $p[$j]) { $ok = $false; break } }
    if ($ok) { $n++ }
  }
  return $n
}

# Dump all SSDTs and count pattern hits. Returns @{ Orig=n; Patched=n; Tables=[...] }
function Scan-Acpi {
  $v = Join-Path $dir 'scan'
  New-Item -ItemType Directory -Force $v | Out-Null
  Remove-Item "$v\*.dat" -ErrorAction SilentlyContinue
  Push-Location $v; & $dump -b -n SSDT 2>&1 | Out-Null; Pop-Location
  $r = @{ Orig = 0; Patched = 0; Tables = @() }
  foreach ($f in Get-ChildItem "$v\*.dat") {
    $b  = [IO.File]::ReadAllBytes($f.FullName)
    $id = [Text.Encoding]::ASCII.GetString($b, 16, 8).Trim([char]0, ' ')
    $o  = Find-Bytes $b $PAT_ORIG
    $p  = Find-Bytes $b $PAT_PATCHED
    if ($o -or $p) { $r.Tables += "$($f.Name) [$id] orig=$o patched=$p" }
    $r.Orig += $o; $r.Patched += $p
  }
  Remove-Item $v -Recurse -Force -ErrorAction SilentlyContinue
  return $r
}

switch ($Action) {
 'check' {
  $s = Scan-Acpi
  $s.Tables | ForEach-Object { Write-Host "  $_" }
  if ($s.Patched -gt 0) { Write-Host 'ALREADY PATCHED (this boot went through OpenCore).' -ForegroundColor Green }
  elseif ($s.Orig -eq 1) { Write-Host 'COMPATIBLE: NVPCF TPP code found exactly once. Safe to install.' -ForegroundColor Green }
  elseif ($s.Orig -gt 1) { Write-Host "UNSURE: pattern found $($s.Orig) times. Do NOT install, open an issue with your ACPI dump." -ForegroundColor Yellow }
  else { Write-Host 'NOT COMPATIBLE: this BIOS does not use the expected NVPCF code. Do NOT install.' -ForegroundColor Red }
 }
 'install' {
  if (-not (Test-Admin)) { Write-Host 'ERROR: right-click the .bat -> Run as administrator' -ForegroundColor Red; break }
  try { if (Confirm-SecureBootUEFI) { Write-Host 'ERROR: Secure Boot is ON. Disable it in BIOS first.' -ForegroundColor Red; break } } catch {}
  $s = Scan-Acpi
  if ($s.Patched -eq 0 -and $s.Orig -ne 1) { Write-Host 'ERROR: compatibility check failed (run 0_check.bat). Aborted, nothing changed.' -ForegroundColor Red; break }
  Write-Host '[0/4] Backup BCD + restore point'
  if (-not (Test-Path $bcdBak)) { bcdedit /export $bcdBak | Out-Null }
  try { Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue; Checkpoint-Computer -Description 'Before ROG-DB-Unlock' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; Write-Host '      restore point created' } catch { Write-Host ('      restore point skipped: ' + $_.Exception.Message) }
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
    $o = (bcdedit /copy '{bootmgr}' /d 'OpenCore DB') -join ' '
    if ($o -match '\{[0-9a-fA-F-]{36}\}') { $g = $matches[0] } else { Write-Host ('ERROR: ' + $o) -ForegroundColor Red; break }
    Set-Content -Path $guidFile -Value $g
  }
  bcdedit /set $g path '\EFI\OC\OpenCore.efi' | Out-Null
  bcdedit /set '{fwbootmgr}' bootsequence $g | Out-Null
  if (((bcdedit /enum '{fwbootmgr}') -join "`n") -match [regex]::Escape($g)) { Write-Host "      entry $g set as next boot" -ForegroundColor Green } else { Write-Host 'ERROR: bootsequence not set' -ForegroundColor Red; break }
  Write-Host '[4/4] DONE. Reboot now. OpenCore menu shows, Windows starts in 3s.' -ForegroundColor Green
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
  $s = Scan-Acpi
  if ($s.Patched -eq 0) { Write-Host 'ERROR: not patched in this boot. Reboot via OpenCore and run 2_verify.bat first.' -ForegroundColor Red; break }
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
  Write-Host 'OpenCore removed. Original boot restored.' -ForegroundColor Green
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
 default { Write-Host 'Usage: oc.ps1 check|install|verify|permanent|uninstall|diag' }
}
