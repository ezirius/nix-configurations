{
  config,
  pkgs,
  modulesPath,
  ...
}:
let
  common = import ../../Private/Common/git-agecrypt.nix;
  secrets = import ../../Private/Nithra/git-agecrypt.nix;
  pubkeys = import ../../Public/Nithra/keys.nix;
  pubconfig = import ../../Public/Nithra/configurations.nix;
  # Initrd host key must be in Nix store (available at build time, not activation time)
  initrdHostKey = pkgs.writeText "nithra_all_all_boot" secrets.hostKeys.nithra_all_all_boot;
in
{
  imports = [
    ../Common
    ./disko-config.nix
    ../../Homes/root/nithra-account.nix
    ../../Homes/ezirius/nithra-account.nix
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  networking.hostName = "nithra";
  system.stateVersion = "24.11";

  # --- LOCALE & TIMEZONE ---
  time.timeZone = common.locale.timeZone;
  i18n.defaultLocale = secrets.locale.defaultLocale;

  # --- SYSTEM PACKAGES (Nithra-specific) ---
  environment.systemPackages = builtins.attrValues {
    inherit (pkgs)
      # --- Remote Desktop (Virtual Display) ---
      dmenu # Application launcher - minimal, keyboard-driven (vs rofi: heavier, more features)
      rustdesk-flutter # Remote desktop - open source, self-hostable (vs TeamViewer: closed source, third-party servers)
      tigervnc # VNC server - provides Xvnc virtual display (vs x11vnc: captures existing display only)
      ;
  };

  # --- NIX SETTINGS (NixOS-specific) ---
  nix.gc.dates = "Mon 06:00"; # NixOS uses dates, Darwin uses interval
  nix.settings.auto-optimise-store = true; # Hardlink duplicate files in store

  # --- FILESYSTEM MAINTENANCE ---
  boot.tmp.cleanOnBoot = true; # Clear /tmp on reboot (security: removes stale credentials, temp files)
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
  };
  # Note: SSD TRIM handled by discard=async mount option on Btrfs

  # --- LOGGING ---
  services.journald.extraConfig = ''
    SystemMaxUse=500M
    MaxRetentionSec=1month
  '';

  # --- FIREWALL ---
  networking.firewall = {
    enable = true;
    # SSH (22/tcp) is implicitly opened by services.openssh.openFirewall (default: true)
    # Mosh needs UDP ports (limited range for reduced attack surface)
    allowedUDPPortRanges = [
      {
        from = 60000;
        to = 60010;
      }
    ];
  };

  # --- FAIL2BAN (Brute-force Protection) ---
  services.fail2ban = {
    enable = true;
    maxretry = 3;
    bantime = "1h";
    bantime-increment = {
      enable = true;
      multipliers = "1 2 4 8 16 32 64";
      maxtime = "168h";
      overalljails = true;
    };
  };

  # --- SSH (MAXIMUM SECURITY) ---
  services.openssh = {
    enable = true;
    settings = {
      # 1. Root CANNOT log in via SSH (Forces you to use Ezirius -> Sudo)
      PermitRootLogin = "no";

      # 2. No Passwords allowed. Keys Only.
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;

      # 3. Forwarding restrictions
      X11Forwarding = false;
      AllowTcpForwarding = false;
      AllowAgentForwarding = false;
      AllowStreamLocalForwarding = false;
      AuthenticationMethods = "publickey";

      # 4. Restrict SSH access to specific users
      AllowUsers = [ "ezirius" ];

      # 5. Connection timeouts and limits
      LoginGraceTime = 30; # Drop unauthenticated connections after 30s
      MaxAuthTries = 3; # 3 auth attempts per connection (fail2ban handles IP bans)
      MaxStartups = "10:30:60"; # Rate limit unauthenticated connections (start:rate:full)
      MaxSessions = 10; # Max sessions per connection (explicit, same as default)
      ClientAliveInterval = 300; # Keepalive every 5 min
      ClientAliveCountMax = 2; # Drop after 2 missed keepalives (10 min total)

      # 6. Host key algorithm (only offer ed25519)
      HostKeyAlgorithms = "ssh-ed25519";

      # 7. Algorithm hardening (ssh-audit.com recommended, OpenSSH 10.0 defaults)
      KexAlgorithms = [
        "mlkem768x25519-sha256" # Post-quantum (macOS Tahoe)
        "sntrup761x25519-sha512@openssh.com" # Post-quantum (Sequoia/Sonoma/Ventura)
        "curve25519-sha256" # Modern ECC (Blink Shell fallback)
        "curve25519-sha256@libssh.org" # Alias for compatibility
      ];
      Ciphers = [
        "chacha20-poly1305@openssh.com" # Best overall
        "aes256-gcm@openssh.com" # Blink Shell fallback
      ];
      Macs = [
        "hmac-sha2-512-etm@openssh.com" # Best
      ];
    };
  };

  # --- DISABLE CONSOLE LOGIN ---
  # No login prompt on physical console/VNC - access via SSH or RustDesk only
  # Recovery: boot live ISO if both SSH and RustDesk are broken
  console.enable = false;

  # --- REMOTE DESKTOP (Virtual Display Only) ---
  # Physical display shows kernel messages only - no GUI, no login prompt
  # RustDesk session runs in virtual Xvnc framebuffer
  services.xserver = {
    enable = true;
    displayManager.startx.enable = true; # No display manager, no physical GUI
    windowManager.i3.enable = true;
  };

  # Systemd service: auto-start virtual X session
  systemd.services.virtual-desktop = {
    description = "Virtual X Desktop (Xvnc + i3)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "ezirius";
      Type = "simple";
      ExecStart = "${pkgs.tigervnc}/bin/Xvnc :1 -geometry 1920x1080 -depth 24 -localhost yes"; # -localhost yes binds to 127.0.0.1 only (RustDesk uses X11 directly)
      Restart = "always";
      RestartSec = 3;
    };
  };

  # Systemd service: start i3 in virtual display
  systemd.services.virtual-i3 = {
    description = "i3 Window Manager in Virtual Display";
    after = [ "virtual-desktop.service" ];
    bindsTo = [ "virtual-desktop.service" ]; # Stop if Xvnc stops
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "ezirius";
      Type = "simple";
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'n=0; while [ ! -e /tmp/.X11-unix/X1 ] && [ $n -lt 60 ]; do sleep 0.5; n=$((n+1)); done; [ -e /tmp/.X11-unix/X1 ]'"; # Wait for Xvnc socket (max 30s)
      ExecStart = "${pkgs.i3}/bin/i3";
      Restart = "always";
      RestartSec = 3;
    };
    environment.DISPLAY = ":1";
  };

  # Systemd service: start RustDesk in virtual display
  systemd.services.virtual-rustdesk = {
    description = "RustDesk in Virtual Display";
    after = [ "virtual-i3.service" ];
    bindsTo = [ "virtual-i3.service" ]; # Stop if i3 stops
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "ezirius";
      Type = "simple";
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'n=0; while ! ${pkgs.i3}/bin/i3-msg get_version &>/dev/null && [ $n -lt 60 ]; do sleep 0.5; n=$((n+1)); done'"; # Wait for i3 IPC socket (max 30s)
      ExecStart = "${pkgs.rustdesk-flutter}/bin/rustdesk --service";
      Restart = "always";
      RestartSec = 3;
    };
    environment.DISPLAY = ":1";
  };

  # --- KERNEL HARDENING ---
  security.protectKernelImage = true; # Prevent /dev/mem and /dev/kmem access

  boot.kernel.sysctl = {
    # Disable Magic SysRq (not needed on VPS, prevents /proc/sysrq-trigger abuse)
    "kernel.sysrq" = 0;

    # Network hardening
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv4.conf.default.accept_source_route" = 0;
    "net.ipv6.conf.all.accept_source_route" = 0;
    "net.ipv6.conf.default.accept_source_route" = 0;
    "net.ipv4.conf.all.rp_filter" = 1; # Reverse path filtering (anti-spoofing)
    "net.ipv4.conf.default.rp_filter" = 1;
    "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv4.tcp_syncookies" = 1; # SYN flood protection

    # Kernel hardening
    "kernel.kptr_restrict" = 2; # Hide kernel pointers from unprivileged users
    "kernel.dmesg_restrict" = 1; # Restrict dmesg to root
    "kernel.perf_event_paranoid" = 3; # Restrict perf to root
    "kernel.yama.ptrace_scope" = 2; # Restrict ptrace to root
    "kernel.unprivileged_bpf_disabled" = 1; # Disable unprivileged BPF
    "net.core.bpf_jit_harden" = 2; # Harden BPF JIT compiler
  };

  # --- SOPS ---
  sops.defaultSopsFile = ../../Private/Nithra/sops-nix.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.secrets.rootPassword.neededForUsers = true;
  sops.secrets.eziriusPassword.neededForUsers = true;

  sops.secrets.nithra_github_ezirius_nix-configurations = {
    owner = "ezirius";
    path = "/home/ezirius/.ssh/nithra_github_ezirius_nix-configurations";
    mode = "0600";
  };

  sops.secrets.nithra_github_ezirius_sign = {
    owner = "ezirius";
    path = "/home/ezirius/.ssh/nithra_github_ezirius_sign";
    mode = "0600";
  };

  # --- ENSURE ~/.ssh/ EXISTS WITH CORRECT OWNERSHIP ---
  # Sops-nix creates parent directories as root; this ensures home-manager can write ~/.ssh/config
  systemd.tmpfiles.rules = [
    "d /home/ezirius/.ssh 0700 ezirius users -"
  ];

  # --- SSH LOGIN KEYS (from Public/, available at eval time) ---
  users.users.ezirius.openssh.authorizedKeys.keys = [
    pubkeys.loginKeysPub.ipsa_nithra_ezirius_login
    pubkeys.loginKeysPub.ipirus_nithra_ezirius_login
    pubkeys.loginKeysPub.maldoria_nithra_ezirius_login
  ];

  # --- FILESYSTEM ---
  # /var/log needs to be available early for proper boot logging
  fileSystems."/var/log".neededForBoot = true;

  # --- HOST KEYS ---
  # OpenSSH host key - disable auto-generation, use our managed key from sops
  services.openssh.hostKeys = [ ];
  sops.secrets.nithra_all_all_login = {
    path = "/etc/ssh/ssh_host_ed25519_key";
    mode = "0600";
  };

  # --- KERNEL MODULES ---
  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "virtio_net"
    "sd_mod"
    "sr_mod"
    "aesni_intel"
    "cryptd" # Hardware AES acceleration for faster LUKS
  ];

  # --- INITRD SSH (LUKS Unlock) ---
  boot.initrd.systemd.enable = true;
  boot.initrd.network = {
    enable = true;
    flushBeforeStage2 = true;
    ssh = {
      enable = true;
      port = 22;
      hostKeys = [ initrdHostKey ]; # Nix store path (available at build time)
      authorizedKeys = [
        pubkeys.bootKeysPub.ipsa_nithra_root_boot
        pubkeys.bootKeysPub.ipirus_nithra_root_boot
        pubkeys.bootKeysPub.maldoria_nithra_root_boot
      ];
      extraConfig = ''
        PermitRootLogin forced-commands-only
      '';
    };
  };

  # --- INITRD NETWORK (Static IP for initrd SSH via systemd-networkd) ---
  # kernel ip= param doesn't work with systemd initrd, use systemd-networkd instead
  boot.initrd.systemd.network = {
    enable = true;
    networks."10-ens18" = {
      matchConfig.Name = "ens18";
      networkConfig = {
        Address = "${common.network.nithraIp}/${toString pubconfig.network.nithraPrefixLength}";
        Gateway = secrets.network.nithraGateway;
        DHCP = "no";
      };
    };
  };

  boot.kernelParams = [
    "rd.luks.options=timeout=0" # Prevent 90s timeout during unlock
  ];

  # --- OS NETWORK (Static IP for Main System) ---
  networking.useDHCP = false;
  networking.interfaces.ens18.ipv4.addresses = [
    {
      address = common.network.nithraIp;
      prefixLength = pubconfig.network.nithraPrefixLength;
    }
  ];
  networking.defaultGateway = secrets.network.nithraGateway;
  networking.nameservers = pubconfig.nameservers;

  # --- BOOTLOADER ---
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10; # Limit boot entries to prevent /boot filling up
  boot.loader.efi.canTouchEfiVariables = true;
}
