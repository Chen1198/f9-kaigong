@echo off
chcp 65001 >nul
title F9开工 - 换皮肤
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Change-Skin.ps1"
