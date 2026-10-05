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

import 'package:flauncher/flauncher_channel.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Shows the natively rendered animated wallpaper (LiveWallpaper.java) as a texture.
///
/// The shader only runs while the launcher is on screen: it is paused whenever the app is not
/// resumed (another app in front, screen off / standby) and released when this widget goes away.
/// [placeholder] (the static wallpaper) is shown until the first frame is ready.
class LiveWallpaperView extends StatefulWidget {
  final String shader;
  final int fps;
  final int renderHeight;
  final Widget placeholder;

  const LiveWallpaperView({
    super.key,
    required this.shader,
    required this.fps,
    required this.renderHeight,
    required this.placeholder,
  });

  @override
  State<LiveWallpaperView> createState() => _LiveWallpaperViewState();
}

class _LiveWallpaperViewState extends State<LiveWallpaperView> with WidgetsBindingObserver {
  late final FLauncherChannel _channel;
  int? _textureId;
  Size? _renderSize;
  bool _disposed = false;
  bool _starting = false;
  bool? _running;

  @override
  void initState() {
    super.initState();
    _channel = context.read<FLauncherChannel>();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _start();
  }

  @override
  void didUpdateWidget(LiveWallpaperView old) {
    super.didUpdateWidget(old);
    if (_textureId == null) return;
    if (old.renderHeight != widget.renderHeight) {
      _restart();
    }
    else if (old.shader != widget.shader || old.fps != widget.fps) {
      _channel.liveWallpaperUpdate(
        shader: old.shader != widget.shader ? widget.shader : null,
        fps: old.fps != widget.fps ? widget.fps : null,
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _updateRunning();

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    if (_textureId != null) _channel.liveWallpaperStop();
    super.dispose();
  }

  /// Render size: the screen's aspect ratio at [LiveWallpaperView.renderHeight] pixels high.
  Size _targetSize() {
    final screen = MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
    final height = widget.renderHeight.clamp(1, screen.height.round()).toDouble();
    return Size((screen.width * height / screen.height).roundToDouble(), height);
  }

  Future<void> _start() async {
    final size = _targetSize();
    if (_starting || (_textureId != null && size == _renderSize) || size.isEmpty) return;
    _starting = true;
    try {
      final id = await _channel.liveWallpaperStart(widget.shader, size.width.toInt(), size.height.toInt(), widget.fps);
      if (_disposed) {
        if (id != null) _channel.liveWallpaperStop();
        return;
      }
      setState(() {
        _textureId = id;
        _renderSize = size;
        _running = null;
      });
      _updateRunning();
    } finally {
      _starting = false;
    }
  }

  void _restart() {
    _textureId = null;
    _start();
  }

  void _updateRunning() {
    if (_textureId == null) return;
    final running = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (running != _running) {
      _running = running;
      _channel.liveWallpaperUpdate(running: running);
    }
  }

  @override
  // The texture is opaque, so the placeholder is dropped once it exists (no full-screen overdraw).
  Widget build(BuildContext context) => _textureId == null
      ? widget.placeholder
      : Texture(textureId: _textureId!, filterQuality: FilterQuality.low);
}
