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

package me.efesser.flauncher;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;

import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.ExecutorService;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import io.flutter.plugin.common.EventChannel;

/**
 * Physical (non-VPN) network type and Wi-Fi SSID, pushed to Dart only when they change.
 *
 * Tracks networks with a ConnectivityManager callback (no polling). The SSID comes from the
 * network's WifiInfo (Android 12+: callback registered with FLAG_INCLUDE_LOCATION_INFO), else from
 * WifiManager.getConnectionInfo(); both need ACCESS_FINE_LOCATION and location mode on. If both are
 * redacted ("<unknown ssid>") it is read once per network with `cmd wifi status` through the TV's
 * own adbd (LocalAdb), which also grants the location permission for next time.
 */
final class NetworkSummary implements EventChannel.StreamHandler {
    private static final String TAG = "FLauncherNet";
    private static final String UNKNOWN_SSID = "<unknown ssid>";
    private static final long DEBOUNCE_MS = 300;
    private static final long ADB_RETRY_MS = 60_000;
    private static final Pattern WIFI_STATUS_SSID = Pattern.compile("Wifi is connected to \"(.*)\"");

    private final Context context;
    private final ConnectivityManager connectivityManager;
    private final WifiManager wifiManager;
    private final ExecutorService executor;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Map<Network, NetworkCapabilities> networks = new LinkedHashMap<>();
    /** SSID per Wi-Fi network, kept while the network lives (reads are redacted in background). */
    private final Map<Network, String> ssidCache = new HashMap<>();

    private EventChannel.EventSink sink;
    private Map<String, Object> last;
    private boolean adbRunning = false;
    private long adbFailedAt = 0;

    private final Runnable emit = this::emitIfChanged;

    NetworkSummary(Context context, ExecutorService executor) {
        this.context = context.getApplicationContext();
        this.executor = executor;
        connectivityManager = (ConnectivityManager) this.context.getSystemService(Context.CONNECTIVITY_SERVICE);
        wifiManager = (WifiManager) this.context.getSystemService(Context.WIFI_SERVICE);

        // Default capabilities include NOT_VPN, so this only matches physical networks.
        NetworkRequest request = new NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build();
        ConnectivityManager.NetworkCallback callback = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
                ? new Callback(ConnectivityManager.NetworkCallback.FLAG_INCLUDE_LOCATION_INFO)
                : new Callback();
        try {
            connectivityManager.registerNetworkCallback(request, callback, handler);
        } catch (RuntimeException e) {
            Log.w(TAG, "registerNetworkCallback failed", e);
        }
    }

    private class Callback extends ConnectivityManager.NetworkCallback {
        Callback() { super(); }

        Callback(int flags) { super(flags); }

        @Override
        public void onCapabilitiesChanged(@NonNull Network network, @NonNull NetworkCapabilities caps) {
            networks.put(network, caps);
            schedule();
        }

        @Override
        public void onLost(@NonNull Network network) {
            networks.remove(network);
            ssidCache.remove(network);
            schedule();
        }
    }

    private void schedule() {
        handler.removeCallbacks(emit);
        handler.postDelayed(emit, DEBOUNCE_MS);
    }

    /** Current summary {type: wifi|ethernet|none, ssid}; main thread. May start an adb lookup. */
    Map<String, Object> current() {
        Network ethernet = null, wifi = null;
        for (Map.Entry<Network, NetworkCapabilities> e : networks.entrySet()) {
            NetworkCapabilities caps = e.getValue();
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) ethernet = e.getKey();
            else if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) wifi = e.getKey();
        }
        Map<String, Object> map = new HashMap<>();
        if (ethernet != null) {
            map.put("type", "ethernet");
            map.put("ssid", null);
        } else if (wifi != null) {
            map.put("type", "wifi");
            map.put("ssid", ssid(wifi));
        } else {
            map.put("type", "none");
            map.put("ssid", null);
        }
        return map;
    }

    private String ssid(Network network) {
        String ssid = null;
        NetworkCapabilities caps = networks.get(network);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && caps != null
                && caps.getTransportInfo() instanceof WifiInfo info) {
            ssid = clean(info.getSSID());
        }
        if (ssid == null) {
            try {
                //noinspection deprecation
                ssid = clean(wifiManager.getConnectionInfo().getSSID());
            } catch (RuntimeException ignored) { }
        }
        if (ssid != null) {
            ssidCache.put(network, ssid);
            return ssid;
        }
        ssid = ssidCache.get(network);
        if (ssid == null) lookupWithAdb(network);
        return ssid;
    }

    private static String clean(String ssid) {
        if (ssid == null || ssid.isEmpty() || UNKNOWN_SSID.equals(ssid)) return null;
        if (ssid.length() >= 2 && ssid.startsWith("\"") && ssid.endsWith("\"")) {
            ssid = ssid.substring(1, ssid.length() - 1);
        }
        return ssid.isEmpty() ? null : ssid;
    }

    private void lookupWithAdb(Network network) {
        long now = android.os.SystemClock.elapsedRealtime();
        if (adbRunning || (adbFailedAt != 0 && now - adbFailedAt < ADB_RETRY_MS)) return;
        adbRunning = true;
        boolean grant = context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                != PackageManager.PERMISSION_GRANTED;
        executor.execute(() -> {
            String ssid = null;
            LocalAdb adb = null;
            try {
                adb = LocalAdb.connect(context, null, 15_000);
                String cmd = "cmd wifi status";
                if (grant) {
                    cmd = "pm grant " + context.getPackageName() + " "
                            + Manifest.permission.ACCESS_FINE_LOCATION + " 2>/dev/null; " + cmd;
                }
                Matcher m = WIFI_STATUS_SSID.matcher(adb.shell(cmd));
                if (m.find()) ssid = clean("\"" + m.group(1) + "\"");
            } catch (Exception e) {
                Log.w(TAG, "adb ssid lookup failed", e);
            } finally {
                if (adb != null) adb.close();
            }
            final String result = ssid;
            handler.post(() -> {
                adbRunning = false;
                if (result == null) {
                    adbFailedAt = android.os.SystemClock.elapsedRealtime();
                } else if (networks.containsKey(network)) {
                    ssidCache.put(network, result);
                    schedule();
                }
            });
        });
    }

    /** Re-reads the SSID (e.g. back in the foreground, where reads are not redacted). */
    void refresh() {
        schedule();
    }

    private void emitIfChanged() {
        Map<String, Object> now = current();
        if (Objects.equals(now, last)) return;
        last = now;
        if (sink != null) sink.success(now);
    }

    @Override
    public void onListen(Object arguments, EventChannel.EventSink events) {
        sink = events;
        last = current();
        events.success(last);
    }

    @Override
    public void onCancel(Object arguments) {
        sink = null;
    }
}
