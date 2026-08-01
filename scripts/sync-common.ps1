function Get-AiRulesSafePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$ChildPath,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([System.IO.Path]::IsPathRooted($ChildPath)) {
        throw "$Label должен быть относительным путём: $ChildPath"
    }

    $baseFullPath = [System.IO.Path]::GetFullPath($BasePath).TrimEnd([char[]]@('\', '/'))
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $baseFullPath $ChildPath))
    $prefix = $baseFullPath + [System.IO.Path]::DirectorySeparatorChar
    if (
        $candidate -ne $baseFullPath -and
        -not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "$Label выходит за пределы разрешённого корня: $ChildPath"
    }

    return $candidate
}

function Get-AiRulesSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $textExtensions = @('.md', '.json', '.yml', '.yaml', '.txt')
    if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -in $textExtensions) {
        $content = [System.IO.File]::ReadAllText($Path)
        $normalizedContent = $content.Replace("`r`n", "`n").Replace("`r", "`n")
        $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
        $bytes = $utf8WithoutBom.GetBytes($normalizedContent)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash($bytes)
            return (($hashBytes | ForEach-Object { $_.ToString('x2') }) -join '')
        }
        finally {
            $sha256.Dispose()
        }
    }

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
