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

import 'package:flauncher/l10n/app_localizations.dart';

/// An animated wallpaper: a fragment shader drawn natively with OpenGL ES (see LiveWallpaper.java),
/// either built in (android/app/src/main/assets/shaders/<id>.frag) or uploaded through the API.
class LiveWallpaperShader {
  final String id;
  final bool builtin;
  final bool custom;
  /// Preferred render height / frame rate ("// @height" / "// @fps" in the shader), if declared.
  final int? height;
  final int? fps;

  const LiveWallpaperShader(this.id, {this.builtin = true, this.custom = false, this.height, this.fps});

  /// Localized name of a built-in shader; uploaded shaders show their id.
  String name(AppLocalizations l) => switch (id) {
    "ribbons" => l.liveWallpaperRibbons,
    "aurora" => l.liveWallpaperAurora,
    "caustics" => l.liveWallpaperCaustics,
    "ink" => l.liveWallpaperInk,
    "topo" => l.liveWallpaperTopo,
    "waves" => l.liveWallpaperWaves,
    "mesh" => l.liveWallpaperMesh,
    _ => id,
  };

  /// Display order of the built-in shaders; uploaded ones follow, by id.
  static const builtinOrder = ["ribbons", "waves", "mesh", "topo", "ink", "aurora", "caustics"];

  static int compare(LiveWallpaperShader a, LiveWallpaperShader b) {
    int rank(LiveWallpaperShader s) {
      final i = builtinOrder.indexOf(s.id);
      return i < 0 ? builtinOrder.length : i;
    }
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : a.id.compareTo(b.id);
  }
}
