# YoRHa shell layer. Sourced from ~/.zshrc as the last line.
# Disable everything here by commenting out that one line.

source "$HOME/.config/yorha/palette.sh"

# Banner is ON. It was briefly disabled for slow startup, but measurement showed
# this whole layer costs 0.05-0.12s while the pre-existing Herd/NVM/gcloud/Antigravity
# setup costs 0.88-1.80s on its own. The banner was never the problem.
# Set YORHA_MOTD=0 in your environment to silence it.
: ${YORHA_MOTD:=1}

yorha_boot() {
  local dim=$'\e[38;5;242m' amber=$'\e[38;5;179m' reset=$'\e[0m'
  print -P ""
  print -P "  ${dim}/////////${reset}  BOOT SEQUENCE COMPLETE"
  print -P "  ${dim}/////////${reset}  YoRHa Shell — Ver. 1.0"
  print -P "  ${dim}/////////${reset}  ${amber}HOST${reset} $(sw_vers -productVersion)  ${amber}SHELL${reset} zsh ${ZSH_VERSION}"
  print -P ""
}

# Only on interactive shells, only once per window, and only when stdout is a real
# terminal. Without the `-t 1` test, `zsh -ilc '<cmd>'` with redirected stdout gets the
# banner prepended — which corrupts the PATH/env harvesting that IDEs and GUI apps do.
if [[ -o interactive && -t 1 && "$YORHA_MOTD" == "1" && -z "$YORHA_BOOTED" ]]; then
  export YORHA_BOOTED=1
  yorha_boot
fi

export STARSHIP_CONFIG="$HOME/.config/yorha/starship.toml"
command -v starship >/dev/null && eval "$(starship init zsh)"

alias yorha-fetch='yorha_boot; fastfetch --config ~/.config/yorha/fastfetch.jsonc'
alias yorha-restore='bash "$(cat ~/.config/yorha/BACKUP_PATH)/restore.sh"'
