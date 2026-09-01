# SPECTER server launcher
# First run:  right-click > Run with PowerShell, or:  ./run.ps1
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

# Create/refresh a local venv so we don't touch the system Python.
if (-not (Test-Path ".venv")) {
    Write-Host "[setup] creating virtual environment..."
    python -m venv .venv
}
& ".venv\Scripts\python.exe" -m pip install --quiet --upgrade pip
& ".venv\Scripts\python.exe" -m pip install --quiet -r requirements.txt

Write-Host "[run] starting SPECTER server (Ctrl+C to stop)..."
& ".venv\Scripts\python.exe" specter_server.py
