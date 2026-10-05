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

import android.content.Context;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLExt;
import android.opengl.EGLSurface;
import android.opengl.GLES30;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;
import java.util.regex.Pattern;

/**
 * Live wallpaper shaders: built-in ones in assets/shaders/&lt;id&gt;.frag and uploaded ones in
 * files/shaders/&lt;id&gt;.frag (an upload with a built-in id overrides it). Sources are read from disk
 * only when a shader is switched to; nothing is cached.
 */
final class ShaderStore {
    static final Pattern ID = Pattern.compile("[a-z0-9_-]{1,32}");
    /** "// @height 360" / "// @fps 20" in a shader: its preferred render height and frame rate. */
    private static final Pattern DIRECTIVE = Pattern.compile("//\\s*@(height|fps)\\s+(\\d+)");

    private final Context context;
    private final File dir;

    ShaderStore(Context context) {
        this.context = context;
        dir = new File(context.getFilesDir(), "shaders");
    }

    /** [{id, builtin, custom, height?, fps?}] sorted by id. */
    List<Map<String, Object>> list() {
        TreeSet<String> builtin = new TreeSet<>();
        TreeSet<String> custom = new TreeSet<>();
        try {
            String[] names = context.getAssets().list("shaders");
            if (names != null) for (String name : names) if (name.endsWith(".frag")) builtin.add(stem(name));
        } catch (IOException ignored) {
        }
        File[] files = dir.listFiles();
        if (files != null) for (File file : files) if (file.getName().endsWith(".frag")) custom.add(stem(file.getName()));
        TreeSet<String> all = new TreeSet<>(builtin);
        all.addAll(custom);
        List<Map<String, Object>> result = new ArrayList<>();
        for (String id : all) {
            Map<String, Object> entry = new HashMap<>();
            entry.put("id", id);
            entry.put("builtin", builtin.contains(id));
            entry.put("custom", custom.contains(id));
            try {
                java.util.regex.Matcher m = DIRECTIVE.matcher(read(id));
                while (m.find()) entry.put(m.group(1), Integer.parseInt(m.group(2)));
            } catch (IOException | NumberFormatException ignored) {
            }
            result.add(entry);
        }
        return result;
    }

    boolean exists(String id) {
        try {
            read(id);
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    String read(String id) throws IOException {
        if (!ID.matcher(id).matches()) throw new IOException("bad shader id " + id);
        File file = new File(dir, id + ".frag");
        try (InputStream in = file.isFile() ? new FileInputStream(file) : context.getAssets().open("shaders/" + id + ".frag")) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int n;
            while ((n = in.read(buffer)) > 0) out.write(buffer, 0, n);
            return out.toString(StandardCharsets.UTF_8.name());
        }
    }

    /** Compiles [source] in a throwaway context; saves it if it compiles. Returns the compile error or null. */
    String save(String id, String source) throws IOException {
        if (!ID.matcher(id).matches()) throw new IOException("shader id must match " + ID.pattern());
        String error = compileCheck(source);
        if (error != null) return error;
        if (!dir.isDirectory() && !dir.mkdirs()) throw new IOException("cannot create " + dir);
        File tmp = new File(dir, id + ".frag.tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            out.write(source.getBytes(StandardCharsets.UTF_8));
        }
        if (!tmp.renameTo(new File(dir, id + ".frag"))) throw new IOException("cannot save " + id);
        return null;
    }

    /** Removes an uploaded shader (a built-in one with the same id shows again). */
    boolean delete(String id) {
        return ID.matcher(id).matches() && new File(dir, id + ".frag").delete();
    }

    private static String stem(String name) {
        return name.substring(0, name.length() - ".frag".length());
    }

    /** Compiles and links the shader on an offscreen 1x1 context, then destroys everything. */
    static String compileCheck(String source) {
        EGLDisplay display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        int[] version = new int[2];
        EGL14.eglInitialize(display, version, 0, version, 1);
        EGLConfig[] configs = new EGLConfig[1];
        int[] count = new int[1];
        EGL14.eglChooseConfig(display, new int[]{
                EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT, EGL14.EGL_NONE}, 0, configs, 0, 1, count, 0);
        EGLContext context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
                new int[]{EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE}, 0);
        EGLSurface surface = EGL14.eglCreatePbufferSurface(display, configs[0],
                new int[]{EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE}, 0);
        try {
            EGL14.eglMakeCurrent(display, surface, surface, context);
            StringBuilder log = new StringBuilder();
            int program = LiveWallpaper.buildProgram(source, log);
            if (program == 0) return log.toString().trim();
            GLES30.glDeleteProgram(program);
            return null;
        } finally {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
            EGL14.eglDestroySurface(display, surface);
            EGL14.eglDestroyContext(display, context);
            EGL14.eglReleaseThread();
        }
    }
}
