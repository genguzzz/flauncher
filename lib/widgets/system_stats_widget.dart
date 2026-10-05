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
import 'package:flauncher/providers/stats_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// "CPU 13% · 内存 2.1/3.5G" — plain text, rebuilt only when a new sample arrives.
class SystemStatsWidget extends StatelessWidget {
  final TextStyle? textStyle;

  const SystemStatsWidget({super.key, this.textStyle});

  static String _gb(int bytes) => (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) => Selector<StatsService, SystemStats?>(
    selector: (_, service) => service.stats,
    builder: (context, stats, _) {
      if (stats == null) {
        return const SizedBox.shrink();
      }
      final localizations = AppLocalizations.of(context)!;
      final parts = <String>[
        if (stats.cpu != null) localizations.statsCpu(stats.cpu!.round().toString()),
        if (stats.memTotal > 0) localizations.statsMemory(_gb(stats.memUsed), _gb(stats.memTotal)),
      ];
      return RepaintBoundary(
        child: Text(parts.join(" · "), style: textStyle, maxLines: 1, softWrap: false),
      );
    },
  );
}
