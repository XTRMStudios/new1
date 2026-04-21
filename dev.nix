{ pkgs, ... }: {
  # Which nixpkgs channel to use
  channel = "stable-24.05"; # or "unstable"

  # Packages to be installed in the development environment
  packages = with pkgs; [
    unzip
    openssh
    git
    qemu_kvm
    sudo
    cdrkit
    cloud-utils
    qemu
  ];

  # Environment variables for the workspace
  env = {
    # Example: set default editor
    EDITOR = "nano";
  };

  idx = {
    # Extensions from https://open-vsx.org (use "publisher.id")
    extensions = [
      "Dart-Code.flutter"
      "Dart-Code.dart-code"
    ];

    workspace = {
      # Runs when a workspace is first created
      onCreate = { };

      # Runs each time the workspace is (re)started
      onStart = { };
    };

    # Disable previews completely
    previews = {
      enable = false;
    };
  };
}
