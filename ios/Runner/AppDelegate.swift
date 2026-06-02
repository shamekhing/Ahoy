import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let localFilePolicyChannel = "local_file_policy"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerLocalFilePolicyChannel(engineBridge.pluginRegistry)
  }

  private func registerLocalFilePolicyChannel(_ registry: FlutterPluginRegistry) {
    let registrar = registry.registrar(forPlugin: "LocalFilePolicy")
    let channel = FlutterMethodChannel(
      name: Self.localFilePolicyChannel,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let path = call.arguments as? String, !path.isEmpty else {
        result(FlutterError(code: "INVALID_ARGS", message: "path required", details: nil))
        return
      }

      var url = URL(fileURLWithPath: path)
      do {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        result(true)
      } catch {
        result(FlutterError(
          code: "BACKUP_EXCLUSION_FAILED",
          message: "Could not exclude file from backup",
          details: nil
        ))
      }
    }
  }
}
