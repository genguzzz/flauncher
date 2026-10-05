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

import 'dart:io';

import 'package:flauncher/flauncher_channel.dart';
import 'package:flauncher/gradients.dart';
import 'package:flauncher/live_wallpapers.dart';
import 'package:flauncher/providers/settings_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

class WallpaperService extends ChangeNotifier {
  final FLauncherChannel _fLauncherChannel;
  final SettingsService _settingsService;

  late File _wallpaperFile;
  late final Future<void> _ready;

  ImageProvider? _wallpaper;

  ImageProvider?  get wallpaper     => _wallpaper;

  FLauncherGradient get gradient => FLauncherGradients.all.firstWhere(
        (gradient) => gradient.uuid == _settingsService.gradientUuid,
        orElse: () => FLauncherGradients.greatWhale,
      );

  WallpaperService(this._fLauncherChannel, this._settingsService) :
    _wallpaper = null
  {
    _ready = _init();
    // Live wallpaper settings (fps, resolution) can also change through the API.
    _settingsService.addListener(notifyListeners);
  }

  Future<void> _init() async {
    final directory = await getApplicationDocumentsDirectory();
    _wallpaperFile = File("${directory.path}/wallpaper");
    if (await _wallpaperFile.exists()) {
      _wallpaper = FileImage(_wallpaperFile);
      notifyListeners();
    }
  }

  Future<void> pickWallpaper() async {
    if (!await _fLauncherChannel.checkForGetContentAvailability()) {
      throw NoFileExplorerException();
    }

    final imagePicker = ImagePicker();
    final pickedFile = await imagePicker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      Uint8List bytes = await pickedFile.readAsBytes();
      await _wallpaperFile.writeAsBytes(bytes);

      _wallpaper = MemoryImage(bytes);
      await _settingsService.setLiveWallpaper("");
      notifyListeners();
    }
  }

  bool get hasWallpaper => _wallpaper != null;

  /// The animated wallpaper drawn over the picture / gradient, or null when off.
  LiveWallpaperShader? get liveWallpaper => LiveWallpapers.byId(_settingsService.liveWallpaper);

  int get liveWallpaperFps => _settingsService.liveWallpaperFps;

  int get liveWallpaperHeight => _settingsService.liveWallpaperHeight;

  /// Turns the animated wallpaper on ([id] from [LiveWallpapers]) or off (empty string). The picture /
  /// gradient is kept and shows again when it is turned off.
  Future<void> setLiveWallpaper(String id) async {
    if (id.isNotEmpty && LiveWallpapers.byId(id) == null) {
      throw ArgumentError("unknown live wallpaper $id");
    }
    await _settingsService.setLiveWallpaper(id);
    notifyListeners();
  }

  /// Sets a picture as wallpaper from encoded image bytes (PNG, JPEG, WebP...).
  Future<void> setWallpaperBytes(Uint8List bytes) async {
    await _ready;
    await _wallpaperFile.writeAsBytes(bytes, flush: true);
    _wallpaper = MemoryImage(bytes);
    await _settingsService.setLiveWallpaper("");
    notifyListeners();
  }

  /// Removes the picture wallpaper; the selected gradient is shown again.
  Future<void> clearWallpaper() async {
    await _ready;
    if (await _wallpaperFile.exists()) {
      await _wallpaperFile.delete();
    }
    _wallpaper = null;
    notifyListeners();
  }

  Future<void> setGradient(FLauncherGradient fLauncherGradient) async {
    await _ready;
    if (await _wallpaperFile.exists()) {
      await _wallpaperFile.delete();
    }
    _wallpaper = null;

    await _settingsService.setGradientUuid(fLauncherGradient.uuid);
    await _settingsService.setLiveWallpaper("");
    notifyListeners();
  }
}

class NoFileExplorerException implements Exception {}
