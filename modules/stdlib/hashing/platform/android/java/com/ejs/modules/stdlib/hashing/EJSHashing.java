package com.ejs.modules.stdlib.hashing;

import com.ejs.platform.EJSContext;
import com.ejs.platform.EJSProvider;
import com.ejs.platform.EJSProviderOperation;
import com.ejs.platform.EJSProviderResponder;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class EJSHashing {
    private EJSHashing() {}

    public static boolean installIntoContext(EJSContext context) throws Exception {
        if (context == null) {
            throw new IllegalArgumentException("Context is required");
        }
        for (EJSHashingBundle.Script script : EJSHashingBundle.SCRIPTS) {
            if (!context.evaluateScript(script.source, script.name)) {
                throw new IllegalStateException("Failed to evaluate " + script.name);
            }
        }
        if (!context.registerProvider(new HashingProvider())) {
            throw new IllegalStateException("Failed to register ejs.hashing provider");
        }
        return true;
    }

    private static final class HashingProvider implements EJSProvider {
        static final String MODULE_ID = "ejs.hashing";
        private static final EJSProviderOperation IMMEDIATE_OPERATION = new EJSProviderOperation() {
            @Override
            public void cancel() {}
        };
        private static final Pattern ALGORITHM_PATTERN = Pattern.compile("\\\"algorithm\\\"\\s*:\\s*\\\"([^\\\"]*)\\\"");
        private static final Pattern ENCODING_PATTERN = Pattern.compile("\\\"encoding\\\"\\s*:\\s*\\\"([^\\\"]*)\\\"");
        private static final char[] HEX = "0123456789abcdef".toCharArray();

        @Override
        public String getModuleID() {
            return MODULE_ID;
        }

        @Override
        public EJSProviderOperation invokeMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context, EJSProviderResponder responder) {
            try {
                if (!"digest".equals(methodID)) {
                    throw new UnsupportedOperationException("Unsupported ejs.hashing method");
                }
                if (payload == null || payload.length == 0) {
                    throw new IllegalArgumentException("hash payload is required");
                }
                if (transferBuffer == null) {
                    throw new IllegalArgumentException("digest requires a transfer buffer");
                }

                String request = new String(payload, StandardCharsets.UTF_8);
                String algorithm = match(request, ALGORITHM_PATTERN, "").toLowerCase(Locale.ROOT);
                String encoding = match(request, ENCODING_PATTERN, "hex").toLowerCase(Locale.ROOT);
                MessageDigest digest = MessageDigest.getInstance(messageDigestName(algorithm));
                byte[] digestBytes = digest.digest(transferBuffer);
                String digestString;
                if ("hex".equals(encoding)) {
                    digestString = hex(digestBytes);
                } else if ("base64".equals(encoding)) {
                    digestString = android.util.Base64.encodeToString(digestBytes, android.util.Base64.NO_WRAP);
                } else {
                    throw new UnsupportedOperationException("Unsupported hash encoding");
                }
                byte[] result = ("{\"digest\":\"" + digestString + "\"}").getBytes(StandardCharsets.UTF_8);
                responder.finishWithData(result, null);
            } catch (Exception error) {
                responder.finishWithData(null, error);
            }
            return IMMEDIATE_OPERATION;
        }

        private static String match(String source, Pattern pattern, String fallback) {
            Matcher matcher = pattern.matcher(source);
            return matcher.find() ? matcher.group(1) : fallback;
        }

        private static String messageDigestName(String algorithm) {
            if ("sha256".equals(algorithm)) {
                return "SHA-256";
            }
            if ("sha512".equals(algorithm)) {
                return "SHA-512";
            }
            throw new UnsupportedOperationException("Unsupported hash algorithm");
        }

        private static String hex(byte[] bytes) {
            char[] output = new char[bytes.length * 2];
            for (int i = 0; i < bytes.length; i++) {
                int value = bytes[i] & 0xff;
                output[i * 2] = HEX[value >>> 4];
                output[i * 2 + 1] = HEX[value & 0x0f];
            }
            return new String(output);
        }
    }
}
