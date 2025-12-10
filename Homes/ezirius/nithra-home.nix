# Nithra-specific home-manager configuration for ezirius
# Shared settings are in common-ezirius-home.nix
{ pkgs, ... }:
let
  common = import ../../Public/Common/keys.nix;
in
{
  imports = [ ../Common/common-ezirius-home.nix ];

  home.stateVersion = "24.11";
  home.username = "ezirius";
  home.homeDirectory = "/home/ezirius";

  # --- SSH CONFIG ---
  # Private key is managed by sops-nix at ~/.ssh/nithra_github_ezirius_nix-configurations
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    matchBlocks = {
      # Global defaults - hardened algorithms matching server config
      "*" = {
        serverAliveInterval = 60;
        serverAliveCountMax = 3;
        extraOptions = {
          KexAlgorithms = "mlkem768x25519-sha256,sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org";
          Ciphers = "chacha20-poly1305@openssh.com";
          MACs = "hmac-sha2-512-etm@openssh.com";
        };
      };
      "nithra-github-ezirius-nix-configurations" = {
        hostname = "github.com";
        user = "git";
        identityFile = "~/.ssh/nithra_github_ezirius_nix-configurations";
        identitiesOnly = true;
        extraOptions.HostKeyAlias = "nithra-github-ezirius-nix-configurations";
      };
    };
  };

  # --- KNOWN HOSTS ---
  # GitHub keys: from Public/Common/keys.nix
  home.file.".ssh/known_hosts".text = ''
    nithra-github-ezirius-nix-configurations ${common.hostKeysPub.github.ed25519}
    nithra-github-ezirius-nix-configurations ${common.hostKeysPub.github.rsa}
    nithra-github-ezirius-nix-configurations ${common.hostKeysPub.github.ecdsa}
  '';

  # --- JUJUTSU (host-specific signing) ---
  programs.jujutsu.settings.signing = {
    backend = "ssh";
    key = "~/.ssh/nithra_github_ezirius_sign";
    sign-all = true;
  };

  # --- GIT (host-specific signing and includes) ---
  programs.git = {
    signing = {
      key = "~/.ssh/nithra_github_ezirius_sign";
      signByDefault = true;
    };
    includes = [
      {
        condition = "gitdir:~/Documents/Ezirius/Development/GitHub/Nix-Configurations/";
        contents = {
          url."git@nithra-github-ezirius-nix-configurations:".insteadOf = "git@github.com:";
        };
      }
    ];
  };

  # --- TERMINAL ---
  programs.ghostty = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      font-family = "JetBrainsMono Nerd Font";
      font-size = 14;
      theme = "catppuccin-mocha";
      window-padding-x = 8;
      window-padding-y = 8;
      window-decoration = true;
      mouse-hide-while-typing = true;
      cursor-style = "block";
      cursor-style-blink = false;
      copy-on-select = true;
      clipboard-trim-trailing-spaces = true;
      shell-integration = "detect";
      scrollback-limit = 10000;
      confirm-close-surface = false; # Don't prompt on close
      bold-is-bright = false; # Use actual bold font
    };
  };

  # --- i3STATUS (VPS-appropriate status bar) ---
  programs.i3status = {
    enable = true;
    enableDefault = false; # VPS has no battery/wifi/volume

    general = {
      colors = true;
      # Catppuccin Mocha
      color_good = "#a6e3a1"; # green
      color_degraded = "#f9e2af"; # yellow
      color_bad = "#f38ba8"; # red
      interval = 5;
    };

    modules = {
      cpu_usage = {
        position = 1;
        settings = {
          format = "CPU: %usage";
          degraded_threshold = 50;
          max_threshold = 80;
        };
      };

      memory = {
        position = 2;
        settings = {
          format = "RAM: %percentage_used";
          threshold_degraded = "20%";
          threshold_critical = "10%";
        };
      };

      "disk /" = {
        position = 3;
        settings = {
          format = "Disk: %avail";
          low_threshold = 10;
          threshold_type = "percentage_avail";
        };
      };

      load = {
        position = 4;
        settings = {
          format = "Load: %1min";
          max_threshold = 4;
        };
      };

      # Interface name is VPS-specific (Proxmox VirtIO). Update if hardware changes.
      "ethernet ens18" = {
        position = 5;
        settings = {
          format_up = "E: %ip";
          format_down = "E: down";
        };
      };

      "tztime local" = {
        position = 6;
        settings = {
          format = "%Y-%m-%d %H:%M";
        };
      };
    };
  };

  # --- i3 WINDOW MANAGER ---
  xsession.windowManager.i3 = {
    enable = true;
    config = {
      modifier = "Mod1"; # Alt key
      defaultWorkspace = "workspace number 1";

      # Font for window titles and bar
      fonts = {
        names = [ "JetBrainsMono Nerd Font" ];
        size = 10.0;
      };

      # Window settings
      window = {
        titlebar = false;
        hideEdgeBorders = "smart";
      };

      floating = {
        titlebar = false;
      };

      # Catppuccin Mocha colours (official theme)
      colors = {
        focused = {
          border = "#b4befe"; # lavender
          background = "#1e1e2e"; # base
          text = "#cdd6f4"; # text
          indicator = "#f5e0dc"; # rosewater
          childBorder = "#b4befe"; # lavender
        };
        focusedInactive = {
          border = "#6c7086"; # overlay0
          background = "#1e1e2e"; # base
          text = "#cdd6f4"; # text
          indicator = "#f5e0dc"; # rosewater
          childBorder = "#6c7086"; # overlay0
        };
        unfocused = {
          border = "#6c7086"; # overlay0
          background = "#1e1e2e"; # base
          text = "#cdd6f4"; # text
          indicator = "#f5e0dc"; # rosewater
          childBorder = "#6c7086"; # overlay0
        };
        urgent = {
          border = "#fab387"; # peach
          background = "#1e1e2e"; # base
          text = "#fab387"; # peach
          indicator = "#f5e0dc"; # rosewater (consistent with other states)
          childBorder = "#fab387"; # peach
        };
        placeholder = {
          border = "#6c7086"; # overlay0
          background = "#1e1e2e"; # base
          text = "#cdd6f4"; # text
          indicator = "#f5e0dc"; # rosewater (consistent with other states)
          childBorder = "#6c7086"; # overlay0
        };
        background = "#1e1e2e"; # base
      };

      keybindings =
        let
          mod = "Mod1";
          terminal = "ghostty";
        in
        {
          # Focus (h/j/k/l)
          "${mod}+h" = "focus left";
          "${mod}+j" = "focus down";
          "${mod}+k" = "focus up";
          "${mod}+l" = "focus right";

          # Move window (shift + h/j/k/l)
          "${mod}+Shift+h" = "move left";
          "${mod}+Shift+j" = "move down";
          "${mod}+Shift+k" = "move up";
          "${mod}+Shift+l" = "move right";

          # Workspaces
          "${mod}+1" = "workspace number 1";
          "${mod}+2" = "workspace number 2";
          "${mod}+3" = "workspace number 3";
          "${mod}+4" = "workspace number 4";
          "${mod}+5" = "workspace number 5";
          "${mod}+6" = "workspace number 6";
          "${mod}+7" = "workspace number 7";
          "${mod}+8" = "workspace number 8";
          "${mod}+9" = "workspace number 9";
          "${mod}+0" = "workspace number 10";

          # Send to workspace
          "${mod}+Shift+1" = "move container to workspace number 1";
          "${mod}+Shift+2" = "move container to workspace number 2";
          "${mod}+Shift+3" = "move container to workspace number 3";
          "${mod}+Shift+4" = "move container to workspace number 4";
          "${mod}+Shift+5" = "move container to workspace number 5";
          "${mod}+Shift+6" = "move container to workspace number 6";
          "${mod}+Shift+7" = "move container to workspace number 7";
          "${mod}+Shift+8" = "move container to workspace number 8";
          "${mod}+Shift+9" = "move container to workspace number 9";
          "${mod}+Shift+0" = "move container to workspace number 10";

          # Layout
          "${mod}+b" = "split h";
          "${mod}+v" = "split v";
          "${mod}+f" = "fullscreen toggle";
          "${mod}+s" = "layout stacking";
          "${mod}+w" = "layout tabbed";
          "${mod}+e" = "layout toggle split";

          # Focus
          "${mod}+a" = "focus parent";
          "${mod}+Shift+a" = "focus child";
          "${mod}+space" = "focus mode_toggle";

          # Floating
          "${mod}+Shift+space" = "floating toggle";

          # Scratchpad
          "${mod}+Shift+minus" = "move scratchpad";
          "${mod}+minus" = "scratchpad show";

          # Core
          "${mod}+q" = "kill";
          "${mod}+Return" = "exec ${terminal}";
          "${mod}+d" = "exec dmenu_run";

          # Resize mode
          "${mod}+r" = "mode resize";

          # Session
          "${mod}+Shift+r" = "restart";
          "${mod}+Shift+e" = "exec i3-nagbar -t warning -m 'Exit i3?' -B 'Yes' 'i3-msg exit'";
        };
      modes = {
        resize = {
          "h" = "resize shrink width 50 px";
          "j" = "resize grow height 50 px";
          "k" = "resize shrink height 50 px";
          "l" = "resize grow width 50 px";
          "Escape" = "mode default";
          "Return" = "mode default";
        };
      };
      bars = [
        {
          position = "top";
          statusCommand = "${pkgs.i3status}/bin/i3status";
          colors = {
            # Catppuccin Mocha (official theme)
            background = "#1e1e2e"; # base
            statusline = "#cdd6f4"; # text
            separator = "#1e1e2e"; # base
            focusedWorkspace = {
              border = "#1e1e2e"; # base
              background = "#cba6f7"; # mauve
              text = "#11111b"; # crust
            };
            activeWorkspace = {
              border = "#1e1e2e"; # base
              background = "#585b70"; # surface2
              text = "#cdd6f4"; # text
            };
            inactiveWorkspace = {
              border = "#1e1e2e"; # base
              background = "#1e1e2e"; # base
              text = "#cdd6f4"; # text
            };
            urgentWorkspace = {
              border = "#1e1e2e"; # base
              background = "#f38ba8"; # red
              text = "#11111b"; # crust
            };
            bindingMode = {
              border = "#1e1e2e"; # base
              background = "#fab387"; # peach
              text = "#11111b"; # crust
            };
          };
        }
      ];
    };
  };
}
