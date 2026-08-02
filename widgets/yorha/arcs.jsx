// Corner arc pairs, ported from the user's own portfolio (al.is-a.dev,
// src/components/decoration/circle-line.tsx): two nested quarter-arcs at the
// top-left, a 180°-rotated pair at the bottom-right. The path data is verbatim
// from CircleLine; the animation mirrors its Framer variants:
//   entrance — pathLength 0 -> 1, spring(1.5s, bounce 0), staggered 0.5s/arc
//   idle     — scale 1 <-> 1.1, 3s easeInOut, infinite reverse, same stagger
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
`;

// verbatim from CircleLine (428x432 box); pathLength=100 normalizes the dash math
const P1 = "M427.112 0C436.64 210.577 247.658 431 .017 431";
const P2 = "M413.878 0C423.112 204.353 239.978 418.261 0 418.261";

const arc = (d, cls) => (
  <div className={"breathe " + cls} style={{ position: "absolute", left: 0, top: 0, width: 428, height: 432 }}>
    <svg width="428" height="432" viewBox="0 0 428 432" fill="none" style={{ overflow: "visible" }}>
      <path d={d} pathLength="100" stroke="#4A4741" strokeOpacity="0.3" strokeWidth="2"
            className={"draw " + cls} />
    </svg>
  </div>
);

export const render = () => (
  <div>
    <style>{`
      .corner { position: absolute; width: 428px; height: 432px; }
      .tl { top: 0; left: 0; }
      .br { bottom: 0; right: 0; transform: rotate(180deg); }

      /* breathing: composited transform on the wrapper, portfolio params
         (scale 1<->1.1, 3s ease-in-out, infinite reverse, 0.5s stagger) */
      .breathe { transform-origin: center; animation: breathe 3s ease-in-out infinite alternate; will-change: transform; }
      .a0.breathe { animation-delay: 0s; }
      .a1.breathe { animation-delay: .5s; }
      @keyframes breathe { from { transform: scale(1); } to { transform: scale(1.1); } }

      /* draw-on: dashoffset 100 -> 0 approximating spring(1.5, bounce 0).
         Base state is the DRAWN arc; 'backwards' only covers the delay gap. */
      .draw { stroke-dasharray: 100; animation: draw 1.5s cubic-bezier(0.22, 1, 0.36, 1) backwards; }
      .a0.draw { animation-delay: 0s; }
      .a1.draw { animation-delay: .5s; }
      @keyframes draw {
        from { stroke-dashoffset: 100; opacity: 0; }
        1%   { opacity: 1; }
        to   { stroke-dashoffset: 0; opacity: 1; }
      }

      @media (prefers-reduced-motion: reduce) {
        .breathe { animation: none; }
        .draw { animation: none; }
      }
    `}</style>
    <div className="corner tl">
      {arc(P1, "a0")}
      {arc(P2, "a1")}
    </div>
    <div className="corner br">
      {arc(P1, "a0")}
      {arc(P2, "a1")}
    </div>
  </div>
);
