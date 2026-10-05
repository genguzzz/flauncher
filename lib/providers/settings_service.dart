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

import 'package:flauncher/widgets/settings/back_button_actions.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _appHighlightAnimationEnabledKey = "app_highlight_animation_enabled";
const _appKeyClickEnabledKey = "app_key_click_enabled";
const _autoHideAppBar = "auto_hide_app_bar";
const _gradientUuidKey = "gradient_uuid";
const _backButtonAction = "back_button_action";
const _dateFormat = "date_format";
const _showCategoryTitles = "show_category_titles";
const _showDateInStatusBar = "show_date_in_status_bar";
const _showTimeInStatusBar = "show_time_in_status_bar";
const _timeFormat = "time_format";
const _showSystemStats = "show_system_stats";
const _showWifiName = "show_wifi_name";
const _newAppsCategory = "new_apps_category";
const _apiToken = "api_token";

class SettingsService extends ChangeNotifier {
  static final defaultDateFormat = "EEEE d";
  static final defaultTimeFormat = "H:mm";
  static const defaultNewAppsCategory = "新应用";
  final SharedPreferences _sharedPreferences;


  bool get appHighlightAnimationEnabled => _sharedPreferences.getBool(_appHighlightAnimationEnabledKey) ?? true;

  bool get appKeyClickEnabled => _sharedPreferences.getBool(_appKeyClickEnabledKey) ?? true;

  bool get autoHideAppBarEnabled => _sharedPreferences.getBool(_autoHideAppBar) ?? false;

  bool get showCategoryTitles => _sharedPreferences.getBool(_showCategoryTitles) ?? true;

  bool get showDateInStatusBar => _sharedPreferences.getBool(_showDateInStatusBar) ?? true;

  bool get showTimeInStatusBar => _sharedPreferences.getBool(_showTimeInStatusBar) ?? true;

  String? get gradientUuid => _sharedPreferences.getString(_gradientUuidKey);

  String get backButtonAction => _sharedPreferences.getString(_backButtonAction) ?? BACK_BUTTON_ACTION_NOTHING;

  String get dateFormat => _sharedPreferences.getString(_dateFormat) ?? defaultDateFormat;

  String get timeFormat => _sharedPreferences.getString(_timeFormat) ?? defaultTimeFormat;

  /// Show the CPU / memory indicator in the status bar.
  bool get showSystemStats => _sharedPreferences.getBool(_showSystemStats) ?? true;

  /// Show the (shortened) Wi-Fi name next to the network icon.
  bool get showWifiName => _sharedPreferences.getBool(_showWifiName) ?? true;

  /// Name of the category newly installed apps are added to; empty disables auto-adding.
  String get newAppsCategory => _sharedPreferences.getString(_newAppsCategory) ?? defaultNewAppsCategory;

  /// Bearer token required by the control API; empty means no authentication.
  String get apiToken => _sharedPreferences.getString(_apiToken) ?? "";

  SettingsService(
    this._sharedPreferences
  );

  Future<void> set(String key, bool value) async {
    await _sharedPreferences.setBool(key, value);
    notifyListeners();
  }

  Future<void> setAppHighlightAnimationEnabled(bool value) async {
    return set(_appHighlightAnimationEnabledKey, value);
  }

  Future<void> setAppKeyClickEnabled(bool value) async {
    return set(_appKeyClickEnabledKey, value);
  }

  Future<void> setAutoHideAppBarEnabled(bool value) async {
    return set(_autoHideAppBar, value);
  }

  Future<void> setGradientUuid(String value) async {
    await _sharedPreferences.setString(_gradientUuidKey, value);
    notifyListeners();
  }

  Future<void> setBackButtonAction(String value) async {
    await _sharedPreferences.setString(_backButtonAction, value);
    notifyListeners();
  }

  Future<void> setDateTimeFormat(String dateFormatString, String timeFormatString) async {
    await Future.wait([
      _sharedPreferences.setString(_dateFormat, dateFormatString),
      _sharedPreferences.setString(_timeFormat, timeFormatString)
    ]);
    notifyListeners();
  }

  Future<void> setShowCategoryTitles(bool show) async {
    return set(_showCategoryTitles, show);
  }

  Future<void> setShowDateInStatusBar(bool show) async {
    return set(_showDateInStatusBar, show);
  }

  Future<void> setShowTimeInStatusBar(bool show) async {
    return set(_showTimeInStatusBar, show);
  }

  Future<void> setShowSystemStats(bool show) async {
    return set(_showSystemStats, show);
  }

  Future<void> setShowWifiName(bool show) async {
    return set(_showWifiName, show);
  }

  Future<void> setNewAppsCategory(String name) async {
    await _sharedPreferences.setString(_newAppsCategory, name.trim());
    notifyListeners();
  }

  Future<void> setApiToken(String token) async {
    await _sharedPreferences.setString(_apiToken, token);
    notifyListeners();
  }

  /// All settings as JSON-friendly values, keyed by their preference names.
  Map<String, dynamic> toJson() => {
    _appHighlightAnimationEnabledKey: appHighlightAnimationEnabled,
    _appKeyClickEnabledKey: appKeyClickEnabled,
    _autoHideAppBar: autoHideAppBarEnabled,
    _gradientUuidKey: gradientUuid,
    _backButtonAction: backButtonAction,
    _dateFormat: dateFormat,
    _timeFormat: timeFormat,
    _showCategoryTitles: showCategoryTitles,
    _showDateInStatusBar: showDateInStatusBar,
    _showTimeInStatusBar: showTimeInStatusBar,
    _showSystemStats: showSystemStats,
    _showWifiName: showWifiName,
    _newAppsCategory: newAppsCategory,
    _apiToken: apiToken.isEmpty ? "" : "***",
  };

  static const Set<String> boolKeys = {
    _appHighlightAnimationEnabledKey, _appKeyClickEnabledKey, _autoHideAppBar, _showCategoryTitles,
    _showDateInStatusBar, _showTimeInStatusBar, _showSystemStats, _showWifiName,
  };

  static const Set<String> stringKeys = {
    _backButtonAction, _dateFormat, _timeFormat, _newAppsCategory, _apiToken,
  };

  /// Key of the gradient setting; applying it goes through the WallpaperService.
  static const String gradientKey = _gradientUuidKey;

  /// Writes plain (bool / string) settings. Throws [ArgumentError] on unknown keys or bad types.
  Future<void> applyJson(Map<String, dynamic> values) async {
    for (final entry in values.entries) {
      final key = entry.key, value = entry.value;
      if (boolKeys.contains(key)) {
        if (value is! bool) throw ArgumentError("$key must be a boolean");
      }
      else if (stringKeys.contains(key)) {
        if (value is! String) throw ArgumentError("$key must be a string");
        if (key == _backButtonAction && !const ["", "CLOCK", "SCREENSAVER"].contains(value)) {
          throw ArgumentError("$key must be one of \"\", \"CLOCK\", \"SCREENSAVER\"");
        }
      }
      else {
        throw ArgumentError("unknown setting $key");
      }
    }
    for (final entry in values.entries) {
      final value = entry.value;
      if (value is bool) {
        await _sharedPreferences.setBool(entry.key, value);
      }
      else {
        await _sharedPreferences.setString(entry.key, entry.key == _newAppsCategory ? (value as String).trim() : value);
      }
    }
    notifyListeners();
  }
}
