Add-Type -AssemblyName System.Drawing
$size = 256
$bitmap = New-Object System.Drawing.Bitmap $size,$size
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = 'AntiAlias'
$graphics.Clear([System.Drawing.Color]::Transparent)

# A calm, high-contrast mark: friendly white tile, black play face, tiny star.
$white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
$black = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(15,18,23))
$tile = [System.Drawing.RectangleF]::new(18,18,220,220)
$path = [System.Drawing.Drawing2D.GraphicsPath]::new()
$radius = 66
$path.AddArc($tile.X,$tile.Y,$radius,$radius,180,90)
$path.AddArc($tile.Right-$radius,$tile.Y,$radius,$radius,270,90)
$path.AddArc($tile.Right-$radius,$tile.Bottom-$radius,$radius,$radius,0,90)
$path.AddArc($tile.X,$tile.Bottom-$radius,$radius,$radius,90,90)
$path.CloseFigure()
$graphics.FillPath($white,$path)

$play = [System.Drawing.Drawing2D.GraphicsPath]::new()
$play.AddPolygon([System.Drawing.PointF[]]@(
  [System.Drawing.PointF]::new(98,83),
  [System.Drawing.PointF]::new(98,173),
  [System.Drawing.PointF]::new(177,128)
))
$graphics.FillPath($black,$play)
$graphics.FillEllipse($black,68,102,14,14)
$graphics.FillEllipse($black,68,140,14,14)
$pen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(15,18,23),6)
$graphics.DrawArc($pen,56,90,78,78,72,64)
$graphics.FillEllipse($black,180,56,16,16)
$graphics.FillEllipse($black,200,76,9,9)

$png = Join-Path $PSScriptRoot '..\windows\runner\resources\app_icon.png'
$ico = Join-Path $PSScriptRoot '..\windows\runner\resources\app_icon.ico'
$bitmap.Save($png,[System.Drawing.Imaging.ImageFormat]::Png)
$pngBytes = [System.IO.File]::ReadAllBytes($png)
$header = [byte[]](0,0,1,0,1,0,0,0,0,0,0,0,1,0,32,0,22,0,0,0,0,0)
[System.BitConverter]::GetBytes($pngBytes.Length).CopyTo($header,14)
[System.BitConverter]::GetBytes(22).CopyTo($header,18)
[System.IO.File]::WriteAllBytes($ico, $header + $pngBytes)
$pen.Dispose(); $black.Dispose(); $white.Dispose(); $graphics.Dispose(); $bitmap.Dispose(); $path.Dispose(); $play.Dispose()
