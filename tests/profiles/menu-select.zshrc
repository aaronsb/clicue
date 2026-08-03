# The configuration class that hid a real bug: `menu select` makes
# _main_complete recompute compstate AFTER the capture widget's suppression,
# so a capture that is silent under plain.zshrc can insert the first
# candidate and open the interactive listing here [MEASURED: 'ffmpeg -' +
# Tab leaked the full compsys menu over the card]. Every capture-adjacent
# scenario must pass under THIS profile, not only plain.
PS1='%% '
autoload -Uz compinit && compinit -u -d "$HOME/.zcompdump"
zstyle ':completion:*' menu select=1
zstyle ':completion:*' list-prompt %SAt %p: Hit TAB for more, or the character to insert%s
eval "$(clicue init zsh)"
