package com.example.ahoy

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

    companion object {
        private const val WD_CHANNEL  = "wifi_direct"
        private const val BLE_CHANNEL = "ble_advertiser"
        private const val TAG = "Ahoy"
        private const val P2P_PORT = 8765
        private const val MAX_PAYLOAD = 10 * 1024 * 1024 // 10 MB guard
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

    // IPs of clients that have connected to our server socket (group-owner side).
    private val connectedClients = mutableSetOf<String>()

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
                Log.d(TAG, "BLE GATT connection: ${device.address} state=$newState")
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
                    bleGattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
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
                        Log.e(TAG, "BLE GATT write parse error: $e")
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
                Log.d(TAG, "BLE advertising started")
                runOnUiThread { result.success(true) }
            }
            override fun onStartFailure(errorCode: Int) {
                Log.e(TAG, "BLE advertising failed: errorCode=$errorCode")
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
        if (serverSocket != null && !serverSocket!!.isClosed) {
            result.success(true)
            return
        }
        thread(name = "wd-server") {
            try {
                serverSocket = ServerSocket(P2P_PORT)
                Log.d(TAG, "Listening on port $P2P_PORT")
                runOnUiThread { result.success(true) }
                while (!serverSocket!!.isClosed) {
                    try {
                        val client = serverSocket!!.accept()
                        thread(name = "wd-client") { handleIncomingConnection(client) }
                    } catch (e: IOException) {
                        if (serverSocket?.isClosed == false) Log.e(TAG, "accept() error: $e")
                    }
                }
            } catch (e: IOException) {
                Log.e(TAG, "ServerSocket failed: $e")
                runOnUiThread { result.success(false) }
            }
        }
    }

    private fun cmdDiscoverPeers(result: MethodChannel.Result) {
        wifiP2pManager.discoverPeers(wifiP2pChannel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "Discovery initiated")
                result.success(null)
            }
            override fun onFailure(reason: Int) {
                Log.e(TAG, "discoverPeers failed: reason=$reason")
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
                Log.d(TAG, "Connect initiated → $deviceAddress")
                result.success(null)
            }
            override fun onFailure(reason: Int) {
                Log.e(TAG, "connect failed: reason=$reason")
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
        val recipientIP = call.argument<String>("recipientIP")

        // Build the list of targets:
        //   • explicit recipientIP always wins
        //   • group owner broadcasts to all known clients
        //   • client always sends to group owner
        val targets: List<String> = when {
            !recipientIP.isNullOrEmpty()    -> listOf(recipientIP)
            isGroupOwner                    -> connectedClients.toList()
            !groupOwnerAddress.isNullOrEmpty() -> listOf(groupOwnerAddress!!)
            else                            -> emptyList()
        }

        if (targets.isEmpty()) {
            result.error("NO_PEER", "No connected peers to send to", null)
            return
        }

        thread(name = "wd-send") {
            var allOk = true
            for (ip in targets) {
                try {
                    Socket(ip, P2P_PORT).use { sock ->
                        val out = DataOutputStream(sock.getOutputStream())
                        out.writeInt(data.size)
                        out.write(data)
                        out.flush()
                    }
                } catch (e: IOException) {
                    Log.e(TAG, "Send to $ip failed: $e")
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
                Log.d(TAG, "Group removed")
                result.success(null)
                methodChannel.invokeMethod("onDisconnected", null)
            }
            override fun onFailure(reason: Int) {
                // Not in a group is not a hard error on the Dart side.
                Log.w(TAG, "removeGroup failed (may not be in a group): reason=$reason")
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
        if (senderIP.isNotEmpty()) connectedClients.add(senderIP)
        try {
            val input = DataInputStream(socket.getInputStream())
            val length = input.readInt()
            if (length <= 0 || length > MAX_PAYLOAD) {
                Log.w(TAG, "Rejected packet: invalid length=$length from $senderIP")
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
            Log.e(TAG, "handleIncomingConnection error ($senderIP): $e")
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
        // Clients route all outbound traffic to the group owner's IP.
        // Group owner uses null so cmdSendData broadcasts to connectedClients.
        groupOwnerAddress = if (info.isGroupOwner) null else info.groupOwnerAddress?.hostAddress

        Log.d(TAG, "Connection: isGroupOwner=$isGroupOwner groupOwnerAddress=$groupOwnerAddress")

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
