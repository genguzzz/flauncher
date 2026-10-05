// FLauncher "ribbons": deep indigo sky with slow blue / violet aurora ribbons and soft bokeh,
// in the palette of the default picture wallpaper. Cheap: no noise, 8 sines, no exp / pow.
// @height 432   (render height in pixels, scaled up to the screen)
// @fps 30

float band(vec2 p, float y0, float amp, float freq, float speed, float phase, float width, float t)
{
    float y = y0
            + amp * sin(p.x * freq + t * speed + phase)
            + amp * 0.45 * sin(p.x * freq * 2.13 - t * speed * 1.37 + phase * 1.9);
    float d = p.y - y;
    // Sharp lower edge, long soft glow above it — the curtain shape of an aurora. Rational
    // falloffs instead of exp(): same shape, a reciprocal instead of an exponential.
    float a = max(d, 0.0) / (width * 3.2);
    float b = min(d, 0.0) / (width * 0.42);
    return 1.0 / ((1.0 + a + 0.5 * a * a) * (1.0 + b * b));
}

float bokeh(vec2 p, vec2 c, float r)
{
    vec2 d = p - c;
    return smoothstep(r * r, r * r * 0.3, dot(d, d));   // squared distance: no sqrt
}

void main()
{
    vec2 uv = qt_TexCoord0;
    vec2 p = uv * 2.0 - 1.0;
    float asp = u_res.x / max(u_res.y, 1.0);
    p.x *= asp;
    float t = u_time;

    // Sky: navy at the top-right, indigo-black at the bottom.
    vec3 color = mix(vec3(0.004, 0.008, 0.035), vec3(0.020, 0.040, 0.140), uv.y * 0.8 + 0.2 * (1.0 - uv.x));

    // Diagonal ribbons (tilted with the picture wallpaper's main streak).
    vec2 q = vec2(p.x * 0.92 + p.y * 0.38, p.y * 0.92 - p.x * 0.38);
    float b1 = band(q, 0.10, 0.16, 1.15, 0.090, 0.0, 0.050, t);
    float b2 = band(q, -0.22, 0.12, 1.55, -0.070, 2.1, 0.035, t);
    float b3 = band(q, 0.42, 0.10, 2.05, 0.055, 4.2, 0.030, t);

    // Hue drifts along each ribbon: cyan -> blue -> violet.
    float h1 = 0.5 + 0.5 * sin(q.x * 1.3 + t * 0.05);
    float h2 = 0.5 + 0.5 * sin(q.x * 1.7 - t * 0.04 + 1.5);
    vec3 cyan = vec3(0.10, 0.62, 1.00);
    vec3 blue = vec3(0.12, 0.28, 0.95);
    vec3 violet = vec3(0.48, 0.22, 0.95);
    color += mix(cyan, blue, h1) * b1 * 0.55;
    color += mix(blue, violet, h2) * b2 * 0.45;
    color += mix(violet, cyan, h1) * b3 * 0.22;

    // Hot core where the main ribbon is brightest.
    float b1c = b1 * b1 * b1;
    color += vec3(0.55, 0.85, 1.0) * (b1c * b1c) * 0.30;

    // Slowly drifting bokeh discs.
    vec2 c1 = vec2(-0.85 * asp, 0.55) + 0.08 * vec2(sin(t * 0.031), cos(t * 0.027));
    vec2 c2 = vec2(-0.20 * asp, 0.62) + 0.06 * vec2(cos(t * 0.023), sin(t * 0.035));
    vec2 c3 = vec2(0.80 * asp, -0.10) + 0.07 * vec2(sin(t * 0.019 + 1.0), cos(t * 0.029));
    vec2 c4 = vec2(-0.55 * asp, 0.25) + 0.05 * vec2(cos(t * 0.037), sin(t * 0.021));
    color += vec3(0.10, 0.20, 0.70) * bokeh(p, c1, 0.10) * 0.22;
    color += vec3(0.10, 0.22, 0.75) * bokeh(p, c2, 0.08) * 0.20;
    color += vec3(0.35, 0.25, 0.85) * bokeh(p, c3, 0.12) * 0.16;
    color += vec3(0.10, 0.25, 0.80) * bokeh(p, c4, 0.07) * 0.18;

    // Vignette toward the bottom and the corners.
    float vignette = 1.0 - smoothstep(0.55, 1.45, length((uv - vec2(0.45, 0.55)) * vec2(1.6, 1.9)));
    color *= mix(0.45, 1.0, vignette);

    fragColor = vec4(max(color, vec3(0.0)), 1.0);
}
