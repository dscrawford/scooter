# Mounts the node store, its trusted daemon socket and per-sandbox GC roots into sandboxes.
# SECURITY: a sandbox becomes root on its node; single-user clusters only.

{ config, lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.scooter.sandbox.sharedStore;
  mnt = "/nix/.scooter-host";
in
{
  options.scooter.sandbox.sharedStore = {
    enable = mkEnableOption ''
      sandboxes sharing their node's Nix store through a trusted node daemon socket.
      Effectively gives every sandbox root on its node'';

    socketDir = mkOption {
      type = types.str;
      default = "/run/scooter-nix-daemon";
      description = "Node dir holding the trusted daemon `socket` (services.scooterSharedStore.socketDir).";
    };

    rootsDir = mkOption {
      type = types.str;
      default = "/nix/var/nix/gcroots/scooter";
      description = "Node dir of per-sandbox GC roots, one subdir per sandbox pod (services.scooterSharedStore.rootsDir).";
    };
  };

  config = lib.mkIf cfg.enable {
    scooter.sandboxPod = {
      extraEnv = if config.scooter.warmStore.enable
        then throw "scooter.sandbox.sharedStore replaces the overlay PVC the warm store pools; turn scooter.warmStore off"
        else [{ name = "SCOOTER_POD_NAME"; valueFrom.fieldRef.fieldPath = "metadata.name"; }];
      extraVolumes = [
        { name = "scooter-host-store"; hostPath = { path = "/nix/store"; type = "Directory"; }; }
        # Directory, not DirectoryOrCreate: a node without the socket unit fails the pod loudly.
        { name = "scooter-host-daemon"; hostPath = { path = cfg.socketDir; type = "Directory"; }; }
        { name = "scooter-host-roots"; hostPath = { path = cfg.rootsDir; type = "DirectoryOrCreate"; }; }
      ];
      extraVolumeMounts = [
        { name = "scooter-host-store"; mountPath = "${mnt}/store"; readOnly = true; }
        { name = "scooter-host-daemon"; mountPath = "${mnt}/daemon"; }
        # The pod name is conv-<id>, stable across suspend, so roots survive a restart.
        { name = "scooter-host-roots"; mountPath = "${mnt}/roots"; subPathExpr = "$(SCOOTER_POD_NAME)"; }
      ];
    };
  };
}
