Add-Type -AssemblyName System.Drawing
$size = 256
$source = Join-Path $PSScriptRoot '..\app\assets\mova-logo.png'
$original = [System.Drawing.Image]::FromFile($source)
$bitmap = New-Object System.Drawing.Bitmap $size,$size
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CompositingQuality = 'HighQuality'
$graphics.InterpolationMode = 'HighQualityBicubic'
$graphics.SmoothingMode = 'HighQuality'
$graphics.PixelOffsetMode = 'HighQuality'
$graphics.Clear([System.Drawing.Color]::Transparent)
$graphics.DrawImage($original, 0, 0, $size, $size)

$png = Join-Path $PSScriptRoot '..\windows\runner\resources\app_icon.png'
$ico = Join-Path $PSScriptRoot '..\windows\runner\resources\app_icon.ico'
$bitmap.Save($png,[System.Drawing.Imaging.ImageFormat]::Png)
$pngBytes = [System.IO.File]::ReadAllBytes($png)
$header = [byte[]](0,0,1,0,1,0,0,0,0,0,0,0,1,0,32,0,22,0,0,0,0,0)
[System.BitConverter]::GetBytes($pngBytes.Length).CopyTo($header,14)
[System.BitConverter]::GetBytes(22).CopyTo($header,18)
[System.IO.File]::WriteAllBytes($ico, $header + $pngBytes)
$original.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
