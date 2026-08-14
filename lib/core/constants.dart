/// Constantes partagées par les applications Windows et Android.
abstract final class CastFlowProtocol {
  static const version = 1;
  static const defaultHttpPort = 53317;
  static const defaultWsPort = 53318;
  static const discoveryPort = 54545;

  static const maxFilesPerTransfer = 500;
  static const maxManifestBytes = 1024 * 1024;
  static const maxFileSize = 1024 * 1024 * 1024 * 1024; // 1 Tio
  static const tokenTtl = Duration(minutes: 10);
  static const pinLockout = Duration(minutes: 1);
  static const maxPinAttempts = 3;
  static const announceInterval = Duration(seconds: 2);
  static const deviceTtl = Duration(seconds: 7);
}
