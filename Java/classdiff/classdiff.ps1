[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)] [string] $Before,
    [Parameter(Mandatory = $true, Position = 1)] [string] $After,
    [Parameter(Position = 2)] [string] $Output = "classdiff-report.md"
)
$ErrorActionPreference = "Stop"
$sourceFile = Join-Path $PSScriptRoot "src\ClassDiff.java"
$buildDir = Join-Path $PSScriptRoot "build"

function Find-JdkTool([string] $Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    if ($env:JAVA_HOME) {
        $candidate = Join-Path $env:JAVA_HOME "bin\$Name.exe"
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    foreach ($root in @("C:\Program Files\Java", "C:\Program Files\Eclipse Adoptium", "C:\Program Files\Microsoft", "C:\Program Files\Amazon Corretto")) {
        if (Test-Path -LiteralPath $root) {
            $found = Get-ChildItem -LiteralPath $root -Recurse -Filter "$Name.exe" -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match "\\bin\\$Name\.exe$" } | Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }
    throw "JDK tool '$Name' was not found. Install JDK 8 or newer and set JAVA_HOME."
}

$java = Find-JdkTool "java"
$javac = Find-JdkTool "javac"
$javap = Find-JdkTool "javap"
if (-not (Test-Path -LiteralPath $buildDir)) { New-Item -ItemType Directory -Path $buildDir | Out-Null }
$classFile = Join-Path $buildDir "ClassDiff.class"
if (-not (Test-Path -LiteralPath $classFile) -or (Get-Item $sourceFile).LastWriteTimeUtc -gt (Get-Item $classFile).LastWriteTimeUtc) {
    & $javac -encoding UTF-8 -d $buildDir $sourceFile
    if ($LASTEXITCODE -ne 0) { throw "Compilation failed (exit $LASTEXITCODE)." }
}
& $java -cp $buildDir ClassDiff --javap $javap -o $Output $Before $After
exit $LASTEXITCODE
