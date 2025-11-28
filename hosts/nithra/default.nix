{ config, pkgs, modulesPath, ... }:
let
  secrets = import ../../secrets/nithra/git-agecrypt.nix;
  # Initrd host key must be in Nix store (available at build time, not activation time)
  initrdHostKey = pkgs.writeText "initrd_ssh_host_ed25519_key" secrets.hostKeys.boot;
in
{
  imports = [
    ./disko-config.nix
    ../../modules/core
    ../../users/root
    ../../users/ezirius
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  networking.hostName = "nithra";
  system.stateVersion = "24.11";

  # --- SOPS ---
  sops.defaultSopsFile = ../../secrets/nithra/sops-nix.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.secrets.root-password.neededForUsers = true;
  sops.secrets.ezirius-password.neededForUsers = true;

  sops.secrets.github-ssh-key-nithra = {
    owner = "ezirius";
    path = "/home/ezirius/.ssh/id_ed25519";
    mode = "0600";
  };

  # --- SSH LOGIN KEYS (from git-agecrypt, available at eval time) ---
  users.users.ezirius.openssh.authorizedKeys.keys = [
    secrets.sshPubKeys.ipsa
    secrets.sshPubKeys.ipirus
    secrets.sshPubKeys.maldoria
  ];

  # --- FILESYSTEM ---
  # /var/log needs to be available early for proper boot logging
  fileSystems."/var/log".neededForBoot = true;

  # --- HOST KEYS (from git-agecrypt) ---
  # OpenSSH host key - disable auto-generation, use our managed key
  services.openssh.hostKeys = [ ];
  environment.etc."ssh/ssh_host_ed25519_key" = {
    text = secrets.hostKeys.login;
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

  # --- DROPBEAR (SSH Unlock) ---
  boot.initrd.systemd.enable = true;
  boot.initrd.network = {
    enable = true;
    flushBeforeStage2 = true;
    ssh = {
      enable = true;
      port = 22;
      hostKeys = [ initrdHostKey ]; # Nix store path (available at build time)
      authorizedKeys = secrets.dropbear.authorizedKeys;
    };
  };

  # --- INITRD NETWORK (Static IP for Dropbear) ---
  boot.kernelParams = [
    "ip=${secrets.network.ip}::${secrets.network.gateway}:${secrets.network.netmask}:nithra:ens18:off"
    "rd.luks.options=timeout=0" # Prevent 90s timeout during unlock
  ];

  # --- OS NETWORK (Static IP for Main System) ---
  networking.useDHCP = false;
  networking.interfaces.ens18.ipv4.addresses = [
    {
      address = secrets.network.ip;
      prefixLength = secrets.network.prefixLength;
    }
  ];
  networking.defaultGateway = secrets.network.gateway;
  networking.nameservers = [
    "1.1.1.1"
    "8.8.8.8"
  ];

  # --- BOOTLOADER ---
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10; # Limit boot entries to prevent /boot filling up
  boot.loader.efi.canTouchEfiVariables = true;
}
