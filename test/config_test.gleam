import successor/config

// Strict validation (chapter 23.1C): unknown or nonsensical values are
// errors, never silently projected away.

pub fn default_config_is_valid_test() {
  let assert Ok(_) = config.validate(config.default(data_dir: "/tmp/some-store"))
}

pub fn empty_data_dir_is_rejected_test() {
  let cfg = config.Config(..config.default(data_dir: ""), data_dir: "")
  let assert Error(_) = config.validate(cfg)
}

pub fn out_of_range_port_is_rejected_test() {
  let bad =
    config.Config(
      ..config.default(data_dir: "/tmp/x"),
      operator: config.OperatorBinding(host: "127.0.0.1", port: -1),
    )
  let assert Error(_) = config.validate(bad)
}

pub fn schema_version_is_one_test() {
  assert config.schema_version == 1
}

pub fn zero_providers_is_valid_test() {
  let cfg = config.default(data_dir: "/tmp/x")
  let assert [] = cfg.providers
}
