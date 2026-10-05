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

import 'package:flauncher/api_server.dart';
import 'package:flauncher/database.dart';
import 'package:flauncher/flauncher_channel.dart';
import 'package:flauncher/providers/apps_service.dart';
import 'package:flauncher/providers/launcher_state.dart';
import 'package:flauncher/providers/network_service.dart';
import 'package:flauncher/providers/settings_service.dart';
import 'package:flauncher/providers/stats_service.dart';
import 'package:flauncher/providers/wallpaper_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'flauncher_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeDateFormatting();

  final sharedPreferences = await SharedPreferences.getInstance();
  final fLauncherChannel = FLauncherChannel();
  final fLauncherDatabase = FLauncherDatabase(connect());

  // Created eagerly (not lazily by the providers) because the control API uses them too.
  final settingsService = SettingsService(sharedPreferences);
  final appsService = AppsService(fLauncherChannel, fLauncherDatabase, settingsService);
  final wallpaperService = WallpaperService(fLauncherChannel, settingsService);
  final statsService = StatsService(fLauncherChannel, settingsService);

  ApiServer(
    settings: settingsService,
    apps: appsService,
    wallpaper: wallpaperService,
    stats: statsService,
    channel: fLauncherChannel,
  ).start();

  runApp(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settingsService),
        ChangeNotifierProvider.value(value: appsService),
        ChangeNotifierProvider(create: (_) => LauncherState()),
        ChangeNotifierProvider(create: (_) => NetworkService(fLauncherChannel)),
        ChangeNotifierProvider.value(value: wallpaperService),
        ChangeNotifierProvider.value(value: statsService),
      ],
      child: FLauncherApp()
    )
  );
}
