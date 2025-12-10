{ ... }:
{
  home.stateVersion = "24.11";
  home.username = "root";
  home.homeDirectory = "/root";

  # Minimal zsh config for root (no fancy tools, just basics)
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    history = {
      size = 10000;
      save = 10000;
      ignoreAllDups = true;
      ignoreSpace = true;
    };
    shellAliases = {
      ll = "ls -la";
      rm = "rm -i";
      cp = "cp -i";
      mv = "mv -i";
    };
  };

  # Basic vim for root
  programs.vim = {
    enable = true;
    defaultEditor = true;
    settings = {
      number = true;
      expandtab = true;
      tabstop = 2;
      shiftwidth = 2;
      ignorecase = true;
      smartcase = true;
      mouse = "a";
    };
  };
}
