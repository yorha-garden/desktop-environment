export const refreshFrequency = false;
export const className = `left:0;top:0;width:0;height:0;pointer-events:none;`;
export const render = () => <style>{`
  :root {
    --yorha-field:#CAC5B0; --yorha-text:#4A4741; --yorha-value:#4A4741;
    --yorha-panel:rgba(214,210,193,.5); --yorha-ornament:#4A4741;
    --yorha-track:rgba(74,71,65,.18); --yorha-accent:#BC9A5A; --yorha-alert:#BB3B36;
  }
  @media (prefers-color-scheme: dark) { :root {
    --yorha-field:#16161A; --yorha-text:#D8D4C4; --yorha-value:#EFEBDB;
    --yorha-panel:rgba(58,58,64,.72); --yorha-ornament:#6E7B8B;
    --yorha-track:rgba(216,212,196,.18); --yorha-accent:#BC9A5A; --yorha-alert:#BB3B36;
  }}
`}</style>;
