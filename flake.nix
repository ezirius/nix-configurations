{
  description = "Nithra Infrastructure";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      home-manager,
      sops-nix,
      ...
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      # Formatter for `nix fmt`
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);

      nixosConfigurations.nithra = nixpkgs.lib.nixosSystem {
        modules = [
          # Set platform (modern approach, replaces system arg)
          { nixpkgs.hostPlatform = "x86_64-linux"; }

          # 1. Disko Module
          disko.nixosModules.disko

          # 2. Sops Module
          sops-nix.nixosModules.sops

          # 3. Host Config
          ./hosts/nithra

          # 4. Home Manager Module
          home-manager.nixosModules.home-manager

          # 5. Home Manager Settings
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "hm-backup";
            home-manager.users.root = import ./users/root/home.nix;
            home-manager.users.ezirius = import ./users/ezirius/home.nix;
          }
        ];
      };
    };
}
