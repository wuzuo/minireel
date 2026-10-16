import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// X-Gorgon / X-Argus 等端内请求签名,移植自 hgtv-tv 的 Signer.kt
/// (GPL-3.0, 源自 drpys)。红果取播放地址的接口必须带完整签名,
/// 否则网关静默返回 200 + 空体(见 HongguoApi.kt 注释)。
///
/// 实测仅需 X-Gorgon + X-Argus + X-Khronos + X-Ladon 即可通过校验,
/// 无需对 query 做 branch=0 的偏移搜索(那是 X-Medusa 的约束)。
final class HongguoSigner {
  const HongguoSigner();

  /// 为给定 query + body 生成签名头。按 hgtv-tv `Signer.sign` 的实测可用子集。
  Map<String, String> sign(Uri uri, String body, DateTime now) {
    final query = uri.query;
    final bodyBytes = Uint8List.fromList(utf8.encode(body));
    final seconds = now.millisecondsSinceEpoch ~/ 1000;
    final ticket = now.millisecondsSinceEpoch;
    final random = Random().nextInt(65536);
    final bodyMd5 = MD5Digest().process(bodyBytes);
    final xssStub = _hex(bodyMd5).toUpperCase();
    final gorgon = _gorgon(query, bodyBytes, seconds, random);
    final argus = base64Encode(_le32(seconds));
    final ladon = base64Encode(_be32(seconds));
    return {
      'X-Khronos': '$seconds',
      'X-Gorgon': gorgon,
      'X-Argus': argus,
      'X-Ladon': ladon,
      'X-SS-STUB': xssStub,
      'X-SS-Req-Ticket': '$ticket',
      'X-TT-Request-Tag': 't=0;n=0',
      'passport-sdk-version': '50561',
      'X-XS-From-Web': '0',
      'X-TT-Dt': '',
    };
  }

  String _gorgon(String query, List<int> body, int ts, int random) {
    final queryMd5 = MD5Digest().process(
      Uint8List.fromList(utf8.encode(query)),
    );
    final bodyMd5 = MD5Digest().process(Uint8List.fromList(body));
    final input = <int>[
      ...queryMd5.sublist(0, 4),
      ...bodyMd5.sublist(0, 4),
      ...List.filled(4, 0),
      ..._le32(67503104),
      ..._be32(ts),
    ];
    final key = [
      0x4a,
      0x40,
      0x16,
      (random >> 8) & 255,
      0x47,
      0x6c,
      1,
      random & 255,
    ];
    final s = List<int>.generate(256, (i) => i);
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + s[i] + key[i % 8]) & 255;
      final t = s[i];
      s[i] = s[j];
      s[j] = t;
    }
    j = 0;
    final out = List<int>.filled(input.length, 0);
    for (var n = 0; n < input.length; n++) {
      final i = n + 1;
      j += s[i & 255];
      final y = s[j & 255];
      s[i & 255] = y;
      out[n] = input[n] ^ s[(y + y) & 255];
    }
    for (var i = 0; i < out.length; i++) {
      final value = ((out[i] >> 4) | (out[i] << 4)) & 255;
      final next = out[i + 1 < out.length ? i + 1 : 0];
      final reversed = (_reverse32((next ^ value) & 255) >>> 24) & 255;
      out[i] = (~(reversed ^ 20)) & 255;
    }
    final prefix = <int>[0x84, 0x04, random & 255, (random >> 8) & 255, 0x40, 1, ...out];
    return _hex(prefix);
  }

  int _reverse32(int x) {
    var r = 0;
    for (var i = 0; i < 32; i++) {
      r = (r << 1) | ((x >> i) & 1);
    }
    return r;
  }

  List<int> _le32(int n) =>
      [n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255];

  List<int> _be32(int n) =>
      [(n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255];

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
