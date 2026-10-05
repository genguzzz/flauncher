// FLauncher "waves": stacked soft wave sheets with drop shadows, in the spirit of the macOS
// Big Sur / Monterey wallpapers. Original code (not Apple's artwork).
// Cost: the sheets are searched front to back and only the visible one is shaded, so a pixel
// evaluates ~half of the 7 edges (2 sines each) and one exp.
// @height 540   (render height in pixels, scaled up to the screen)
// @fps 20

const int LAYERS = 7;

float dither(vec2 p)
{
    p = fract(p * vec2(443.897, 441.423));
    p += dot(p, p.yx + 19.19);
    return fract((p.x + p.y) * p.x) - 0.5;
}

float edgeOf(int i, float x, float asp, float t)
{
    float fi = float(i);
    float k = fi / float(LAYERS - 1);
    float base = 0.88 - k * 0.80 + (x - 0.5 * asp) * (0.30 - 0.10 * k);
    return base
         + 0.060 * sin(x * (1.6 + 0.25 * fi) + t * (0.9 + 0.13 * fi) + fi * 1.7)
         + 0.030 * sin(x * (3.1 + 0.40 * fi) - t * (1.3 + 0.07 * fi) + fi * 0.6);
}

vec3 sheetColor(int i)
{
    float k = float(i) / float(LAYERS - 1);
    vec3 c0 = vec3(0.42, 0.24, 0.78);   // violet (back)
    vec3 c1 = vec3(0.86, 0.32, 0.62);   // magenta
    vec3 c2 = vec3(0.98, 0.52, 0.40);   // coral
    vec3 c3 = vec3(0.20, 0.22, 0.70);   // deep blue (front)
    return k < 0.33 ? mix(c0, c1, k / 0.33)
         : k < 0.66 ? mix(c1, c2, (k - 0.33) / 0.33)
         : mix(c2, c3, (k - 0.66) / 0.34);
}

void main()
{
    vec2 uv = qt_TexCoord0;
    float asp = u_res.x / max(u_res.y, 1.0);
    vec2 p = vec2(uv.x * asp, uv.y);
    float t = u_time * 0.12;
    float px = 1.0 / u_res.y;

    // Frontmost sheet covering this pixel (front = last layer), and the edge distance of the
    // sheet just in front of it (which casts the shadow).
    int j = -1;
    float dj = 0.0;
    float dFront = -1.0;
    for (int i = LAYERS - 1; i >= 0; i--) {
        float d = edgeOf(i, p.x, asp, t) - p.y;
        if (d > 0.0) { j = i; dj = d; break; }
        dFront = d;
    }

    vec3 color;
    if (j < 0) {
        color = mix(vec3(0.10, 0.06, 0.26), vec3(0.30, 0.16, 0.48), uv.y);   // sky
    } else {
        vec3 sheet = sheetColor(j);
        float lit = exp(-dj * 9.0);
        color = sheet * (0.62 + 0.38 * lit);
        color += vec3(1.0, 0.92, 0.95) * 0.18 * smoothstep(3.0 * px, 0.0, dj);   // thin rim light
        // Anti-aliased edge: fade toward the (shadowed) sheet behind over ~1.5 px.
        vec3 behind = j > 0 ? sheetColor(j - 1) * 0.50 : vec3(0.20, 0.11, 0.37);
        color = mix(behind, color, smoothstep(0.0, 1.5 * px, dj));
    }
    // Soft shadow of the sheet in front.
    color *= 1.0 - 0.35 * exp(dFront * 22.0);

    color *= 0.62;
    color *= 1.0 - 0.35 * smoothstep(0.6, 1.4, length((uv - vec2(0.55, 0.55)) * vec2(1.4, 1.8)));
    color += dither(gl_FragCoord.xy) / 255.0;
    fragColor = vec4(max(color, vec3(0.0)), 1.0);
}
