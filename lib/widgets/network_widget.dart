import 'package:flauncher/l10n/app_localizations.dart';
import 'package:flauncher/providers/network_service.dart';
import 'package:flauncher/providers/settings_service.dart';
import 'package:flauncher/widgets/status_bar_button.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Network icon plus the first 4 characters of the Wi-Fi name ("有线" / "未连接" otherwise).
/// Focusable; OK opens the system Wi-Fi settings.
class NetworkWidget extends StatelessWidget
{
  final TextStyle? textStyle;

  const NetworkWidget({super.key, this.textStyle});

  @override
  Widget build(BuildContext context) {
    return Consumer<NetworkService>(
      builder: (context, networkService, _) {
        IconData iconData;

        switch (networkService.networkType)
        {
          case NetworkType.Cellular:
            switch (networkService.cellularNetworkType)
            {
              case CellularNetworkType.Cdma || CellularNetworkType.Gsm || CellularNetworkType.Gprs:
                iconData = Icons.g_mobiledata;

              case CellularNetworkType.Edge: iconData = Icons.e_mobiledata;

              case CellularNetworkType.Hspa || CellularNetworkType.Hsdpa || CellularNetworkType.Hsupa:
                iconData = Icons.h_mobiledata;

              case CellularNetworkType.Hspap: iconData = Icons.h_plus_mobiledata;

              case CellularNetworkType.Umts || CellularNetworkType.TdScdma:
                iconData = Icons.three_g_mobiledata; break;

              case CellularNetworkType.Lte: iconData = Icons.four_g_mobiledata_outlined; break;
              case CellularNetworkType.Nr: iconData = Icons.five_g;

              default: iconData = Icons.question_mark; break;
            }
            break;
          case NetworkType.Wifi:
            int signalLevel = networkService.wirelessNetworkSignalLevel;
            if (signalLevel == 0) {
              iconData = Icons.signal_wifi_0_bar;
            }
            else if (signalLevel == 1) {
              iconData = Icons.network_wifi_1_bar;
            }
            else if (signalLevel == 2) {
              iconData = Icons.network_wifi_2_bar;
            }
            else if (signalLevel == 3) {
              iconData = Icons.network_wifi_3_bar;
            }
            else {
              iconData = Icons.signal_wifi_4_bar;
            }
            break;
          case NetworkType.Vpn: iconData = Icons.vpn_key; break;
          case NetworkType.Wired: iconData = Icons.lan; break;
          case NetworkType.Unknown: iconData = Icons.link_off; break;
        }

        final showName = context.select<SettingsService, bool>((settings) => settings.showWifiName);
        final icon = Icon(iconData, shadows: statusBarShadows);

        return StatusBarButton(
          onPressed: () => networkService.openWifiSettings(),
          child: showName
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  icon,
                  const SizedBox(width: 6),
                  Text(
                    NetworkService.shortLabel(networkService.physicalType, networkService.ssid,
                        AppLocalizations.of(context)!),
                    style: textStyle,
                    maxLines: 1,
                    softWrap: false,
                  ),
                ],
              )
            : icon,
        );
      }
    );
  }
}