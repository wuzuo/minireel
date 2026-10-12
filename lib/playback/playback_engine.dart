import 'package:flutter/foundation.dart';

import '../domain/models/playback_source.dart';
import '../domain/models/preferences.dart';

final class EngineSnapshot {
  const EngineSnapshot({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffer = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.error,
  });
  final Duration position;
  final Duration duration;
  final Duration buffer;
  final bool playing;
  final bool buffering;
  final bool completed;
  final String? error;

  EngineSnapshot copyWith({
    Duration? position,
    Duration? duration,
    Duration? buffer,
    bool? playing,
    bool? buffering,
    bool? completed,
    String? error,
  }) => EngineSnapshot(
    position: position ?? this.position,
    duration: duration ?? this.duration,
    buffer: buffer ?? this.buffer,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    completed: completed ?? this.completed,
    error: error ?? this.error,
  );
}

abstract interface class PlaybackEngine {
  ValueListenable<EngineSnapshot> get state;
  Future<void> open(
    PlaybackSource source, {
    required Duration start,
    required bool Function() isCurrent,
    String? episodeId,
    DecodeMethod? decodeMethod,
  });
  Future<void> stop();
  Future<void> setPlaying(bool playing);
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  Future<void> dispose();
}

/// Optional native media buffering, separate from playback URL resolution.
abstract interface class PreloadingPlaybackEngine {
  Future<void> preload(PlaybackSource source, {required String episodeId});
  void discardPreload();
}
