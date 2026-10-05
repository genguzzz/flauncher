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

import android.content.res.AssetManager;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLExt;
import android.opengl.EGLSurface;
import android.opengl.GLES30;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Process;
import android.util.Log;
import android.view.Choreographer;
import android.view.Surface;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import io.flutter.view.TextureRegistry;

/**
 * Animated wallpaper: a full-screen GLSL ES 3.00 fragment shader (assets/shaders/&lt;name&gt;.frag)
 * drawn with OpenGL ES on its own thread into a Flutter {@link TextureRegistry.SurfaceProducer},
 * which the Dart side shows with a {@code Texture} widget behind the launcher.
 *
 * The shader runs at a reduced resolution and frame rate (it is scaled up with bilinear filtering;
 * the shaders are soft gradients, so that is invisible) and only while running is set — the Dart
 * side stops it whenever the launcher is not on screen. Shader time only advances while running,
 * so the picture resumes where it stopped.
 */
final class LiveWallpaper implements TextureRegistry.SurfaceProducer.Callback, Choreographer.FrameCallback {
    private static final String TAG = "LiveWallpaper";
    /** Shader time wraps here; keeps float precision for the fast terms after days on the home screen. */
    private static final double TIME_WRAP = 3600.0 * 6;

    private static final String VERTEX_SHADER =
            "#version 300 es\n" +
            "out vec2 qt_TexCoord0;\n" +
            "void main() {\n" +
            "    vec2 uv = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));\n" +
            "    qt_TexCoord0 = uv;\n" +
            "    gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);\n" +
            "}\n";

    private static final String FRAGMENT_PREAMBLE =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "in vec2 qt_TexCoord0;\n" +
            "out vec4 fragColor;\n" +
            "uniform float u_time;\n" +
            "uniform vec2 u_res;\n" +
            "#line 1\n";

    private final AssetManager assets;
    private final TextureRegistry.SurfaceProducer producer;
    private final HandlerThread thread;
    private final Handler handler;

    // Everything below is only touched on the GL thread.
    private EGLDisplay display = EGL14.EGL_NO_DISPLAY;
    private EGLContext context = EGL14.EGL_NO_CONTEXT;
    private EGLConfig config;
    private EGLSurface eglSurface = EGL14.EGL_NO_SURFACE;
    private Surface surface;
    private int vertexArray;
    private int program;
    private int timeLocation = -1;
    private int resolutionLocation = -1;
    private String shader;
    private int width;
    private int height;
    private int fps;
    private boolean running;
    private boolean frameScheduled;
    private long lastFrameNanos;
    private long lastDrawNanos;
    private double time;
    private boolean released;

    LiveWallpaper(AssetManager assets, TextureRegistry textureRegistry, String shader, int width, int height, int fps) {
        this.assets = assets;
        this.shader = shader;
        this.width = width;
        this.height = height;
        this.fps = clampFps(fps);
        producer = textureRegistry.createSurfaceProducer(TextureRegistry.SurfaceLifecycle.manual);
        producer.setSize(width, height);
        producer.setCallback(this);
        thread = new HandlerThread("LiveWallpaper", Process.THREAD_PRIORITY_DISPLAY);
        thread.start();
        handler = new Handler(thread.getLooper());
        final Surface initial = producer.getSurface();
        handler.post(() -> {
            initEgl();
            attachSurface(initial);
            loadProgram();
            drawOnce();
        });
    }

    long id() {
        return producer.id();
    }

    /** Switches the shader; returns false (keeping the current one) if it does not exist. */
    boolean setShader(String name) {
        if (!shaderExists(assets, name)) {
            return false;
        }
        handler.post(() -> {
            if (released || name.equals(shader)) return;
            shader = name;
            time = 0;
            loadProgram();
            drawOnce();
        });
        return true;
    }

    void setFrameRate(int fps) {
        final int value = clampFps(fps);
        handler.post(() -> this.fps = value);
    }

    void setRunning(boolean value) {
        handler.post(() -> {
            if (released || running == value) return;
            running = value;
            lastFrameNanos = 0;
            if (running) scheduleFrame();
        });
    }

    void release() {
        handler.post(() -> {
            released = true;
            running = false;
            destroyGl();
            thread.quitSafely();
        });
        producer.release();
    }

    static boolean shaderExists(AssetManager assets, String name) {
        try (InputStream ignored = assets.open("shaders/" + name + ".frag")) {
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    private static int clampFps(int fps) {
        return Math.max(1, Math.min(60, fps));
    }

    // --- SurfaceProducer.Callback (main thread) ------------------------------------------------------

    @Override
    public void onSurfaceAvailable() {
        final Surface next = producer.getSurface();
        handler.post(() -> {
            if (released) return;
            attachSurface(next);
            drawOnce();
        });
    }

    @Override
    public void onSurfaceCleanup() {
        // The surface is destroyed right after this returns: stop drawing into it first.
        final CountDownLatch done = new CountDownLatch(1);
        handler.post(() -> {
            detachSurface();
            done.countDown();
        });
        try {
            done.await(500, TimeUnit.MILLISECONDS);
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
    }

    // --- rendering (GL thread) -----------------------------------------------------------------------

    private void scheduleFrame() {
        if (!frameScheduled) {
            frameScheduled = true;
            Choreographer.getInstance().postFrameCallback(this);
        }
    }

    @Override
    public void doFrame(long frameTimeNanos) {
        frameScheduled = false;
        if (released || !running) return;
        if (lastFrameNanos != 0) {
            time = (time + (frameTimeNanos - lastFrameNanos) / 1e9) % TIME_WRAP;
        }
        lastFrameNanos = frameTimeNanos;
        // Vsync is 60 Hz; skip vsyncs to hit the target rate (2 ms slack for vsync jitter).
        if (frameTimeNanos - lastDrawNanos >= 1_000_000_000L / fps - 2_000_000L) {
            lastDrawNanos = frameTimeNanos;
            draw();
        }
        scheduleFrame();
    }

    private void drawOnce() {
        if (!running) draw();
    }

    private void draw() {
        if (eglSurface == EGL14.EGL_NO_SURFACE || program == 0) return;
        GLES30.glViewport(0, 0, width, height);
        GLES30.glUseProgram(program);
        GLES30.glUniform1f(timeLocation, (float) time);
        GLES30.glUniform2f(resolutionLocation, width, height);
        GLES30.glBindVertexArray(vertexArray);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
        if (!EGL14.eglSwapBuffers(display, eglSurface)) {
            int error = EGL14.eglGetError();
            Log.w(TAG, "eglSwapBuffers failed: 0x" + Integer.toHexString(error));
            if (error == EGL14.EGL_BAD_SURFACE || error == EGL14.EGL_BAD_NATIVE_WINDOW) {
                detachSurface();
            }
        }
    }

    private void initEgl() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        int[] version = new int[2];
        EGL14.eglInitialize(display, version, 0, version, 1);
        int[] attributes = {
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
                EGL14.EGL_NONE
        };
        EGLConfig[] configs = new EGLConfig[1];
        int[] count = new int[1];
        EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0);
        config = configs[0];
        context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT,
                new int[]{EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE}, 0);
        // A 1x1 pbuffer keeps the context current while there is no window surface.
        EGLSurface pbuffer = EGL14.eglCreatePbufferSurface(display, config,
                new int[]{EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE}, 0);
        EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context);
        EGL14.eglDestroySurface(display, pbuffer);  // freed once it is no longer current
        int[] vao = new int[1];
        GLES30.glGenVertexArrays(1, vao, 0);
        vertexArray = vao[0];
    }

    private void attachSurface(Surface next) {
        if (next == surface && eglSurface != EGL14.EGL_NO_SURFACE) return;
        detachSurface();
        if (next == null || !next.isValid()) return;
        surface = next;
        eglSurface = EGL14.eglCreateWindowSurface(display, config, surface, new int[]{EGL14.EGL_NONE}, 0);
        if (eglSurface == EGL14.EGL_NO_SURFACE) {
            Log.w(TAG, "eglCreateWindowSurface failed: 0x" + Integer.toHexString(EGL14.eglGetError()));
            return;
        }
        EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context);
        // Pacing is done by the Choreographer; never block in eglSwapBuffers.
        EGL14.eglSwapInterval(display, 0);
    }

    private void detachSurface() {
        if (eglSurface != EGL14.EGL_NO_SURFACE) {
            EGLSurface pbuffer = EGL14.eglCreatePbufferSurface(display, config,
                    new int[]{EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE}, 0);
            EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context);
            EGL14.eglDestroySurface(display, pbuffer);
            EGL14.eglDestroySurface(display, eglSurface);
            eglSurface = EGL14.EGL_NO_SURFACE;
        }
        surface = null;
    }

    private void loadProgram() {
        String source;
        try {
            source = readAsset("shaders/" + shader + ".frag");
        } catch (IOException e) {
            Log.w(TAG, "missing shader " + shader, e);
            return;
        }
        int vertex = compile(GLES30.GL_VERTEX_SHADER, VERTEX_SHADER);
        int fragment = compile(GLES30.GL_FRAGMENT_SHADER, FRAGMENT_PREAMBLE + source);
        if (vertex == 0 || fragment == 0) {
            GLES30.glDeleteShader(vertex);
            GLES30.glDeleteShader(fragment);
            return;
        }
        int next = GLES30.glCreateProgram();
        GLES30.glAttachShader(next, vertex);
        GLES30.glAttachShader(next, fragment);
        GLES30.glLinkProgram(next);
        GLES30.glDeleteShader(vertex);
        GLES30.glDeleteShader(fragment);
        int[] status = new int[1];
        GLES30.glGetProgramiv(next, GLES30.GL_LINK_STATUS, status, 0);
        if (status[0] == 0) {
            Log.w(TAG, "link " + shader + ": " + GLES30.glGetProgramInfoLog(next));
            GLES30.glDeleteProgram(next);
            return;
        }
        if (program != 0) GLES30.glDeleteProgram(program);
        program = next;
        timeLocation = GLES30.glGetUniformLocation(program, "u_time");
        resolutionLocation = GLES30.glGetUniformLocation(program, "u_res");
    }

    private int compile(int type, String source) {
        int id = GLES30.glCreateShader(type);
        GLES30.glShaderSource(id, source);
        GLES30.glCompileShader(id);
        int[] status = new int[1];
        GLES30.glGetShaderiv(id, GLES30.GL_COMPILE_STATUS, status, 0);
        if (status[0] == 0) {
            Log.w(TAG, "compile " + shader + ": " + GLES30.glGetShaderInfoLog(id));
            GLES30.glDeleteShader(id);
            return 0;
        }
        return id;
    }

    private String readAsset(String path) throws IOException {
        try (InputStream in = assets.open(path)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int n;
            while ((n = in.read(buffer)) > 0) out.write(buffer, 0, n);
            return out.toString(StandardCharsets.UTF_8.name());
        }
    }

    private void destroyGl() {
        if (display == EGL14.EGL_NO_DISPLAY) return;
        detachSurface();
        if (program != 0) GLES30.glDeleteProgram(program);
        if (vertexArray != 0) GLES30.glDeleteVertexArrays(1, new int[]{vertexArray}, 0);
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
        EGL14.eglDestroyContext(display, context);
        EGL14.eglReleaseThread();
        display = EGL14.EGL_NO_DISPLAY;
        context = EGL14.EGL_NO_CONTEXT;
        program = 0;
        vertexArray = 0;
    }
}
