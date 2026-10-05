/*
 * FLauncher
 * Copyright (C) 2026 genguzzz
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';

import 'package:flauncher/flauncher_channel.dart';
import 'package:flauncher/providers/settings_service.dart';
import 'package:flutter/widgets.dart';

class SystemStats {
  /// Whole-device CPU busy percentage, null when it cannot be read.
  final double? cpu;
  final int memTotal;
  final int memAvailable;
  final String cpuSource;

  const SystemStats({this.cpu, required this.memTotal, required this.memAvailable, this.cpuSource = "none"});

  int get memUsed => memTotal - memAvailable;

  /// Equal when the status bar text would be the same (whole CPU %, memory in 0.1 GB), so the
  /// indicator is only rebuilt and repainted when its text actually changes.
  @override
  bool operator ==(Object other) =>
      other is SystemStats &&
      other.cpu?.round() == cpu?.round() &&
      other.memTotal >> 26 == memTotal >> 26 &&
      (other.memUsed / (1 << 30) * 10).round() == (memUsed / (1 << 30) * 10).round();

  @override
  int get hashCode => Object.hash(cpu?.round(), memTotal >> 26, (memUsed / (1 << 30) * 10).round());

  factory SystemStats.fromMap(Map<String, dynamic> map) => SystemStats(
    cpu: (map["cpu"] as num?)?.toDouble(),
    memTotal: (map["memTotal"] as num?)?.toInt() ?? 0,
    memAvailable: (map["memAvailable"] as num?)?.toInt() ?? 0,
    cpuSource: map["cpuSource"] as String? ?? "none",
  );
}

/// Polls CPU / memory every [interval] while the launcher is in the foreground and the
/// status bar indicator is enabled. Nothing runs while the launcher is paused.
class StatsService extends ChangeNotifier {
  static const interval = Duration(seconds: 2);

  final FLauncherChannel _channel;
  final SettingsService _settings;
  late final AppLifecycleListener _lifecycleListener;

  Timer? _timer;
  bool _foreground = WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  bool _sampling = false;
  SystemStats? _stats;

  SystemStats? get stats => _stats;

  StatsService(this._channel, this._settings) {
    _lifecycleListener = AppLifecycleListener(onStateChange: _onLifecycleChanged);
    _settings.addListener(_update);
    _update();
  }

  void _onLifecycleChanged(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _update();
  }

  void _update() {
    final shouldRun = _foreground && _settings.showSystemStats;
    if (shouldRun && _timer == null) {
      _tick();
      _timer = Timer.periodic(interval, (_) => _tick());
    }
    else if (!shouldRun && _timer != null) {
      _timer!.cancel();
      _timer = null;
      _channel.releaseSystemStats().catchError((_) {});
    }
  }

  Future<void> _tick() async {
    if (_sampling) {
      return;
    }
    _sampling = true;
    try {
      final stats = await sample();
      if (stats != _stats) {
        _stats = stats;
        if (_timer != null) {
          notifyListeners();
        }
      }
    }
    catch (_) { }
    finally {
      _sampling = false;
    }
  }

  /// Takes a sample now (also used by the control API).
  Future<SystemStats> sample() async => SystemStats.fromMap(await _channel.getSystemStats());

  @override
  void dispose() {
    _timer?.cancel();
    _settings.removeListener(_update);
    _lifecycleListener.dispose();
    super.dispose();
  }
}
