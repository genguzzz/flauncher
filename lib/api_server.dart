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
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flauncher/flauncher_channel.dart';
import 'package:flauncher/gradients.dart';
import 'package:flauncher/l10n/app_localizations.dart';
import 'package:flauncher/live_wallpapers.dart';
import 'package:flauncher/models/app.dart';
import 'package:flauncher/models/category.dart';
import 'package:flauncher/providers/apps_service.dart';
import 'package:flauncher/providers/settings_service.dart';
import 'package:flauncher/providers/network_service.dart';
import 'package:flauncher/providers/stats_service.dart';
import 'package:flauncher/providers/wallpaper_service.dart';
import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter/widgets.dart' show WidgetsBinding, basicLocaleListResolution;

/// JSON control API on port 10600 (all interfaces) so scripts / agents on the LAN can configure
/// the launcher — the TV's IME cannot type into Flutter views. Every change goes through the
/// services, so the UI updates live. See the "TV custom build" section of README.md.
class ApiServer {
  static const int port = 10600;
  static const int _maxBodyBytes = 40 * 1024 * 1024;

  final SettingsService settings;
  final AppsService apps;
  final WallpaperService wallpaper;
  final StatsService stats;
  final NetworkService network;
  final FLauncherChannel channel;

  HttpServer? _server;

  ApiServer({
    required this.settings,
    required this.apps,
    required this.wallpaper,
    required this.stats,
    required this.network,
    required this.channel,
  });

  Future<void> start() async {
    for (int attempt = 0; _server == null; attempt++) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
      }
      catch (e) {
        debugPrint("ApiServer: bind failed ($e), retrying");
        await Future.delayed(Duration(seconds: attempt < 5 ? 2 : 30));
      }
    }
    _server!.listen((request) => _handle(request).catchError((_) {}));
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set("Access-Control-Allow-Origin", "*")
      ..set("Access-Control-Allow-Headers", "Authorization, Content-Type")
      ..set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");

    try {
      if (request.method == "OPTIONS") {
        response.statusCode = HttpStatus.noContent;
        await response.close();
        return;
      }

      final token = settings.apiToken;
      if (token.isNotEmpty && request.headers.value(HttpHeaders.authorizationHeader) != "Bearer $token") {
        throw _ApiError(HttpStatus.unauthorized, "missing or wrong Authorization: Bearer <api_token>");
      }

      final segments = request.uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
      if (segments.isEmpty || segments[0] != "api") {
        throw _ApiError(HttpStatus.notFound, "not found, see GET /api");
      }
      final path = segments.sublist(1);
      // Mutations are queued behind package events and rescans (refresh queues itself).
      final result = request.method == "GET" || (path.isNotEmpty && path[0] == "refresh")
          ? await _route(request, request.method, path)
          : await apps.serialized(() => _route(request, request.method, path));
      await _send(response, HttpStatus.ok, result);
    }
    on _ApiError catch (e) {
      await _send(response, e.status, {"error": e.message});
    }
    on ArgumentError catch (e) {
      await _send(response, HttpStatus.badRequest, {"error": e.message.toString()});
    }
    on FormatException catch (e) {
      await _send(response, HttpStatus.badRequest, {"error": "bad request: ${e.message}"});
    }
    catch (e) {
      await _send(response, HttpStatus.internalServerError, {"error": e.toString()});
    }
  }

  Future<void> _send(HttpResponse response, int status, Object? body) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(const JsonEncoder.withIndent("  ").convert(body));
    await response.close();
  }

  Future<Object?> _route(HttpRequest request, String method, List<String> path) async {
    final resource = path.isEmpty ? "" : path[0];
    final arg = path.length > 1 ? path.sublist(1).join("/") : null;

    switch ((method, resource, arg != null)) {
      case ("GET", "", false):
        return _index();

      case ("GET", "settings", false):
        return _settingsJson();
      case ("PUT" || "POST", "settings", false):
        return _updateSettings(await _jsonObject(request));

      case ("GET", "gradients", false):
        return FLauncherGradients.all.map((g) => {"uuid": g.uuid, "name": g.name}).toList();

      case ("GET", "wallpaper", false):
        return {..._wallpaperJson(), "live_wallpaper_stats": await channel.liveWallpaperStats()};
      case ("POST" || "PUT", "wallpaper", false):
        return _setWallpaper(request);
      case ("DELETE", "wallpaper", false):
        await wallpaper.clearWallpaper();
        return _wallpaperJson();

      case ("GET", "apps", false):
        return _appsJson();
      case ("GET", "apps", true):
        return _appJson(_app(arg!), await apps.categoryMemberships());
      case ("POST" || "PUT", "apps", true):
        return _updateApp(_app(arg!), await _jsonObject(request));

      case ("GET", "categories", false):
        return _categoriesJson();
      case ("POST", "categories", false):
        return _createCategory(await _jsonObject(request));
      case ("GET", "categories", true):
        return _categoryJson(_category(arg!));
      case ("POST" || "PUT", "categories", true):
        return _updateCategory(_category(arg!), await _jsonObject(request));
      case ("DELETE", "categories", true):
        await apps.deleteCategory(_category(arg!));
        return _categoriesJson();

      case ("GET", "stats", false):
        return _statsJson(await stats.sample());

      case ("GET", "network", false):
        return _networkJson();

      case ("POST", "launch", true):
        return _launch(arg!);

      case ("POST", "refresh", false):
        await apps.refresh();
        return {"ok": true, "apps": apps.applications.length};
    }
    throw _ApiError(HttpStatus.notFound, "no route for $method ${request.uri.path}, see GET /api");
  }

  Map<String, Object?> _index() => {
    "name": "FLauncher control API",
    "endpoints": [
      "GET  /api/settings", "PUT|POST /api/settings {key: value, ...}",
      "GET  /api/gradients",
      "GET  /api/wallpaper", "POST /api/wallpaper (image/* body | {\"url\": ...})", "DELETE /api/wallpaper",
      "GET  /api/apps", "GET  /api/apps/<package>",
      "POST /api/apps/<package> {hidden, category, order, remove_from, categories}",
      "GET  /api/categories", "POST /api/categories {name, type, sort, columns, row_height, position, apps}",
      "GET|POST|DELETE /api/categories/<id or name>",
      "GET  /api/stats", "GET  /api/network", "POST /api/launch/<package>", "POST /api/refresh",
    ],
  };

  // --- settings ---------------------------------------------------------------------------------

  Map<String, Object?> _settingsJson() => settings.toJson();

  Future<Object?> _updateSettings(Map<String, dynamic> body) async {
    final values = Map<String, dynamic>.of(body);
    final gradientUuid = values.remove(SettingsService.gradientKey);
    final live = values.remove(SettingsService.liveWallpaperKey);
    if (live != null && (live is! String || (live.isNotEmpty && LiveWallpapers.byId(live) == null))) {
      throw ArgumentError("live_wallpaper must be \"\" or one of ${LiveWallpapers.all.map((s) => s.id).join(", ")}");
    }
    FLauncherGradient? gradient;
    if (gradientUuid != null) {
      gradient = FLauncherGradients.all.where((g) => g.uuid == gradientUuid || g.name == gradientUuid).firstOrNull;
      if (gradient == null) {
        throw ArgumentError("unknown gradient $gradientUuid, see GET /api/gradients");
      }
    }
    await settings.applyJson(values);
    if (gradient != null) {
      await wallpaper.setGradient(gradient);
    }
    if (live != null) {
      await wallpaper.setLiveWallpaper(live as String);
    }
    return _settingsJson();
  }

  // --- wallpaper --------------------------------------------------------------------------------

  Map<String, Object?> _wallpaperJson() => {
    "custom_picture": wallpaper.hasWallpaper,
    "gradient_uuid": wallpaper.gradient.uuid,
    "gradient_name": wallpaper.gradient.name,
    "live_wallpaper": wallpaper.liveWallpaper?.id ?? "",
    "live_wallpapers": LiveWallpapers.all.map((s) => s.id).toList(),
    "live_wallpaper_fps": wallpaper.liveWallpaperFps,
    "live_wallpaper_height": wallpaper.liveWallpaperHeight,
  };

  Future<Object?> _setWallpaper(HttpRequest request) async {
    final contentType = request.headers.contentType;
    Uint8List bytes;
    if (contentType != null && contentType.mimeType == "application/json") {
      final body = jsonDecode(utf8.decode(await _body(request)));
      if (body is! Map || body["url"] is! String) {
        throw ArgumentError("expected {\"url\": \"http(s)://...\"}");
      }
      bytes = await _download(Uri.parse(body["url"]));
    }
    else {
      bytes = await _body(request);
    }
    if (bytes.isEmpty) {
      throw ArgumentError("empty image");
    }
    await _checkImage(bytes);
    await wallpaper.setWallpaperBytes(bytes);
    return {..._wallpaperJson(), "bytes": bytes.length};
  }

  Future<Uint8List> _download(Uri uri) async {
    if (uri.scheme != "http" && uri.scheme != "https") {
      throw ArgumentError("url must be http(s)");
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != HttpStatus.ok) {
        throw _ApiError(HttpStatus.badGateway, "download failed: HTTP ${res.statusCode}");
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(const Duration(seconds: 60))) {
        builder.add(chunk);
        if (builder.length > _maxBodyBytes) {
          throw _ApiError(HttpStatus.requestEntityTooLarge, "image larger than $_maxBodyBytes bytes");
        }
      }
      return builder.takeBytes();
    }
    on _ApiError {
      rethrow;
    }
    catch (e) {
      throw _ApiError(HttpStatus.badGateway, "download failed: $e");
    }
    finally {
      client.close(force: true);
    }
  }

  Future<void> _checkImage(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 16);
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      codec.dispose();
    }
    catch (e) {
      throw ArgumentError("not a decodable image ($e)");
    }
  }

  // --- apps -------------------------------------------------------------------------------------

  App _app(String packageName) {
    final app = apps.applicationByPackage(packageName);
    if (app == null) {
      throw _ApiError(HttpStatus.notFound, "unknown package $packageName");
    }
    return app;
  }

  Map<String, Object?> _appJson(App app, Map<String, List<int>> memberships) {
    final categoriesById = {for (final category in apps.categories) category.id: category};
    return {
      "package": app.packageName,
      "name": app.name,
      "version": app.version,
      "hidden": app.hidden,
      "sideloaded": app.sideloaded,
      "categories": [
        for (final id in memberships[app.packageName] ?? <int>[])
          if (categoriesById.containsKey(id))
            {
              "id": id,
              "name": categoriesById[id]!.name,
              "order": categoriesById[id]!.applications.indexWhere((a) => a.packageName == app.packageName),
            }
      ],
    };
  }

  Future<Object?> _appsJson() async {
    final memberships = await apps.categoryMemberships();
    return apps.applications.map((app) => _appJson(app, memberships)).toList();
  }

  Future<Object?> _updateApp(App app, Map<String, dynamic> body) async {
    const known = {"hidden", "category", "order", "remove_from", "categories"};
    final unknown = body.keys.where((key) => !known.contains(key));
    if (unknown.isNotEmpty) {
      throw ArgumentError("unknown field(s) ${unknown.join(", ")}");
    }
    final packageName = app.packageName;

    if (body.containsKey("hidden")) {
      if (body["hidden"] is! bool) throw ArgumentError("hidden must be a boolean");
      await apps.setApplicationHidden(app, body["hidden"]);
    }

    if (body.containsKey("categories")) {
      final list = body["categories"];
      if (list is! List) throw ArgumentError("categories must be a list of ids or names");
      final wanted = list.map((ref) => _category(ref.toString())).toList();
      final current = (await apps.categoryMemberships())[packageName] ?? [];
      for (final id in current) {
        if (!wanted.any((category) => category.id == id)) {
          final category = apps.findCategory(id.toString());
          if (category != null) await apps.removeFromCategory(_app(packageName), category);
        }
      }
      for (final category in wanted) {
        if (!current.contains(category.id)) await apps.addToCategory(_app(packageName), category);
      }
    }

    if (body.containsKey("remove_from")) {
      final ref = body["remove_from"].toString();
      final current = (await apps.categoryMemberships())[packageName] ?? [];
      final targets = ref == "all"
          ? current.map((id) => apps.findCategory(id.toString())).whereType<Category>().toList()
          : [_category(ref)];
      for (final category in targets) {
        await apps.removeFromCategory(_app(packageName), category);
      }
    }

    if (body.containsKey("category")) {
      final category = _category(body["category"].toString());
      final current = (await apps.categoryMemberships())[packageName] ?? [];
      if (!current.contains(category.id)) {
        await apps.addToCategory(_app(packageName), category);
      }
      if (body.containsKey("order")) {
        final order = body["order"];
        if (order is! int) throw ArgumentError("order must be an integer");
        await apps.moveApplicationInCategory(category, _app(packageName), order);
      }
    }
    else if (body.containsKey("order")) {
      throw ArgumentError("order needs category");
    }

    return _appJson(_app(packageName), await apps.categoryMemberships());
  }

  // --- categories -------------------------------------------------------------------------------

  Category _category(String reference) {
    final category = apps.findCategory(reference);
    if (category == null) {
      throw _ApiError(HttpStatus.notFound, "unknown category $reference");
    }
    return category;
  }

  Map<String, Object?> _categoryJson(Category category) {
    final current = apps.findCategory(category.id.toString()) ?? category;
    final sections = apps.launcherSections;
    return {
      "id": current.id,
      "name": current.name,
      "type": current.type.name,
      "sort": current.sort.name,
      "columns": current.columnsCount,
      "row_height": current.rowHeight,
      "position": sections.indexWhere((s) => s is Category && s.id == current.id),
      "apps": current.applications.map((app) => app.packageName).toList(),
    };
  }

  Object? _categoriesJson() => apps.launcherSections
      .whereType<Category>()
      .map(_categoryJson)
      .toList();

  Future<Object?> _createCategory(Map<String, dynamic> body) async {
    final name = body["name"];
    if (name is! String || name.trim().isEmpty) {
      throw ArgumentError("name is required");
    }
    if (apps.findCategory(name) != null) {
      throw _ApiError(HttpStatus.conflict, "category $name already exists");
    }
    final position = body["position"];
    if (position != null && position is! int) throw ArgumentError("position must be an integer");
    final id = await apps.addCategory(name.trim(),
      type: _enum(CategoryType.values, body["type"], Category.Type),
      sort: _enum(CategorySort.values, body["sort"], Category.Sort),
      columnsCount: _int(body["columns"], Category.ColumnsCount, 1, 20, "columns"),
      rowHeight: _int(body["row_height"], Category.RowHeight, 20, 500, "row_height"),
      position: position ?? apps.launcherSections.length,
    );
    if (id < 0) {
      throw _ApiError(HttpStatus.internalServerError, "could not create category");
    }
    final category = _category(id.toString());
    if (body["apps"] is List) {
      for (final packageName in body["apps"]) {
        final app = apps.applicationByPackage(packageName.toString());
        if (app != null) await apps.addToCategory(app, category);
      }
    }
    return _categoryJson(category);
  }

  Future<Object?> _updateCategory(Category category, Map<String, dynamic> body) async {
    const known = {"name", "type", "sort", "columns", "row_height", "position", "apps"};
    final unknown = body.keys.where((key) => !known.contains(key));
    if (unknown.isNotEmpty) {
      throw ArgumentError("unknown field(s) ${unknown.join(", ")}");
    }
    final name = body["name"] ?? category.name;
    if (name is! String || name.trim().isEmpty) throw ArgumentError("name must be a non-empty string");
    await apps.updateCategory(
      category.id,
      name.trim(),
      _enum(CategorySort.values, body["sort"], category.sort),
      _enum(CategoryType.values, body["type"], category.type),
      _int(body["columns"], category.columnsCount, 1, 20, "columns"),
      _int(body["row_height"], category.rowHeight, 20, 500, "row_height"),
    );
    if (body.containsKey("position")) {
      final position = body["position"];
      if (position is! int) throw ArgumentError("position must be an integer");
      await apps.moveCategoryTo(category, position);
    }
    if (body.containsKey("apps")) {
      final list = body["apps"];
      if (list is! List) throw ArgumentError("apps must be a list of package names");
      // Adds missing apps, then orders them as listed (apps not listed keep their place after).
      final packageNames = list.map((e) => e.toString()).toList();
      for (final packageName in packageNames) {
        final app = apps.applicationByPackage(packageName);
        if (app == null) throw _ApiError(HttpStatus.notFound, "unknown package $packageName");
        final current = (await apps.categoryMemberships())[packageName] ?? [];
        if (!current.contains(category.id)) await apps.addToCategory(app, category);
      }
      await apps.setCategoryApplicationsOrder(category, packageNames);
    }
    return _categoryJson(category);
  }

  // --- misc -------------------------------------------------------------------------------------

  Map<String, Object?> _statsJson(SystemStats s) => {
    "cpu_percent": s.cpu == null ? null : double.parse(s.cpu!.toStringAsFixed(1)),
    "cpu_source": s.cpuSource,
    "mem_total": s.memTotal,
    "mem_available": s.memAvailable,
    "mem_used": s.memUsed,
    "mem_total_gb": double.parse((s.memTotal / (1 << 30)).toStringAsFixed(2)),
    "mem_used_gb": double.parse((s.memUsed / (1 << 30)).toStringAsFixed(2)),
  };

  Future<Map<String, Object?>> _networkJson() async {
    final summary = await network.summary();
    final locale = basicLocaleListResolution(
        WidgetsBinding.instance.platformDispatcher.locales, AppLocalizations.supportedLocales);
    return {
      "type": summary.type,
      "ssid": summary.ssid,
      "short": NetworkService.shortLabel(summary.type, summary.ssid, lookupAppLocalizations(locale)),
    };
  }

  Future<Object?> _launch(String packageName) async {
    final app = apps.applicationByPackage(packageName);
    if (app != null) {
      await apps.launchApp(app);
    }
    else {
      await channel.launchApp(packageName);
    }
    return {"ok": true, "package": packageName};
  }

  // --- helpers ----------------------------------------------------------------------------------

  Future<Uint8List> _body(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > _maxBodyBytes) {
        throw _ApiError(HttpStatus.requestEntityTooLarge, "body larger than $_maxBodyBytes bytes");
      }
    }
    return builder.takeBytes();
  }

  Future<Map<String, dynamic>> _jsonObject(HttpRequest request) async {
    final bytes = await _body(request);
    if (bytes.isEmpty) return {};
    final body = jsonDecode(utf8.decode(bytes));
    if (body is! Map) throw ArgumentError("expected a JSON object");
    return body.cast<String, dynamic>();
  }

  static T _enum<T extends Enum>(List<T> values, Object? value, T fallback) {
    if (value == null) return fallback;
    final found = values.where((v) => v.name == value.toString()).firstOrNull;
    if (found == null) {
      throw ArgumentError("must be one of ${values.map((v) => v.name).join(", ")}, got $value");
    }
    return found;
  }

  static int _int(Object? value, int fallback, int min, int max, String name) {
    if (value == null) return fallback;
    if (value is! int || value < min || value > max) {
      throw ArgumentError("$name must be an integer in [$min, $max]");
    }
    return value;
  }
}

class _ApiError implements Exception {
  final int status;
  final String message;

  _ApiError(this.status, this.message);
}
