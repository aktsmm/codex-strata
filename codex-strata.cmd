@echo off
rem SPDX-License-Identifier: Apache-2.0
rem Copyright 2026 aktsmm
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo [codex-strata] PowerShell 7 is required. Install it and reopen your terminal. 1>&2
  exit /b 1
)
pwsh.exe -NoLogo -NoProfile -File "%~dp0codex-strata.ps1" %*
exit /b %errorlevel%
