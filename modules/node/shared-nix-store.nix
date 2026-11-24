# Node half of scooter.sandbox.sharedStore: a trusted nix daemon socket for sandboxes.
# SECURITY: every client is trusted, so a sandbox is effectively root on this node.

{ config, lib, pkgs, ... }:

let
  cfg = config.services.scooterSharedStore;
  nix = config.nix.package;
in
{
  options.services.scooterSharedStore = {
    enable = lib.mkEnableOption "a trusted nix daemon socket for Scooter sandboxes sharing this node's store";

    socketDir = lib.mkOption {
      type = lib.types.str;
      default = "/run/scooter-nix-daemon";
      description = "Directory holding `socket`, mounted into sandboxes; match `scooter.sandbox.sharedStore.socketDir`.";
    };

    rootsDir = lib.mkOption {
      type = lib.types.str;
      default = "/nix/var/nix/gcroots/scooter";
      description = "Parent of each sandbox's GC-roots dir; match `scooter.sandbox.sharedStore.rootsDir`.";
    };

    sliceConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { CPUQuota = "400%"; MemoryMax = "16G"; };
      description = ''
        Limits on `scooter-nix.slice`, which holds every sandbox build: they run in
        the daemon, outside the pods' own CPU and memory limits.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.sockets.scooter-nix-daemon = {
      description = "Trusted nix daemon socket for Scooter sandboxes";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "${cfg.socketDir}/socket" ];
      # Sandboxes connect as their userns-mapped uid, which owns nothing here.
      socketConfig = { Accept = true; SocketMode = "0666"; DirectoryMode = "0755"; };
    };

    systemd.services."scooter-nix-daemon@" = {
      description = "Trusted nix daemon connection from a Scooter sandbox";
      # nix-daemon.service's tools and env (proxies, CA bundle), minus the PATH it derives from them.
      path = [ nix pkgs.util-linux config.programs.ssh.package ];
      environment = lib.filterAttrs (n: _: n != "PATH") config.systemd.services.nix-daemon.environment;
      serviceConfig = {
        ExecStart = "${nix}/bin/nix --extra-experimental-features nix-command --extra-experimental-features daemon-trust-override daemon --stdio --force-trusted";
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
        Slice = "scooter-nix.slice";
        # Builders must outlive a dropped connection's cleanup, like nix-daemon's.
        KillMode = "process";
      };
    };

    systemd.slices.scooter-nix = {
      description = "Builds for Scooter sandboxes";
      sliceConfig = cfg.sliceConfig;
    };

    systemd.tmpfiles.rules = [ "d ${cfg.rootsDir} 0755 root root -" ];
  };
}
