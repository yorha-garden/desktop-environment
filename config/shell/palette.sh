# ~/.config/yorha/palette.sh — single source of truth. No leading '#'.
export YORHA_BONE=CAC5B0
export YORHA_BONE_RAISED=D6D2C1
export YORHA_BONE_RECESSED=B5B09A
export YORHA_INK=4A4741
export YORHA_INK_MUTED=6E6B62
export YORHA_ALERT=BB3B36
export YORHA_AMBER=BC9A5A
export YORHA_VOID=16161A
export YORHA_VOID_TEXT=D8D4C4
export YORHA_BRIGHT=EFEBDB
export YORHA_STEEL=6E7B8B

# --- Extended tokens -------------------------------------------------------
# These were originally hardcoded straight into consumers, which defeats the point
# of this file. An audit caught them; they are declared here so every colour in the
# system has exactly one definition and one name.

# Recessed chrome sitting BEHIND the terminal surface: editor sidebar, activity bar,
# title bar. Deliberately darker than VOID so panels read as further back.
export YORHA_VOID_DEEP=131317

# Second-level dark surface used by the Starship prompt segments and Ghostty's
# ANSI slot 8. Between VOID and INK.
export YORHA_SURFACE=3A3A40

# Desaturated olive used for numeric literals and Ghostty ANSI slot 10. The only
# green in the system; kept muted so it never competes with AMBER.
export YORHA_OLIVE=A3A87E
