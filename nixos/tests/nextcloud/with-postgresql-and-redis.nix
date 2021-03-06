import ../make-test.nix ({ pkgs, ...}: let
  adminpass = "hunter2";
  adminuser = "custom-admin-username";
in {
  name = "nextcloud-with-postgresql-and-redis";
  meta = with pkgs.stdenv.lib.maintainers; {
    maintainers = [ eqyiel ];
  };

  nodes = {
    # The only thing the client needs to do is download a file.
    client = { ... }: {};

    nextcloud = { config, pkgs, ... }: {
      networking.firewall.allowedTCPPorts = [ 80 ];

      services.nextcloud = {
        enable = true;
        hostName = "nextcloud";
        nginx.enable = true;
        caching = {
          apcu = false;
          redis = true;
          memcached = false;
        };
        config = {
          dbtype = "pgsql";
          dbname = "nextcloud";
          dbuser = "nextcloud";
          dbhost = "/run/postgresql";
          inherit adminuser;
          adminpassFile = toString (pkgs.writeText "admin-pass-file" ''
            ${adminpass}
          '');
        };
      };

      services.redis = {
        unixSocket = "/var/run/redis/redis.sock";
        enable = true;
        extraConfig = ''
          unixsocketperm 770
        '';
      };

      systemd.services.redis = {
        preStart = ''
          mkdir -p /var/run/redis
          chown ${config.services.redis.user}:${config.services.nginx.group} /var/run/redis
        '';
        serviceConfig.PermissionsStartOnly = true;
      };

      systemd.services."nextcloud-setup"= {
        requires = ["postgresql.service"];
        after = [
          "postgresql.service"
          "chown-redis-socket.service"
        ];
      };

      # At the time of writing, redis creates its socket with the "nobody"
      # group.  I figure this is slightly less bad than making the socket world
      # readable.
      systemd.services."chown-redis-socket" = {
        enable = true;
        script = ''
          until ${pkgs.redis}/bin/redis-cli ping; do
            echo "waiting for redis..."
            sleep 1
          done
          chown ${config.services.redis.user}:${config.services.nginx.group} /var/run/redis/redis.sock
        '';
        after = [ "redis.service" ];
        requires = [ "redis.service" ];
        wantedBy = [ "redis.service" ];
        serviceConfig = {
          Type = "oneshot";
        };
      };

      services.postgresql = {
        enable = true;
        ensureDatabases = [ "nextcloud" ];
        ensureUsers = [
          { name = "nextcloud";
            ensurePermissions."DATABASE nextcloud" = "ALL PRIVILEGES";
          }
        ];
      };
    };
  };

  testScript = let
    configureRedis = pkgs.writeScript "configure-redis" ''
      #!${pkgs.stdenv.shell}
      nextcloud-occ config:system:set redis 'host' --value '/var/run/redis/redis.sock' --type string
      nextcloud-occ config:system:set redis 'port' --value 0 --type integer
      nextcloud-occ config:system:set memcache.local --value '\OC\Memcache\Redis' --type string
      nextcloud-occ config:system:set memcache.locking --value '\OC\Memcache\Redis' --type string
    '';
    withRcloneEnv = pkgs.writeScript "with-rclone-env" ''
      #!${pkgs.stdenv.shell}
      export RCLONE_CONFIG_NEXTCLOUD_TYPE=webdav
      export RCLONE_CONFIG_NEXTCLOUD_URL="http://nextcloud/remote.php/webdav/"
      export RCLONE_CONFIG_NEXTCLOUD_VENDOR="nextcloud"
      export RCLONE_CONFIG_NEXTCLOUD_USER="${adminuser}"
      export RCLONE_CONFIG_NEXTCLOUD_PASS="$(${pkgs.rclone}/bin/rclone obscure ${adminpass})"
      "''${@}"
    '';
    copySharedFile = pkgs.writeScript "copy-shared-file" ''
      #!${pkgs.stdenv.shell}
      echo 'hi' | ${pkgs.rclone}/bin/rclone rcat nextcloud:test-shared-file
    '';

    diffSharedFile = pkgs.writeScript "diff-shared-file" ''
      #!${pkgs.stdenv.shell}
      diff <(echo 'hi') <(${pkgs.rclone}/bin/rclone cat nextcloud:test-shared-file)
    '';
  in ''
    startAll();
    $nextcloud->waitForUnit("multi-user.target");
    $nextcloud->succeed("${configureRedis}");
    $nextcloud->succeed("curl -sSf http://nextcloud/login");
    $nextcloud->succeed("${withRcloneEnv} ${copySharedFile}");
    $client->waitForUnit("multi-user.target");
    $client->succeed("${withRcloneEnv} ${diffSharedFile}");
  '';
})
