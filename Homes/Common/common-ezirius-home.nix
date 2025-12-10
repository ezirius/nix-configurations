# Shared home-manager configuration for ezirius across all hosts
# Host-specific settings (signing keys, SSH config) are in host-specific files
{ ... }:
let
  pubconfig = import ../../Public/Common/configurations.nix;
in
{
  imports = [ ./common-all-home.nix ];

  # --- GIT TOOLS ---
  # Delta - theme handled by catppuccin/nix module
  programs.delta = {
    enable = true;
    enableJujutsuIntegration = true; # Configure jj to use delta
    options = {
      navigate = true;
      side-by-side = true;
      line-numbers = true;
      hyperlinks = true;
      tabs = 2;
    };
  };

  # --- JUJUTSU (shared settings) ---
  # Note: ui.pager is set by programs.delta.enableJujutsuIntegration
  programs.jujutsu = {
    enable = true;
    settings = {
      user = pubconfig.user;
      ui = {
        editor = "vim";
        diff-editor = ":builtin"; # Built-in side-by-side diff editor
      };
    };
  };

  # --- GIT (shared settings) ---
  # Host-specific settings (signing key, gpg.ssh.program) are in host files
  programs.git = {
    enable = true;
    ignores = [
      # Editor/IDE
      "*~"
      "*.swp"
      "*.swo"
      ".idea/"
      ".vscode/"

      # OS
      ".DS_Store"
      "Thumbs.db"

      # Build artifacts
      "*.log"
      "*.tmp"

      # Direnv/Nix
      ".direnv/"
      "result"
      "result-*"

      # Environment files
      ".env.local"
    ];
    settings = {
      gpg.format = "ssh";
      user = pubconfig.user;
      init.defaultBranch = "main";
      alias = {
        # Status
        st = "status -sb";
        s = "status";

        # Branching
        co = "checkout";
        br = "branch";
        sw = "switch";
        sc = "switch -c"; # switch create

        # Committing
        ci = "commit";
        ca = "commit --amend";
        cm = "commit -m";
        can = "commit --amend --no-edit";

        # Staging
        a = "add";
        ap = "add -p"; # patch mode - interactive staging
        aa = "add --all";
        unstage = "reset HEAD --";

        # Diffing
        d = "diff";
        dc = "diff --cached";
        ds = "diff --stat";

        # Logging
        lg = "log --oneline --graph --decorate";
        ll = "log --oneline -20";
        last = "log -1 HEAD --stat";
        history = "log --follow -p --";

        # Undoing
        undo = "reset --soft HEAD~1";
        discard = "restore"; # Modern replacement for 'checkout --' (Git 2.23+)

        # Stashing
        sta = "stash";
        stap = "stash pop";
        stal = "stash list";
        stas = "stash show -p"; # Show stash diff

        # Utility
        recent = "branch --sort=-committerdate --format='%(committerdate:relative)%09%(refname:short)'";
        aliases = "config --get-regexp ^alias\\\\.";
        root = "rev-parse --show-toplevel";
        whoami = "config user.email";
      };
      commit.verbose = true; # Show diff in commit message editor
      branch.sort = "-committerdate"; # Recent branches first
      pull.rebase = true;
      push.autoSetupRemote = true;
      fetch.prune = true;
      rebase.autoStash = true;
      diff.algorithm = "histogram";
      diff.colorMoved = "default";
      merge.conflictStyle = "zdiff3";
      core.autocrlf = "input";
      help.autocorrect = 10;
      rerere.enabled = true; # Remember conflict resolutions
    };
  };
}
