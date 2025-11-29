{ ... }:
{
  home.stateVersion = "24.11";
  home.username = "ezirius";
  home.homeDirectory = "/home/ezirius";

  # SSH config for GitHub
  # Private key is managed by sops-nix at ~/.ssh/id_ed25519
  programs.ssh = {
    enable = true;
    matchBlocks = {
      "github.com" = {
        identityFile = "~/.ssh/id_ed25519";
        identitiesOnly = true;
      };
    };
  };

  # GitHub known host key (declarative)
  # Verify at: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
  # SHA256 fingerprint: +DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
  home.file.".ssh/known_hosts".text = ''
    github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
  '';

  programs.jujutsu = {
    enable = true;
    settings = {
      user = {
        name = "Ezirius";
        email = "66864416+Ezirius@users.noreply.github.com";
      };
    };
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
  };

  programs.git = {
    enable = true;
    settings.user = {
      name = "Ezirius";
      email = "66864416+Ezirius@users.noreply.github.com";
    };
  };
}
