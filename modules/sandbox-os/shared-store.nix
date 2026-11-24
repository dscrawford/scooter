# Shared node store: /nix/store is the node's, and builds go to a trusted node daemon,
# so sandboxes on one node hold each path once. An existing overlay upper wins.
# SECURITY: trusted means root on the node, and able to plant paths other sandboxes run.

{ config, lib, pkgs, ... }:

let
  cfg = config.programs.sharedStore;
  ovl = config.programs.overlayStore;
  nix = config.nix.package;
  storeConf = "/run/scooter/nix-store.conf";
  imageRoots = "/run/scooter/image-roots";
  sock = "${cfg.hostPath}/daemon/socket";
  roots = "${cfg.hostPath}/roots";
  feats = "--extra-experimental-features 'nix-command read-only-local-store'";

  # Mirrors scooter-store's profile list (store-gc.nix).
  syncRoots = pkgs.writeShellApplication {
    name = "scooter-shared-roots";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils ];
    text = ''
      roots=${lib.escapeShellArg roots}
      [ -f ${storeConf} ] || { echo "shared store not active"; exit 0; }
      shopt -s nullglob
      want=$(mktemp); trap 'rm -f "$want"' EXIT
      {
        for l in /run/current-system /run/booted-system; do readlink -f "$l" || true; done
        find /nix/var/nix/profiles /nix/var/nix/gcroots /root/.local/state/nix/profiles \
          /workspace/.local/state/nix/profiles /home/*/.local/state/nix/profiles \
          -type l -exec readlink -f {} + 2>/dev/null || true
        cat ${imageRoots} 2>/dev/null || true
      } | { grep -E '^/nix/store/[^/]+$' || true; } | sort -u > "$want"
      # Add before removing, so a live path is never unrooted in between.
      while read -r p; do
        n=''${p#/nix/store/}
        [ -L "$roots/$n" ] || ln -sfn "$p" "$roots/$n"
      done < "$want"
      for l in "$roots"/*; do
        grep -qxF "$(readlink "$l")" "$want" || rm -f "$l"
      done
      echo "shared-roots: $(wc -l < "$want") roots in $roots"
    '';
  };
in
{
  options.programs.sharedStore = {
    enable = lib.mkEnableOption "the node-shared Nix store behind a trusted node daemon socket";

    hostPath = lib.mkOption {
      type = lib.types.str;
      default = "/nix/.scooter-host";
      description = ''
        Where the deployer mounts the node's pieces: `store/` (the node /nix/store,
        read-only), `daemon/socket` (the trusted node daemon) and `roots/` (this
        sandbox's own GC-roots dir on the node).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ syncRoots ];

    # Later settings win, so this overrides the overlay `store` when the setup wrote it.
    nix.extraOptions = lib.mkAfter "!include ${storeConf}";

    systemd.services.shared-store-setup = {
      description = "Switch /nix/store to the node's shared store";
      wantedBy = [ "local-fs.target" ];
      before = [ "local-fs.target" "overlay-store-setup.service" "nix-daemon.service" "nix-daemon.socket" ];
      after = [ "-.mount" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # The first sandbox of an image on a node copies the image's store over.
        TimeoutStartSec = "15min";
      };
      path = [ nix pkgs.util-linux pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.jq ];
      script = ''
        set -eu
        host=${lib.escapeShellArg cfg.hostPath}
        sock=${lib.escapeShellArg sock}
        lower=${lib.escapeShellArg ovl.lowerPath}

        # An existing overlay upper holds this conversation's builds; keep using it.
        if ${lib.boolToString ovl.enable} && mountpoint -q ${lib.escapeShellArg ovl.upperPath}; then
          echo "shared-store: overlay upper present; not switching"; exit 0
        fi
        if [ ! -S "$sock" ] || [ ! -d "$host/store" ]; then
          echo "shared-store: no node socket/store under $host; store unchanged"; exit 0
        fi
        if [ -f ${storeConf} ]; then
          echo "shared-store: already active"; exit 0
        fi

        # Everything the image ships must be in the node store before the bind hides it.
        image='local?read-only=true'
        nix ${feats} copy --no-check-sigs --from "$image" --to "unix://$sock" --all
        # Root the image's top-level paths so node GC can't drop them from under us.
        mkdir -p /run/scooter
        nix ${feats} path-info --store "$image" --all --json --json-format 1 \
          | jq -r 'to_entries | (map(.key as $k | (.value.references // []) - [$k] | .[] | {(.): 1}) | add // {}) as $r
                   | map(.key | select($r[.] == null))[]' \
          > ${imageRoots}

        # Mounts on store paths (a CDI GPU plugin's driver) would be hidden; re-bound below.
        submounts=$(awk '$5 ~ "^/nix/store/" { print $5 }' /proc/self/mountinfo | sort -u)
        mkdir -p "$lower"
        if ! mountpoint -q "$lower"; then
          mount --rbind /nix/store "$lower"
          mount --make-rprivate "$lower"
          mount -o remount,bind,ro "$lower"
        fi

        # A plain bind (not an overlay): paths the node daemon adds show up at once.
        mount --bind "$host/store" /nix/store
        mount -o remount,bind,ro /nix/store
        for t in $submounts; do
          if [ -e "$t" ]; then mount --bind "$lower''${t#/nix/store}" "$t"; fi
        done

        printf 'store = unix://%s\n' "$sock" > ${storeConf}
        echo "shared-store: /nix/store = node store via $sock"
      '';
    };

    # The node daemon only sees roots on the node, so mirror ours into its roots dir.
    systemd.services.scooter-shared-roots = {
      description = "Mirror this sandbox's GC roots into the node store";
      after = [ "shared-store-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = storeConf;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${syncRoots}/bin/scooter-shared-roots";
      };
    };
    systemd.paths.scooter-shared-roots = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = [ "/nix/var/nix/profiles" "/nix/var/nix/profiles/per-user/root" "/run/current-system" ];
    };
    systemd.timers.scooter-shared-roots = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "2min"; OnUnitActiveSec = "5min"; };
    };
  };
}
