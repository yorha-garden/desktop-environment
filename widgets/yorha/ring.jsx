// Live reticle over the wallpaper's targeting array.
// Styling follows the al.is-a.dev fiducial-marker language: frame square,
// double-line corner brackets, cardinal dots, fine rings.
//
// PERFORMANCE NOTE — why each rotating ring is its own <div> wrapping its own <svg>:
// rotating SVG *children* (a <g> inside one svg) goes through WebKit's legacy
// non-composited SVG path, re-rasterizing the ring geometry on the CPU every frame.
// Rotating an HTML element instead promotes it to a composited layer, so the GPU
// does the transform and the CPU stays idle. Same visuals, measurably cheaper.
//
// The command export is required even though its output is unused: Übersicht creates
// the refresh timer only for widgets WITH a command, so without it refreshFrequency
// is never read and the widget renders exactly once. The hourly re-render re-reads
// window dimensions so display changes self-heal.
export const refreshFrequency = 3600000;
export const command = "true";

export const className = `
  left: 0; top: 0; width: 100%; height: 100%;
  pointer-events: none;
`;

const WALL_W = 5120, WALL_H = 2880, ARR_X = 3440, ARR_Y = 1260;
let entered = false;

export const render = () => {
  const W = window.innerWidth, H = window.innerHeight;
  const s = Math.max(W / WALL_W, H / WALL_H);          // scale-to-fill
  const cx = ARR_X * s - (WALL_W * s - W) / 2;          // crop is centred
  const cy = ARR_Y * s - (WALL_H * s - H) / 2;

  const R  = 830 * s;        // instrument ring, outside the outermost painted ring
  const R2 = 290 * s;        // inner ring, in the clear band of the painted array
  const F  = 900 * s;        // fiducial frame half-size
  const B  = 34 * s * 2;     // bracket square size
  const size = (F + B) * 2 + 8;
  const c = size / 2;
  const haloR = 70 * s;

  const enterCls = entered ? "" : " ring-enter";
  entered = true;

  const bracket = (x, y) => (
    <g key={x + "," + y} transform={"translate(" + x + "," + y + ")"}>
      <rect x={-B / 2} y={-B / 2} width={B} height={B}
            fill="none" stroke="#4A4741" strokeOpacity="0.5" strokeWidth="1.5" />
      <rect x={-B / 2 - 5} y={-B / 2 - 5} width={B + 10} height={B + 10}
            fill="none" stroke="#4A4741" strokeOpacity="0.28" strokeWidth="0.75" />
    </g>
  );

  // each rotating layer: full-size absolutely-positioned div holding one svg
  const layer = (cls, children) => (
    <div className={cls} style={{ position: "absolute", left: 0, top: 0, width: size, height: size }}>
      <svg width={size} height={size} viewBox={"0 0 " + size + " " + size}>{children}</svg>
    </div>
  );

  return (
    <div className={"wrap" + enterCls} style={{ left: cx - c, top: cy - c, width: size, height: size }}>
      <style>{`
        .wrap { position: absolute; }
        .ring-enter { opacity: 0; animation: ringIn .9s cubic-bezier(.34,1.56,.64,1) both .45s; }
        @keyframes ringIn {
          from { opacity: 0; transform: scale(.92); }
          60%  { opacity: 1; transform: scale(1.03); }
          to   { opacity: 1; transform: scale(1); }
        }
        /* composited layers — transform on the element, not on svg children */
        .rot-a { animation: spinA 90s linear infinite; will-change: transform; }
        .rot-b { animation: spinB 140s linear infinite; will-change: transform; }
        @keyframes spinA { from { transform: rotate(0deg); }   to { transform: rotate(360deg); } }
        @keyframes spinB { from { transform: rotate(360deg); } to { transform: rotate(0deg); } }
        .ring-halo { position: absolute; border: 1.5px solid #BB3B36; border-radius: 50%;
                     animation: haloPulse 4s ease-in-out infinite alternate; }
        @keyframes haloPulse { from { opacity: .22; } to { opacity: .55; } }
        @media (prefers-reduced-motion: reduce) {
          .rot-a, .rot-b, .ring-halo { animation: none; }
          .ring-halo { opacity: .35; }
        }
      `}</style>

      {/* static fiducial frame */}
      <svg width={size} height={size} viewBox={"0 0 " + size + " " + size}
           style={{ position: "absolute", left: 0, top: 0 }}>
        <rect x={c - F} y={c - F} width={F * 2} height={F * 2}
              fill="none" stroke="#4A4741" strokeOpacity="0.14" strokeWidth="1" />
        {bracket(c - F, c - F)}{bracket(c + F, c - F)}
        {bracket(c - F, c + F)}{bracket(c + F, c + F)}
        <rect x={c - 3} y={c - F - 3} width="6" height="6" fill="#4A4741" fillOpacity="0.45" />
        <rect x={c - 3} y={c + F - 3} width="6" height="6" fill="#4A4741" fillOpacity="0.45" />
        <rect x={c - F - 3} y={c - 3} width="6" height="6" fill="#4A4741" fillOpacity="0.45" />
        <rect x={c + F - 3} y={c - 3} width="6" height="6" fill="#4A4741" fillOpacity="0.45" />
      </svg>

      {/* rotating instrument ring + its amber marker */}
      {layer("rot-a", [
        <circle key="a1" cx={c} cy={c} r={R} fill="none" stroke="#4A4741" strokeOpacity="0.35"
                strokeWidth="2" strokeDasharray="3 26" />,
        <circle key="a2" cx={c} cy={c} r={R} fill="none" stroke="#BC9A5A" strokeOpacity="0.8"
                strokeWidth="3" pathLength="100" strokeDasharray="4 96" />,
      ])}

      {/* counter-rotating inner ring */}
      {layer("rot-b", [
        <circle key="b1" cx={c} cy={c} r={R2} fill="none" stroke="#4A4741" strokeOpacity="0.3"
                strokeWidth="1" strokeDasharray="1 14" />,
        <circle key="b2" cx={c} cy={c} r={R2} fill="none" stroke="#4A4741" strokeOpacity="0.4"
                strokeWidth="2" pathLength="100" strokeDasharray="10 90" />,
      ])}

      <div className="ring-halo"
           style={{ left: c - haloR, top: c - haloR, width: haloR * 2, height: haloR * 2 }} />
    </div>
  );
};
