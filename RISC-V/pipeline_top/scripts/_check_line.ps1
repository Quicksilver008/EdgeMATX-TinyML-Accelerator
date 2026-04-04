$x = 42
$md = @"
Line one
| col1 | col2 |
|------|------|
| $x   | foo  |
"@
Write-Host $md
