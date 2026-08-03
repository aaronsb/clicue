# Minimal interactive zsh: compsys on, no styles. The friendliest possible
# host — scenarios that pass ONLY here are not verified against real configs.
PS1='%% '
HISTSIZE=1000
SAVEHIST=0   # never write history at exit — it races the harness teardown
autoload -Uz compinit && compinit -u -d "$HOME/.zcompdump"
eval "$(clicue init zsh)"
