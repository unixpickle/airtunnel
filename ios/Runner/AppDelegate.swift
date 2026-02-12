import Flutter
import SystemConfiguration
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let channelName = "dns_server"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: channelName, binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { call, result in
        if call.method == "getDnsServers" {
          result(self.getDnsServers())
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func getDnsServers() -> [String] {
    if let value = SCDynamicStoreCopyValue(nil, "State:/Network/Global/DNS" as CFString),
       let dict = value as? [String: Any],
       let servers = dict["ServerAddresses"] as? [String] {
      return servers
    }
    return []
  }
}
