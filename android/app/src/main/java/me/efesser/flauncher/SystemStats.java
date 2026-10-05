package me.efesser.flauncher;

import android.app.ActivityManager;
import android.content.Context;
import android.os.SystemClock;
import android.util.Log;

import java.io.BufferedReader;
import java.io.FileReader;
import java.util.HashMap;
import java.util.Map;

/**
 * Whole-device CPU busy % (from /proc/stat deltas) and memory (ActivityManager.MemoryInfo).
 *
 * Normal apps are usually denied /proc/stat by SELinux (proc_stat), so if reading it directly
 * fails, the cpu line is fetched through the TV's own adbd on 127.0.0.1:5555 (LocalAdb). If that
 * fails as well the CPU value is reported as null and the widget only shows memory.
 *
 * All methods block; call them off the main thread.
 */
final class SystemStats {
    private static final String TAG = "FLauncherStats";
    /** Do not retry a failed adb connection more often than this. */
    private static final long ADB_RETRY_MS = 60_000;

    private final Context context;

    private enum Source { UNKNOWN, PROC, ADB, NONE }

    private Source source = Source.UNKNOWN;
    private LocalAdb adb;
    private long adbFailedAt = 0;
    private int adbFailures = 0;
    private String lastError = null;

    private long[] prev;          // {busy, total}
    private long prevAt;          // elapsedRealtime of prev
    private Double lastCpu;

    SystemStats(Context context) {
        this.context = context.getApplicationContext();
    }

    synchronized Map<String, Object> sample() {
        Map<String, Object> map = new HashMap<>();

        ActivityManager am = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
        ActivityManager.MemoryInfo mi = new ActivityManager.MemoryInfo();
        am.getMemoryInfo(mi);
        map.put("memTotal", mi.totalMem);
        map.put("memAvailable", mi.availMem);

        long[] now = readCpu();
        long nowAt = SystemClock.elapsedRealtime();
        if (now != null) {
            // First sample, or the previous one is stale (launcher was in background): take a
            // short second sample so callers always get a meaningful value.
            if (prev == null || nowAt - prevAt > 10_000) {
                prev = now;
                prevAt = nowAt;
                SystemClock.sleep(500);
                now = readCpu();
                nowAt = SystemClock.elapsedRealtime();
            }
        }
        if (now != null && prev != null) {
            long dTotal = now[1] - prev[1];
            long dBusy = now[0] - prev[0];
            if (dTotal > 0) {
                lastCpu = Math.max(0.0, Math.min(100.0, 100.0 * dBusy / dTotal));
            }
            prev = now;
            prevAt = nowAt;
        } else if (now == null) {
            lastCpu = null;
            prev = null;
        }

        map.put("cpu", lastCpu);
        map.put("cpuSource", source.name().toLowerCase());
        map.put("cpuCount", Runtime.getRuntime().availableProcessors());
        if (lastError != null) map.put("cpuError", lastError);
        return map;
    }

    /** Releases the adb connection (called when the launcher goes to background). */
    synchronized void release() {
        if (adb != null) {
            adb.close();
            adb = null;
        }
    }

    /** @return {busy, total} jiffies of the aggregate "cpu" line, or null if unavailable. */
    private long[] readCpu() {
        if (source == Source.UNKNOWN || source == Source.PROC) {
            try (BufferedReader r = new BufferedReader(new FileReader("/proc/stat"))) {
                long[] v = parse(r.readLine());
                if (v != null) {
                    source = Source.PROC;
                    return v;
                }
            } catch (Exception e) {
                lastError = "/proc/stat: " + e.getMessage();
                Log.i(TAG, "direct /proc/stat read failed, trying local adb: " + e);
            }
            source = Source.ADB;
        }
        if (source == Source.ADB) {
            long now = SystemClock.elapsedRealtime();
            if (adb == null) {
                if (adbFailedAt != 0 && now - adbFailedAt < ADB_RETRY_MS) return null;
                try {
                    // Short approval timeout: never block the stats loop on a dialog.
                    adb = LocalAdb.connect(context, null, 15_000);
                } catch (Exception e) {
                    adbFailedAt = now;
                    adbFailures++;
                    lastError = "adb: " + e;
                    Log.w(TAG, "local adb connect failed", e);
                    if (adbFailures >= 5) source = Source.NONE;
                    return null;
                }
            }
            try {
                String out = adb.shell("head -n 1 /proc/stat");
                long[] v = parse(out.trim());
                if (v != null) {
                    adbFailures = 0;
                    lastError = null;
                    return v;
                }
                lastError = "adb: unexpected output";
            } catch (Exception e) {
                lastError = "adb: " + e;
                Log.w(TAG, "local adb shell failed", e);
            }
            adb.close();
            adb = null;
            adbFailedAt = now;
            return null;
        }
        return null;
    }

    private static long[] parse(String line) {
        if (line == null || !line.startsWith("cpu ")) return null;
        String[] f = line.trim().split("\\s+");
        if (f.length < 5) return null;
        long total = 0, idle = 0;
        // user nice system idle iowait irq softirq steal (guest/guest_nice are included in user)
        for (int i = 1; i < f.length && i <= 8; i++) {
            long v = Long.parseLong(f[i]);
            total += v;
            if (i == 4 || i == 5) idle += v;
        }
        return new long[]{total - idle, total};
    }
}
