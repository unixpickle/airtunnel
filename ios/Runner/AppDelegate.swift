import Flutter
import Network
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
    if #available(iOS 14.0, *) {
      let monitor = NWPathMonitor()
      let queue = DispatchQueue(label: "dns.server.monitor")
      var servers: [String] = []
      let sem = DispatchSemaphore(value: 0)
      monitor.pathUpdateHandler = { path in
        servers = path.dnsServers
        sem.signal()
        monitor.cancel()
      }
      monitor.start(queue: queue)
      _ = sem.wait(timeout: .now() + 1.0)
      return servers
    }
    return []
  }
}
