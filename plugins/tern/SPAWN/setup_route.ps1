# Offline native-terminal route observation; normal execution policy applies.
param([Parameter(Mandatory=$true)][string]$Output,[Parameter(Mandatory=$true)][string]$Nonce,[Parameter(Mandatory=$true)][string]$Value)
$ErrorActionPreference = 'Stop'
if (-not [IO.Path]::IsPathRooted($Output) -or $Output -match '[\r\n]' -or $Output -match '(^|[\\/])\.\.?([\\/]|$)') { throw 'Absolute diagnostic path without traversal required' }
if ($Nonce -notmatch '^[a-z0-9_-]+$') { throw 'Invalid diagnostic identity' }
$parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Output))
while ($parent) {
 $item = Get-Item -LiteralPath $parent -Force
 if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe diagnostic directory' }
 $parent = [IO.Path]::GetDirectoryName($parent)
}
$hash = [Security.Cryptography.SHA256]::Create()
try { $digest = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
$bytes = [Text.Encoding]::UTF8.GetBytes($Nonce+"`n"+$digest+"`n"+[Security.Principal.WindowsIdentity]::GetCurrent().Name+"`n")
$file = [IO.File]::Open($Output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try { $file.Write($bytes,0,$bytes.Length) } finally { $file.Dispose() }
Write-Output 'SPAWN native route diagnostic complete'
# Retain this PowerShell invocation until native owner cleanup, with one fixed
# lifetime after publication. Output alone never proves native pane ownership.
Start-Sleep -Seconds 45
