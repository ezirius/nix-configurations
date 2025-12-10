# Public configurations
{
  # Networking
  network = {
    nithraPrefixLength = 24;
  };

  # Public DNS resolvers
  nameservers = [
    "1.1.1.1" # Cloudflare
    "8.8.8.8" # Google
  ];
}
