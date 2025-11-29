{ pkgs, ... }:
{
  # --- LOCALE & TIMEZONE ---
  time.timeZone = "Africa/Johannesburg";
  i18n.defaultLocale = "en_GB.UTF-8";

  # Universal Packages
  environment.systemPackages = builtins.attrValues {
    inherit (pkgs)
      curl
      git
      htop
      jujutsu
      mosh
      opencode
      vim
      ;
  };

  # --- NIX SETTINGS ---
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
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
    # Mosh needs UDP 60000-61000
    allowedUDPPortRanges = [
      {
        from = 60000;
        to = 61000;
      }
    ];
  };

  # --- FAIL2BAN (Brute-force Protection) ---
  services.fail2ban.enable = true;

  # --- AUTOMATIC SECURITY UPDATES ---
  # DISABLED: Risk of lockout on remote server with LUKS
  # Upgrades should be done manually with ./install.sh to ensure
  # you can monitor for issues and rollback if needed
  # system.autoUpgrade = {
  #   enable = true;
  #   allowReboot = false;
  #   dates = "06:00";
  # };

  # --- SSH (MAXIMUM SECURITY) ---
  services.openssh = {
    enable = true;
    settings = {
      # 1. Root CANNOT log in via SSH (Forces you to use Ezirius -> Sudo)
      PermitRootLogin = "no";

      # 2. No Passwords allowed. Keys Only.
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;

      # 3. Additional Hardening
      X11Forwarding = false;
      AllowTcpForwarding = false;
      AllowAgentForwarding = false;
      AllowStreamLocalForwarding = false;
      AuthenticationMethods = "publickey";

      # 4. Restrict SSH access to specific users
      AllowUsers = [ "ezirius" ];
    };
  };

  # --- KERNEL HARDENING ---
  security.protectKernelImage = true; # Prevent /dev/mem and /dev/kmem access

  boot.kernel.sysctl = {
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

}
