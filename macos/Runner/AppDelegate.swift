import Cocoa
import FlutterMacOS
import Network

@main
class AppDelegate: FlutterAppDelegate {
  private let channelName = "dns_server"

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    guard
      let window = NSApplication.shared.windows.first,
      let controller = window.contentViewController as? FlutterViewController
    else {
      return
    }

    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      if call.method == "getDnsServers" {
        result(self.getDnsServers())
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func getDnsServers() -> [String] {
    if #available(macOS 11.0, *) {
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
