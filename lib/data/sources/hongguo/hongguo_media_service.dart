import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/config/source_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../domain/models/playback_source.dart';
import 'hongguo_app_client.dart';
import 'hongguo_parser.dart';
import 'hongguo_playback_codec.dart';

final class HongguoMediaService {
  HongguoMediaService(this.client, this.config);
  final HongguoAppClient client;
  final SourceConfig config;

  Future<PlaybackOptions> resolve(
    String videoId, {
    CancelToken? cancelToken,
  }) async {
    // 红果取播放地址必须走 preload 入口 + video_platform=1024 +
    // mixed_video_id_map 的 key "1"，并带完整签名(见 HongguoAppClient)。
    // 旧端点 /novel/player/video_model/v1/ + platform=3 已被服务端静默返回空体。
    final result = await client.post(
      '/novel/player/multi_video_model/preload/v1',
      {
        'biz_param': {
          'detail_page_version': 0,
          'device_level': 3,
          'disable_digg_stat': false,
          'disable_video_relate_book': false,
          'need_all_video_definition': true,
          'need_mp4_align': false,
          'use_os_player': false,
          'use_server_dns': false,
          'video_platform': 1024,
        },
        'dr_scene': 'preload',
        'mixed_video_id_map': {'1': [videoId]},
      },
      cancelToken: cancelToken,
    );
    final data = objectMap(result['data']);
    final value = objectMap(data[videoId])['video_model'];
    if (value == null) throw const AppException('App 未返回该集播放信息');
    try {
      final model = value is String ? jsonDecode(value) : value;
      return parse(objectMap(model));
    } on FormatException {
      throw const AppException('App 播放信息格式异常');
    }
  }

  PlaybackOptions parse(Map<String, dynamic> model) {
    final rows = model['video_list'];
    final variants = rows is Map ? rows.values.toList() : anyList(rows);
    final seconds = double.tryParse(
      field(model, ['video_duration', 'duration']),
    );
    final duration = seconds != null && seconds.isFinite && seconds > 0
        ? Duration(milliseconds: (seconds * 1000).round())
        : null;
    final sources = <({PlaybackSource source, int score})>[];
    for (final row in variants) {
      final variant = objectMap(row);
      final meta = objectMap(variant['video_meta']);
      final codec = field(meta, ['codec_type']).toLowerCase();
      if (codec == 'bytevc2' ||
          field(variant, ['gear_des_key']).toLowerCase().contains('bytevc2')) {
        continue;
      }
      final uri = mediaUri(field(variant, ['main_url']));
      if (uri == null) continue;
      final encryption = objectMap(variant['encrypt_info']);
      // 优先顶层 spade_a；encrypt_info.spade_a 作为兜底(不同接口返回位置不一致)。
      final spade = field(variant, ['spade_a'], field(encryption, ['spade_a']));
      final encrypted =
          spade.isNotEmpty ||
          encryption['encrypt'] == true ||
          field(encryption, ['encryption_method']) == 'cenc-aes-ctr';
      try {
        final key = encrypted
            ? const HongguoPlaybackCodec().decodeContentKey(spade)
            : null;
        final definition = int.tryParse(
          RegExp(r'\d+').firstMatch(field(meta, ['definition']))?.group(0) ??
              '',
        );
        final height =
            definition ?? int.tryParse(field(meta, ['vheight'])) ?? 0;
        sources.add((
          source: PlaybackSource(
            uri: uri,
            kind: encrypted
                ? PlaybackKind.cenc
                : uri.path.toLowerCase().contains('.m3u8')
                ? PlaybackKind.hls
                : PlaybackKind.direct,
            headers: config.playbackHeaders(mediaReferer: config.mediaReferer),
            duration: duration,
            contentKey: key,
            route: PlaybackRoute.app,
            quality: height > 0 ? '${height}P' : '原画',
          ),
          score:
              height * 10 + (['h264', 'avc1', 'avc'].contains(codec) ? 1 : 0),
        ));
      } on AppException {
        // A broken encrypted variant must not hide other playable variants.
        continue;
      }
    }
    sources.sort((a, b) => b.score.compareTo(a.score));
    if (sources.isEmpty) throw const AppException('App 未返回兼容的媒体');
    final qualities = <String>{};
    return PlaybackOptions([
      for (final item in sources)
        if (qualities.add(item.source.quality)) item.source,
    ]);
  }
}
