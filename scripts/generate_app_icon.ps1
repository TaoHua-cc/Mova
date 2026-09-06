Add-Type -AssemblyName System.Drawing
$source = Join-Path $PSScriptRoot '..\app\assets\mova-logo.png'
$original = [System.Drawing.Image]::FromFile($source)
$sourceBitmap = [System.Drawing.Bitmap]::new($original)
$corners = @(
  $sourceBitmap.GetPixel(0, 0),
  $sourceBitmap.GetPixel($sourceBitmap.Width - 1, 0),
  $sourceBitmap.GetPixel(0, $sourceBitmap.Height - 1),
  $sourceBitmap.GetPixel($sourceBitmap.Width - 1, $sourceBitmap.Height - 1)
)
if ($corners.Where({ $_.A -ne 0 }).Count -gt 0) {
  $sourceBitmap.Dispose()
  $original.Dispose()
  throw 'Mova logo background must be transparent at all four corners.'
}
$sourceBitmap.Dispose()
$png = Join-Path $PSScriptRoot '..\windows\runner\resources\app_icon.png'
$ico = Join-Path $PSScriptRoot '..\windows\runner\resources\app_icon.ico'
$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$layers = @()
foreach ($size in $sizes) {
  $bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
  $graphics.CompositingQuality = 'HighQuality'
  $graphics.InterpolationMode = 'HighQualityBicubic'
  $graphics.SmoothingMode = 'HighQuality'
  $graphics.PixelOffsetMode = 'HighQuality'
  $graphics.Clear([System.Drawing.Color]::Transparent)
  $graphics.DrawImage($original, 0, 0, $size, $size)
  $graphics.Dispose()

  $outputCorners = @(
    $bitmap.GetPixel(0, 0),
    $bitmap.GetPixel($size - 1, 0),
    $bitmap.GetPixel(0, $size - 1),
    $bitmap.GetPixel($size - 1, $size - 1)
  )
  if ($outputCorners.Where({ $_.A -ne 0 }).Count -gt 0) {
    $bitmap.Dispose()
    $original.Dispose()
    throw "Generated ${size}px Windows icon background is not transparent."
  }

  $stream = [System.IO.MemoryStream]::new()
  $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
  if ($size -eq 256) {
    $bitmap.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
  }
  $layers += ,@($size, $stream.ToArray())
  $stream.Dispose()
  $bitmap.Dispose()
}

$icoStream = [System.IO.MemoryStream]::new()
$writer = [System.IO.BinaryWriter]::new($icoStream)
$writer.Write([uint16]0)
$writer.Write([uint16]1)
$writer.Write([uint16]$layers.Count)
$offset = 6 + (16 * $layers.Count)
foreach ($layer in $layers) {
  $size = [int]$layer[0]
  $bytes = [byte[]]$layer[1]
  $writer.Write([byte]$(if ($size -eq 256) { 0 } else { $size }))
  $writer.Write([byte]$(if ($size -eq 256) { 0 } else { $size }))
  $writer.Write([byte]0)
  $writer.Write([byte]0)
  $writer.Write([uint16]1)
  $writer.Write([uint16]32)
  $writer.Write([uint32]$bytes.Length)
  $writer.Write([uint32]$offset)
  $offset += $bytes.Length
}
foreach ($layer in $layers) {
  $writer.Write([byte[]]$layer[1])
}
$writer.Flush()
[System.IO.File]::WriteAllBytes($ico, $icoStream.ToArray())
$writer.Dispose()
$icoStream.Dispose()
$original.Dispose()
