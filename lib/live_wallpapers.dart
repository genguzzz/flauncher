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

/// An animated wallpaper: a fragment shader in android/app/src/main/assets/shaders/<id>.frag,
/// drawn natively with OpenGL ES (see LiveWallpaper.java).
class LiveWallpaperShader {
  final String id;
  final String Function(AppLocalizations) name;

  const LiveWallpaperShader(this.id, this.name);
}

class LiveWallpapers {
  static final List<LiveWallpaperShader> all = [
    LiveWallpaperShader("ribbons", (l) => l.liveWallpaperRibbons),
    LiveWallpaperShader("aurora", (l) => l.liveWallpaperAurora),
    LiveWallpaperShader("caustics", (l) => l.liveWallpaperCaustics),
    LiveWallpaperShader("ink", (l) => l.liveWallpaperInk),
    LiveWallpaperShader("topo", (l) => l.liveWallpaperTopo),
  ];

  static LiveWallpaperShader? byId(String id) => all.where((s) => s.id == id).firstOrNull;
}
