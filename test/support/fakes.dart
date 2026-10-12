import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:minireel/core/errors/app_exception.dart';
import 'package:minireel/data/local/app_store.dart';
import 'package:minireel/data/sources/source_adapter.dart';
import 'package:minireel/domain/models/drama.dart';
import 'package:minireel/domain/models/playback_source.dart';
import 'package:minireel/domain/models/preferences.dart';
import 'package:minireel/domain/models/watch_record.dart';
import 'package:minireel/playback/playback_engine.dart';

const sampleDrama = Drama(
  id: 'test:100',
  source: 'test',
  sourceId: '100',
  title: '雨夜重逢',
  intro: '在熟悉的街角，再一次相遇。',
  category: '甜宠',
  episodeCount: 4,
  tags: ['甜宠', '都市'],
);
final sampleEpisodes = List.generate(
  4,
  (i) => Episode(
    id: 'test:100:${i + 1}',
    dramaId: sampleDrama.id,
    sourceEpisodeId: '${i + 1}',
    index: i + 1,
  ),
);

PlaybackOptions mediaFor(Episode episode) => PlaybackOptions([
  PlaybackSource(
    uri: Uri.parse('https://example.invalid/${episode.index}.mp4'),
    kind: PlaybackKind.direct,
    headers: const {},
    quality: '1080P',
  ),
]);

class MemoryStore implements AppStore {
  final Map<String, Drama> catalog = {};
  final Map<String, DramaDetail> details = {};
  final Map<String, Drama> favorites = {};
  final Map<String, WatchRecord> history = {};
  Preferences preferences = const Preferences();
  List<String> searches = [];
  DateTime? lastRefresh;
  @override
  Future<List<Drama>> readCatalog() async => catalog.values.toList();
  @override
  Future<void> saveCatalog(List<Drama> dramas) async {
    for (final d in dramas) {
      catalog[d.id] = d;
    }
  }

  @override
  Future<DramaDetail?> readDetail(String id) async => details[id];
  @override
  Future<void> saveDetail(DramaDetail detail) async {
    details[detail.drama.id] = detail;
  }

  @override
  Future<List<Drama>> readFavorites() async => favorites.values.toList();
  @override
  Future<void> setFavorite(Drama drama, bool enabled) async {
    if (enabled) {
      favorites[drama.id] = drama;
    } else {
      favorites.remove(drama.id);
    }
  }

  @override
  Future<List<WatchRecord>> readHistory() async => history.values.toList();
  @override
  Future<void> saveRecord(WatchRecord record) async {
    history[record.drama.id] = record;
  }

  @override
  Future<void> deleteHistory(Iterable<String> ids) async {
    for (final id in ids) {
      history.remove(id);
    }
  }

  @override
  Future<Preferences> readPreferences() async => preferences;
  @override
  Future<void> savePreferences(Preferences value) async {
    preferences = value;
  }

  @override
  Future<List<String>> readSearches() async => searches;
  @override
  Future<void> saveSearches(List<String> value) async {
    searches = value;
  }

  @override
  Future<DateTime?> readLastRefresh() async => lastRefresh;
  @override
  Future<void> saveLastRefresh(DateTime time) async {
    lastRefresh = time;
  }

  @override
  Future<int> cacheBytes() async => catalog.length * 500;
  @override
  Future<void> clearCache() async {
    catalog.clear();
    details.clear();
    lastRefresh = null;
  }

  @override
  Future<void> close() async {}
}

class FakeSource implements DramaSourceAdapter {
  bool failCatalog = false;
  Future<PlaybackOptions> Function(Episode, CancelToken?)? resolve;
  Future<PlaybackOptions> Function(Episode, CancelToken?)? fallback;
  final fallbackRequests = <bool>[];
  Future<List<Drama>> Function(DramaChannel, int)? catalogLoader;
  @override
  String get id => 'test';
  @override
  String get displayName => 'Test source';
  @override
  int get maxPages => 3;
  @override
  int get pageSize => 2;
  @override
  Future<List<Drama>> fetchCatalog(
    DramaChannel channel,
    int page, {
    CancelToken? cancelToken,
  }) async {
    if (failCatalog) throw const AppException('测试网络不可用');
    if (catalogLoader != null) return catalogLoader!(channel, page);
    return channel == DramaChannel.real ? [sampleDrama] : [];
  }

  @override
  Future<DramaDetail> fetchDetail(
    Drama drama, {
    CancelToken? cancelToken,
  }) async => DramaDetail(drama: sampleDrama, episodes: sampleEpisodes);
  @override
  Future<PlaybackOptions> resolvePlayback(
    Drama drama,
    Episode episode, {
    CancelToken? cancelToken,
    bool fallbackOnly = false,
  }) async {
    fallbackRequests.add(fallbackOnly);
    if (fallbackOnly && fallback != null) {
      return fallback!(episode, cancelToken);
    }
    return resolve == null ? mediaFor(episode) : resolve!(episode, cancelToken);
  }
}

class FakeEngine implements PlaybackEngine {
  @override
  final ValueNotifier<EngineSnapshot> state = ValueNotifier(
    const EngineSnapshot(),
  );
  final opened = <String>[];
  final starts = <Duration>[];
  final rates = <double>[];
  final volumes = <double>[];
  bool disposed = false;
  Completer<void>? openGate;
  @override
  Future<void> open(
    PlaybackSource source, {
    required Duration start,
    required bool Function() isCurrent,
    String? episodeId,
    DecodeMethod? decodeMethod,
  }) async {
    if (openGate != null) await openGate!.future;
    if (!isCurrent() || disposed) return;
    opened.add(source.uri.path);
    starts.add(start);
    state.value = EngineSnapshot(
      position: start,
      duration: const Duration(seconds: 120),
    );
  }

  @override
  Future<void> stop() async {
    if (!disposed) state.value = const EngineSnapshot();
  }

  @override
  Future<void> setPlaying(bool playing) async {
    if (!disposed) state.value = state.value.copyWith(playing: playing);
  }

  @override
  Future<void> seek(Duration position) async {
    state.value = state.value.copyWith(position: position, completed: false);
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
  }

  void tick(int seconds) {
    state.value = state.value.copyWith(position: Duration(seconds: seconds));
  }

  void complete() {
    state.value = state.value.copyWith(
      position: state.value.duration,
      playing: false,
      completed: true,
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    state.dispose();
  }
}
