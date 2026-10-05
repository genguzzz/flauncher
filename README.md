# FLauncher (fork)
#### This is a fork of the GitLab repository at: https://gitlab.com/flauncher/flauncher.

FLauncher is an open-source alternative launcher for Android TV, built with [Flutter](https://flutter.dev).

## TV custom build

Branch `tv-custom` of [genguzzz/flauncher](https://github.com/genguzzz/flauncher), based on tag
`v2025.07.001`, built for a Skyworth/Coocaa Android 12 TV (32-bit userspace). It keeps the package name
`me.efesser.flauncher`, so it installs over the stock build and keeps its database and preferences.

Changes:

- **New apps are visible by default.** A newly installed launchable app (also one that is reinstalled or
  updated while it belongs to no category, or installed while the launcher was not running) is added to
  the category named by the setting `new_apps_category` (default `新应用`, created at the end on demand;
  empty string disables it). Apps that are hidden stay hidden. Settings → 新应用加入的分类.
- **Banners/icons refresh live** after an app is updated or reinstalled (no force-stop needed).
- **CPU / memory indicator** in the status bar (`CPU 13% · 内存 2.1/3.5G`), refreshed every 2 s only while
  the launcher is in the foreground. CPU = whole-device busy from `/proc/stat` deltas (read directly; if
  SELinux denies it, through the TV's own adbd on 127.0.0.1:5555; hidden if neither works). Toggle:
  Settings → Status bar → CPU / 内存指示, or `show_system_stats`.
- **Control HTTP API** on port **10600** (all interfaces), started with the app.
- Chinese (`zh`) translation; build fixes for Flutter 3.38 (Gradle 8.12, AGP 8.9.1, generated l10n in
  `lib/l10n`, malformed `app_es.arb` placeholders, ABI split list).

### Build and install

```sh
./tv-build.sh            # armeabi-v7a release, android:debuggable=true, signed with the TV key
~/Code/skyworth-tv/tv-install.sh build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk
```

`tv-build.sh` reads `FLAUNCHER_KEYSTORE` (default `~/Code/skyworth-tv/remote-keys/release.keystore`),
`FLAUNCHER_KEYSTORE_PASSWORD`, `FLAUNCHER_SIGNING_KEY_ALIAS`, `BUILD_NAME`/`BUILD_NUMBER` (default from
`pubspec.yaml`; the version code must stay above 20). It removes any `.idsig` so adb never uses incremental
install. The manifest is debuggable (via a placeholder, not `buildType.debuggable`, which would make Flutter
build a JIT debug app) so `run-as me.efesser.flauncher` keeps working.

### Control API

Base URL `http://<tv>:10600/api`, JSON in and out. If the setting `api_token` is non-empty every request
needs `Authorization: Bearer <token>` (empty by default). Changes go through the app's services, so the UI
updates immediately. Errors return `{"error": "..."}` with 400/401/404/409/5xx.

| Method & path | Body / result |
|---|---|
| `GET /api` | endpoint list |
| `GET /api/settings` | all settings (see keys below) |
| `PUT\|POST /api/settings` | partial object `{key: value}`; unknown keys → 400 |
| `GET /api/gradients` | `[{uuid, name}]` |
| `GET /api/wallpaper` | `{custom_picture, gradient_uuid, gradient_name}` |
| `POST /api/wallpaper` | raw image bytes (`Content-Type: image/*`) or `{"url": "https://..."}`; checked by decoding, max 40 MB |
| `DELETE /api/wallpaper` | remove the picture, the gradient shows again |
| `GET /api/apps` | `[{package, name, version, hidden, sideloaded, categories: [{id, name, order}]}]` |
| `GET /api/apps/<pkg>` | one app |
| `POST /api/apps/<pkg>` | any of `hidden` (bool), `category` (id or name: add to it) + optional `order` (index in it), `remove_from` (id, name or `"all"`), `categories` (exact list of ids/names) |
| `GET /api/categories` | categories in display order: `{id, name, type: row\|grid, sort: manual\|alphabetical, columns, row_height, position, apps: [pkg]}` |
| `POST /api/categories` | create: `{name, type?, sort?, columns?, row_height?, position? (default: last), apps?}` |
| `GET /api/categories/<id or name>` | one category |
| `POST\|PUT /api/categories/<id or name>` | update any of `name, type, sort, columns (1-20), row_height (20-500), position, apps` (`apps`: listed packages are added if missing and put first, in that order) |
| `DELETE /api/categories/<id or name>` | delete (apps stay installed) |
| `GET /api/stats` | `{cpu_percent, cpu_source: proc\|adb\|none, mem_total, mem_available, mem_used, mem_total_gb, mem_used_gb}` |
| `POST /api/launch/<pkg>` | start the app |
| `POST /api/refresh` | rescan installed apps (new ones go to `new_apps_category`) |

Setting keys: `app_highlight_animation_enabled`, `app_key_click_enabled`, `auto_hide_app_bar`,
`show_category_titles`, `show_date_in_status_bar`, `show_time_in_status_bar`, `show_system_stats` (bools);
`gradient_uuid` (uuid or name from `/api/gradients`, also removes a picture wallpaper);
`back_button_action` (`""`, `"CLOCK"`, `"SCREENSAVER"`); `date_format`, `time_format` (ICU patterns, e.g.
`"EEEE d"`, `"H:mm"`); `new_apps_category` (string, empty = off); `api_token` (string, reported as `***`).

```sh
TV=http://192.168.0.109:10600
curl $TV/api/settings
curl -X POST $TV/api/settings -d '{"show_system_stats": false, "time_format": "HH:mm"}'
curl -X POST $TV/api/wallpaper -H 'Content-Type: image/jpeg' --data-binary @wall.jpg
curl -X POST $TV/api/wallpaper -H 'Content-Type: application/json' -d '{"url": "https://example.com/a.jpg"}'
curl -X POST $TV/api/categories -d '{"name": "游戏", "type": "grid", "columns": 6}'
curl -X POST $TV/api/apps/org.smarttube.stable -d '{"category": "看电视", "order": 0}'
curl -X POST $TV/api/categories/看电视 -d '{"apps": ["org.smarttube.stable", "com.ktcp.video"]}'
```

The server runs in the Flutter engine, i.e. whenever the launcher process is alive (also while another app is
in the foreground). Note: an app inside a full-tunnel VPN (`addRoute 0.0.0.0/0` without excluding the LAN)
answers LAN clients through the tunnel, so the port is unreachable from the LAN while such a VPN runs;
`adb forward tcp:10600 tcp:10600` and `http://127.0.0.1:10600` work regardless.

## Download
Get the latest build from the [releases](https://github.com/osrosal/flauncher/releases) page, you can look for older builds on the [actions](https://github.com/CocoCR300/flauncher/actions) tab, where they are uploaded as artifacts.

## Features
For a list of the changes introduced by this fork from the original, see the [CHANGELOG](CHANGELOG.md) file.

- [x] No ads
- [x] Customizable categories
- [x] Manually reorder apps within categories
- [x] Wallpaper support
- [x] Open "Android Settings"
- [x] Open "App info"
- [x] Uninstall app
- [x] Clock
- [x] Switch between row and grid for categories
- [x] Support for non-TV (sideloaded) apps
- [x] Navigation sound feedback
- [ ] Force stop app

## Screenshots
|  |  |  |
|--|--|--|
| ![](screenshots/Screenshot_1624378896.png) | ![](screenshots/Screenshot_1624378921.png) | ![](screenshots/Screenshot_1624378938.png) |

## Set FLauncher as default launcher

### Method 1: remap the Home button
This is the "safer" and easiest way. Use [Button Mapper](https://play.google.com/store/apps/details?id=flar2.homebutton) to remap the Home button of the remote to launch FLauncher.

### Method 2: disable the default launcher
**:warning: Disclaimer :warning:**

**You are doing this at your own risk, and you'll be responsible in any case of malfunction on your device.**

The following commands have been tested on Chromecast with Google TV only. This may be different on other devices.

Once the default launcher is disabled, press the Home button on the remote, and you'll be prompted by the system to choose which app to set as default.

#### Disable default launcher
```shell
# Disable com.google.android.apps.tv.launcherx which is the default launcher on CCwGTV
$ adb shell pm disable-user --user 0 com.google.android.apps.tv.launcherx
# com.google.android.tungsten.setupwraith will then be used as a 'fallback' and will automatically
# re-enable the default launcher, so disable it as well
$ adb shell pm disable-user --user 0 com.google.android.tungsten.setupwraith
```

#### Re-enable default launcher
```shell
$ adb shell pm enable com.google.android.apps.tv.launcherx
$ adb shell pm enable com.google.android.tungsten.setupwraith
```

#### Known issues
On Chromecast with Google TV (maybe others), the "YouTube" remote button will stop working if the default launcher is disabled. As a workaround, you can use [Button Mapper](https://play.google.com/store/apps/details?id=flar2.homebutton) to remap it correctly.

## Wallpaper
Because Android's `WallpaperManager` is not available on some Android TV devices, FLauncher implements its own wallpaper management method.

Please note that changing wallpaper requires a file explorer to be installed on the device in order to pick a file.

## Support the original author: [etienn01](https://github.com/etienn01)
<a href="https://www.buymeacoffee.com/etienn01" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" width="200"></a>
