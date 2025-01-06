_: {
  services = {
    openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };

    logind = {
      lidSwitch = "ignore";
      lidSwitchDocked = "ignore";
    };
  };
}
