import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:minireel/core/errors/app_exception.dart';
import 'package:minireel/domain/models/playback_source.dart';
import 'package:minireel/domain/models/preferences.dart';
import 'package:minireel/playback/buffered_playback_engine.dart';

import 'support/fakes.dart';

Future<void> flush() => Future<void>.delayed(Duration.zero);

class _FailingEngine extends FakeEngine {
  @override
  Future<void> open(
    PlaybackSource source, {
    required Duration start,
    required bool Function() isCurrent,
    String? episodeId,
    DecodeMethod? decodeMethod,
  }) async => throw const AppException('Decoder unavailable');
}

class _SlowStopEngine extends FakeEngine {
  final stopped = Completer<void>();

  @override
  Future<void> stop() async {
    await stopped.future;
    await super.stop();
  }
}

void main() {
  test(
    'discarding a candidate during foreground stop cannot promote a disposed player',
    () async {
      final foreground = _SlowStopEngine();
      final standby = FakeEngine();
      final engine = BufferedPlaybackEngine(
        (preloading) => preloading ? standby : foreground,
      );
      addTearDown(engine.dispose);
      await engine.open(
        mediaFor(sampleEpisodes[0]).sources.single,
        start: Duration.zero,
        isCurrent: () => true,
        episodeId: sampleEpisodes[0].id,
      );
      final next = mediaFor(sampleEpisodes[1]).sources.single;
      await engine.preload(next, episodeId: sampleEpisodes[1].id);
      final opening = engine.open(
        next,
        start: Duration.zero,
        isCurrent: () => true,
        episodeId: sampleEpisodes[1].id,
      );
      await flush();
      engine.discardPreload();
      foreground.stopped.complete();
      await opening;
      expect(standby.disposed, isTrue);
      expect(engine.activeEngine, same(foreground));
      expect(foreground.opened, ['/1.mp4', '/2.mp4']);
    },
  );

  test(
    'promotion retains the buffered media without reopening or leaking audio',
    () async {
      final players = <FakeEngine>[];
      final engine = BufferedPlaybackEngine((_) {
        final player = FakeEngine();
        players.add(player);
        return player;
      });
      addTearDown(engine.dispose);
      final first = mediaFor(sampleEpisodes[0]).sources.single;
      final second = mediaFor(sampleEpisodes[1]).sources.single;
      await engine.open(
        first,
        start: Duration.zero,
        isCurrent: () => true,
        episodeId: sampleEpisodes[0].id,
      );
      await engine.setVolume(.35);
      await engine.setRate(1.5);
      await engine.setPlaying(true);
      await engine.preload(second, episodeId: sampleEpisodes[1].id);
      final standby = players[1];
      standby.state.value = standby.state.value.copyWith(
        buffer: const Duration(seconds: 12),
      );
      expect(engine.state.value.playing, isTrue);
      expect(standby.state.value.playing, isFalse);
      expect(standby.volumes, [0]);
      await engine.stop();
      await engine.open(
        second,
        start: Duration.zero,
        isCurrent: () => true,
        episodeId: sampleEpisodes[1].id,
      );
      await engine.setPlaying(true);
      expect(engine.activeEngine, same(standby));
      expect(standby.opened, ['/2.mp4']);
      expect(engine.state.value.buffer, const Duration(seconds: 12));
      expect(standby.volumes.last, .35);
      expect(standby.rates.last, 1.5);
      expect(players.first.disposed, isTrue);
      expect(engine.preloadedEpisodeId, isNull);
    },
  );

  test(
    'skipping an in-flight preload cannot replace the selected episode',
    () async {
      final gate = Completer<void>();
      final players = <FakeEngine>[];
      final engine = BufferedPlaybackEngine((preloading) {
        final player = FakeEngine();
        if (preloading) player.openGate = gate;
        players.add(player);
        return player;
      });
      addTearDown(engine.dispose);
      final warm = engine.preload(
        mediaFor(sampleEpisodes[1]).sources.single,
        episodeId: sampleEpisodes[1].id,
      );
      await flush();
      engine.discardPreload();
      await engine.open(
        mediaFor(sampleEpisodes[3]).sources.single,
        start: Duration.zero,
        isCurrent: () => true,
        episodeId: sampleEpisodes[3].id,
      );
      gate.complete();
      await warm;
      expect(players.first.opened, ['/4.mp4']);
      expect(players[1].opened, isEmpty);
      expect(players[1].disposed, isTrue);
      expect(engine.activeEpisodeId, sampleEpisodes[3].id);
    },
  );

  test(
    'different quality or fresh credentials never reuse a stale buffer',
    () async {
      final players = <FakeEngine>[];
      final engine = BufferedPlaybackEngine((_) {
        final player = FakeEngine();
        players.add(player);
        return player;
      });
      addTearDown(engine.dispose);
      final old = mediaFor(sampleEpisodes[1]).sources.single;
      await engine.preload(old, episodeId: sampleEpisodes[1].id);
      final fresh = PlaybackSource(
        uri: old.uri,
        kind: old.kind,
        quality: '720P',
        headers: const {'Authorization': 'synthetic-new-header'},
      );
      await engine.open(
        fresh,
        start: Duration.zero,
        isCurrent: () => true,
        episodeId: sampleEpisodes[1].id,
      );
      expect(engine.activeEngine, same(players.first));
      expect(players.first.opened, ['/2.mp4']);
      expect(players[1].disposed, isTrue);
    },
  );

  test(
    'a failed standby leaves foreground playback intact and can reopen normally',
    () async {
      final foreground = FakeEngine();
      final engine = BufferedPlaybackEngine(
        (preloading) => preloading ? _FailingEngine() : foreground,
      );
      addTearDown(engine.dispose);
      await engine.open(
        mediaFor(sampleEpisodes[0]).sources.single,
        start: Duration.zero,
        isCurrent: () => true,
        episodeId: sampleEpisodes[0].id,
      );
      await engine.setPlaying(true);
      final next = mediaFor(sampleEpisodes[1]).sources.single;
      await engine.preload(next, episodeId: sampleEpisodes[1].id);
      expect(engine.state.value.playing, isTrue);
      expect(engine.state.value.error, isNull);
      expect(engine.preloadedEpisodeId, isNull);
      await engine.open(
        next,
        start: Duration.zero,
        isCurrent: () => true,
        episodeId: sampleEpisodes[1].id,
      );
      expect(foreground.opened, ['/1.mp4', '/2.mp4']);
    },
  );

  test(
    'closing disposes both players and ignores late standby completion',
    () async {
      final gate = Completer<void>();
      final players = <FakeEngine>[];
      final engine = BufferedPlaybackEngine((preloading) {
        final player = FakeEngine();
        if (preloading) player.openGate = gate;
        players.add(player);
        return player;
      });
      final pending = engine.preload(
        mediaFor(sampleEpisodes[1]).sources.single,
        episodeId: sampleEpisodes[1].id,
      );
      await flush();
      await engine.dispose();
      gate.complete();
      await pending;
      expect(players.every((player) => player.disposed), isTrue);
      expect(players.every((player) => !player.state.value.playing), isTrue);
      await engine.dispose();
    },
  );
}
