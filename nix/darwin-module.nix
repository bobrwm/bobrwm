flake: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.bobrwm;
in {
  options.services.bobrwm = {
    enable = lib.mkEnableOption "bobrwm tiling window manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = flake.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "flake.packages.\${system}.default";
    };

    logDir = lib.mkOption {
      type = lib.types.str;
      default = "/tmp";
    };
  };

  config = lib.mkIf cfg.enable {
    launchd.user.agents.com-bobrwm-bobrwm = {
      serviceConfig = {
        Label = "com.bobrwm.bobrwm";
        ProgramArguments = ["${cfg.package}/bin/bobrwm"];
        RunAtLoad = true;
        KeepAlive = {
          SuccessfulExit = false;
          Crashed = true;
        };
        StandardOutPath = "${cfg.logDir}/bobrwm.out.log";
        StandardErrorPath = "${cfg.logDir}/bobrwm.err.log";
        ProcessType = "Interactive";
        LimitLoadToSessionType = "Aqua";
        Nice = -20;
      };
    };
  };
}
