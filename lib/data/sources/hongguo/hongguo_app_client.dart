import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../../../core/config/source_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/network/app_http_client.dart';
import '../../local/app_store.dart';
import 'hongguo_parser.dart';
import 'hongguo_signer.dart';

final class HongguoAppClient {
  HongguoAppClient(this.config, this.transport, {this.store});
  final SourceConfig config;
  final TextClient transport;
  final SourceStateStore? store;
  Future<void>? _identityReady;
  late String _deviceId;
  late String _installId;

  bool get enabled =>
      config.appBaseUrl != null && transport is SignedJsonClient;

  Future<void> _loadIdentity() async {
    final saved = await store?.readSourceState('hongguo:identity');
    // 红果服务端会风控固定的静态设备号,这里改用 16 位随机号(对齐 hgtv-tv 的
    // VendorConstants,已实测签名可过)。旧的 19 位号会被重新生成为 16 位。
    String identity(dynamic value) {
      if (value is String && RegExp(r'^[0-9]{16}$').hasMatch(value)) {
        return value;
      }
      // nextInt 上限为 2^32-1,9e15 超出会抛错,故用 nextDouble 生成 16 位随机号。
      final random = Random.secure();
      final number =
          1000000000000000 + (random.nextDouble() * 9000000000000000).floor();
      return number.toString();
    }

    _deviceId = identity(saved?['deviceId']);
    _installId = identity(saved?['installId']);
    await store?.saveSourceState('hongguo:identity', {
      'deviceId': _deviceId,
      'installId': _installId,
    });
  }

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> payload, {
    CancelToken? cancelToken,
  }) async {
    if (!enabled) throw const AppException('App 数据源未配置');
    cancelToken?.throwIfCancellationRequested();
    try {
      await (_identityReady ??= _loadIdentity());
    } on Exception {
      _identityReady = null;
      throw const AppException('App 设备信息暂时无法保存', kind: FailureKind.storage);
    }
    cancelToken?.throwIfCancellationRequested();
    final body = jsonEncode(payload);
    late DateTime now;
    final signer = const HongguoSigner();
    final text = await (transport as SignedJsonClient).postSignedJson(
      () {
        now = DateTime.now();
        final seconds = now.millisecondsSinceEpoch ~/ 1000;
        final parameters = {
          ...config.appParameters,
          'iid': _installId,
          'device_id': _deviceId,
          'ts': '$seconds',
          '_rticket': '${now.millisecondsSinceEpoch}',
        };
        final keys = parameters.keys.toList()..sort();
        // 签名的 gorgon 计算于此处构造的 query;二者必须完全一致。
        final query = keys
            .map(
              (key) =>
                  '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(parameters[key]!)}',
            )
            .join('&');
        return config.appBaseUrl!.resolve(path).replace(query: query);
      },
      body,
      (uri) => {
        ...config.appHeaders,
        'User-Agent': config.appUserAgent,
        'Accept': 'application/json; charset=utf-8,application/x-protobuf',
        'Content-Type': 'application/json; charset=utf-8',
        'Sdk-Version': '2',
        ...signer.sign(uri, body, now),
      },
      cancelToken: cancelToken,
    );
    cancelToken?.throwIfCancellationRequested();
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      final code = field(decoded, [
        'code',
        'Code',
        'status_code',
      ], field(objectMap(decoded['BaseResp']), ['StatusCode']));
      if (code.isNotEmpty && code != '0') {
        throw const AppException('App 接口暂不可用');
      }
      return decoded;
    } on FormatException {
      throw const AppException('App 接口返回格式异常', kind: FailureKind.parsing);
    }
  }
}
