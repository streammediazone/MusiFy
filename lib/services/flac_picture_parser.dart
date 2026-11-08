import 'dart:typed_data';

class FlacPictureResult {
  const FlacPictureResult(this.complete, this.image);
  final bool complete;
  final Uint8List? image;
}

/// Parses FLAC metadata from a growing byte buffer without copying the full
/// buffer on each chunk. Only the embedded image bytes are copied on success.
FlacPictureResult readFlacPicture(List<int> bytes) {
  if (bytes.length < 4) return const FlacPictureResult(false, null);
  if (bytes[0] != 0x66 || bytes[1] != 0x4C || bytes[2] != 0x61 || bytes[3] != 0x43) {
    return const FlacPictureResult(true, null);
  }
  var offset = 4;
  while (true) {
    if (bytes.length < offset + 4) return const FlacPictureResult(false, null);
    final header = bytes[offset];
    final type = header & 0x7F;
    final last = (header & 0x80) != 0;
    final length = (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
    final end = offset + 4 + length;
    if (bytes.length < end) return const FlacPictureResult(false, null);
    if (type == 6) {
      var p = offset + 4;
      int read32() {
        if (p + 4 > end) throw const FormatException('Neúplný FLAC PICTURE blok.');
        final value = (bytes[p] << 24) | (bytes[p + 1] << 16) | (bytes[p + 2] << 8) | bytes[p + 3];
        p += 4;
        return value;
      }
      try {
        read32(); // picture type
        final mimeLength = read32();
        if (mimeLength < 0 || p + mimeLength > end) throw const FormatException('Neplatná MIME dĺžka.');
        p += mimeLength;
        final descriptionLength = read32();
        if (descriptionLength < 0 || p + descriptionLength > end) throw const FormatException('Neplatná dĺžka popisu.');
        p += descriptionLength;
        read32(); read32(); read32(); read32(); // dimensions, depth, indexed colors
        final imageLength = read32();
        if (imageLength <= 0 || p + imageLength > end) return FlacPictureResult(last, null);
        return FlacPictureResult(true, Uint8List.fromList(bytes.sublist(p, p + imageLength)));
      } catch (_) {
        return FlacPictureResult(last, null);
      }
    }
    offset = end;
    if (last) return const FlacPictureResult(true, null);
  }
}

