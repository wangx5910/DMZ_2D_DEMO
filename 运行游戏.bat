@echo off
chcp 65001 >nul
cd /d "%~dp0"
if not exist "Godot_v4.7.1-stable_win64.exe" (
  echo 缺少 Godot_v4.7.1-stable_win64.exe
  pause
  exit /b 1
)
start "" "%~dp0Godot_v4.7.1-stable_win64.exe" --path "%~dp0"
