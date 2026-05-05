#lang nisp

;; A typical NixOS module: { config, lib, pkgs, ... }: { ... }
(raw-file
  (fn-set-rest (config lib pkgs)
    (att
    (imports (lst (p "./hardware-configuration.nix")))
    (boot.loader.systemd-boot.enable #t)
    (networking.hostName "hello")
    (services.openssh.enable #t)
    (users.users.tom
      (att
        (isNormalUser #t)
        (extraGroups (lst "wheel" "networkmanager"))
        (shell pkgs.zsh)))
      (environment.systemPackages
        (with-pkgs git vim curl htop)))))
