// YoRHa CRT — original work. Shadertoy convention: iChannel0 is the terminal.
// Raise values slowly; anything above ~0.25 scanline starts eating small text.

const float SCANLINE      = 0.22; // darkness of the scanline bands
const float SCAN_PERIOD   = 6.0;  // physical px per scanline cycle (2 dark rows per cycle)
const float GLOW          = 0.020;// phosphor lift on lit rows — bands need this to read on near-black
const float SWEEP         = 0.035;// brightness of the travelling scan beam; set 0.0 to disable
const float SWEEP_SECONDS = 7.0;  // seconds for the beam to cross the screen
const float CURVE         = 0.020;// barrel distortion
const float ABERRATION_PX = 0.6;  // rgb split at the tube edge, in PHYSICAL PIXELS
const float VIGNETTE      = 0.22; // corner falloff
const float FLICKER       = 0.010;// subtle refresh shimmer

// Scanline visibility on a dark theme is not free. The background is RGB(22,22,26);
// darkening it 10% moves it ~2/255 — invisible — and a 1-physical-px stripe is half a
// logical pixel on a 2x panel. Hence: 6px cycle, 22% depth, plus a +5/255 glow on lit
// rows so the bands modulate ~10/255 of real contrast.

// ABERRATION_PX is in pixels ON PURPOSE. The previous version expressed the split in
// UV units and then multiplied by 40, which on a Retina panel worked out to ~36px per
// channel — red one way, blue the other, so ~70px of total split. Text came out
// tripled and unreadable. Anything above ~1.5 here starts to look like a fault rather
// than a CRT.

vec2 curve(vec2 uv) {
    uv = uv * 2.0 - 1.0;
    vec2 offset = abs(uv.yx) / vec2(6.0, 5.0);
    uv += uv * offset * offset * CURVE * 12.0;
    return uv * 0.5 + 0.5;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 cuv = curve(uv);

    // outside the tube after curvature -> hard black, no smeared edges
    if (cuv.x < 0.0 || cuv.x > 1.0 || cuv.y < 0.0 || cuv.y > 1.0) {
        // Match the window's own alpha rather than forcing opaque black, or the
        // curved corners punch solid rectangles through a transparent window.
        fragColor = vec4(0.0, 0.0, 0.0, texture(iChannel0, clamp(cuv, 0.0, 1.0)).a);
        return;
    }

    // CRT power-on: the first 0.7s after this surface is created, the picture
    // expands vertically from a bright horizontal line, like a tube warming up.
    // iTime is per-surface, so each new terminal window replays it once.
    float on = clamp(iTime / 0.7, 0.0, 1.0);
    float bloom = 1.0;
    if (on < 1.0) {
        float squeeze = max(on * on, 0.004);
        float dy = (cuv.y - 0.5) / squeeze;
        if (abs(dy) > 0.5) {
            fragColor = vec4(0.0, 0.0, 0.0, texture(iChannel0, clamp(cuv, 0.0, 1.0)).a);
            return;
        }
        cuv.y = 0.5 + dy;
        bloom = 1.0 + (1.0 - on) * 2.2;   // hot line early, settles to 1.0
    }

    // Chromatic aberration, strongest at the edges, zero dead centre.
    // Dividing by iResolution.x converts pixels -> uv, so the split stays the same
    // apparent size on any display instead of scaling with resolution.
    float edge = length(cuv - 0.5);          // 0.0 centre .. ~0.707 corners
    vec2 shift = vec2(ABERRATION_PX * edge / iResolution.x, 0.0);
    vec4 col;
    col.r = texture(iChannel0, cuv + shift).r;
    col.g = texture(iChannel0, cuv).g;
    col.b = texture(iChannel0, cuv - shift).b;
    // Carry the terminal's alpha through. Hardcoding 1.0 discards it and silently
    // cancels background-opacity = 0.94 and background-blur = 20.
    col.a = texture(iChannel0, cuv).a;

    // Scanlines, driven by the integer device row.
    // Do NOT use sin(row * PI) here: fragments are shaded at pixel CENTRES (n + 0.5),
    // where sin(PI*(n+0.5)) is always +/-1, so sin^2 is a constant 1.0 and the pattern
    // silently collapses into a flat uniform dim.
    float row  = floor(cuv.y * iResolution.y);
    float line = step(mod(row, SCAN_PERIOD), 1.5);   // first 2 rows of each cycle are dark
    col.rgb += GLOW * (1.0 - line) * vec3(0.85, 0.87, 0.80);  // phosphor lift on lit rows
    col.rgb *= 1.0 - SCANLINE * line;

    // Wrapped time for the periodic effects. iTime is a raw float32 seconds-since-
    // surface-creation; after ~a day its ulp exceeds a frame time and the beam
    // visibly stutters, and after a week it freezes for frames at a stretch.
    // 630 = 90 × SWEEP_SECONDS, so the sweep phase is continuous at the wrap.
    // (Power-on above deliberately uses RAW iTime — wrapping would replay it.)
    float t = mod(iTime, 630.0);

    // Travelling scan beam — the slow horizontal band sweeping down the screen,
    // Needs custom-shader-animation = true (it is).
    // smoothstep with reversed edges is undefined per the GLSL spec (§8.3);
    // the 1.0-minus form is the well-defined equivalent.
    float sweepPos = fract(t / SWEEP_SECONDS);
    float beam = 1.0 - smoothstep(0.0, 0.035, abs((1.0 - cuv.y) - sweepPos));
    col.rgb += SWEEP * beam * vec3(0.90, 0.90, 0.85);

    // vignette
    col.rgb *= 1.0 - VIGNETTE * edge * edge * 2.0;

    // slow flicker
    col.rgb *= 1.0 + FLICKER * sin(t * 18.0);

    // power-on bloom (1.0 after the first 0.7s)
    col.rgb *= bloom;

    fragColor = col;
}
