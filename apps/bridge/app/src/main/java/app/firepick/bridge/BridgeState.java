package app.firepick.bridge;

import java.util.Collections;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

public final class BridgeState {
    private static final BridgeState INSTANCE = new BridgeState();

    private final List<Listener> listeners = new CopyOnWriteArrayList<>();
    private volatile String address = "";
    private volatile String fingerprint = "";
    private volatile String pairingCode = "";
    private volatile String pairingURI = "";
    private volatile boolean running;

    private BridgeState() {}

    public static BridgeState get() {
        return INSTANCE;
    }

    public void update(String address, String fingerprint, String pairingCode, String pairingURI, boolean running) {
        this.address = address;
        this.fingerprint = fingerprint;
        this.pairingCode = pairingCode;
        this.pairingURI = pairingURI;
        this.running = running;
        for (Listener listener : listeners) listener.onChanged();
    }

    public String getAddress() { return address; }
    public String getFingerprint() { return fingerprint; }
    public String getPairingCode() { return pairingCode; }
    public String getPairingURI() { return pairingURI; }
    public boolean isRunning() { return running; }

    public void addListener(Listener listener) {
        listeners.add(listener);
    }

    public void removeListener(Listener listener) {
        listeners.remove(listener);
    }

    public interface Listener {
        void onChanged();
    }
}

