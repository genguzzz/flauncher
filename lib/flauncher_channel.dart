/*
 * FLauncher
 * Copyright (C) 2021  Étienne Fesser
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

import 'package:flauncher/live_wallpapers.dart';
import 'package:flutter/services.dart';

class FLauncherChannel {
  static const _methodChannel = MethodChannel('me.efesser.flauncher/method');
  static const _appsEventChannel = EventChannel('me.efesser.flauncher/event_apps');
  static const _networkEventChannel = EventChannel('me.efesser.flauncher/event_network');
  static const _networkSummaryEventChannel = EventChannel('me.efesser.flauncher/event_network_summary');

  Future<List<Map<dynamic, dynamic>>> getApplications() async {
    List<Map<dynamic, dynamic>>? applications = await _methodChannel.invokeListMethod("getApplications");
    return applications!;
  }

  Future<Uint8List> getApplicationBanner(String packageName) async {
    Uint8List bytes = await _methodChannel.invokeMethod("getApplicationBanner", packageName);
    return bytes;
  }

  Future<Uint8List> getApplicationIcon(String packageName) async {
    Uint8List bytes = await _methodChannel.invokeMethod("getApplicationIcon", packageName);
    return bytes;
  }

  Future<bool> applicationExists(String packageName) async =>
      await _methodChannel.invokeMethod('applicationExists', packageName);

  Future<void> launchActivityFromAction(String action) async => await _methodChannel.invokeMethod('launchActivityFromAction', action);

  /// Starts the animated wallpaper renderer; returns its texture id, or null if the shader is unknown.
  Future<int?> liveWallpaperStart(String shader, int width, int height, int fps) async =>
      await _methodChannel.invokeMethod<int>("liveWallpaperStart",
          {"shader": shader, "width": width, "height": height, "fps": fps});

  Future<void> liveWallpaperUpdate({String? shader, int? fps, bool? running}) async =>
      await _methodChannel.invokeMethod("liveWallpaperUpdate", {"shader": shader, "fps": fps, "running": running});

  Future<List<LiveWallpaperShader>> liveWallpaperList() async {
    final list = await _methodChannel.invokeListMethod<Map>("liveWallpaperList") ?? [];
    return list.map((e) => LiveWallpaperShader(e["id"] as String,
        builtin: e["builtin"] as bool, custom: e["custom"] as bool,
        height: e["height"] as int?, fps: e["fps"] as int?)).toList();
  }

  /// Saves a shader (compiled first); returns the compile error or null.
  Future<String?> liveWallpaperSave(String id, String source) async =>
      await _methodChannel.invokeMethod<String>("liveWallpaperSave", {"id": id, "source": source});

  Future<bool> liveWallpaperDelete(String id) async =>
      await _methodChannel.invokeMethod<bool>("liveWallpaperDelete", id) ?? false;

  /// Rendering statistics of the last 5 s (frame rate, GPU time), or null when not running.
  Future<String?> liveWallpaperStats() async => await _methodChannel.invokeMethod<String>("liveWallpaperStats");

  Future<void> liveWallpaperStop() async => await _methodChannel.invokeMethod("liveWallpaperStop");

  Future<void> launchApp(String packageName) async => await _methodChannel.invokeMethod('launchApp', packageName);

  Future<void> openSettings() async => await _methodChannel.invokeMethod('openSettings');

  Future<void> openAppInfo(String packageName) async => await _methodChannel.invokeMethod('openAppInfo', packageName);

  Future<void> uninstallApp(String packageName) async => await _methodChannel.invokeMethod('uninstallApp', packageName);

  Future<bool> isDefaultLauncher() async => await _methodChannel.invokeMethod('isDefaultLauncher');

  Future<bool> checkForGetContentAvailability() async =>
      await _methodChannel.invokeMethod("checkForGetContentAvailability");

  Future<Map<String, dynamic>> getActiveNetworkInformation() async {
    Map<dynamic, dynamic> map = await _methodChannel.invokeMethod("getActiveNetworkInformation");
    return map.cast<String, dynamic>();
  }

  Future<void> startAmbientMode() async => await _methodChannel.invokeMethod("startAmbientMode");

  Future<Map<String, dynamic>> getSystemStats() async {
    Map<dynamic, dynamic> map = await _methodChannel.invokeMethod("getSystemStats");
    return map.cast<String, dynamic>();
  }

  Future<void> releaseSystemStats() async => await _methodChannel.invokeMethod("releaseSystemStats");

  /// {type: wifi|ethernet|none, ssid} of the physical network.
  Future<Map<String, dynamic>> getNetworkSummary() async {
    Map<dynamic, dynamic> map = await _methodChannel.invokeMethod("getNetworkSummary");
    return map.cast<String, dynamic>();
  }

  /// Starts an explicit activity; false if it does not exist or cannot be started.
  Future<bool> launchComponent(String packageName, String className) async =>
      await _methodChannel.invokeMethod<bool>("launchComponent", {"package": packageName, "class": className}) ?? false;

  /// Pushes the network summary now and whenever its type or SSID changes.
  void addNetworkSummaryListener(void Function(Map<String, dynamic>) listener) =>
      _networkSummaryEventChannel.receiveBroadcastStream().listen((event) {
        Map<dynamic, dynamic> eventMap = event;
        listener(eventMap.cast<String, dynamic>());
      });

  void addAppsChangedListener(void Function(Map<String, dynamic>) listener) =>
      _appsEventChannel.receiveBroadcastStream().listen((event) {
        Map<dynamic, dynamic> eventMap = event;
        listener(eventMap.cast<String, dynamic>());
      });

  void addNetworkChangedListener(void Function(Map<String, dynamic>) listener) =>
      _networkEventChannel.receiveBroadcastStream().listen((event) {
        Map<dynamic, dynamic> eventMap = event;
        listener(eventMap.cast<String, dynamic>());
      });
}
