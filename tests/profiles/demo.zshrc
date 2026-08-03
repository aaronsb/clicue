# The recording shell: a friendly prompt, compsys on, clicue in.
PS1='%F{13}❯%f '
HISTSIZE=1000
SAVEHIST=0   # never write history at exit — it races the harness teardown
autoload -Uz compinit && compinit -u -d "$HOME/.zcompdump"
eval "$(clicue init zsh)"
