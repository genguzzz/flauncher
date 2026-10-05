// FLauncher "mesh": an animated mesh gradient in the style of the iOS / macOS "Hello" wallpapers —
// a few soft colour points drifting on slow orbits, blended by inverse-distance weights over a
// gently warped plane. Original code. Cheap: 5 points, no noise.
// @height 540   (render height in pixels, scaled up to the screen)
// @fps 30

float dither(vec2 p)
{
    p = fract(p * vec2(443.897, 441.423));
    p += dot(p, p.yx + 19.19);
    return fract((p.x + p.y) * p.x) - 0.5;
}

void main()
{
    vec2 uv = qt_TexCoord0;
    float asp = u_res.x / max(u_res.y, 1.0);
    vec2 p = vec2((uv.x - 0.5) * asp, uv.y - 0.5);
    float t = u_time * 0.10;

    // A slow, large-scale swirl so the colour fields bend instead of sliding as circles.
    p += 0.10 * vec2(sin(p.y * 2.3 + t * 1.3), sin(p.x * 2.1 - t * 1.1));

    vec2 pts[5];
    pts[0] = vec2(-0.55 * asp, 0.30) + 0.22 * vec2(sin(t * 0.71), cos(t * 0.53));
    pts[1] = vec2( 0.45 * asp, 0.35) + 0.20 * vec2(cos(t * 0.62 + 1.0), sin(t * 0.47 + 2.0));
    pts[2] = vec2( 0.05 * asp, -0.05) + 0.25 * vec2(sin(t * 0.43 + 3.0), cos(t * 0.67 + 1.0));
    pts[3] = vec2(-0.40 * asp, -0.40) + 0.20 * vec2(cos(t * 0.57 + 4.0), sin(t * 0.39));
    pts[4] = vec2( 0.50 * asp, -0.38) + 0.22 * vec2(sin(t * 0.49 + 5.0), cos(t * 0.73 + 3.0));

    vec3 cols[5];
    cols[0] = vec3(0.36, 0.20, 0.80);   // indigo
    cols[1] = vec3(0.95, 0.42, 0.30);   // coral
    cols[2] = vec3(0.86, 0.22, 0.55);   // magenta
    cols[3] = vec3(0.10, 0.45, 0.85);   // blue
    cols[4] = vec3(0.98, 0.70, 0.30);   // amber

    vec3 sum = vec3(0.0);
    float wsum = 0.0;
    for (int i = 0; i < 5; i++) {
        vec2 d = p - pts[i];
        float w = 1.0 / (dot(d, d) * dot(d, d) + 0.004);   // ~1/r^4: wide soft regions, smooth seams
        sum += cols[i] * w;
        wsum += w;
    }
    vec3 color = sum / wsum;

    // Dim for legibility of the launcher, with a soft vignette.
    color *= 0.60;
    color *= 1.0 - 0.30 * smoothstep(0.5, 1.3, length(p * vec2(0.9, 1.6)));
    color += dither(gl_FragCoord.xy) / 255.0;
    fragColor = vec4(color, 1.0);
}
