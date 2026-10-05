package me.efesser.flauncher;

import android.content.Context;
import android.util.Base64;

import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.math.BigInteger;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.PrivateKey;
import java.security.interfaces.RSAPublicKey;
import java.security.spec.PKCS8EncodedKeySpec;
import java.security.spec.X509EncodedKeySpec;

import javax.crypto.Cipher;

/**
 * Minimal ADB client for the TV's own adbd (adb tcpip on 127.0.0.1:5555), ported from
 * genguzzz/skyworth-tv remote-keys. Used as a fallback to read /proc/stat when SELinux denies it.
 * adbd runs commands as the shell user.
 *
 * The TV has ro.adb.secure=1: the first connection shows "allow USB debugging?" on screen with
 * this app's key; after "always allow" later connections authenticate silently.
 */
final class LocalAdb implements AutoCloseable {
    private static final int A_CNXN = 0x4e584e43;
    private static final int A_AUTH = 0x48545541;
    private static final int A_OPEN = 0x4e45504f;
    private static final int A_OKAY = 0x59414b4f;
    private static final int A_CLSE = 0x45534c43;
    private static final int A_WRTE = 0x45545257;
    private static final int VERSION = 0x01000001;
    private static final int MAX_DATA = 256 * 1024;
    private static final int AUTH_TOKEN = 1;
    private static final int AUTH_SIGNATURE = 2;
    private static final int AUTH_RSAPUBLICKEY = 3;
    /** DER prefix of a SHA-1 DigestInfo: adbd verifies the token as if it were a SHA-1 digest. */
    private static final byte[] SHA1_PREFIX = {
            0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14};

    static final int PORT = 5555;

    private final Socket socket;
    private final DataInputStream in;
    private final OutputStream out;
    private int nextLocalId = 1;

    private static final class Msg {
        int cmd, arg0, arg1;
        byte[] data;
    }

    interface Listener {
        /** Called when adbd asks the user to accept our key on screen. */
        void onAwaitingApproval();
    }

    private LocalAdb(Socket s) throws IOException {
        socket = s;
        in = new DataInputStream(s.getInputStream());
        out = s.getOutputStream();
    }

    /** Connects and authenticates; waits up to {@code approvalMs} for the user to accept the key. */
    static LocalAdb connect(Context c, Listener listener, int approvalMs) throws Exception {
        KeyPair keys = keys(c);
        Socket s = new Socket();
        s.connect(new InetSocketAddress("127.0.0.1", PORT), 3000);
        s.setSoTimeout(5000);
        LocalAdb adb = new LocalAdb(s);
        try {
            adb.send(A_CNXN, VERSION, MAX_DATA, "host::\0".getBytes(StandardCharsets.UTF_8));
            boolean signed = false;
            while (true) {
                Msg m = adb.read();
                if (m.cmd == A_CNXN) return adb;
                if (m.cmd != A_AUTH || m.arg0 != AUTH_TOKEN) throw new IOException("unexpected " + m.cmd);
                if (!signed) {
                    adb.send(A_AUTH, AUTH_SIGNATURE, 0, sign(keys.getPrivate(), m.data));
                    signed = true;
                } else {
                    // Key not known yet: offer it, adbd shows the confirmation dialog.
                    adb.send(A_AUTH, AUTH_RSAPUBLICKEY, 0, publicKeyBlob((RSAPublicKey) keys.getPublic()));
                    if (listener != null) listener.onAwaitingApproval();
                    s.setSoTimeout(approvalMs);
                    Msg ok = adb.read();
                    if (ok.cmd != A_CNXN) throw new IOException("key not accepted");
                    s.setSoTimeout(5000);
                    return adb;
                }
            }
        } catch (Exception e) {
            adb.close();
            throw e;
        }
    }

    /** Runs a shell command and returns its output (stdout and stderr). */
    String shell(String command) throws IOException {
        int local = nextLocalId++;
        send(A_OPEN, local, 0, ("shell:" + command + "\0").getBytes(StandardCharsets.UTF_8));
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        socket.setSoTimeout(30000);
        while (true) {
            Msg m = read();
            if (m.arg1 != local) continue;
            if (m.cmd == A_WRTE) {
                buf.write(m.data);
                send(A_OKAY, local, m.arg0, null);
            } else if (m.cmd == A_CLSE) {
                send(A_CLSE, local, m.arg0, null);
                break;
            }
        }
        return new String(buf.toByteArray(), StandardCharsets.UTF_8);
    }

    @Override
    public void close() {
        try {
            socket.close();
        } catch (IOException ignored) {
        }
    }

    private void send(int cmd, int arg0, int arg1, byte[] data) throws IOException {
        int len = data == null ? 0 : data.length;
        int sum = 0;
        for (int i = 0; i < len; i++) sum += data[i] & 0xff;
        ByteBuffer b = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN);
        b.putInt(cmd).putInt(arg0).putInt(arg1).putInt(len).putInt(sum).putInt(~cmd);
        out.write(b.array());
        if (len > 0) out.write(data);
        out.flush();
    }

    private Msg read() throws IOException {
        byte[] h = new byte[24];
        in.readFully(h);
        ByteBuffer b = ByteBuffer.wrap(h).order(ByteOrder.LITTLE_ENDIAN);
        Msg m = new Msg();
        m.cmd = b.getInt();
        m.arg0 = b.getInt();
        m.arg1 = b.getInt();
        int len = b.getInt();
        m.data = new byte[len];
        in.readFully(m.data);
        return m;
    }

    private static byte[] sign(PrivateKey key, byte[] token) throws Exception {
        Cipher c = Cipher.getInstance("RSA/ECB/PKCS1Padding");
        c.init(Cipher.ENCRYPT_MODE, key);
        c.update(SHA1_PREFIX);
        return c.doFinal(token);
    }

    /** adbd's key format: base64 of the mincrypt RSAPublicKey struct, then " user@host". */
    private static byte[] publicKeyBlob(RSAPublicKey pub) {
        final int words = 2048 / 32;
        BigInteger n = pub.getModulus();
        BigInteger r32 = BigInteger.ONE.shiftLeft(32);
        BigInteger n0inv = n.remainder(r32).modInverse(r32).negate().mod(r32);
        BigInteger rr = BigInteger.ONE.shiftLeft(4096).mod(n);
        ByteBuffer b = ByteBuffer.allocate(4 + 4 + words * 4 * 2 + 4).order(ByteOrder.LITTLE_ENDIAN);
        b.putInt(words);
        b.putInt(n0inv.intValue());
        putWords(b, n, words);
        putWords(b, rr, words);
        b.putInt(pub.getPublicExponent().intValue());
        String s = Base64.encodeToString(b.array(), Base64.NO_WRAP) + " flauncher@tv\0";
        return s.getBytes(StandardCharsets.UTF_8);
    }

    private static void putWords(ByteBuffer b, BigInteger v, int words) {
        BigInteger mask = BigInteger.ONE.shiftLeft(32).subtract(BigInteger.ONE);
        for (int i = 0; i < words; i++) {
            b.putInt(v.shiftRight(i * 32).and(mask).intValue());
        }
    }

    private static synchronized KeyPair keys(Context c) throws Exception {
        File priv = new File(c.getFilesDir(), "adbkey");
        File pub = new File(c.getFilesDir(), "adbkey.pub");
        KeyFactory kf = KeyFactory.getInstance("RSA");
        if (priv.exists() && pub.exists()) {
            return new KeyPair(kf.generatePublic(new X509EncodedKeySpec(readAll(pub))),
                    kf.generatePrivate(new PKCS8EncodedKeySpec(readAll(priv))));
        }
        KeyPairGenerator g = KeyPairGenerator.getInstance("RSA");
        g.initialize(2048);
        KeyPair kp = g.generateKeyPair();
        writeAll(priv, kp.getPrivate().getEncoded());
        writeAll(pub, kp.getPublic().getEncoded());
        return kp;
    }

    private static byte[] readAll(File f) throws IOException {
        try (InputStream is = new FileInputStream(f)) {
            ByteArrayOutputStream o = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = is.read(buf)) > 0) o.write(buf, 0, n);
            return o.toByteArray();
        }
    }

    private static void writeAll(File f, byte[] data) throws IOException {
        try (OutputStream os = new FileOutputStream(f)) {
            os.write(data);
        }
    }
}
