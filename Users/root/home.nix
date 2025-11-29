{ ... }:
{
  home.stateVersion = "24.11";
  home.username = "root";
  home.homeDirectory = "/root";

  # Minimal root shell config
  home.sessionVariables = {
    EDITOR = "vim";
  };
}
