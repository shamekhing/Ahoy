package com.ahoy.app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDeviceList
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.ParcelUuid
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Block screenshots and recents thumbnails for the chat surface
        // (audit L-16). Debug builds stay screenshotable for development.
        if (!isDebugBuild) {
            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    companion object {
        private const val WD_CHANNEL  = "wifi_direct"
        private const val BLE_CHANNEL = "ble_advertiser"
        private const val TAG = "Ahoy"
        private const val P2P_PORT = 8765
        private const val MAX_PAYLOAD = 10 * 1024 * 1024 // 10 MB guard
        private const val CLIENT_TTL_MS = 10 * 60 * 1000L // prune idle clients

        // Ninth review (N-5): bound concurrent inbound handlers. Without this
        // cap the accept loop queues unbounded sockets, each of which may
        // allocate up to MAX_PAYLOAD for a single frame. Mirrors the LAN
        // connection cap (spec §8.1); the group subnet check (§8.2) already
        // limits who can reach this server.
        private const val MAX_INBOUND_CONNECTIONS = 16
    }

    private val isDebugBuild: Boolean
        get() = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    private fun logDebug(message: String) {
        if (isDebugBuild) Log.d(TAG, message)
    }

    private fun logWarn(message: String) {
        if (isDebugBuild) Log.w(TAG, message)
    }

    private fun logError(message: String, error: Throwable? = null) {
        if (!isDebugBuild) return
        if (error == null) Log.e(TAG, message) else Log.e(TAG, message, error)
    }

    // ── BLE advertiser state ──────────────────────────────────────────────────
    private var bleAdvertiser: BluetoothLeAdvertiser? = null
    private var bleGattServer: BluetoothGattServer? = null
    private var bleAdvertising = false
    private var bleChannel: MethodChannel? = null

    private lateinit var methodChannel: MethodChannel
    private lateinit var wifiP2pManager: WifiP2pManager
    private lateinit var wifiP2pChannel: WifiP2pManager.Channel
    private var broadcastReceiver: BroadcastReceiver? = null

    private var serverSocket: ServerSocket? = null
    private var isGroupOwner = false
    private var groupOwnerAddress: String? = null

    // /24 prefix of the WiFi Direct group (derived from the group owner's
    // address) connections from outside it are rejected (audit M-4).
    private var p2pSubnetPrefix: String? = null

    // IPs of clients that have connected to our server socket (group-owner side).
    // ip → last-seen timestamp, TTL-pruned; accessed from both UI thread and
    // wd-client background threads → ConcurrentHashMap (audit L-2).
    private val connectedClients = java.util.concurrent.ConcurrentHashMap<String, Long>()

    // Bounded pool for incoming-connection handlers a flood of connections
    // can no longer spawn unbounded threads (audit L-2).
    private val clientExecutor = java.util.concurrent.Executors.newFixedThreadPool(4)

    // Permits for concurrent inbound handlers (ninth review N-5): sockets
    // beyond the cap are closed immediately instead of queueing.
    private val inboundPermits = java.util.concurrent.Semaphore(MAX_INBOUND_CONNECTIONS)

    private val p2pIntentFilter = IntentFilter().apply {
        addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
        addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
        addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
        addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Lifecycle
    // ──────────────────────────────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        wifiP2pManager = getSystemService(Context.WIFI_P2P_SERVICE) as WifiP2pManager
        wifiP2pChannel = wifiP2pManager.initialize(this, mainLooper, null)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WD_CHANNEL)
        methodChannel.setMethodCallHandler(::handleMethodCall)

        // BLE advertiser channel
        bleChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BLE_CHANNEL)
        bleChannel!!.setMethodCallHandler(::handleBleMethodCall)
    }

    override fun onResume() {
        super.onResume()
        broadcastReceiver = WifiDirectReceiver(wifiP2pManager, wifiP2pChannel, this)
        registerReceiver(broadcastReceiver, p2pIntentFilter)
    }

    override fun onPause() {
        super.onPause()
        broadcastReceiver?.let { unregisterReceiver(it) }
        broadcastReceiver = null
    }

    override fun onDestroy() {
        super.onDestroy()
        serverSocket?.close()
        serverSocket = null
        stopBleAdvertising()
    }

    // ──────────────────────────────────────────────────────────────────────────
    // BLE advertising (peripheral / GATT server)
    // ──────────────────────────────────────────────────────────────────────────

    private fun handleBleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startAdvertising" -> {
                val serviceUuid = call.argument<String>("serviceUuid") ?: run {
                    result.error("INVALID_ARGS", "serviceUuid required", null); return
                }
                val payload = call.argument<ByteArray>("payload")
                startBleAdvertising(serviceUuid, payload, result)
            }
            "stopAdvertising" -> {
                stopBleAdvertising()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun startBleAdvertising(serviceUuid: String, payload: ByteArray?, result: MethodChannel.Result) {
        val btManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val btAdapter = btManager?.adapter
        if (btAdapter == null || !btAdapter.isEnabled) {
            result.error("BT_UNAVAILABLE", "Bluetooth adapter not available or off", null)
            return
        }

        val advertiser = btAdapter.bluetoothLeAdvertiser
        if (advertiser == null) {
            result.error("BLE_NOT_SUPPORTED", "BLE advertising not supported on this device", null)
            return
        }

        stopBleAdvertising() // stop any existing session first

        val uuid = UUID.fromString(serviceUuid)

        // Open a GATT server so the service is discoverable
        bleGattServer = btManager.openGattServer(this, object : BluetoothGattServerCallback() {
            override fun onConnectionStateChange(device: android.bluetooth.BluetoothDevice, status: Int, newState: Int) {
                logDebug("BLE GATT connection state changed")
            }

            override fun onCharacteristicWriteRequest(
                device: android.bluetooth.BluetoothDevice,
                requestId: Int,
                characteristic: BluetoothGattCharacteristic,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray?
            ) {
                if (responseNeeded) {
                    // Capture the server reference stopBleAdvertising may
                    // null the field from the UI thread while this binder
                    // callback runs (third review #8).
                    val server = bleGattServer
                    server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                }
                if (value != null && value.isNotEmpty()) {
                    try {
                        val chunk = String(value, Charsets.UTF_8)
                        runOnUiThread {
                            bleChannel?.invokeMethod("onBleChunkReceived", mapOf(
                                "chunk" to chunk,
                                "deviceAddress" to device.address
                            ))
                        }
                    } catch (e: Exception) {
                        logError("BLE GATT write parse error", e)
                    }
                }
            }
        })
        bleGattServer?.addService(
            BluetoothGattService(uuid, BluetoothGattService.SERVICE_TYPE_PRIMARY).also { svc ->
                svc.addCharacteristic(
                    BluetoothGattCharacteristic(
                        UUID.fromString("12345678-1234-1234-1234-123456789def"),
                        BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_WRITE,
                        BluetoothGattCharacteristic.PERMISSION_READ or BluetoothGattCharacteristic.PERMISSION_WRITE
                    )
                )
            }
        )

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setConnectable(true)
            .setTimeout(0)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .build()

        // Main advertisement packet: service UUID only (3 flags + 18 UUID = 21 bytes, fits in 31).
        val advData = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(uuid))
            .setIncludeDeviceName(false)
            .build()

        // Scan response carries the identity payload (max 13 bytes with 128-bit UUID).
        // Dart side already truncates to 13 bytes: shortId(6) + 0x00 + name(6).
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .also { b ->
                if (payload != null && payload.size <= 13) {
                    b.addServiceData(ParcelUuid(uuid), payload)
                }
            }
            .build()

        bleAdvertiser = advertiser
        bleAdvertising = true

        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
                logDebug("BLE advertising started")
                runOnUiThread { result.success(true) }
            }
            override fun onStartFailure(errorCode: Int) {
                logError("BLE advertising failed")
                bleAdvertising = false
                runOnUiThread { result.error("ADV_FAILED", "errorCode=$errorCode", null) }
            }
        }
        advertiser.startAdvertising(settings, advData, scanResponse, callback)
    }

    private fun stopBleAdvertising() {
        if (bleAdvertising) {
            bleAdvertiser?.stopAdvertising(object : AdvertiseCallback() {})
            bleAdvertising = false
        }
        bleGattServer?.close()
        bleGattServer = null
        bleAdvertiser = null
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Method channel dispatch
    // ──────────────────────────────────────────────────────────────────────────

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize"    -> cmdInitialize(result)
            "discoverPeers" -> cmdDiscoverPeers(result)
            "connect"       -> cmdConnect(call, result)
            "sendData"      -> cmdSendData(call, result)
            "disconnect"    -> cmdDisconnect(result)
            else            -> result.notImplemented()
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Commands
    // ──────────────────────────────────────────────────────────────────────────

    private fun cmdInitialize(result: MethodChannel.Result) {
        if (serverSocket?.isClosed == false) {
            result.success(true)
            return
        }
        thread(name = "wd-server") {
            try {
                serverSocket = ServerSocket(P2P_PORT)
                logDebug("WiFi Direct server listening")
                runOnUiThread { result.success(true) }
                while (true) {
                    val server = serverSocket
                    if (server == null || server.isClosed) break
                    try {
                        val client = server.accept()
                        if (!inboundPermits.tryAcquire()) {
                            logWarn("WiFi Direct inbound connection cap reached; rejecting")
                            try { client.close() } catch (_: IOException) {}
                            continue
                        }
                        clientExecutor.execute {
                            try {
                                handleIncomingConnection(client)
                            } finally {
                                inboundPermits.release()
                            }
                        }
                    } catch (e: IOException) {
                        if (server.isClosed.not()) logError("WiFi Direct accept error", e)
                    }
                }
            } catch (e: IOException) {
                logError("WiFi Direct server socket failed", e)
                runOnUiThread { result.success(false) }
            }
        }
    }

    private fun cmdDiscoverPeers(result: MethodChannel.Result) {
        wifiP2pManager.discoverPeers(wifiP2pChannel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                logDebug("WiFi Direct discovery initiated")
                result.success(null)
            }
            override fun onFailure(reason: Int) {
                logError("WiFi Direct discovery failed")
                result.error("DISCOVERY_FAILED", "reason=$reason", null)
            }
        })
    }

    private fun cmdConnect(call: MethodCall, result: MethodChannel.Result) {
        val deviceAddress = call.argument<String>("deviceAddress")
        if (deviceAddress.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "deviceAddress required", null)
            return
        }
        val config = WifiP2pConfig().apply { this.deviceAddress = deviceAddress }
        wifiP2pManager.connect(wifiP2pChannel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                logDebug("WiFi Direct connect initiated")
                result.success(null)
            }
            override fun onFailure(reason: Int) {
                logError("WiFi Direct connect failed")
                result.error("CONNECT_FAILED", "reason=$reason", null)
                runOnUiThread { methodChannel.invokeMethod("onConnectionFailed", reason) }
            }
        })
    }

    private fun cmdSendData(call: MethodCall, result: MethodChannel.Result) {
        val data = call.argument<ByteArray>("data")
        if (data == null) {
            result.error("INVALID_ARGS", "data required", null)
            return
        }
        if (data.isEmpty() || data.size > MAX_PAYLOAD) {
            result.error("PAYLOAD_TOO_LARGE", "payload too large", null)
            return
        }
        val recipientIP = call.argument<String>("recipientIP")

        // Build the list of targets:
        //   • explicit recipientIP always wins
        //   • group owner broadcasts to all known clients
        //   • client always sends to group owner
        val targets: List<String> = when {
            !recipientIP.isNullOrEmpty()    -> listOf(recipientIP)
            isGroupOwner                    -> connectedClients.keys.toList()
            !groupOwnerAddress.isNullOrEmpty() -> listOf(groupOwnerAddress!!)
            else                            -> emptyList()
        }

        // Only send into the WiFi Direct group subnet (audit M-4) fail
        // closed when the group subnet is not (yet) known.
        val prefix = p2pSubnetPrefix
        val safeTargets = if (prefix == null) {
            emptyList()
        } else {
            targets.filter { it.startsWith("$prefix.") }
        }

        if (safeTargets.isEmpty()) {
            result.error("NO_PEER", "No connected peers to send to", null)
            return
        }

        thread(name = "wd-send") {
            var allOk = true
            for (ip in safeTargets) {
                try {
                    Socket(ip, P2P_PORT).use { sock ->
                        val out = DataOutputStream(sock.getOutputStream())
                        out.writeInt(data.size)
                        out.write(data)
                        out.flush()
                    }
                } catch (e: IOException) {
                    logError("WiFi Direct send failed", e)
                    allOk = false
                }
            }
            runOnUiThread {
                if (allOk) result.success(true)
                else result.error("SEND_FAILED", "One or more sends failed", null)
            }
        }
    }

    private fun cmdDisconnect(result: MethodChannel.Result) {
        serverSocket?.close()
        serverSocket = null
        connectedClients.clear()

        wifiP2pManager.removeGroup(wifiP2pChannel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                isGroupOwner = false
                groupOwnerAddress = null
                logDebug("WiFi Direct group removed")
                result.success(null)
                methodChannel.invokeMethod("onDisconnected", null)
            }
            override fun onFailure(reason: Int) {
                // Not in a group is not a hard error on the Dart side.
                logWarn("WiFi Direct removeGroup failed")
                isGroupOwner = false
                groupOwnerAddress = null
                result.success(null)
                methodChannel.invokeMethod("onDisconnected", null)
            }
        })
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Incoming-connection handler (runs on background thread)
    // ──────────────────────────────────────────────────────────────────────────

    private fun handleIncomingConnection(socket: Socket) {
        val senderIP = socket.inetAddress.hostAddress ?: ""

        // Reject connections from outside the WiFi Direct group subnet
        // (audit M-4) fail closed when the group subnet is unknown.
        val prefix = p2pSubnetPrefix
        if (prefix == null || !senderIP.startsWith("$prefix.")) {
            logWarn("Rejected WiFi Direct connection from outside the group subnet")
            try { socket.close() } catch (_: IOException) {}
            return
        }

        if (senderIP.isNotEmpty()) {
            val now = System.currentTimeMillis()
            // Prune clients not seen recently so the broadcast set cannot
            // grow without bound (audit L-2).
            connectedClients.entries.removeIf { now - it.value > CLIENT_TTL_MS }
            connectedClients[senderIP] = now
        }
        try {
            socket.soTimeout = 10_000 // 10 s prevent threads from blocking forever
            val input = DataInputStream(socket.getInputStream())
            val length = input.readInt()
            if (length <= 0 || length > MAX_PAYLOAD) {
                logWarn("Rejected WiFi Direct packet with invalid length")
                socket.close()
                return
            }
            val data = ByteArray(length)
            input.readFully(data)
            socket.close()
            runOnUiThread {
                methodChannel.invokeMethod(
                    "onDataReceived",
                    mapOf("data" to data, "senderIP" to senderIP)
                )
            }
        } catch (e: IOException) {
            logError("WiFi Direct incoming connection error", e)
            try { socket.close() } catch (_: IOException) {}
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Called by WifiDirectReceiver (on main thread via requestPeers callback)
    // ──────────────────────────────────────────────────────────────────────────

    fun onPeersDiscovered(peers: WifiP2pDeviceList) {
        val list = peers.deviceList.map { d ->
            mapOf(
                "deviceName"    to d.deviceName,
                "deviceAddress" to d.deviceAddress,
                "status"        to d.status.toString()
            )
        }
        methodChannel.invokeMethod("onPeersDiscovered", list)
    }

    fun onConnectionInfoAvailable(info: WifiP2pInfo) {
        if (!info.groupFormed) {
            onWifiDirectDisconnected()
            return
        }
        isGroupOwner = info.isGroupOwner
        // Derive the WiFi Direct group subnet from the group owner's address
        // so incoming connections can be scoped to the group (audit M-4).
        p2pSubnetPrefix = info.groupOwnerAddress?.hostAddress
            ?.split(".")?.takeIf { it.size == 4 }
            ?.let { "${it[0]}.${it[1]}.${it[2]}" }
        // Clients route all outbound traffic to the group owner's IP.
        // Group owner uses null so cmdSendData broadcasts to connectedClients.
        groupOwnerAddress = if (info.isGroupOwner) null else info.groupOwnerAddress?.hostAddress

        logDebug("WiFi Direct connection info available")

        methodChannel.invokeMethod(
            "onConnectionEstablished",
            mapOf(
                "isGroupOwner" to isGroupOwner,
                "address"      to (groupOwnerAddress ?: "")
            )
        )
    }

    fun onWifiDirectDisconnected() {
        isGroupOwner = false
        groupOwnerAddress = null
        p2pSubnetPrefix = null
        connectedClients.clear()
        methodChannel.invokeMethod("onDisconnected", null)
    }
}

// ────────────────────────────────────────────────────────────────────────────
// BroadcastReceiver for WiFi P2P system events
// ────────────────────────────────────────────────────────────────────────────

class WifiDirectReceiver(
    private val manager: WifiP2pManager,
    private val channel: WifiP2pManager.Channel,
    private val activity: MainActivity,
) : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                manager.requestPeers(channel, activity::onPeersDiscovered)
            }
            WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                // Always request fresh info rather than relying on deprecated NetworkInfo extra.
                manager.requestConnectionInfo(channel, activity::onConnectionInfoAvailable)
            }
        }
    }
}
