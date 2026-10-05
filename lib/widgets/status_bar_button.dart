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

import 'package:flutter/material.dart';

/// Focusable, clickable status bar item with the same focus highlight as the settings gear
/// (a static primaryColorLight fill; nothing animates while it stays focused).
class StatusBarButton extends StatelessWidget {
  final Widget child;
  final VoidCallback onPressed;

  const StatusBarButton({super.key, required this.child, required this.onPressed});

  @override
  Widget build(BuildContext context) => Center(
    child: Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onPressed,
        customBorder: const StadiumBorder(),
        focusColor: Theme.of(context).primaryColorLight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: child,
        ),
      ),
    ),
  );
}

/// Shadow used by all status bar text and icons.
const statusBarShadows = [Shadow(color: Colors.black54, offset: Offset(0, 2), blurRadius: 8)];
