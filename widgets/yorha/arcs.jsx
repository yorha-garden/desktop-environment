// Corner ornaments, ported from the user's own portfolio (al.is-a.dev,
// src/components/decoration/): CircleLine's two nested quarter-arcs plus
// ThreeLine's diagonal line trio, top-left and rotated 180° at bottom-right,
// composed exactly as the site's layout/ornament.tsx places them.
// Geometry is verbatim; the animation mirrors the Framer variants:
//   arcs entrance  — pathLength 0 -> 1, spring(1.5s, bounce 0), stagger 0.5s
//   arcs idle      — scale 1 <-> 1.1, 3s easeInOut, infinite reverse
//   lines entrance — same spring, stagger 0.2s/line
//   lines idle     — y 0 -> -10 -> 0 wave, 4s easeInOut, infinite, stagger 0.2s
//
// NAMESPACE EVERYTHING: Übersicht injects every widget's <style> into one
// shared document. A generic `.tl { top:0 }` here once overrode the HUD's
// `.tl { top:60px }` and yanked its left column to the screen edge.
//
// Perf/robustness rules this file inherits (see README gotchas):
// - breathing scales an HTML wrapper per arc, never SVG children (composited,
//   measured 0% CPU on the reticle; animated SVG children rasterize on CPU)
// - no command + refreshFrequency false -> renders exactly once, no timers
// - stroke-dashoffset entrance uses fill-mode backwards, but the BASE state is
//   the drawn arc, so a dropped animation fails visible, not blank
export const refreshFrequency = false;

export const className = `
  left: 0; top: 0; width: 100%; height: 100%;
  pointer-events: none; overflow: hidden;
  color: var(--yorha-ornament, #4A4741);
  transition: color 200ms ease;
`;

// verbatim from CircleLine (428x432 box); pathLength=100 normalizes the dash math
const P1 = "M427.112 0C436.64 210.577 247.658 431 .017 431";
const P2 = "M413.878 0C423.112 204.353 239.978 418.261 0 418.261";

// verbatim from ThreeLine (707x714 box): three parallel 45° diagonals
const LINES = [
  { x1: 0.353803, y1: -0.353303, x2: 707.354, y2: 707.647 },
  { x1: 34.3541,  y1: 86.647,    x2: 659.354, y2: 713.647 },
  { x1: 143.354,  y1: 86.6468,   x2: 707.354, y2: 651.647 },
];

const arc = (d, cls) => (
  <div className={"arc-breathe " + cls} style={{ position: "absolute", left: 0, top: 0, width: 428, height: 432 }}>
    <svg width="428" height="432" viewBox="0 0 428 432" fill="none" style={{ overflow: "visible" }}>
      <path d={d} pathLength="100" stroke="currentColor" strokeOpacity="0.3" strokeWidth="2"
            className={"arc-draw " + cls} />
    </svg>
  </div>
);

const threeLines = () => (
  <div style={{ position: "absolute", left: 0, top: 0, width: 707, height: 714 }}>
    {LINES.map((l, i) => (
      <div key={i} className={"arc-wave arc-w" + i}
           style={{ position: "absolute", left: 0, top: 0, width: 707, height: 714 }}>
        <svg width="707" height="714" viewBox="0 0 707 714" fill="none" style={{ overflow: "visible" }}>
          <line x1={l.x1} y1={l.y1} x2={l.x2} y2={l.y2} pathLength="100"
                stroke="currentColor" strokeOpacity="0.3" strokeWidth="2"
                className={"arc-draw arc-w" + i} />
        </svg>
      </div>
    ))}
  </div>
);

export const render = () => (
  <div>
    <style>{`
      .arc-corner { position: absolute; width: 428px; height: 432px; color: var(--yorha-ornament, #4A4741); transition: color 200ms ease; }
      .arc-tl { top: 0; left: 0; }
      .arc-br { bottom: 0; right: 0; transform: rotate(180deg); }

      /* breathing: composited transform on the wrapper, portfolio params
         (scale 1<->1.1, 3s ease-in-out, infinite reverse, 0.5s stagger) */
      .arc-breathe { transform-origin: center; animation: arcBreathe 3s ease-in-out infinite alternate; will-change: transform; }
      .arc-a0.arc-breathe { animation-delay: 0s; }
      .arc-a1.arc-breathe { animation-delay: .5s; }
      @keyframes arcBreathe { from { transform: scale(1); } to { transform: scale(1.1); } }

      /* draw-on: dashoffset 100 -> 0 approximating spring(1.5, bounce 0).
         Base state is the DRAWN arc; 'backwards' only covers the delay gap. */
      .arc-draw { stroke-dasharray: 100; animation: arcDraw 1.5s cubic-bezier(0.22, 1, 0.36, 1) backwards; }
      .arc-a0.arc-draw { animation-delay: 0s; }
      .arc-a1.arc-draw { animation-delay: .5s; }
      @keyframes arcDraw {
        from { stroke-dashoffset: 100; opacity: 0; }
        1%   { opacity: 1; }
        to   { stroke-dashoffset: 0; opacity: 1; }
      }

      /* ThreeLine's wave: y 0 -> -10 -> 0 over 4s, staggered 0.2s per line —
         translateY on composited wrappers, same rule as the breathing */
      .arc-wave { animation: arcWave 4s ease-in-out infinite; will-change: transform; }
      .arc-w0.arc-wave { animation-delay: 0s; }
      .arc-w1.arc-wave { animation-delay: .2s; }
      .arc-w2.arc-wave { animation-delay: .4s; }
      @keyframes arcWave {
        0%   { transform: translateY(0); }
        50%  { transform: translateY(-10px); }
        100% { transform: translateY(0); }
      }
      .arc-w0.arc-draw { animation-delay: 0s; }
      .arc-w1.arc-draw { animation-delay: .2s; }
      .arc-w2.arc-draw { animation-delay: .4s; }

      /* ThreeLine's corner offsets, from ornament.tsx: top-left at origin,
         bottom-right shifted -bottom-16 -right-24 (Tailwind: 64px, 96px) */
      .arc-lines-tl { position: absolute; top: 0; left: 0; width: 707px; height: 714px; color: var(--yorha-ornament, #4A4741); transition: color 200ms ease; }
      .arc-lines-br { position: absolute; bottom: -64px; right: -96px; width: 707px; height: 714px;
                      transform: rotate(180deg); color: var(--yorha-ornament, #4A4741); transition: color 200ms ease; }

      @media (prefers-reduced-motion: reduce) {
        .arc-breathe { animation: none; }
        .arc-draw { animation: none; }
        .arc-wave { animation: none; }
      }
    `}</style>
    <div className="arc-lines-tl">{threeLines()}</div>
    <div className="arc-lines-br">{threeLines()}</div>
    <div className="arc-corner arc-tl">
      {arc(P1, "arc-a0")}
      {arc(P2, "arc-a1")}
    </div>
    <div className="arc-corner arc-br">
      {arc(P1, "arc-a0")}
      {arc(P2, "arc-a1")}
    </div>
  </div>
);
