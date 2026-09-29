Add-Type -AssemblyName System.Drawing

$source = Join-Path $PSScriptRoot '..\windows\runner\resources\app_icon.png'
$resources = Join-Path $PSScriptRoot '..\windows\runner\resources'
$designDirectory = Join-Path $PSScriptRoot '..\docs\design'
New-Item -ItemType Directory -Force -Path $designDirectory | Out-Null
$appIcon = [System.Drawing.Image]::FromFile($source)

function New-RoundRectPath([float]$x, [float]$y, [float]$width, [float]$height, [float]$radius) {
  $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $diameter = [Math]::Min($radius * 2, [Math]::Min($width, $height))
  $path.AddArc($x, $y, $diameter, $diameter, 180, 90)
  $path.AddArc($x + $width - $diameter, $y, $diameter, $diameter, 270, 90)
  $path.AddArc($x + $width - $diameter, $y + $height - $diameter, $diameter, $diameter, 0, 90)
  $path.AddArc($x, $y + $height - $diameter, $diameter, $diameter, 90, 90)
  $path.CloseFigure()
  return $path
}

function New-PlayerIcon([int]$size) {
  $bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
  $graphics.CompositingQuality = 'HighQuality'
  $graphics.InterpolationMode = 'HighQualityBicubic'
  $graphics.SmoothingMode = 'AntiAlias'
  $graphics.PixelOffsetMode = 'HighQuality'
  $graphics.Clear([System.Drawing.Color]::Transparent)
  $graphics.DrawImage($appIcon, 0, 0, $size, $size)

  # A fine pearl frame keeps the player glyph distinct at 16–24px taskbar sizes.
  $inset = [Math]::Max(1.0, $size * 0.055)
  $framePath = New-RoundRectPath $inset $inset ($size - 2 * $inset) ($size - 2 * $inset) ($size * 0.22)
  $framePen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(210, 235, 239, 245), [Math]::Max(1.0, $size * 0.022))
  $graphics.DrawPath($framePen, $framePath)
  $framePen.Dispose()
  $framePath.Dispose()

  $diameter = [Math]::Max(5.0, $size * 0.32)
  $x = $size - $diameter - $inset * 0.78
  $y = $size - $diameter - $inset * 0.78
  $ring = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 15, 19, 27))
  $pearl = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
    [System.Drawing.RectangleF]::new($x, $y, $diameter, $diameter),
    [System.Drawing.Color]::FromArgb(255, 255, 255, 252),
    [System.Drawing.Color]::FromArgb(255, 218, 225, 235),
    [System.Drawing.Drawing2D.LinearGradientMode]::Vertical
  )
  $graphics.FillEllipse($ring, $x - $size * 0.014, $y - $size * 0.014, $diameter + $size * 0.028, $diameter + $size * 0.028)
  $graphics.FillEllipse($pearl, $x, $y, $diameter, $diameter)
  $triangle = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $triangle.AddPolygon([System.Drawing.PointF[]]@(
    [System.Drawing.PointF]::new($x + $diameter * 0.40, $y + $diameter * 0.29),
    [System.Drawing.PointF]::new($x + $diameter * 0.70, $y + $diameter * 0.50),
    [System.Drawing.PointF]::new($x + $diameter * 0.40, $y + $diameter * 0.71)
  ))
  $ink = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 20, 25, 34))
  $graphics.FillPath($ink, $triangle)

  $ink.Dispose()
  $triangle.Dispose()
  $pearl.Dispose()
  $ring.Dispose()
  $graphics.Dispose()
  return $bitmap
}

$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$layers = @()
foreach ($size in $sizes) {
  $bitmap = New-PlayerIcon $size
  $stream = [System.IO.MemoryStream]::new()
  $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
  if ($size -eq 256) {
    $bitmap.Save((Join-Path $resources 'player_icon.png'), [System.Drawing.Imaging.ImageFormat]::Png)
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
foreach ($layer in $layers) { $writer.Write([byte[]]$layer[1]) }
$writer.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $resources 'player_icon.ico'), $icoStream.ToArray())
$writer.Dispose()
$icoStream.Dispose()

# A compact visual comparison plus realistic taskbar-size samples for design review.
$width = 1400
$height = 820
$board = [System.Drawing.Bitmap]::new($width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($board)
$g.SmoothingMode = 'AntiAlias'
$g.InterpolationMode = 'HighQualityBicubic'
$g.Clear([System.Drawing.Color]::FromArgb(255, 12, 15, 21))
$titleFont = [System.Drawing.Font]::new('Segoe UI', 28, [System.Drawing.FontStyle]::Bold)
$subFont = [System.Drawing.Font]::new('Segoe UI', 13, [System.Drawing.FontStyle]::Regular)
$labelFont = [System.Drawing.Font]::new('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$smallFont = [System.Drawing.Font]::new('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
$white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 244, 246, 249))
$muted = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 156, 165, 178))
$panel = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 22, 27, 35))
$hairline = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(90, 225, 231, 240), 1)
$g.DrawString('MOVA  /  PLAYER ICON', $titleFont, $white, 72, 56)
$g.DrawString('The M mark stays. A pearl play badge makes the playback window instantly recognizable.', $subFont, $muted, 74, 101)

$cards = @(@(72, 164, 'APP ICON', 'Original Mova identity'), @(722, 164, 'PLAYER ICON', 'M mark + playback signal'))
foreach ($card in $cards) {
  $cardPath = New-RoundRectPath $card[0] $card[1] 606 380 24
  $g.FillPath($panel, $cardPath)
  $g.DrawPath($hairline, $cardPath)
  $cardPath.Dispose()
  $g.DrawString($card[2], $labelFont, $white, $card[0] + 28, $card[1] + 24)
  $g.DrawString($card[3], $smallFont, $muted, $card[0] + 28, $card[1] + 47)
}
$g.DrawImage($appIcon, 233, 242, 240, 240)
$preview = New-PlayerIcon 256
$g.DrawImage($preview, 883, 242, 240, 240)
$preview.Dispose()
$g.DrawString('MOVA', $smallFont, $muted, 323, 500)
$g.DrawString('MOVA PLAYER', $smallFont, $muted, 951, 500)

$taskbarPath = New-RoundRectPath 72 590 1256 150 22
$g.FillPath($panel, $taskbarPath)
$g.DrawPath($hairline, $taskbarPath)
$taskbarPath.Dispose()
$g.DrawString('TASKBAR SCALE', $labelFont, $white, 100, 612)
$g.DrawImage($appIcon, 105, 654, 38, 38)
$g.DrawString('Mova', $smallFont, $muted, 154, 665)
$playerAtTaskbar = New-PlayerIcon 48
$g.DrawImage($playerAtTaskbar, 292, 654, 38, 38)
$g.DrawString('Mova Player / playing', $smallFont, $white, 341, 665)
$playerAtTaskbar.Dispose()
$g.DrawString('Same pearl M. Playback is marked by a framed edge and a clear play medallion.', $smallFont, $muted, 750, 666)

$board.Save((Join-Path $designDirectory 'player-icon-concept.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$hairline.Dispose()
$panel.Dispose()
$muted.Dispose()
$white.Dispose()
$smallFont.Dispose()
$labelFont.Dispose()
$subFont.Dispose()
$titleFont.Dispose()
$g.Dispose()
$board.Dispose()
$appIcon.Dispose()
