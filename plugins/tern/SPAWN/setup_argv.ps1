# Harmless setup-only literal argv observation; no provider or repository effects.
param([Parameter(Mandatory=$true)][string]$Value)
$ErrorActionPreference = 'Stop'
[Console]::Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value)))
