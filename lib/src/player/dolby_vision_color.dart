import '../platform/window_host.dart';

/// Selects the decoding path used before gpu-next performs colour conversion.
///
/// Windows hardware decoders do not consistently forward Dolby Vision RPU
/// side data to libplacebo. Prefer software decoding for DV so Profile 5/7/8
/// frames are reshaped before they reach the Flutter texture.
String playerHwdecValue({
  required bool enabled,
  required bool dolbyVision,
  bool? isDesktop,
}) {
  if (!enabled) return 'no';
  final desktop = isDesktop ?? WindowHost.isDesktop;
  if (desktop && dolbyVision) return 'no';
  // Keep decoded Windows frames on the GPU: the copy-back path stalls 4K60
  // HEVC playback on the measured RTX 3080 setup. Android remains unchanged.
  return desktop ? 'd3d11va' : 'mediacodec-copy';
}

/// libplacebo settings that map DV/HDR to the display's actual HDR10 or SDR
/// target instead of showing the unreshaped base layer.
Map<String, String> playerColorProperties({required bool hdrEnabled}) => {
  'target-colorspace-hint': hdrEnabled ? 'auto' : 'no',
  'target-colorspace-hint-mode': 'target',
  'tone-mapping': 'bt.2446a',
  'gamut-mapping-mode': 'perceptual',
  'hdr-compute-peak': 'auto',
  'dither-depth': 'auto',
};
