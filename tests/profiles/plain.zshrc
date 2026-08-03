# Minimal interactive zsh: compsys on, no styles. The friendliest possible
# host — scenarios that pass ONLY here are not verified against real configs.
PS1='%% '
autoload -Uz compinit && compinit -u -d "$HOME/.zcompdump"
eval "$(clicue init zsh)"
