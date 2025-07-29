rec {
  static_ip = "192.168.1.12";
  base_domain_name = "local.cloud";
  plane_app_port = 7000;
  plane_app_domain = "plane.${base_domain_name}";
}
