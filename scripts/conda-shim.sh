# Sourced from ~/.bash_profile on the Deck.
#
# Positron starts a conda-based R by running `conda activate <env>` in a login
# shell. SteamOS has no conda, so `conda` here forwards to micromamba's shell
# hook, which does a real activation.

export MAMBA_ROOT_PREFIX="$HOME/micromamba"

if [[ -x "$HOME/.local/bin/micromamba" ]] && ! command -v conda >/dev/null 2>&1; then
  eval "$("$HOME/.local/bin/micromamba" shell hook -s bash)"
  conda() { micromamba "$@"; }
fi
