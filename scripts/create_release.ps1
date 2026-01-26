# Script para criar release manual
$Tag = $args[0]
if ($Tag -eq $null) {
    Write-Host "Uso: scripts\create_release.ps1 v0.1.2"
    exit 1
}

Write-Host "Criando release $Tag..."
Write-Host ""
Write-Host "Binario: artifacts\windows-x64\odbc_engine.dll"
Write-Host ""
Write-Host "Abrindo navegador..."
Start-Process "https://github.com/cesar-carlos/dart_odbc_fast/releases/new"
Write-Host ""
Write-Host "Instrucoes:"
Write-Host "  1. Tag: $Tag"
Write-Host "  2. Title: Release $Tag - Windows and Linux"
Write-Host "  3. Copie conteudo de artifacts\RELEASE_NOTES.md"
Write-Host "  4. Upload: artifacts\windows-x64\odbc_engine.dll"
Write-Host ""
Start-Sleep -Seconds 2
notepad artifacts\RELEASE_NOTES.md
