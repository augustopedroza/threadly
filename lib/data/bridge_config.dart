/// Configuration for the gmessages bridge read source.
///
/// Values are injected at build time via `--dart-define` (conveniently
/// `--dart-define-from-file=bridge.json`, which is gitignored) so **no
/// credentials live in source**. With the defaults below — i.e. no defines —
/// the app falls back to the device SMS source, so it still builds and runs
/// for anyone without a bridge.
class BridgeConfig {
  /// Read from the bridge instead of the device SMS provider.
  static const bool useBridge =
      bool.fromEnvironment('USE_BRIDGE', defaultValue: false);

  /// Homeserver base URL, e.g. http://192.168.86.60:8008
  static const String homeserver = String.fromEnvironment('BRIDGE_HOMESERVER');
  static const String user = String.fromEnvironment('BRIDGE_USER');
  static const String password = String.fromEnvironment('BRIDGE_PASSWORD');
}
