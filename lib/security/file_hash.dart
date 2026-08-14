import 'dart:io';
import 'dart:typed_data';

const int _mask32 = 0xffffffff;
const int _primeLow = 0x1b3;
const int _primeHigh = 0x100;

class Fnv1a64 {
  int _high = 0xcbf29ce4;
  int _low = 0x84222325;

  void add(List<int> bytes) {
    for (final byte in bytes) {
      _low = (_low ^ byte) & _mask32;
      final lowProduct = _low * _primeLow;
      final carry = lowProduct ~/ 0x100000000;
      final highProduct = _high * _primeLow + _low * _primeHigh + carry;
      _low = lowProduct & _mask32;
      _high = highProduct & _mask32;
    }
  }

  String digest() {
    final high = _high.toRadixString(16).padLeft(8, '0');
    final low = _low.toRadixString(16).padLeft(8, '0');
    return 'fnv1a64:$high$low';
  }
}

String hashBytes(List<int> bytes) {
  final hash = Fnv1a64()..add(bytes);
  return hash.digest();
}

Future<String> hashFile(String path) async {
  final hash = Fnv1a64();
  await for (final chunk in File(path).openRead()) {
    hash.add(chunk);
  }
  return hash.digest();
}

Future<String> hashRandomAccessFile(RandomAccessFile file) async {
  final hash = Fnv1a64();
  await file.setPosition(0);
  while (true) {
    final chunk = await file.read(1024 * 1024);
    if (chunk.isEmpty) break;
    hash.add(Uint8List.fromList(chunk));
  }
  return hash.digest();
}

bool hashMatches(String? expected, String actual) =>
    expected == null || expected.toLowerCase() == actual.toLowerCase();
