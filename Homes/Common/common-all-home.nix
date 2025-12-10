# Shared home-manager configuration for ALL users across all hosts
# User-specific settings should be in Homes/Common/<user>/home.nix
{ pkgs, ... }:
{
  # --- PACKAGES ---
  home.packages = builtins.attrValues {
    inherit (pkgs) opencode;
    inherit (pkgs.nerd-fonts) jetbrains-mono;
  };

  # --- OPENCODE ---
  xdg.configFile."opencode/opencode.json".text = ''
    {
      "$schema": "https://opencode.ai/config.json",
      "autoupdate": false,
      "share": "manual",
      "theme": "catppuccin",
      "tools": {
        "bash": false,
        "edit": false,
        "glob": false,
        "grep": false,
        "list": false,
        "patch": false,
        "read": false,
        "todoread": false,
        "todowrite": false,
        "webfetch": false,
        "write": false
      },
      "permission": {
        "bash": "deny",
        "doom_loop": "deny",
        "edit": "deny",
        "external_directory": "deny",
        "webfetch": "deny"
      }
    }
  '';

  # --- CATPPUCCIN THEME ---
  catppuccin = {
    enable = true;
    flavor = "mocha";
    accent = "mauve";
  };

  # --- ZSH ---
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    historySubstringSearch = {
      enable = true;
      searchUpKey = [
        "^[[A"
        "^[OA"
      ]; # Arrow up (CSI + SS3)
      searchDownKey = [
        "^[[B"
        "^[OB"
      ]; # Arrow down (CSI + SS3)
    };
    defaultKeymap = "viins"; # Vi mode, start in insert
    history = {
      size = 100000;
      save = 100000;
      extended = true;
      ignoreAllDups = true; # Superset of ignoreDups
      ignoreSpace = true;
      share = true; # Implies INC_APPEND_HISTORY
    };
    shellAliases = {
      # Override la to include -l (home-manager default is -a only)
      la = "eza -la";
      # bat - official docs recommend this for cat alias
      cat = "bat --paging=never --style=plain";
      # Safer file operations
      rm = "rm -i";
      cp = "cp -i";
      mv = "mv -i";
      # run-help alias
      help = "run-help";
    };
    initContent = ''
      # --- VI MODE ---
      # Reduce mode switch delay (10ms)
      export KEYTIMEOUT=1

      # Cursor shape: beam for insert, block for normal
      function zle-keymap-select zle-line-init {
        case $KEYMAP in
          vicmd)      echo -ne '\e[2 q' ;;  # Block cursor
          viins|main) echo -ne '\e[6 q' ;;  # Beam cursor
        esac
      }
      zle -N zle-keymap-select
      zle -N zle-line-init

      # Fix backspace in vi mode
      bindkey -M viins '^?' backward-delete-char
      bindkey -M viins '^H' backward-delete-char

      # Emacs-style bindings in insert mode (muscle memory)
      bindkey -M viins '^A' beginning-of-line
      bindkey -M viins '^E' end-of-line
      bindkey -M viins '^K' kill-line
      bindkey -M viins '^U' backward-kill-line
      bindkey -M viins '^W' backward-kill-word
      bindkey -M viins '^Y' yank

      # Edit command in $EDITOR (press v in normal mode)
      autoload -Uz edit-command-line
      zle -N edit-command-line
      bindkey -M vicmd 'v' edit-command-line

      # --- HISTORY SEARCH ---
      # Vi command mode: k/j for history search
      bindkey -M vicmd 'k' history-substring-search-up
      bindkey -M vicmd 'j' history-substring-search-down

      # Ctrl+P/N in insert mode
      bindkey -M viins '^P' history-substring-search-up
      bindkey -M viins '^N' history-substring-search-down

      # --- RUN-HELP ---
      # Provides inline help for commands (Alt+H or ESC H)
      unalias run-help 2>/dev/null
      autoload -Uz run-help
      autoload -Uz run-help-git
      autoload -Uz run-help-sudo

      # --- COMPLETION ---
      zstyle ':completion:*' menu select
      zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

      # --- DIRECTORY NAVIGATION ---
      setopt AUTO_CD
      setopt AUTO_PUSHD
      setopt PUSHD_IGNORE_DUPS
      setopt PUSHD_SILENT

      # --- GLOBBING ---
      setopt EXTENDED_GLOB
      setopt NO_CASE_GLOB
      setopt GLOB_DOTS              # Include dotfiles in glob patterns

      # --- CORRECTION ---
      setopt CORRECT
      setopt CORRECT_ALL

      # --- HISTORY ---
      setopt HIST_VERIFY            # Show command before executing from history
      setopt HIST_REDUCE_BLANKS     # Remove superfluous blanks
      setopt HIST_EXPIRE_DUPS_FIRST # Expire duplicates first when trimming history
      setopt HIST_NO_STORE          # Don't store 'history' command itself
      # Note: INC_APPEND_HISTORY not needed - SHARE_HISTORY (share=true) implies it

      # --- MISC ---
      setopt INTERACTIVE_COMMENTS   # Allow comments in interactive shell
      setopt NO_BEEP                # Disable beep on error
      setopt NO_FLOW_CONTROL        # Disable Ctrl+S/Ctrl+Q flow control
      setopt LONG_LIST_JOBS         # List jobs in long format
      setopt NOTIFY                 # Report status of background jobs immediately

      # --- COMPLETION OPTIONS ---
      setopt COMPLETE_IN_WORD       # Complete from both ends of cursor
      setopt PATH_DIRS              # Tab-complete into path directories
    '';
  };

  # --- NAVIGATION ---
  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
    tmux.enableShellIntegration = true; # fzf in tmux popup
    defaultCommand = "fd --type f --strip-cwd-prefix --hidden --follow --exclude .git";
    fileWidgetCommand = "fd --type f --strip-cwd-prefix --hidden --follow --exclude .git";
    changeDirWidgetCommand = "fd --type d --strip-cwd-prefix --hidden --follow --exclude .git";
    defaultOptions = [
      "--height 40%"
      "--layout=reverse"
      "--border"
      "--inline-info"
    ];
    fileWidgetOptions = [
      "--preview 'bat --color=always --style=numbers --line-range=:500 {}'"
    ];
    changeDirWidgetOptions = [
      "--preview 'eza --tree --color=always {} | head -200'"
    ];
    historyWidgetOptions = [
      "--sort"
      "--exact"
    ];
  };

  # --- DOCUMENTATION ---
  programs.tealdeer = {
    enable = true;
    settings.updates.auto_update = true;
  };

  # --- SYSTEM MONITORING ---
  programs.btop = {
    enable = true;
    settings = {
      vim_keys = true;
      update_ms = 1000;
      proc_sorting = "cpu lazy";
      shown_boxes = "cpu mem net proc";
      clock_format = "%H:%M";
      rounded_corners = true;
      graph_symbol = "braille";
      temp_scale = "celsius";
    };
  };

  # --- TERMINAL MULTIPLEXER ---
  programs.tmux = {
    enable = true;
    mouse = true;
    keyMode = "vi";
    prefix = "C-a";
    historyLimit = 50000;
    escapeTime = 0;
    baseIndex = 1;
    terminal = "tmux-256color";
    clock24 = true;
    focusEvents = true; # For vim/neovim autoread

    extraConfig = ''
      # True colour support
      set -ag terminal-overrides ",xterm-256color:RGB"

      # Clipboard integration
      set -g set-clipboard on

      # Easier pane splitting (keep CWD)
      bind | split-window -h -c "#{pane_current_path}"
      bind - split-window -v -c "#{pane_current_path}"

      # New window in current directory
      bind c new-window -c "#{pane_current_path}"

      # Vi keys in command prompt
      set -g status-keys vi

      # Show messages for 3 seconds (default 1s too short)
      set -g display-time 3000

      # Vim-style pane navigation (repeatable)
      bind -r h select-pane -L
      bind -r j select-pane -D
      bind -r k select-pane -U
      bind -r l select-pane -R

      # Vim-style pane resizing
      bind -r H resize-pane -L 5
      bind -r J resize-pane -D 5
      bind -r K resize-pane -U 5
      bind -r L resize-pane -R 5

      # Vim-style copy mode
      bind -T copy-mode-vi v send-keys -X begin-selection
      bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel
      bind -T copy-mode-vi C-v send-keys -X rectangle-toggle

      # Reload config
      bind r source-file ~/.config/tmux/tmux.conf \; display "Config reloaded!"

      # Renumber windows when one is closed
      set -g renumber-windows on
    '';
  };

  # --- EDITOR ---
  programs.vim = {
    enable = true;
    defaultEditor = true;
    plugins = [ pkgs.vimPlugins.catppuccin-vim ];
    settings = {
      number = true;
      relativenumber = true;
      expandtab = true;
      tabstop = 2;
      shiftwidth = 2;
      ignorecase = true;
      smartcase = true;
      hidden = true;
      mouse = "a";
      history = 10000;
      undofile = true;
      background = "dark";
    };
    extraConfig = ''
      " True colour support for vim (not neovim)
      if has('termguicolors')
        let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
        let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"
        set termguicolors
      endif

      " Catppuccin theme
      colorscheme catppuccin_mocha

      " Auto-indentation
      set autoindent
      set smartindent

      " Command-line completion
      set wildmenu

      " System clipboard
      set clipboard=unnamedplus

      " Better UI
      set cursorline
      set scrolloff=8
      set signcolumn=yes
      set colorcolumn=80
      set nowrap
      set encoding=utf-8
      set autoread

      " Intuitive backspace behaviour
      set backspace=indent,eol,start

      " Always show status line
      set laststatus=2

      " Show cursor position in status line
      set ruler

      " Search highlighting
      set hlsearch
      set incsearch

      " Faster updates
      set updatetime=250
      set timeoutlen=300

      " Split behaviour
      set splitright
      set splitbelow

      " Clear search highlighting with Escape
      nnoremap <Esc> :nohlsearch<CR>

      " Better window navigation
      nnoremap <C-h> <C-w>h
      nnoremap <C-j> <C-w>j
      nnoremap <C-k> <C-w>k
      nnoremap <C-l> <C-w>l
    '';
  };

  # --- FILE VIEWING ---
  programs.bat = {
    enable = true;
    config = {
      style = "numbers,changes,header";
      pager = "less -FR";
      italic-text = "always";
      tabs = "2"; # Match editor tab width
      map-syntax = [
        "*.conf:INI"
        ".ignore:Git Ignore"
      ];
    };
  };

  programs.eza = {
    enable = true;
    git = true;
    icons = "auto";
    extraOptions = [
      "--group-directories-first"
      "--header"
      "--time-style=long-iso"
    ];
  };

  # --- SEARCH ---
  programs.ripgrep = {
    enable = true;
    arguments = [
      "--smart-case"
      "--follow"
      "--hidden"
      "--glob=!.git/*"
      "--glob=!node_modules/*"
      "--glob=!.direnv/*"
      "--max-columns=150"
      "--max-columns-preview"
    ];
  };

  programs.fd = {
    enable = true;
    hidden = true;
    ignores = [
      ".git/"
      "node_modules/"
      ".direnv/"
      "*.pyc"
      "__pycache__/"
      ".mypy_cache/"
      "target/"
      "dist/"
      "build/"
    ];
    extraOptions = [
      "--follow"
      "--no-require-git"
    ];
  };

  # --- NETWORK DIAGNOSTICS ---
  programs.trippy = {
    enable = true;
    settings = {
      trippy = {
        mode = "tui";
      };
      strategy = {
        protocol = "icmp";
        addr-family = "ipv4-then-ipv6";
        max-ttl = 64;
      };
      dns = {
        dns-resolve-method = "system";
        dns-lookup-as-info = true;
      };
      tui = {
        tui-address-mode = "both";
        tui-refresh-rate = "100ms";
      };
    };
  };

  # --- PROMPT ---
  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      # Prompt format (username/hostname only show when SSH'd or root)
      format = "$username$hostname$directory$git_branch$git_status$nix_shell$cmd_duration$line_break$character";

      # Username (only when SSH'd or root)
      username = {
        show_always = false;
        style_user = "bold blue";
        style_root = "bold red";
        format = "[$user]($style)@";
      };

      # Hostname (only when SSH'd)
      hostname = {
        ssh_only = true;
        style = "bold green";
        format = "[$hostname]($style) ";
      };

      # Directory
      directory = {
        style = "bold lavender";
        truncation_length = 3;
        truncate_to_repo = true;
      };

      # Git
      git_branch = {
        style = "bold mauve";
        format = "on [$symbol$branch]($style) ";
      };
      git_status = {
        style = "bold red";
        format = "[$all_status$ahead_behind]($style) ";
        conflicted = "=";
        ahead = "⇡$count";
        behind = "⇣$count";
        diverged = "⇕⇡$ahead_count⇣$behind_count";
        untracked = "?$count";
        stashed = "\\$$count";
        modified = "!$count";
        staged = "+$count";
        renamed = "»$count";
        deleted = "✘$count";
      };

      # Nix shell indicator
      nix_shell = {
        style = "bold blue";
        format = "via [$symbol$state]($style) ";
        symbol = "❄️ ";
        impure_msg = "impure";
        pure_msg = "pure";
      };

      # Command duration (only show if > 2s)
      cmd_duration = {
        style = "bold yellow";
        format = "took [$duration]($style) ";
        min_time = 2000;
      };

      # Prompt character
      character = {
        success_symbol = "[❯](bold green)";
        error_symbol = "[❯](bold red)";
        vimcmd_symbol = "[❮](bold mauve)";
        vimcmd_replace_one_symbol = "[❮](bold peach)";
        vimcmd_replace_symbol = "[❮](bold peach)";
        vimcmd_visual_symbol = "[❮](bold yellow)";
      };
    };
  };

  # --- READLINE (vi mode for bash, python REPL, etc.) ---
  programs.readline = {
    enable = true;
    variables = {
      editing-mode = "vi";
      show-mode-in-prompt = true;
      vi-ins-mode-string = "\\1\\e[6 q\\2"; # Beam cursor for insert
      vi-cmd-mode-string = "\\1\\e[2 q\\2"; # Block cursor for normal
      keyseq-timeout = 50;
      bell-style = "none"; # Disable terminal bell
      colored-stats = true;
      colored-completion-prefix = true;
      completion-ignore-case = true;
      mark-symlinked-directories = true;
      show-all-if-ambiguous = true;
      visible-stats = true;
    };
    bindings = {
      # Vi command mode
      "\\C-p" = "history-search-backward";
      "\\C-n" = "history-search-forward";
    };
  };

  # --- ENVIRONMENT VARIABLES ---
  home.sessionVariables = {
    VISUAL = "vim"; # Some tools use VISUAL instead of EDITOR
    LESS = "-R -F -X -i -J -W"; # -R: raw control chars (colours), -F: quit if one screen, -X: no termcap init, -i: ignore case, -J: status column, -W: highlight first new line
  };
  programs.less = {
    enable = true;
    config = ''
      #command
      j forw-line
      k back-line
      d forw-scroll
      u back-scroll
      g goto-line
      G goto-end
      / forw-search
      ? back-search
      n repeat-search
      N reverse-search
      q quit
    '';
  };

}
