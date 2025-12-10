{ ... }:
let
  secrets = import ../../Private/Common/git-agecrypt.nix;
  pubkeys = import ../../Public/Maldoria/keys.nix;
  username = "ezirius";
  homeDir = "/Users/${username}";
in
{
  imports = [ ../Common ];

  networking.hostName = "maldoria";
  system.stateVersion = 5;

  # --- LOCALE & TIMEZONE ---
  time.timeZone = secrets.locale.timeZone;

  # --- FIREWALL ---
  networking.applicationFirewall = {
    enable = true;
    allowSigned = true; # Apple services (AirDrop, Handoff)
    allowSignedApp = false; # Prompt for third-party apps
    enableStealthMode = true; # Don't respond to probes
  };

  # --- SSH SERVER (HARDENED) ---
  services.openssh = {
    enable = true;
    extraConfig = ''
      # Authentication
      PermitRootLogin no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      AuthenticationMethods publickey
      AllowUsers ${username}

      # Forwarding restrictions
      X11Forwarding no
      AllowTcpForwarding no
      AllowAgentForwarding no
      AllowStreamLocalForwarding no

      # Required: sops-nix creates files as root, then fixes ownership
      StrictModes no

      # Connection timeouts and limits
      LoginGraceTime 30
      MaxAuthTries 3
      MaxStartups 10:30:60
      MaxSessions 10
      ClientAliveInterval 300
      ClientAliveCountMax 2

      # Host key algorithm (only offer ed25519)
      HostKeyAlgorithms ssh-ed25519

      # Algorithm hardening (matches Nithra)
      KexAlgorithms mlkem768x25519-sha256,sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org
      Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
      MACs hmac-sha2-512-etm@openssh.com
    '';
  };

  # --- NIX SETTINGS (Darwin-specific) ---
  nix.enable = true;
  nix.gc.interval = {
    Weekday = 1;
    Hour = 6;
    Minute = 0;
  };
  nix.optimise.automatic = true;

  # --- TOUCH ID FOR SUDO ---
  security.pam.services.sudo_local.touchIdAuth = true;

  # --- ENSURE ~/.ssh/ EXISTS WITH CORRECT OWNERSHIP AND AUTHORIZED_KEYS ---
  # Create .ssh directory BEFORE sops-nix runs (preActivation)
  # sops-nix runs during activation and needs the directory to exist
  system.activationScripts.preActivation.text = ''
    mkdir -p ${homeDir}/.ssh
    chown ${username}:staff ${homeDir}/.ssh
    chmod 700 ${homeDir}/.ssh
  '';

  # Write authorized_keys AFTER sops-nix runs (postActivation)
  # Remove any existing symlink (from old sops template config) before writing
  system.activationScripts.postActivation.text = ''
        rm -f ${homeDir}/.ssh/authorized_keys
        cat > ${homeDir}/.ssh/authorized_keys << 'EOF'
    ${pubkeys.loginKeysPub.ipsa_maldoria_ezirius_login}
    ${pubkeys.loginKeysPub.ipirus_maldoria_ezirius_login}
    EOF
        chown ${username}:staff ${homeDir}/.ssh/authorized_keys
        chmod 600 ${homeDir}/.ssh/authorized_keys
  '';

  # --- SOPS ---
  sops.defaultSopsFile = ../../Private/Maldoria/sops-nix.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";

  sops.secrets.maldoria_github_ezirius_nix-configurations = {
    owner = username;
    path = "${homeDir}/.ssh/maldoria_github_ezirius_nix-configurations";
    mode = "0600";
  };

  sops.secrets.maldoria_github_ezirius_sign = {
    owner = username;
    path = "${homeDir}/.ssh/maldoria_github_ezirius_sign";
    mode = "0600";
  };

  # Nithra SSH private keys (1Password agent uses matching public keys to identify these)
  sops.secrets.maldoria_nithra_root_boot = {
    owner = username;
    path = "${homeDir}/.ssh/maldoria_nithra_root_boot";
    mode = "0600";
  };

  sops.secrets.maldoria_nithra_ezirius_login = {
    owner = username;
    path = "${homeDir}/.ssh/maldoria_nithra_ezirius_login";
    mode = "0600";
  };

}
