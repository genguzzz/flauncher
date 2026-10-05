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
import 'dart:collection';
import 'package:collection/collection.dart' as collection;

import 'package:drift/drift.dart';
import 'package:flauncher/database.dart';
import 'package:flauncher/flauncher_channel.dart';
import 'package:flauncher/providers/settings_service.dart';
import 'package:flutter/foundation.dart' hide Category;
import 'package:tuple/tuple.dart';

import '../models/app.dart';
import '../models/category.dart';

class AppsService extends ChangeNotifier
{
  final FLauncherChannel _fLauncherChannel;
  final FLauncherDatabase _database;
  final SettingsService _settingsService;

  bool _initialized = false;

  /// Bumped for a package whenever it is (re)installed or updated, so cards reload its banner/icon.
  final Map<String, int> _imageGenerations = {};

  /// Serializes state reloads, package events and API mutations.
  Future<void> _queue = Future.value();

  /// An app whose lastUpdateTime is this recent when a PACKAGE_CHANGED event arrives was just
  /// (re)installed or updated, as opposed to e.g. a component being enabled or disabled.
  static const _recentUpdateWindow = Duration(minutes: 2);

  List<LauncherSection> _launcherSections = List.empty(growable: true);
  Map<String, App> _applications = Map();
  Map<int, Category> _categoriesById = Map();

  bool get initialized => _initialized;

  List<App> get applications => UnmodifiableListView(_applications.values.sortedBy((application) => application.name));

  List<LauncherSection> get launcherSections => List.unmodifiable(_launcherSections);
  List<Category> get categories => _categoriesById.values
      .map((category) => category.unmodifiable())
      .toList(growable: false);

  AppsService(this._fLauncherChannel, this._database, this._settingsService) {
    _init();
  }

  /// Runs [action] after every previously queued operation has finished.
  Future<T> serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await action());
      }
      catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _init() async {
    await serialized(() async {
      Set<String> newPackages = await _refreshState(shouldNotifyListeners: false);
      if (_database.wasCreated) {
        await _initDefaultCategories();
      }
      else {
        // Apps installed while the launcher was not running.
        await _addNewApplications(newPackages);
      }
    });

    _fLauncherChannel.addAppsChangedListener((event) => serialized(() => _onAppsChanged(event)));

    _initialized = true;
    notifyListeners();
  }

  Future<void> _onAppsChanged(Map<String, dynamic> event) async {
      switch (event["action"]) {
        case "PACKAGE_ADDED":
        case "PACKAGE_CHANGED":
        case "PACKAGES_AVAILABLE":
          List<dynamic> applicationsInfo = event["activitiesInfo"] ?? [event['activityInfo']];
          await _database.persistApps((applicationsInfo).map(_buildAppCompanion));

          Set<String> candidates = {};
          int now = DateTime.now().millisecondsSinceEpoch;
          for (Map<dynamic, dynamic> applicationInfo in applicationsInfo) {
            String packageName = applicationInfo['packageName'];
            _imageGenerations[packageName] = (_imageGenerations[packageName] ?? 0) + 1;
            int lastUpdateTime = (applicationInfo['lastUpdateTime'] as num?)?.toInt() ?? 0;
            bool recentlyUpdated = (now - lastUpdateTime).abs() < _recentUpdateWindow.inMilliseconds;
            if (event["action"] == "PACKAGE_ADDED" || recentlyUpdated || !_applications.containsKey(packageName)) {
              candidates.add(packageName);
            }
          }

          // Reload everything so in-memory objects keep their hidden flag and category memberships.
          await _refreshState(shouldNotifyListeners: false);
          await _addNewApplications(candidates);
          break;
        case "PACKAGE_REMOVED":
          String packageName = event['packageName'];
          await _database.deleteApps([packageName]);

          App? application = _applications.remove(packageName);

          if (application != null) {
            for (int categoryId in application.categoryOrders.keys) {
              if (_categoriesById.containsKey(categoryId)) {
                Category category = _categoriesById[categoryId]!;
                category.applications.remove(application);
              }
            }
          }
          break;
      }

      notifyListeners();
  }

  /// Rescans the installed applications (also picks up apps that are new to the launcher).
  Future<void> refresh() => serialized(() async {
    Set<String> newPackages = await _refreshState(shouldNotifyListeners: false);
    await _addNewApplications(newPackages);
    notifyListeners();
  });

  /// Adds the given packages to the "new apps" category (setting new_apps_category) unless
  /// they are hidden or already belong to a category. Creates that category at the end if needed.
  Future<void> _addNewApplications(Set<String> packageNames) async {
    String targetName = _settingsService.newAppsCategory.trim();
    if (targetName.isEmpty || packageNames.isEmpty) {
      return;
    }

    Set<String> categorized = (await _database.getAppsCategories())
        .map((appCategory) => appCategory.appPackageName)
        .toSet();
    List<App> toAdd = packageNames
        .where((packageName) => !categorized.contains(packageName))
        .map((packageName) => _applications[packageName])
        .whereType<App>()
        .where((application) => !application.hidden && application.action == null)
        .toList();
    if (toAdd.isEmpty) {
      return;
    }

    Category? target = _categoriesById.values.firstWhereOrNull((category) => category.name == targetName);
    if (target == null) {
      int id = await _addCategoryAt(targetName, _launcherSections.length);
      target = _categoriesById[id];
      if (target == null) {
        return;
      }
    }

    for (App application in toAdd) {
      await addToCategory(application, target, shouldNotifyListeners: false);
    }
    sortCategory(target);
  }

  AppsCompanion _buildAppCompanion(dynamic data) {
    String? version = data["version"];
    if (version == null) {
      version = "";
    }

    return AppsCompanion(
        packageName: Value(data["packageName"]),
        name: Value(data["name"]),
        version: Value(version),
        hidden: const Value.absent()
      );
  }

  Future<void> _initDefaultCategories() {
    final tvApplications = _applications.values.where((application) => application.sideloaded == false);
    final nonTvApplications = _applications.values.where((application) => application.sideloaded == true);

    return _database.transaction(() async {
      if (tvApplications.isNotEmpty) {
        int categoryId = await addCategory("TV Applications",
            type: CategoryType.grid, shouldNotifyListeners: false
        );

        Category tvAppsCategory = _categoriesById[categoryId]!;
        for (final app in tvApplications) {
          await addToCategory(app, tvAppsCategory, shouldNotifyListeners: false);
        }
      }
      if (nonTvApplications.isNotEmpty) {
        int categoryId = await addCategory("Non-TV Applications",
          shouldNotifyListeners: false,
        );
        Category nonTvAppsCategory = _categoriesById[categoryId]!;
        for (final app in nonTvApplications) {
          await addToCategory(app, nonTvAppsCategory, shouldNotifyListeners: false);
        }
      }
    });
  }

  /// Reloads apps, categories and sections. Returns the packages that were not in the database yet.
  Future<Set<String>> _refreshState({bool shouldNotifyListeners = true}) async {
    Future<List<App>> appsFromDatabaseFuture = _database.getApplications();
    Future<List<AppCategory>> appsCategoriesFuture = _database.getAppsCategories();
    Future<List<Category>> categoriesFuture = _database.getCategories();
    Future<List<LauncherSpacer>> spacersFuture = _database.getLauncherSpacers();
    List<Map<dynamic, dynamic>> appsFromSystem = await _fLauncherChannel.getApplications();
    Iterable<MapEntry<String, Tuple2<Map, AppsCompanion>>> appEntries = appsFromSystem.map(
            (appFromSystem) => new MapEntry(appFromSystem['packageName'], Tuple2(appFromSystem, _buildAppCompanion(appFromSystem))));
    Map<String, Tuple2<Map, AppsCompanion>> appsFromSystemByPackageName = Map.fromEntries(appEntries);

    List<App> appsFromDatabase = await appsFromDatabaseFuture;
    final Set<String> knownPackages = appsFromDatabase.map((app) => app.packageName).toSet();
    final Set<String> newPackages = appsFromSystemByPackageName.keys
        .where((packageName) => !knownPackages.contains(packageName))
        .toSet();
    final Iterable<App> appsRemovedFromSystem = appsFromDatabase
        .where((app) => !appsFromSystemByPackageName.containsKey(app.packageName));

    final List<String> uninstalledApplications = [];
    for (App app in appsRemovedFromSystem) {
      String packageName = app.packageName;

      // TODO: Is this really necessary? Can't we get this information from the getApplications method?
      bool appExists = await _fLauncherChannel.applicationExists(packageName);
      if (!appExists) {
        uninstalledApplications.add(packageName);
      }
    }

    await _database.transaction(() async {
      await _database.persistApps(appsFromSystemByPackageName.values.map((tuple) => tuple.item2));
      await _database.deleteApps(uninstalledApplications);
    });

    appsFromDatabaseFuture = _database.getApplications();

    await Future.wait([appsFromDatabaseFuture, appsCategoriesFuture, categoriesFuture, spacersFuture]);

    appsFromDatabase = await appsFromDatabaseFuture;
    List<AppCategory> appsCategories = await appsCategoriesFuture;
    List<Category> categories = await categoriesFuture;
    List<LauncherSpacer> spacers = await spacersFuture;

    _categoriesById = Map.fromEntries(categories.map((category) => MapEntry(category.id, category)));
    _applications = Map.fromEntries(appsFromDatabase.map((application) => MapEntry(application.packageName, application)));

    _launcherSections.clear();
    _launcherSections.addAll(categories);
    _launcherSections.addAll(spacers);
    _launcherSections.sort((ls0, ls1) => ls0.order.compareTo(ls1.order));

    for (App application in _applications.values) {
      Map? applicationFromSystem = appsFromSystemByPackageName[application.packageName]?.item1;

      if (applicationFromSystem != null) {
        if (applicationFromSystem.containsKey('action')) {
          application.action = applicationFromSystem['action'];
        }
        if (applicationFromSystem.containsKey('sideloaded')) {
          application.sideloaded = applicationFromSystem['sideloaded'];
        }
      }

      if (appsCategories.isNotEmpty && !application.hidden) {
        Iterable<AppCategory> currentApplicationCategories = appsCategories
            .where((appCategory) => appCategory.appPackageName == application.packageName);

        for (AppCategory appCategory in currentApplicationCategories) {
          if (_categoriesById.containsKey(appCategory.categoryId)) {
            Category category = _categoriesById[appCategory.categoryId]!;
            application.categoryOrders[category.id] = appCategory.order;
            category.applications.add(application);
          }
        }
      }
    }

    for (Category category in _categoriesById.values) {
      sortCategory(category);
    }

    if (shouldNotifyListeners) {
      notifyListeners();
    }

    return newPackages;
  }

  void sortCategory(Category category) {
    if (category.sort == CategorySort.alphabetical) {
      category.applications.sortBy(
              (application) => application.name);
    }
    else {
      category.applications.sortBy<num>(
              (application) => application.categoryOrders[category.id]!);
    }
  }

  /// Changes when the banner/icon of [application] may have changed (new version or reinstall).
  String imageKey(App application) =>
      "${application.version}#${_imageGenerations[application.packageName] ?? 0}";

  Future<Uint8List> getAppBanner(String packageName) {
    return _fLauncherChannel.getApplicationBanner(packageName);
  }

  Future<Uint8List> getAppIcon(String packageName) {
    return _fLauncherChannel.getApplicationIcon(packageName);
  }

  Future<void> launchApp(App app) {
    Future<void> future;
    if (app.action == null) {
      future = _fLauncherChannel.launchApp(app.packageName);
    }
    else {
      future = _fLauncherChannel.launchActivityFromAction(app.action!);
    }

    return future;
  }

  Future<void> openAppInfo(App app) => _fLauncherChannel.openAppInfo(app.packageName);

  Future<void> uninstallApp(App app) => _fLauncherChannel.uninstallApp(app.packageName);

  Future<void> openSettings() => _fLauncherChannel.openSettings();

  Future<bool> isDefaultLauncher() => _fLauncherChannel.isDefaultLauncher();

  Future<void> startAmbientMode() => _fLauncherChannel.startAmbientMode();

  Future<void> addToCategory(App app, Category category, {bool shouldNotifyListeners = true}) async {
    int index = await _database.nextAppCategoryOrder(category.id) ?? 0;
    await _database.insertAppsCategories([
      AppsCategoriesCompanion.insert(
        categoryId: category.id,
        appPackageName: app.packageName,
        order: index,
      )
    ]);

    if (_categoriesById.containsKey(category.id)) {
      Category categoryFound = _categoriesById[category.id]!;
      app.categoryOrders[categoryFound.id] = index;
      categoryFound.applications.add(app);

      if (shouldNotifyListeners) {
        sortCategory(categoryFound);
        notifyListeners();
      }
    }
  }

  Future<void> removeFromCategory(App application, Category category) async {
    await _database.deleteAppCategory(category.id, application.packageName);
    if (_categoriesById.containsKey(category.id)) {
      Category categoryFound = _categoriesById[category.id]!;
      application.categoryOrders.remove(categoryFound.id);
      categoryFound.applications.remove(application);

      notifyListeners();
    }
  }

  Future<void> saveApplicationOrderInCategory(Category category) async {
    if (!_categoriesById.containsKey(category.id)) {
      return;
    }
    
    Category categoryFound = _categoriesById[category.id]!;
    List<App> applications = categoryFound.applications;
    List<AppsCategoriesCompanion> orderedAppCategories = [];

    for (int i = 0; i < applications.length; ++i) {
      orderedAppCategories.add(AppsCategoriesCompanion(
        categoryId: Value(categoryFound.id),
        appPackageName: Value(applications[i].packageName),
        order: Value(i),
      ));
    }
    await _database.replaceAppsCategories(orderedAppCategories);
    notifyListeners();
  }

  void reorderApplication(Category category, int oldIndex, int newIndex) {
    if (!_categoriesById.containsKey(category.id)) {
      return;
    }
    Category categoryFound = _categoriesById[category.id]!;
    List<App> applications = categoryFound.applications;
    App application = applications.removeAt(oldIndex);
    applications.insert(newIndex, application);

    notifyListeners();
  }

  Future<int> addCategory(String categoryName, {
    CategorySort sort = Category.Sort,
    CategoryType type = Category.Type,
    int columnsCount = Category.ColumnsCount,
    int rowHeight = Category.RowHeight,
    int position = 0,
    bool shouldNotifyListeners = true
  }) async {
    int id = await _addCategoryAt(categoryName, position,
        sort: sort, type: type, columnsCount: columnsCount, rowHeight: rowHeight);
    if (shouldNotifyListeners) {
      notifyListeners();
    }
    return id;
  }

  /// Inserts a category at [position] in the launcher sections (clamped) and renumbers all
  /// sections. Returns the new category id, or -1 on failure.
  Future<int> _addCategoryAt(String categoryName, int position, {
    CategorySort sort = Category.Sort,
    CategoryType type = Category.Type,
    int columnsCount = Category.ColumnsCount,
    int rowHeight = Category.RowHeight,
  }) async {
    position = position.clamp(0, _launcherSections.length);
    int newCategoryId = -1;

    try {
      newCategoryId = await _database.transaction(() async {
        int id = await _database.insertCategory(CategoriesCompanion.insert(
          name: categoryName,
          sort: Value(sort),
          type: Value(type),
          columnsCount: Value(columnsCount),
          rowHeight: Value(rowHeight),
          order: position,
        ));

        Category newCategory = Category(
            id: id,
            name: categoryName,
            sort: sort,
            type: type,
            columnsCount: columnsCount,
            rowHeight: rowHeight,
            order: position
        );
        List<LauncherSection> sections = List.of(_launcherSections);
        sections.insert(position, newCategory);
        await _persistSectionOrder(sections);

        _categoriesById[id] = newCategory;
        _launcherSections = sections;
        return id;
      });
    }
    catch (ex) { }

    return newCategoryId;
  }

  /// Writes each section's index as its order.
  Future<void> _persistSectionOrder(List<LauncherSection> sections) async {
    List<CategoriesCompanion> orderedCategories = [];
    List<LauncherSpacersCompanion> orderedSpacers = [];
    for (int i = 0; i < sections.length; ++i) {
      LauncherSection section = sections[i];
      section.order = i;

      if (section is Category) {
        orderedCategories.add(CategoriesCompanion(id: Value(section.id), order: Value(i)));
      }
      else {
        orderedSpacers.add(LauncherSpacersCompanion(id: Value(section.id), order: Value(i)));
      }
    }

    await _database.updateCategories(orderedCategories);
    await _database.updateSpacers(orderedSpacers);
  }

  Future<void> updateCategory(
    int categoryId,
    String name,
    CategorySort sort,
    CategoryType type,
    int columnsCount,
    int rowHeight, {
    bool shouldNotifyListeners = true
    }) async
  {
    Category? category = _categoriesById[categoryId];
    assert(category != null);

    await _database.updateCategory(categoryId, CategoriesCompanion(
      name: Value(name),
      sort: Value(sort),
      type: Value(type),
      columnsCount: Value(columnsCount),
      rowHeight: Value(rowHeight)
    ));

    CategorySort oldSort = category!.sort;

    category.name = name;
    category.sort = sort;
    category.type = type;
    category.columnsCount = columnsCount;
    category.rowHeight = rowHeight;

    if (oldSort != sort) {
      sortCategory(category);
    }

    if (shouldNotifyListeners) {
      notifyListeners();
    }
  }

  Future<void> addSpacer(int height) async
  {
    int order = launcherSections.length;
    int spacerId = await _database.insertSpacer(
        LauncherSpacersCompanion.insert(height: height, order: order)
    );

    _launcherSections.add(LauncherSpacer(
      id: spacerId,
      height: height,
      order: order
    ));

    notifyListeners();
  }

  Future<void> updateSpacerHeight(LauncherSpacer spacer, int height) async
  {
    await _database.updateSpacer(spacer.id, LauncherSpacersCompanion(
      height: Value(height)
    ));

    spacer.height = height;
    notifyListeners();
  }

  Future<void> renameCategory(Category category, String categoryName) async {
    await _database.updateCategory(category.id, CategoriesCompanion(name: Value(categoryName)));

    if (_categoriesById.containsKey(category.id)) {
      Category categoryFound = _categoriesById[category.id]!;
      categoryFound.name = categoryName;
      notifyListeners();
    }
  }

  Future<void> deleteSection(int index) async
  {
    assert(index < _launcherSections.length);

    LauncherSection section = _launcherSections[index];
    if (section is Category) {
      await _database.deleteCategory(section.id);
      _categoriesById.remove(section.id);
    }
    else {
      await _database.deleteSpacer(section.id);
    }
    
    _launcherSections.removeAt(index);

    notifyListeners();
  }

  Future<void> moveSection(int oldIndex, int newIndex) async {
    List<LauncherSection> newSectionsList = List.of(_launcherSections);
    LauncherSection sectionToMove = newSectionsList.removeAt(oldIndex);
    newSectionsList.insert(newIndex, sectionToMove);

    List<CategoriesCompanion> orderedCategories = [];
    List<LauncherSpacersCompanion> orderedSpacers = [];
    for (int i = 0; i < newSectionsList.length; ++i) {
      LauncherSection section = newSectionsList[i];

      if (section is Category) {
        orderedCategories.add(CategoriesCompanion(id: Value(section.id), order: Value(i)));
      }
      else {
        orderedSpacers.add(LauncherSpacersCompanion(id: Value(section.id), order: Value(i)));
      }
    }

    await Future.wait([
      _database.updateCategories(orderedCategories),
      _database.updateSpacers(orderedSpacers)
    ]);

    _launcherSections = newSectionsList;
    notifyListeners();
  }

  Future<void> hideApplication(App application) async {
    await _database.updateApp(application.packageName, const AppsCompanion(hidden: Value(true)));

    if (_applications.containsKey(application.packageName)) {
      App applicationFound = _applications[application.packageName]!;
      applicationFound.hidden = true;

      for (int categoryId in applicationFound.categoryOrders.keys) {
        if (_categoriesById.containsKey(categoryId)) {
          Category category = _categoriesById[categoryId]!;
          category.applications.removeWhere((application0) => application0.packageName == application.packageName);
        }
      }

      notifyListeners();
    }
  }

  Future<void> showApplication(App application) async {
    await _database.updateApp(application.packageName, const AppsCompanion(hidden: Value(false)));

    if (_applications.containsKey(application.packageName)) {
      App applicationFound = _applications[application.packageName]!;
      applicationFound.hidden = false;

      for (int categoryId in application.categoryOrders.keys) {
        if (_categoriesById.containsKey(categoryId)) {
          Category category = _categoriesById[categoryId]!;
          category.applications.add(application);
          sortCategory(category);
        }
      }

      notifyListeners();
    }
  }

  Future<void> setCategoryType(Category category, CategoryType type, {bool shouldNotifyListeners = true}) async {
    await _database.updateCategory(category.id, CategoriesCompanion(type: Value(type)));

    if (_categoriesById.containsKey(category.id)) {
      Category categoryFound = _categoriesById[category.id]!;
      categoryFound.type = type;

      if (shouldNotifyListeners) {
        notifyListeners();
      }
    }
  }

  Future<void> setCategorySort(Category category, CategorySort sort) async {
    await _database.updateCategory(category.id, CategoriesCompanion(sort: Value(sort)));
    if (_categoriesById.containsKey(category.id)) {
      Category categoryFound = _categoriesById[category.id]!;
      categoryFound.sort = sort;
      sortCategory(categoryFound);

      notifyListeners();
    }

  }

  Future<void> setCategoryColumnsCount(Category category, int columnsCount) async {
    await _database.updateCategory(category.id, CategoriesCompanion(columnsCount: Value(columnsCount)));

    if (_categoriesById.containsKey(category.id)) {
      Category categoryFound = _categoriesById[category.id]!;
      categoryFound.columnsCount = columnsCount;

      notifyListeners();
    }
  }

  Future<void> setCategoryRowHeight(Category category, int rowHeight) async {
    await _database.updateCategory(category.id, CategoriesCompanion(rowHeight: Value(rowHeight)));

    if (_categoriesById.containsKey(category.id)) {
      Category categoryFound = _categoriesById[category.id]!;
      categoryFound.rowHeight = rowHeight;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Helpers for the control API (lib/api_server.dart).

  App? applicationByPackage(String packageName) => _applications[packageName];

  /// Finds a category by numeric id or by exact name.
  Category? findCategory(String reference) {
    int? id = int.tryParse(reference);
    if (id != null && _categoriesById.containsKey(id)) {
      return _categoriesById[id];
    }
    return _categoriesById.values.firstWhereOrNull((category) => category.name == reference);
  }

  /// package name -> ids of the categories it belongs to (from the database, so hidden apps
  /// report their memberships too), in category order.
  Future<Map<String, List<int>>> categoryMemberships() async {
    Map<String, List<int>> memberships = {};
    for (AppCategory appCategory in await _database.getAppsCategories()) {
      memberships.putIfAbsent(appCategory.appPackageName, () => []).add(appCategory.categoryId);
    }
    return memberships;
  }

  Future<void> setApplicationHidden(App application, bool hidden) async {
    if (application.hidden == hidden) {
      return;
    }
    if (hidden) {
      await hideApplication(application);
    }
    else {
      await _database.updateApp(application.packageName, const AppsCompanion(hidden: Value(false)));
      // Memberships of hidden apps are not kept in memory, reload them from the database.
      await _refreshState();
    }
  }

  /// Moves [application] to [index] inside [category] (manual order).
  Future<void> moveApplicationInCategory(Category category, App application, int index) async {
    List<App> applications = _categoriesById[category.id]?.applications ?? [];
    int oldIndex = applications.indexWhere((app) => app.packageName == application.packageName);
    if (oldIndex < 0) {
      return;
    }
    reorderApplication(category, oldIndex, index.clamp(0, applications.length - 1));
    await saveApplicationOrderInCategory(category);
  }

  /// Puts the listed packages first, in that order; other apps keep their relative order after them.
  Future<void> setCategoryApplicationsOrder(Category category, List<String> packageNames) async {
    Category? categoryFound = _categoriesById[category.id];
    if (categoryFound == null) {
      return;
    }
    List<App> applications = categoryFound.applications;
    List<App> ordered = [
      for (String packageName in packageNames)
        ...applications.where((app) => app.packageName == packageName),
      ...applications.where((app) => !packageNames.contains(app.packageName)),
    ];
    applications
      ..clear()
      ..addAll(ordered);
    await saveApplicationOrderInCategory(categoryFound);
  }

  Future<void> deleteCategory(Category category) async {
    int index = _launcherSections.indexWhere((section) => section is Category && section.id == category.id);
    if (index >= 0) {
      await deleteSection(index);
    }
  }

  Future<void> moveCategoryTo(Category category, int position) async {
    int index = _launcherSections.indexWhere((section) => section is Category && section.id == category.id);
    if (index >= 0) {
      await moveSection(index, position.clamp(0, _launcherSections.length - 1));
    }
  }
}
