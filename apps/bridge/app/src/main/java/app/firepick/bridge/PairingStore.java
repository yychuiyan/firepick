package app.firepick.bridge;

import android.content.Context;
import android.content.SharedPreferences;

import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.LinkedHashSet;
import java.util.Set;

public final class PairingStore {
    private static final int MAX_DEVICES = 8;
    private static final String PREFS = "firepick_bridge";
    private static final String TOKENS = "tokens";

    private final SharedPreferences preferences;
    private final SecureRandom random = new SecureRandom();
    private volatile String code;
    private volatile long codeExpiresAt;

    public PairingStore(Context context) {
        preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        rotateCode();
    }

    public synchronized String rotateCode() {
        code = String.format("%06d", random.nextInt(1_000_000));
        codeExpiresAt = System.currentTimeMillis() + 10 * 60_000L;
        return code;
    }

    public synchronized String claim(String suppliedCode) throws SecurityException {
        if (code == null || System.currentTimeMillis() > codeExpiresAt
            || !MessageDigest.isEqual(code.getBytes(), suppliedCode.getBytes())) {
            throw new SecurityException("pairing_code_invalid");
        }
        byte[] bytes = new byte[32];
        random.nextBytes(bytes);
        String token = toHex(bytes);
        Set<String> tokens = new LinkedHashSet<>(preferences.getStringSet(TOKENS, Set.of()));
        if (tokens.size() >= MAX_DEVICES) throw new IllegalStateException("too_many_devices");
        tokens.add(hash(token));
        preferences.edit().putStringSet(TOKENS, tokens).apply();
        code = null;
        return token;
    }

    public boolean authorize(String token) {
        if (token == null || token.isBlank()) return false;
        Set<String> tokens = preferences.getStringSet(TOKENS, Set.of());
        return tokens.contains(hash(token));
    }

    public synchronized String currentCode() {
        return code == null ? rotateCode() : code;
    }

    public synchronized String resetTokens() {
        preferences.edit().remove(TOKENS).apply();
        return rotateCode();
    }

    private static String hash(String value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                .digest(value.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            return toHex(digest);
        } catch (Exception impossible) {
            throw new IllegalStateException(impossible);
        }
    }

    private static String toHex(byte[] value) {
        StringBuilder builder = new StringBuilder(value.length * 2);
        for (byte item : value) builder.append(String.format("%02x", item));
        return builder.toString();
    }
}

