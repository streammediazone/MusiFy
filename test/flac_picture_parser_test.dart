import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musify/services/flac_picture_parser.dart';

void _add32(BytesBuilder builder, int value) {
  builder.add([
    (value >> 24) & 0xff,
    (value >> 16) & 0xff,
    (value >> 8) & 0xff,
    value & 0xff,
  ]);
}

Uint8List _flacWithPicture() {
  final block = BytesBuilder();
  _add32(block, 3); // front cover
  final mime = ascii.encode('image/png');
  _add32(block, mime.length);
  block.add(mime);
  _add32(block, 0); // empty description
  _add32(block, 1); // width
  _add32(block, 1); // height
  _add32(block, 24); // depth
  _add32(block, 0); // indexed colors
  _add32(block, 4); // image length
  block.add([1, 2, 3, 4]);
  final picture = block.takeBytes();
  return Uint8List.fromList([
    0x66, 0x4c, 0x61, 0x43, // fLaC
    0x86, (picture.length >> 16) & 0xff, (picture.length >> 8) & 0xff, picture.length & 0xff,
    ...picture,
  ]);
}

void main() {
  test('extracts a complete embedded FLAC picture', () {
    final result = readFlacPicture(_flacWithPicture());
    expect(result.complete, isTrue);
    expect(result.image, orderedEquals([1, 2, 3, 4]));
  });

  test('reports incomplete metadata without failing', () {
    final bytes = _flacWithPicture();
    final result = readFlacPicture(bytes.sublist(0, bytes.length - 2));
    expect(result.complete, isFalse);
    expect(result.image, isNull);
  });

  test('recognizes a complete FLAC stream without a picture block', () {
    final result = readFlacPicture(Uint8List.fromList([
      0x66, 0x4c, 0x61, 0x43,
      0x80, 0x00, 0x00, 0x00, // last metadata block, type STREAMINFO, empty fixture
    ]));
    expect(result.complete, isTrue);
    expect(result.image, isNull);
  });
}
