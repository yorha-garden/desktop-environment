// Pod 042 — support unit message panel, bottom-right.
//
// Message source, in priority order:
//   1. Gemini (gemini-3.1-flash-lite) via bin/pod-oracle.py, which runs on a
//      launchd timer every 5 minutes and writes a cache. The widget only ever
//      READS that cache — it never touches the network, so a slow or failed API
//      call can never stall the desktop.
//   2. Built-in static reports, byte-identical to the pre-Gemini behaviour,
//      used whenever the cache is missing, unparseable, or stale (> 20 min).
//      Stale means "offline or the API is failing", which is exactly the
//      fallback condition that was asked for.
//
// Overflow: the panel fits ~38 characters. Longer lines ping-pong (marquee
// left, dwell, marquee back) instead of being silently clipped. Two of the
// static reports below have ALWAYS overflowed and were being cut off unseen.
export const refreshFrequency = 45000;

// Line 1 = telemetry, line 2 = the oracle cache (or empty). Two lines keeps the
// message text free of any delimiter collision.
export const command = `
DISK=$(df -h / | awk 'NR==2 {print $4}')
MEM=$(memory_pressure | awk '/percentage/ {print 100-$5}' | tr -d '%')
PM=$(pmset -g batt)
BATT=$(echo "$PM" | grep -Eo '[0-9]+%' | head -1 | tr -d '%')
CHRG=$(echo "$PM" | grep -c 'AC Power')
echo "$DISK|$MEM|$BATT|$CHRG"
cat "$HOME/.config/yorha/cache/pod-oracle.json" 2>/dev/null || echo ""
`;

export const className = `
  bottom: 28px; right: 30px;
  pointer-events: none;
  font-family: 'Cascadia Code', monospace;
  color: var(--yorha-text, #4A4741);
  transition: color 200ms ease;
`;

// MEASURED in the live renderer, not derived. The panel is content-box, so its
// 300px width is the text area and the 15px padding sits outside it — deriving
// 270px from "300 minus padding" was wrong and over-scrolled the marquee by 40px.
// Cascadia's real advance at 11px + .03em tracking measured 6.78px (427px / 63 chars).
const PANEL_CONTENT_PX = 300;
const CHAR_PX = 6.78;
const STALE_AFTER = 20 * 60;    // seconds; ~4 missed oracle runs

let cycle = 0;

export const render = ({ output }) => {
  if (!output || !output.trim()) return <div />;

  const lines = output.split("\n");
  const [disk, mem, batt, chrg] = (lines[0] || "").trim().split("|");
  const rest = lines.slice(1).join("\n").trim();

  // built-in fallback — unchanged from the pre-Gemini widget
  const staticReports = [
    "Proposal: system nominal. Continue operation.",
    "Disk reserve: " + disk + " available.",
    Number(mem) >= 80
      ? "Warning: memory pressure " + mem + "%. Exceeds tolerance."
      : "Memory pressure " + mem + "%. Within tolerance.",
    chrg === "1"
      ? "Power reserve " + batt + "%. External supply connected."
      : "Power reserve " + batt + "%.",
    "Maintenance cycle complete. No anomalies detected.",
    "Analysis: operator condition stable. Recommendation: hydrate.",
  ];

  let reports = staticReports;
  let live = false;
  if (rest) {
    try {
      const j = JSON.parse(rest);
      const age = Math.floor(Date.now() / 1000) - (j.generated || 0);
      if (Array.isArray(j.messages) && j.messages.length && age < STALE_AFTER) {
        reports = j.messages;
        live = true;
      }
    } catch (e) { /* malformed cache -> static, silently */ }
  }

  const msg = reports[cycle % reports.length];
  cycle += 1;

  // marquee only when the line genuinely overflows
  const overshoot = Math.ceil(msg.length * CHAR_PX - PANEL_CONTENT_PX);
  const scrolls = overshoot > 0;
  const dur = scrolls ? (3.2 + overshoot / 26).toFixed(1) : 0;
  const kf = "marq" + Math.abs(overshoot);

  return (
    <div className="pod pod-enter">
      <style>{`
        .pod { width: 300px; border: 1px solid var(--yorha-ornament, #4A4741);
               background: var(--yorha-panel, rgba(214,210,193,.5)); padding: 13px 15px; position: relative;
               transition: background 200ms ease, border 200ms ease; }
        .pod::before, .pod::after { content: ''; position: absolute; width: 8px; height: 8px;
               border: 1px solid var(--yorha-ornament, #4A4741); transition: border 200ms ease; }
        .pod::before { top: -1px; left: -1px; border-right: 0; border-bottom: 0; }
        .pod::after  { bottom: -1px; right: -1px; border-left: 0; border-top: 0; }
        .pod-hd { font-size: 8px; letter-spacing: .3em; text-transform: uppercase;
                  opacity: .6; padding-bottom: 7px; margin-bottom: 8px;
                  border-bottom: 1px solid var(--yorha-ornament, #4A4741);
                  display: flex; justify-content: space-between; align-items: baseline; }
        .pod-src { font-size: 7px; letter-spacing: .18em; opacity: .55; }
        .pod-src.live { color: var(--yorha-accent, #BC9A5A); opacity: .9; transition: color 200ms ease; }
        /* wrapper clips; base state is fully revealed so a typewriter that never
           starts cannot leave the message invisible (that bug shipped once) */
        .pod-msg { font-size: 11px; line-height: 1.7; letter-spacing: .03em;
                   overflow: hidden; max-width: 100%;
                   animation: type 1.6s steps(44, end); }
        .pod-msg-inner { display: inline-block; white-space: nowrap; }
        .pod-msg::after { content: '▌'; opacity: 0; animation: blink 1.05s steps(1) 14; }
        @keyframes type { from { max-width: 0; } to { max-width: 100%; } }
        @keyframes blink { 50% { opacity: 0; } }
        @keyframes ${kf} {
          0%, 18%   { transform: translateX(0); }
          82%, 100% { transform: translateX(-${Math.max(overshoot, 0)}px); }
        }
        .pod-enter { opacity: 0; animation: podIn .6s cubic-bezier(.34,1.56,.64,1) both .85s; }
        @keyframes podIn {
          from { opacity: 0; transform: translateY(10px); }
          60%  { opacity: 1; transform: translateY(-2px); }
          to   { opacity: 1; transform: translateY(0); }
        }
        @media (prefers-reduced-motion: reduce) {
          .pod-msg, .pod-msg-inner, .pod-enter { animation: none !important; }
          .pod-enter { opacity: 1; }
        }
      `}</style>
      <div className="pod-hd">
        <span>Pod 042 — Support Unit</span>
        <span className={"pod-src" + (live ? " live" : "")}>{live ? "◂LINK" : "LOCAL"}</span>
      </div>
      {/* key forces a fresh node per message so the typewriter and marquee replay */}
      <div className="pod-msg" key={String(cycle)}>
        <span
          className="pod-msg-inner"
          style={scrolls
            ? { animation: `${kf} ${dur}s ease-in-out 2s infinite alternate` }
            : undefined}
        >
          {msg}
        </span>
      </div>
    </div>
  );
};
