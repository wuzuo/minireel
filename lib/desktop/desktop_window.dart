import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

enum PlayerWindowMode { normal, fit, mini }

/// Keep a restored window reachable after a display or DPI change.
Rect fitWindowBounds(
  Rect desired,
  List<Rect> workAreas, {
  Size minimum = const Size(720, 520),
}) {
  if (workAreas.isEmpty) return desired;
  var area = workAreas.first;
  var largestIntersection = 0.0;
  for (final candidate in workAreas) {
    final intersection = desired.intersect(candidate);
    final overlap = intersection.isEmpty
        ? 0.0
        : intersection.width * intersection.height;
    if (overlap > largestIntersection) {
      largestIntersection = overlap;
      area = candidate;
    }
  }
  final width = desired.width
      .clamp(math.min(minimum.width, area.width), area.width)
      .toDouble();
  final height = desired.height
      .clamp(math.min(minimum.height, area.height), area.height)
      .toDouble();
  return Rect.fromLTWH(
    desired.left.clamp(area.left, area.right - width),
    desired.top.clamp(area.top, area.bottom - height),
    width,
    height,
  );
}

/// Owns the single native window; playback never recreates the video engine.
class DesktopWindow extends ChangeNotifier with WindowListener {
  static final instance = DesktopWindow();
  static const _system = MethodChannel('app.minireel/window');
  static const browseMinimum = Size(720, 520);
  static const playerMinimum = Size(360, 280);

  bool _native = false;
  bool _inPlayer = false;
  bool _closing = false;
  bool fullScreen = false;
  bool maximized = false;
  bool minimized = false;
  bool pinned = false;
  PlayerWindowMode mode = PlayerWindowMode.normal;
  final Set<String> _systemHolds = {};
  bool get systemBlocked => _systemHolds.isNotEmpty;
  bool get closing => _closing;
  bool get inPlayer => _inPlayer;
  Future<void> Function()? onPlayerClose;
  Future<void> Function()? onAppClose;
  Rect? _browseBounds;
  bool _browseMaximized = false;
  Rect? _playbackBounds;
  bool _playbackMaximized = false;
  bool _previousPin = false;
  File? _stateFile;
  Timer? _saveTimer;
  Future<void> _operations = Future.value();
  Future<void> _stateWrites = Future.value();

  Future<void> initialize() async {
    await windowManager.ensureInitialized();
    _native = true;
    windowManager.addListener(this);
    _system.setMethodCallHandler((call) async {
      handleSystemEvent(call.method);
    });
    final support = await getApplicationSupportDirectory();
    _stateFile = File(path.join(support.path, 'window.json'));
    var bounds = const Rect.fromLTWH(100, 80, 1120, 760);
    try {
      if (await _stateFile!.exists()) {
        final saved =
            jsonDecode(await _stateFile!.readAsString())
                as Map<String, dynamic>;
        final values = [
          'x',
          'y',
          'width',
          'height',
        ].map((key) => saved[key]).toList();
        if (values.every((value) => value is num && value.isFinite) &&
            (values[2] as num) > 0 &&
            (values[3] as num) > 0) {
          bounds = Rect.fromLTWH(
            (values[0] as num).toDouble(),
            (values[1] as num).toDouble(),
            (values[2] as num).toDouble(),
            (values[3] as num).toDouble(),
          );
          _browseMaximized = saved['maximized'] == true;
        }
      }
    } on Object catch (error) {
      debugPrint('Window preferences could not be restored: $error');
    }
    _browseBounds = fitWindowBounds(bounds, await _workAreas());
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: _browseBounds!.size,
        minimumSize: browseMinimum,
        title: 'MiniReel',
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
        backgroundColor: const Color(0xFF0B0D12),
      ),
      () async {
        await windowManager.setBounds(_browseBounds!);
        await windowManager.setPreventClose(true);
        if (_browseMaximized) await windowManager.maximize();
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  void handleSystemEvent(String event) {
    switch (event) {
      case 'sessionLocked':
        _systemHolds.add('lock');
      case 'sessionUnlocked':
        _systemHolds.remove('lock');
      case 'suspend':
        _systemHolds.add('suspend');
      case 'resume':
        _systemHolds.remove('suspend');
    }
    notifyListeners();
  }

  Future<List<Rect>> _workAreas() async => [
    for (final display in await screenRetriever.getAllDisplays())
      (display.visiblePosition ?? Offset.zero) &
          (display.visibleSize ?? display.size),
  ];

  Future<void> _serialize(Future<void> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> enterPlayer() => _serialize(() async {
    if (_inPlayer || _closing) return;
    if (_native) {
      if (!maximized) _browseBounds = await windowManager.getBounds();
      _browseMaximized = maximized;
      await windowManager.setMinimumSize(playerMinimum);
    }
    _inPlayer = true;
    notifyListeners();
  });

  Future<void> leavePlayer() => _serialize(() async {
    if (!_inPlayer || _closing) return;
    if (_native) {
      await windowManager.setFullScreen(false);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.unmaximize();
      await windowManager.setMinimumSize(browseMinimum);
      if (_browseBounds != null) {
        await windowManager.setBounds(
          fitWindowBounds(_browseBounds!, await _workAreas()),
        );
      }
      if (_browseMaximized) await windowManager.maximize();
    }
    fullScreen = false;
    pinned = false;
    mode = PlayerWindowMode.normal;
    _inPlayer = false;
    notifyListeners();
  });

  Future<void> toggleFullScreen() =>
      _serialize(() => _applyFullScreen(!fullScreen));

  Future<void> setFullScreen(bool value) =>
      _serialize(() => _applyFullScreen(value));

  Future<void> _applyFullScreen(bool value) async {
    if (_native) await windowManager.setFullScreen(value);
    fullScreen = value;
    notifyListeners();
  }

  Future<void> togglePinned() => _serialize(() async {
    final value = !pinned;
    if (_native) await windowManager.setAlwaysOnTop(value);
    pinned = value;
    notifyListeners();
  });

  Future<void> changePlayerMode(
    PlayerWindowMode requested,
    double aspectRatio,
  ) => _serialize(() async {
    final target = mode == requested ? PlayerWindowMode.normal : requested;
    if (_native) {
      if (fullScreen) await windowManager.setFullScreen(false);
      fullScreen = false;
      if (mode == PlayerWindowMode.normal) {
        _playbackBounds = await windowManager.getBounds();
        _playbackMaximized = await windowManager.isMaximized();
        _previousPin = pinned;
      }
      await windowManager.unmaximize();
      if (target == PlayerWindowMode.normal) {
        if (_playbackBounds != null) {
          await windowManager.setBounds(
            fitWindowBounds(
              _playbackBounds!,
              await _workAreas(),
              minimum: playerMinimum,
            ),
          );
        }
        if (_playbackMaximized) await windowManager.maximize();
      } else {
        final current = await windowManager.getBounds();
        final ratio = aspectRatio.isFinite && aspectRatio > 0
            ? aspectRatio
            : 9 / 16;
        final width = target == PlayerWindowMode.mini
            ? (ratio > 1 ? 480.0 : 360.0)
            : (ratio > 1 ? 960.0 : 440.0);
        await windowManager.setBounds(
          fitWindowBounds(
            Rect.fromCenter(
              center: current.center,
              width: width,
              height: width / ratio,
            ),
            await _workAreas(),
            minimum: playerMinimum,
          ),
        );
      }
      await windowManager.setAlwaysOnTop(
        target == PlayerWindowMode.mini || _previousPin,
      );
    }
    pinned = target == PlayerWindowMode.mini || _previousPin;
    fullScreen = false;
    mode = target;
    notifyListeners();
  });

  Future<void> minimize() async {
    if (_native) await windowManager.minimize();
  }

  Future<void> toggleMaximized() async {
    if (!_native) return;
    if (fullScreen) return setFullScreen(false);
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  Future<void> startDragging() async {
    if (_native && !fullScreen) await windowManager.startDragging();
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _saveTimer?.cancel();
    await _operations;
    // 先把窗口状态落盘，这一步需要原生窗口句柄，必须在 destroy 之前完成。
    await _saveBounds();
    // 立即销毁窗口，让关闭动作对用户瞬时可见；其余重量级销毁（播放器、SQLite）
    // 放到 destroy 之后，在进程退出期间的事件循环中继续完成，避免关闭时卡顿。
    if (_native) await windowManager.destroy();
    for (final prepare in [onPlayerClose, onAppClose]) {
      try {
        await prepare?.call();
      } on Object catch (error) {
        debugPrint('Window shutdown: $error');
      }
    }
  }

  Future<void> _saveBounds() =>
      _stateWrites = _stateWrites.then((_) => _writeBounds());

  Future<void> _writeBounds() async {
    if (!_native || _stateFile == null) return;
    try {
      if (!_inPlayer && !fullScreen && !maximized && !minimized) {
        _browseBounds = await windowManager.getBounds();
      }
      final bounds = _browseBounds;
      if (bounds == null) return;
      await _stateFile!.parent.create(recursive: true);
      await _stateFile!.writeAsString(
        jsonEncode({
          'x': bounds.left,
          'y': bounds.top,
          'width': bounds.width,
          'height': bounds.height,
          'maximized': _inPlayer ? _browseMaximized : maximized,
        }),
        flush: true,
      );
    } on Object catch (error) {
      debugPrint('Window preferences could not be saved: $error');
    }
  }

  void _scheduleSave() {
    if (_inPlayer || _closing) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 600),
      () => unawaited(_saveBounds()),
    );
  }

  @override
  void onWindowClose() => unawaited(close());
  @override
  void onWindowMoved() => _scheduleSave();
  @override
  void onWindowResized() => _scheduleSave();
  @override
  void onWindowMaximize() {
    maximized = true;
    notifyListeners();
    _scheduleSave();
  }

  @override
  void onWindowUnmaximize() {
    maximized = false;
    notifyListeners();
    _scheduleSave();
  }

  @override
  void onWindowMinimize() {
    minimized = true;
    notifyListeners();
  }

  @override
  void onWindowRestore() {
    minimized = false;
    notifyListeners();
  }

  @override
  void onWindowEnterFullScreen() {
    fullScreen = true;
    notifyListeners();
  }

  @override
  void onWindowLeaveFullScreen() {
    fullScreen = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_native) windowManager.removeListener(this);
    super.dispose();
  }
}
