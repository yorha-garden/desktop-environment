// Desktop scan beam — continuous sweep, as originally specified.
//
// This was briefly throttled to one pass per 180s on the belief that it was
// pinning WindowServer at ~40% of a core. A differential measurement (Übersicht
// running 43% vs killed 44%) disproved that: the compositor load is the machine's
// normal app mix, not this widget. Restored to the continuous sweep.
//
// refreshFrequency false = no command loop at all; the animation is pure CSS
// transform on a composited layer, so the GPU owns it and no JS ever runs.
export const refreshFrequency = false;

export const className = `
  left: 0; top: 0; width: 100%; height: 100%;
  pointer-events: none; overflow: hidden;
`;

export const render = () => (
  <div>
    <style>{`
      .beam { --yorha-beam-rgb:74,71,65; --yorha-beam-surface-rgb:214,210,193; color: var(--yorha-ornament, #4A4741); position: absolute; left: 0; right: 0; height: 14vh; top: 0;
              background: linear-gradient(to bottom,
                rgba(var(--yorha-beam-rgb),0) 0%,
                rgba(var(--yorha-beam-rgb),.05) 45%,
                rgba(var(--yorha-beam-surface-rgb),.07) 55%,
                rgba(var(--yorha-beam-rgb),0) 100%);
              animation: sweep 11s linear infinite;
              will-change: transform; transition: background 200ms ease; }
      @keyframes sweep {
        from { transform: translateY(-16vh); }
        to   { transform: translateY(102vh); }
      }
      @media (prefers-reduced-motion: reduce) { .beam { animation: none; opacity: 0; } }
      @media (prefers-color-scheme: dark) { .beam { --yorha-beam-rgb:110,123,139; --yorha-beam-surface-rgb:58,58,64; } }
    `}</style>
    <div className="beam" />
  </div>
);
