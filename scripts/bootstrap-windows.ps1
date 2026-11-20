param([Parameter(Mandatory=$true)][Uri]$ArchiveUrl)
$ErrorActionPreference = 'Stop'
if ($ArchiveUrl.Scheme -ne 'https') { throw 'Use an HTTPS source archive URL.' }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('localsend-encoder-' + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $archive = Join-Path $temp 'source.zip'
    $expanded = Join-Path $temp 'expanded'
    Invoke-WebRequest -Uri $ArchiveUrl -OutFile $archive -UseBasicParsing
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded
    $root = @(Get-ChildItem -LiteralPath $expanded -Directory)
    if ($root.Count -ne 1) { throw 'Unexpected source archive structure.' }
    $installer = Join-Path $root[0].FullName 'scripts\install-windows.cmd'
    & $installer
    if ($LASTEXITCODE -ne 0) { throw "Installer exited with code $LASTEXITCODE." }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
