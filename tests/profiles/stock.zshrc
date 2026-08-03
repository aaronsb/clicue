# A stock zshrc: the fresh-macOS / new-user shape. No compinit, no plugin
# manager, no clicue line — the install-stock scenario runs `clicue
# install` against THIS and reloads. Nothing may be added here; the
# installer must supply everything it needs.
PS1='%% '
HISTSIZE=1000
SAVEHIST=0   # never write history at exit — it races the harness teardown
export PATH="$HOME/bin:$PATH"
alias ll='ls -alF'
