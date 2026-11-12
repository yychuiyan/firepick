package app.firepick.bridge;

import java.security.MessageDigest;

public final class ConfigurationDigest {
    private ConfigurationDigest() {}

    public static String sha256(byte[] data) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(data);
            StringBuilder builder = new StringBuilder(digest.length * 2);
            for (byte item : digest) builder.append(String.format("%02x", item));
            return builder.toString();
        } catch (Exception impossible) {
            throw new IllegalStateException(impossible);
        }
    }
}

