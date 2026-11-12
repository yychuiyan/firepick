package app.firepick.bridge;

import org.bouncycastle.asn1.x500.X500Name;
import org.bouncycastle.cert.X509CertificateHolder;
import org.bouncycastle.cert.X509v3CertificateBuilder;
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter;
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder;
import org.bouncycastle.jce.provider.BouncyCastleProvider;
import org.bouncycastle.operator.ContentSigner;
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.math.BigInteger;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.Security;
import java.security.cert.X509Certificate;
import java.util.Date;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;

public final class TlsMaterial {
    public final SSLContext context;
    public final String fingerprint;

    private TlsMaterial(SSLContext context, String fingerprint) {
        this.context = context;
        this.fingerprint = fingerprint;
    }

    public static TlsMaterial loadOrCreate(File directory) throws Exception {
        if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
            Security.addProvider(new BouncyCastleProvider());
        }
        File file = new File(directory, "bridge.p12");
        char[] password = "firepick-local-bridge".toCharArray();
        KeyStore keyStore = KeyStore.getInstance("PKCS12");

        if (file.isFile()) {
            try (FileInputStream input = new FileInputStream(file)) {
                keyStore.load(input, password);
            }
        } else {
            KeyPair pair = generate();
            X509Certificate certificate = certificate(pair);
            keyStore.load(null, password);
            keyStore.setKeyEntry("bridge", pair.getPrivate(), password, new java.security.cert.Certificate[]{certificate});
            try (FileOutputStream output = new FileOutputStream(file)) {
                keyStore.store(output, password);
            }
        }

        X509Certificate certificate = (X509Certificate) keyStore.getCertificate("bridge");
        String fingerprint = toHex(MessageDigest.getInstance("SHA-256").digest(certificate.getEncoded()));
        KeyManagerFactory managers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        managers.init(keyStore, password);
        SSLContext context = SSLContext.getInstance("TLS");
        context.init(managers.getKeyManagers(), null, null);
        return new TlsMaterial(context, fingerprint);
    }

    private static KeyPair generate() throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        return generator.generateKeyPair();
    }

    private static X509Certificate certificate(KeyPair pair) throws Exception {
        long now = System.currentTimeMillis();
        X500Name name = new X500Name("CN=Firepick Bridge");
        X509v3CertificateBuilder builder = new JcaX509v3CertificateBuilder(
            name,
            new BigInteger(64, new java.security.SecureRandom()),
            new Date(now - 60_000),
            new Date(now + 10L * 365 * 24 * 60 * 60 * 1000),
            name,
            pair.getPublic()
        );
        ContentSigner signer = new JcaContentSignerBuilder("SHA256withRSA").build(pair.getPrivate());
        X509CertificateHolder holder = builder.build(signer);
        return new JcaX509CertificateConverter().getCertificate(holder);
    }

    private static String toHex(byte[] value) {
        StringBuilder builder = new StringBuilder(value.length * 2);
        for (byte item : value) builder.append(String.format("%02x", item));
        return builder.toString();
    }
}

