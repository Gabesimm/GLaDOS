@echo off
rem Starts the GLaDOS server (minimized) and opens the GLaDOS window.
start "GLaDOS" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
