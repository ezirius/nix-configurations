# Public keys
{
  # Public keys for Secure Shell boot authentication for remote Linux Unified Key Setup unlock
  bootKeysPub = {
    ipsa_nithra_root_boot = ''no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="systemd-tty-ask-password-agent --watch" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOU+zxE8v5NQcHCY/ZdeqY7ATVXJRbrrKwGJW2xTmqmL'';
    ipirus_nithra_root_boot = ''no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="systemd-tty-ask-password-agent --watch" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH3GNZTdiaQnd8uSWNq6zx17eBAOuA2mVRvm7EGxjNbJ'';
    maldoria_nithra_root_boot = ''no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="systemd-tty-ask-password-agent --watch" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOrzNFnJlC1UvMxj59DUjgq6BCAmARAM/EiQwFLbQxhH'';
  };

  # Public keys for Secure Shell login authentication
  loginKeysPub = {
    ipsa_nithra_ezirius_login = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIESPokqP5O8z1YjvQxAlY4oQYdvwR2HeYrlVVuz6GyhJ";
    ipirus_nithra_ezirius_login = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKrST0V666wegSu5UTpaV7dkYEx/Zp78mUuiESdUFmzg";
    maldoria_nithra_ezirius_login = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP2hqezbN/Gdcvybah1SFW35wg4QQ04JCxSbkx9Wlgqs";
  };
}
