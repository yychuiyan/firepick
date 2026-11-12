package app.firepick.bridge;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.IBinder;

import com.github.catvod.Runtime;

public final class BridgeService extends Service {
    static final String ACTION_RESET_PAIRINGS = "app.firepick.bridge.RESET_PAIRINGS";
    private BridgeServer server;
    private NsdManager.RegistrationListener registration;

    @Override
    public void onCreate() {
        super.onCreate();
        String channel = "firepick_bridge";
        getSystemService(NotificationManager.class).createNotificationChannel(
            new NotificationChannel(channel, "Firepick Bridge", NotificationManager.IMPORTANCE_LOW)
        );
        startForeground(1, new Notification.Builder(this, channel)
            .setContentTitle("拾萤 Bridge 正在运行")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .build());
        try {
            PairingStore pairing = new PairingStore(this);
            Runtime.set(this);
            Runtime.setToast(text -> android.util.Log.i("FirepickBridge", text));
            server = new BridgeServer(getFilesDir(), pairing, new FongmiProviderRuntime(this));
            server.start();
            BridgeState.get().update(
                server.address(),
                server.fingerprint(),
                pairing.currentCode(),
                server.pairingURI(),
                true
            );
            registerBonjour(server);
        } catch (Exception error) {
            BridgeState.get().update("", "", "", "", false);
            stopSelf();
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_RESET_PAIRINGS.equals(intent.getAction()) && server != null) {
            server.resetPairings();
            try {
                BridgeState.get().update(
                    server.address(),
                    server.fingerprint(),
                    server.pairingCode(),
                    server.pairingURI(),
                    true
                );
            } catch (Exception error) {
                BridgeState.get().update("", "", "", "", false);
            }
        }
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        if (registration != null) {
            getSystemService(NsdManager.class).unregisterService(registration);
            registration = null;
        }
        if (server != null) server.close();
        BridgeState.get().update("", "", "", "", false);
        super.onDestroy();
    }

    private void registerBonjour(BridgeServer server) {
        NsdServiceInfo info = new NsdServiceInfo();
        info.setServiceName("Firepick Bridge");
        info.setServiceType("_firepick._tcp.");
        info.setPort(Integer.parseInt(server.address().replaceAll(".*:", "")));
        info.setAttribute("pin", server.fingerprint());
        NsdManager manager = getSystemService(NsdManager.class);
        registration = new NsdManager.RegistrationListener() {
            @Override public void onServiceRegistered(NsdServiceInfo value) {}
            @Override public void onRegistrationFailed(NsdServiceInfo value, int errorCode) {}
            @Override public void onServiceUnregistered(NsdServiceInfo value) {}
            @Override public void onUnregistrationFailed(NsdServiceInfo value, int errorCode) {}
        };
        manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration);
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}

