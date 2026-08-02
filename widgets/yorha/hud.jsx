// YoRHa HUD — corner telemetry with boot-in stagger, network and battery.
//
// Quoting note (hard-won): single-quoted awk programs may contain double quotes
// freely — the JS template literal passes them verbatim to the shell. Never
// backslash-escape quotes inside single-quoted awk; that corrupted the first
// version of this widget (awk received a literal backslash and died).
export const refreshFrequency = 10000;

export const command = `
CPU=$(ps -A -o %cpu | awk '{s+=$1} END {printf "%.0f", s/8}')
MEM=$(memory_pressure | awk '/percentage/ {print 100-$5}' | tr -d '%')
UP=$(uptime | awk -F'up ' '{print $2}' | sed -E 's/, *[0-9]+ users?,.*//')
PM=$(pmset -g batt)
BATT=$(echo "$PM" | grep -Eo '[0-9]+%' | head -1 | tr -d '%')
CHRG=$(echo "$PM" | grep -c 'AC Power')
NET=$(netstat -ib | awk -v OFS=/ '/en0.*Link/{i+=$7;o+=$10} END{print i,o}')
echo "$CPU|$MEM|$UP|$BATT|$CHRG|$NET"
`;

export const className = `
  left: 0; top: 0; width: 100%; height: 100%;
  pointer-events: none;
  font-family: 'Cascadia Code', monospace;
  color: #4A4741;
`;

// Module state survives between renders (Übersicht re-evaluates the module only
// when the file changes): previous byte counters for the network rate, and a
// flag so the entrance plays once per session instead of on every refresh.
let prev = null;
let booted = false;

const fmtRate = (bps) => {
  if (!isFinite(bps) || bps < 0) return "—";
  if (bps >= 1048576) return (bps / 1048576).toFixed(1) + " MB/S";
  return Math.round(bps / 1024) + " KB/S";
};

export const render = ({ output }) => {
  // Übersicht renders once with output:"" at mount, before the command has run.
  // Touching prev/booted on that render corrupts the first network rate and
  // consumes the entrance animation — bail out instead.
  if (!output || !output.trim()) return <div />;
  const parts = output.trim().split("|");
  const cpu  = parseInt(parts[0], 10) || 0;
  const mem  = parseInt(parts[1], 10) || 0;
  const up   = parts[2] || "—";
  const batt = parseInt(parts[3], 10);
  const chrg = parts[4] === "1";
  const [ib, ob] = (parts[5] || "0/0").split("/").map(Number);

  let rate = "—";
  if (prev && ib >= prev.ib && ob >= prev.ob) {
    rate = fmtRate((ib - prev.ib + ob - prev.ob) / 10);
  }
  prev = { ib, ob };

  // Latched: the class is applied from the first real render onward and never
  // removed — re-renders keep the same DOM node so the animation does not replay.
  booted = true;

  const memAlert  = mem >= 80;
  const battAlert = !isNaN(batt) && batt < 20 && !chrg;

  const box = (cls, delay) => ({
    className: "box " + cls + " hud-enter",
    style: { animationDelay: delay },
  });

  return (
    <div>
      <style>{`
        .box { position: absolute; }
        .tl { top: 60px; left: 30px; }
        .tr { top: 60px; right: 30px; text-align: right; }
        .bl { bottom: 28px; left: 30px; }
        .k { font-size: 8.5px; letter-spacing: .3em; text-transform: uppercase; opacity: .55; }
        .v { font-size: 19px; letter-spacing: .09em; margin-top: 2px; }
        .v small { font-size: 10px; opacity: .6; }
        .sub { margin-top: 14px; }
        .alert { color: #BB3B36; }
        .meter { width: 126px; height: 3px; background: rgba(74,71,65,.18); margin-top: 8px;
                 position: relative; overflow: hidden; }
        .tr .meter { margin-left: auto; }
        .meter i { position: absolute; top: 0; bottom: 0; left: 0; background: #4A4741;
                   transition: width .8s ease; }
        .meter i.alert { background: #BB3B36; }
        .hud-enter { opacity: 0; animation: bootIn .55s cubic-bezier(.34,1.56,.64,1) both; }
        @keyframes bootIn {
          from { opacity: 0; transform: translateY(9px); }
          60%  { opacity: 1; transform: translateY(-2px); }
          to   { opacity: 1; transform: translateY(0); }
        }
      `}</style>

      <div {...box("tl", ".1s")}>
        <div className="k">Processor load</div>
        <div className="v">{cpu}<small>%</small></div>
        <div className="meter"><i style={{ width: Math.min(cpu, 100) + "%" }} /></div>
        <div className="sub">
          <div className="k">Network</div>
          <div className="v" style={{ fontSize: 14 }}>{rate}</div>
        </div>
      </div>

      <div {...box("tr", ".35s")}>
        <div className="k">Memory pressure</div>
        <div className={"v" + (memAlert ? " alert" : "")}>{mem}<small>%</small></div>
        <div className="meter"><i className={memAlert ? "alert" : ""} style={{ width: Math.min(mem, 100) + "%" }} /></div>
        <div className="sub">
          <div className="k">Power reserve</div>
          <div className={"v" + (battAlert ? " alert" : "")} style={{ fontSize: 14 }}>
            {isNaN(batt) ? "—" : batt + "%"}{chrg ? " ◂AC" : ""}
          </div>
        </div>
      </div>

      <div {...box("bl", ".6s")}>
        <div className="k">Uptime</div>
        <div className="v" style={{ fontSize: 14 }}>{up}</div>
      </div>
    </div>
  );
};
