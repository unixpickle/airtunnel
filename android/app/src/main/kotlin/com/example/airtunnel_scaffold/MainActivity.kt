package com.example.airtunnel_scaffold

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "dns_server"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "getDnsServers") {
                    result.success(getDnsServers())
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun getDnsServers(): List<String> {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork ?: return emptyList()
        val props: LinkProperties = cm.getLinkProperties(network) ?: return emptyList()
        return props.dnsServers.mapNotNull { it.hostAddress }
    }
}
