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
import 'package:flauncher/live_wallpapers.dart';
import 'package:flauncher/providers/wallpaper_service.dart';
import 'package:flauncher/widgets/ensure_visible.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Picks the animated wallpaper (or turns it off). The choice applies immediately, so the
/// wallpaper can be previewed behind the settings panel.
class LiveWallpaperPanelPage extends StatelessWidget {
  static const String routeName = "live_wallpaper_panel";

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final service = context.watch<WallpaperService>();
    final current = service.liveWallpaper?.id ?? "";

    Widget option(String id, String label) => EnsureVisible(
      alignment: 0.5,
      child: TextButton(
        autofocus: id == current,
        onPressed: () => service.setLiveWallpaper(id),
        child: Row(
          children: [
            Icon(id == current ? Icons.radio_button_checked : Icons.radio_button_unchecked),
            Container(width: 8),
            Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
          ],
        ),
      ),
    );

    return Column(
      children: [
        Text(localizations.liveWallpaper, style: Theme.of(context).textTheme.titleLarge),
        const Divider(),
        Expanded(
          child: ListView(
            children: [
              option("", localizations.liveWallpaperOff),
              for (final shader in LiveWallpapers.all) option(shader.id, shader.name(localizations)),
            ],
          ),
        ),
      ],
    );
  }
}
