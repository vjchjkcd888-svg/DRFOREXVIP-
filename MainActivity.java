package com.test;

import com.google.firebase.database.DataSnapshot;
import com.google.firebase.database.DatabaseError;
import com.google.firebase.database.DatabaseReference;
import com.google.firebase.database.FirebaseDatabase;
import com.google.firebase.database.ValueEventListener;

import android.app.Activity;
import android.app.AlarmManager;
import android.app.AlertDialog;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.provider.Settings;
import android.util.Log;
import android.view.View;
import android.widget.ProgressBar;
import android.widget.EditText;
import android.widget.TextView;
import android.widget.Toast;

import androidx.core.app.NotificationCompat;

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import javax.net.ssl.HttpsURLConnection;
import java.util.LinkedHashMap;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

import org.json.JSONObject;

import rikka.shizuku.Shizuku;

public class MainActivity extends Activity {

    private static final String TAG = "PAKDOWNLOAD";

    private static native String nativeTelegramChannelUrl();

    private static final String PAK_NAME = "game_patch_4.6.1.21602-0x567843.pak";
    static { System.loadLibrary("pak_url"); }
    private static native String nativePakUrl();
    private static native String nativePrivateDownloadUrl();

    private static final String NOTIF_CH   = "gook_channel";
    private static final int    SHIZUKU_RC = 1001;
    private static final int    NOTIF_RC   = 1003;
    private static final int    USER_SERVICE_VERSION = 5;
    private static final String KEY_LOGIN_URL = "https://spider.panelvip.site/connect";
    private static final String LOGIN_CERT_PIN = "sha256//6Z1pxAYkQyi6trBKZgiOMsfP80QcZVJF9dD4o6iSUyg=";

    // ✅ مسار shell الآمن
    private static final String TMP_DIR = "/data/local/tmp";

    private static final String FULL_UA =
            "Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 "
                    + "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

    private final Region[] regions = {
            new Region(R.id.card_global,  "ببجي العالمية | Global",  "com.tencent.ig",        "GL", R.drawable.pubg_global),
            new Region(R.id.card_korea,   "ببجي الكورية | Korea",    "com.pubg.krmobile",     "KR", R.drawable.pubg_korea),
            new Region(R.id.card_taiwan,  "ببجي التايوانية | Taiwan", "com.rekoo.pubgm", "TW", R.drawable.pubg_taiwan),
            new Region(R.id.card_vietnam, "ببجي الفيتنامية | Vietnam","com.vng.pubgmobile",    "VN", R.drawable.pubg_vietnam),
            new Region(R.id.card_flash, "ببجي فلاش | Flash", "com.tencent.igfit", "FL", R.drawable.pubg_flash), 
            new Region(R.id.card_india,   "ببجي الهندية | BGMI",     "com.pubg.imobile",      "IN", R.drawable.pubg_vietnam),
            
    };

    private TextView shizukuStatus, globalStatus;
    private ProgressBar progressBar;
    private boolean mainScreenVisible = false;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final LinkedHashMap<String, Runnable> expiryTasks = new LinkedHashMap<>();

    // ================= UserService =================
    private IUserService userService;
    private boolean serviceBound = false;
    private boolean serviceBinding = false;
    private boolean serviceBindFailed = false;
    private String serviceBindError = "";
    private Runnable pendingServiceAction;
    private Runnable serviceBindWatchdog;
    private boolean telegramOpenedForLaunch = false;
    private boolean shizukuPermissionRequested = false;
    private boolean shizukuListenersRegistered = false;

    private final Shizuku.OnBinderReceivedListener binderReceivedListener = () -> {
        Log.d(TAG, "Shizuku binder received");
        ui.post(() -> {
            updateShizukuStatus();
            bindUserServiceIfNeeded();
        });
    };

    private final Shizuku.OnBinderDeadListener binderDeadListener = () -> {
        Log.w(TAG, "Shizuku binder died");
        userService = null;
        serviceBound = false;
        serviceBinding = false;
        ui.post(this::updateShizukuStatus);
    };

    private final Shizuku.OnRequestPermissionResultListener permissionResultListener = (code, grant) -> {
        if (code != SHIZUKU_RC) return;
        shizukuPermissionRequested = false;
        if (grant == PackageManager.PERMISSION_GRANTED) {
            Log.d(TAG, "Shizuku permission granted");
            updateShizukuStatus();
            bindUserServiceIfNeeded();
        } else {
            Log.w(TAG, "Shizuku permission denied by user");
            updateShizukuStatus();
            showBanner("تم رفض صلاحية Shizuku. افتح تطبيق Shizuku وامنح التطبيق الصلاحية.", false);
        }
    };

    private void registerShizukuListeners() {
        if (shizukuListenersRegistered) return;
        Shizuku.addBinderReceivedListener(binderReceivedListener);
        Shizuku.addBinderDeadListener(binderDeadListener);
        Shizuku.addRequestPermissionResultListener(permissionResultListener);
        shizukuListenersRegistered = true;
    }

    private void unregisterShizukuListeners() {
        if (!shizukuListenersRegistered) return;
        Shizuku.removeBinderReceivedListener(binderReceivedListener);
        Shizuku.removeBinderDeadListener(binderDeadListener);
        Shizuku.removeRequestPermissionResultListener(permissionResultListener);
        shizukuListenersRegistered = false;
    }

    private final Shizuku.UserServiceArgs userServiceArgs =
            new Shizuku.UserServiceArgs(
                    new ComponentName("com.test", UserService.class.getName()))
                    .daemon(false)
                    .processNameSuffix("svc")
                    .tag("com.test.user-service.diagnostic")
                    .debuggable(true)
                    .version(USER_SERVICE_VERSION);

    private final ServiceConnection serviceConnection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
            if (serviceBindWatchdog != null) ui.removeCallbacks(serviceBindWatchdog);
            userService = IUserService.Stub.asInterface(binder);
            serviceBound = true;
            serviceBinding = false;
            serviceBindFailed = false;
            serviceBindError = "";
            Log.d(TAG, "UserService connected");
            ui.post(() -> {
                updateShizukuStatus();
                if (pendingServiceAction != null) {
                    Runnable action = pendingServiceAction;
                    pendingServiceAction = null;
                    action.run();
                }
            });
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            if (serviceBindWatchdog != null) ui.removeCallbacks(serviceBindWatchdog);
            userService = null;
            serviceBound = false;
            serviceBinding = false;
            serviceBindFailed = true;
            serviceBindError = "انقطع اتصال الخدمة";
            Log.d(TAG, "UserService disconnected");
            ui.post(MainActivity.this::updateShizukuStatus);
        }
    };

    private void bindUserServiceIfNeeded() {
        if (serviceBound && userService != null) return;
        if (serviceBinding) return;

        if (!Shizuku.pingBinder()) {
            Log.w(TAG, "Shizuku binder not available");
            return;
        }

        int perm = Shizuku.checkSelfPermission();
        if (perm != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "Shizuku permission not granted, requesting...");
            if (!shizukuPermissionRequested) {
                shizukuPermissionRequested = true;
                try { Shizuku.requestPermission(SHIZUKU_RC); }
                catch (Throwable t) { Log.e(TAG, "requestPermission failed", t); }
            }
            return;
        }

        try {
            serviceBinding = true;
            serviceBindFailed = false;
            serviceBindError = "";
            Log.d(TAG, "Binding UserService...");
            Shizuku.bindUserService(userServiceArgs, serviceConnection);
            Log.i(TAG, "bindUserService call returned; waiting for service callback");
            if (serviceBindWatchdog != null) ui.removeCallbacks(serviceBindWatchdog);
            serviceBindWatchdog = () -> {
                if (!serviceBinding || userService != null) return;
                new Thread(() -> {
                    String shellResult = runShizukuShellProbe();
                    ui.post(() -> {
                        if (!serviceBinding || userService != null) return;
                        serviceBinding = false;
                        serviceBindFailed = true;
                        serviceBindError = "انتهت مهلة بدء UserService؛ فحص shell: " + shellResult;
                        Log.e(TAG, "UserService startup watchdog: " + serviceBindError);
                        pendingServiceAction = null;
                        updateShizukuStatus();
                        showBanner("تعذر بدء خدمة Shizuku. افتح سجل التشخيص للتفاصيل.", false);
                    });
                }, "shizuku-startup-probe").start();
            };
            ui.postDelayed(serviceBindWatchdog, 15000);
        } catch (Throwable t) {
            serviceBinding = false;
            serviceBindFailed = true;
            serviceBindError = t.getClass().getSimpleName() + ": " + t.getMessage();
            if (serviceBindWatchdog != null) ui.removeCallbacks(serviceBindWatchdog);
            Log.e(TAG, "bindUserService failed", t);
            updateShizukuStatus();
        }
    }

    private void waitForUserService(Runnable action) {
        if (userService != null) { action.run(); return; }
        pendingServiceAction = action;
        bindUserServiceIfNeeded();
        final long deadline = System.currentTimeMillis() + 20000;
        ui.postDelayed(new Runnable() {
            @Override public void run() {
                if (pendingServiceAction != action) return;
                if (userService != null) {
                    pendingServiceAction = null;
                    action.run();
                    return;
                }
                if (!Shizuku.pingBinder() || Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                    pendingServiceAction = null;
                    showBanner(!Shizuku.pingBinder()
                            ? "Shizuku غير متصل. شغّل الخدمة ثم أعد المحاولة."
                            : "لم تُمنح صلاحية Shizuku للتطبيق.", false);
                    return;
                }
                if (System.currentTimeMillis() >= deadline) {
                    pendingServiceAction = null;
                    String detail = serviceBindError.isEmpty() ? "لا توجد تفاصيل إضافية" : serviceBindError;
                    String shellResult = runShizukuShellProbe();
                    Log.e(TAG, "Timed out waiting for UserService. Shizuku ping="
                            + Shizuku.pingBinder() + ", permission="
                            + (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED)
                            + ", bound=" + serviceBound + ", binding=" + serviceBinding
                            + ", lastError=" + detail + ", shellProbe=" + shellResult);
                    serviceBinding = false;
                    serviceBindFailed = true;
                    serviceBindError = "انتهت المهلة؛ فحص shell: " + shellResult;
                    updateShizukuStatus();
                    showBanner("انتهت مهلة بدء خدمة التطبيق عبر Shizuku. افتح سجل التشخيص للتفاصيل.", false);
                    return;
                }
                ui.postDelayed(this, 500);
            }
        }, 500);
    }

    private IUserService requireUserService() throws IOException {
        if (userService == null) throw new IOException("UserService غير متصل");
        return userService;
    }

    private String runShizukuShellProbe() {
        try {
            String output = ShizukuShell.run("id").trim();
            return output.isEmpty() ? "بدون مخرجات" : output;
        } catch (Throwable t) {
            return t.getClass().getSimpleName() + ": " + t.getMessage();
        }
    }

    // ================= Lifecycle ======حذف===========
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        
        if (isVpnActive()) {
    Intent intent = new Intent(MainActivity.this, BlockedActivity.class);
    startActivity(intent);
    finish();
    return;
           }
        
        registerShizukuListeners();
        showLoginScreen();
        
        // --- بداية كود التحكم عن بعد ---
FirebaseDatabase database = FirebaseDatabase.getInstance();
DatabaseReference myRef = database.getReference("app_forexkk");

myRef.addValueEventListener(new ValueEventListener() {
    @Override
    public void onDataChange(DataSnapshot dataSnapshot) {
        Boolean isEnabled = dataSnapshot.getValue(Boolean.class);
        
        if (isEnabled != null && !isEnabled) {
            // الانتقال إلى شاشة الإيقاف
            Intent intent = new Intent(MainActivity.this, BlockedActivity.class);
            startActivity(intent);
            finish(); 
        }
    }

    @Override
    public void onCancelled(DatabaseError error) {
        // فشل الاتصال
    }
});
// --- نهاية كود التحكم عن بعد ---
        
        
        
myRef.addValueEventListener(new ValueEventListener() {
    @Override
    public void onDataChange(DataSnapshot dataSnapshot) {
        Boolean isEnabled = dataSnapshot.getValue(Boolean.class);
        
        if (isEnabled != null && !isEnabled) {
            // 1. التطبيق موقوف من Firebase
            Intent intent = new Intent(MainActivity.this, BlockedActivity.class);
            startActivity(intent);
            finish(); 
        } else {
            // 2. التطبيق يعمل، لكن نتحقق من البيئة الأمنية
//           if (isVpnActive() || isDeviceRooted() || isUserCertificateInstalled() || isCanaryInstalled()) { // منع دخول ورت الى التطبيق
             if (isVpnActive() || isUserCertificateInstalled() || isCanaryInstalled()) {
                // إذا كان هناك VPN، أو روت، أو شهادة مثبتة -> اعرض شاشة الإيقاف
                Intent intent = new Intent(MainActivity.this, BlockedActivity.class);
                startActivity(intent);
                finish();
            } else {
                // 3. البيئة آمنة، ابدأ الإجراءات الطبيعية
                registerShizukuListeners();
                showLoginScreen();
            }
        }
    }

    @Override
    public void onCancelled(DatabaseError error) {
        registerShizukuListeners();
        showLoginScreen();
    }
});
}
//////////////////////////
    private void showLoginScreen() {
        mainScreenVisible = false;
        setContentView(R.layout.activity_login);
        getWindow().setStatusBarColor(Color.rgb(8, 13, 33));
        getWindow().setNavigationBarColor(Color.rgb(8, 13, 33));
        getWindow().getDecorView().setSystemUiVisibility(0);

        EditText keyInput = findViewById(R.id.login_key);
        TextView loginButton = findViewById(R.id.login_button);
        TextView status = findViewById(R.id.login_status);
        ProgressBar progress = findViewById(R.id.login_progress);
        loginButton.setOnClickListener(v -> {
            String key = keyInput.getText().toString().trim();
            if (key.isEmpty()) {
                keyInput.setError("أدخل مفتاح");
                return;
            }
            loginButton.setEnabled(false);
            progress.setVisibility(View.VISIBLE);
            status.setTextColor(Color.rgb(183, 195, 220));
            status.setText("جارٍ التحقق من المفتاح عبر السيرفر...");
            authenticateKey(key, (result, message) -> {
                if (isFinishing() || isDestroyed()) return;
                progress.setVisibility(View.GONE);
                loginButton.setEnabled(true);
                if (result) {
                    status.setTextColor(Color.rgb(83, 225, 185));
                    status.setText("تم تسجيل الدخول بنجاح");
                    ui.postDelayed(this::showMainScreen, 500);
                } else {
                    status.setTextColor(Color.rgb(240, 128, 168));
                    status.setText(message);
                }
            });
        });
    }

    private interface LoginCallback { void onResult(boolean success, String message); }

    private void authenticateKey(String key, LoginCallback callback) {
        new Thread(() -> {
            boolean success = false;
            String message = "تعذر الاتصال بخادم تسجيل الدخول";
            HttpURLConnection connection = null;
            try {
                String androidId = Settings.Secure.getString(
                        getContentResolver(), Settings.Secure.ANDROID_ID);
                if (androidId == null || androidId.isEmpty()) androidId = "unknown-device";
                String hwid = key + androidId + Build.MODEL + Build.BRAND;
                String serial = md5Hex(hwid);
                String body = "game=" + URLEncoder.encode("PRO", "UTF-8")
                        + "&user_key=" + URLEncoder.encode(key, "UTF-8")
                        + "&serial=" + URLEncoder.encode(serial, "UTF-8");

                connection = (HttpURLConnection) new URL(KEY_LOGIN_URL).openConnection();
                
                // --- حماية ضد أدوات الاعتراض (Canary) ---
                if (connection instanceof javax.net.ssl.HttpsURLConnection) {
                    javax.net.ssl.HttpsURLConnection httpsConn = (javax.net.ssl.HttpsURLConnection) connection;
                    httpsConn.setSSLSocketFactory((javax.net.ssl.HttpsURLConnection.getDefaultSSLSocketFactory()));
                    // تجاهل أي شهادة غير موثوقة
                    httpsConn.setHostnameVerifier((hostname, session) -> {
                        // السماح فقط للنطاق الحقيقي الخاص بك
                        return hostname.equals("spider.panelvip.site") || hostname.endsWith(".spider.panelvip.site");
                    });
                                }
// ----------------------------------------
                
                connection.setRequestMethod("POST");
                connection.setConnectTimeout(15000);
                connection.setReadTimeout(15000);
                connection.setDoOutput(true);
                connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=utf-8");
                connection.setRequestProperty("Accept", "application/json");
                byte[] request = body.getBytes(StandardCharsets.UTF_8);
                connection.setFixedLengthStreamingMode(request.length);
                try (OutputStream out = connection.getOutputStream()) { out.write(request); }

                int code = connection.getResponseCode();

                // Certificate/Public-Key pinning for the login server.
                // The pin format is: sha256//BASE64_SHA256_OF_SPKI
                if (connection instanceof HttpsURLConnection) {
                    verifyCertificatePin((HttpsURLConnection) connection, LOGIN_CERT_PIN);
                }

                InputStream responseStream = code >= 200 && code < 300
                        ? connection.getInputStream() : connection.getErrorStream();
                if (responseStream == null) throw new IOException("HTTP " + code);
                ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                try (InputStream in = responseStream) {
                    byte[] buffer = new byte[2048];
                    int count;
                    while ((count = in.read(buffer)) != -1) bytes.write(buffer, 0, count);
                }
                JSONObject response = new JSONObject(bytes.toString("UTF-8"));
                JSONObject data = response.optJSONObject("data");
                if (code >= 200 && code < 300 && response.optBoolean("status", false)
                        && data != null && !data.optString("token", "").isEmpty()
                        && isLicenseActive(data)) {
                    success = true;
                    message = "تم تسجيل الدخول بنجاح";
                } else if (!response.optString("reason", "").isEmpty()) {
                    message = response.optString("reason");
                } else if (code < 200 || code >= 300) {
                    message = "رفض السيرفر الطلب (HTTP " + code + ")";
                } else {
                    message = "المفتاح غير صالح أو انتهت صلاحيته";
                }
            } catch (Exception e) {
                Log.e(TAG, "Server login failed", e);
            } finally {
                if (connection != null) connection.disconnect();
            }
            boolean result = success;
            String resultMessage = message;
            ui.post(() -> callback.onResult(result, resultMessage));
        }).start();
    }

    private void verifyCertificatePin(HttpsURLConnection connection, String expectedPin) throws Exception {
        Certificate[] certificates = connection.getServerCertificates();
        if (certificates == null || certificates.length == 0) {
            throw new javax.net.ssl.SSLPeerUnverifiedException("لا توجد شهادة من السيرفر");
        }

        for (Certificate certificate : certificates) {
            if (!(certificate instanceof X509Certificate)) continue;
            byte[] publicKey = ((X509Certificate) certificate).getPublicKey().getEncoded();
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(publicKey);
            String actualPin = "sha256//" + android.util.Base64.encodeToString(
                    digest, android.util.Base64.NO_WRAP);
            if (expectedPin.equals(actualPin)) return;
        }

        throw new javax.net.ssl.SSLPeerUnverifiedException(
                "فشل التحقق من بصمة شهادة السيرفر");
    }

    private boolean isLicenseActive(JSONObject data) {
        Object expiration = data.opt("rng");
        if (expiration == null) return false;
        try {
            long expirySeconds = expiration instanceof Number
                    ? ((Number) expiration).longValue()
                    : Long.parseLong(String.valueOf(expiration));
            return expirySeconds + 30L > System.currentTimeMillis() / 1000L;
        } catch (NumberFormatException e) {
            return false;
        }
    }

    private String md5Hex(String value) throws Exception {
        byte[] digest = MessageDigest.getInstance("MD5")
                .digest(value.getBytes(StandardCharsets.UTF_8));
        StringBuilder result = new StringBuilder(digest.length * 2);
        for (byte b : digest) result.append(String.format(java.util.Locale.US, "%02x", b & 0xff));
        return result.toString();
    }

    private void showMainScreen() {
        mainScreenVisible = true;
        setContentView(R.layout.activity_main);
        getWindow().setStatusBarColor(Color.rgb(8, 13, 33));
        getWindow().setNavigationBarColor(Color.rgb(8, 13, 33));
        getWindow().getDecorView().setSystemUiVisibility(0);

        shizukuStatus = findViewById(R.id.shizuku_status);
        globalStatus  = findViewById(R.id.global_status);
        progressBar   = findViewById(R.id.progress_bar);
        findViewById(R.id.download_pak_button).setOnClickListener(v -> downloadPakToPrivateStorage());
        findViewById(R.id.diagnostics_button).setOnClickListener(v -> showDiagnostics());

        if (Build.VERSION.SDK_INT >= 33)
            requestPermissions(new String[]{"android.permission.POST_NOTIFICATIONS"}, NOTIF_RC);

        updateShizukuStatus();
        bindUserServiceIfNeeded();
        for (Region r : regions) bindRegion(r);
    }

    private void showTelegramSubscriptionGate() {
        mainScreenVisible = false;
        setContentView(R.layout.activity_telegram_gate);
        getWindow().setStatusBarColor(Color.rgb(244, 240, 231));
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR);
        if (!telegramOpenedForLaunch) {
            telegramOpenedForLaunch = true;
            openTelegramChannel();
        }
        findViewById(R.id.join_telegram_button).setOnClickListener(v -> openTelegramChannel());
        findViewById(R.id.continue_button).setOnClickListener(v -> showMainScreen());
    }

    private void openTelegramChannel() {
        try {
            startActivity(new Intent(Intent.ACTION_VIEW,
                    android.net.Uri.parse(nativeTelegramChannelUrl())));
        } catch (Exception e) {
            Toast.makeText(this, "تعذر فتح رابط تلجرام", Toast.LENGTH_SHORT).show();
        }
    }

    @Override protected void onResume() {
        super.onResume();

        try {
            Log.d(TAG, "Shizuku pingBinder: " + Shizuku.pingBinder());
            if (Shizuku.pingBinder()) {
                Log.d(TAG, "Shizuku version: " + Shizuku.getVersion());
                Log.d(TAG, "Shizuku permission: " + Shizuku.checkSelfPermission());
            }
        } catch (Throwable t) {
            Log.e(TAG, "Shizuku diag failed", t);
        }

        if (mainScreenVisible) {
            updateShizukuStatus();
            bindUserServiceIfNeeded();
        }
    }

    @Override protected void onDestroy() {
        unregisterShizukuListeners();
        super.onDestroy();
        if (serviceBound) {
            try {
                Shizuku.unbindUserService(userServiceArgs, serviceConnection, true);
            } catch (Throwable ignored) {}
            serviceBound = false;
        }
    }

    // ================= ربط البطاقات =================
    private void bindRegion(Region region) {
        View card = findViewById(region.cardId);
        ((TextView) card.findViewById(R.id.region_title)).setText(region.title);
        ((TextView) card.findViewById(R.id.region_package)).setText(region.packageName);

        android.widget.ImageView icon = card.findViewById(R.id.region_icon);
        if (icon != null) icon.setImageResource(region.iconRes);

        TextView status = card.findViewById(R.id.region_status);
        if (status != null) {
            status.setText("الحماية مغلقة");
            status.setTextColor(Color.parseColor("#984555"));
        }

        card.findViewById(R.id.button_enable).setOnClickListener(v -> enableProtection(region));
        card.findViewById(R.id.button_remove).setOnClickListener(v -> disableProtection(region));
        card.findViewById(R.id.button_launch).setOnClickListener(v -> launchGame(region));
    }

    private void updateRegionStatus(Region region, boolean enabled) {
        View card = findViewById(region.cardId);
        if (card == null) return;
        TextView status = card.findViewById(R.id.region_status);
        if (status == null) return;
        if (enabled) {
            status.setText("الحماية مفعلة");
            status.setTextColor(Color.parseColor("#386B55"));
        } else {
            status.setText("الحماية مغلقة");
            status.setTextColor(Color.parseColor("#984555"));
        }
    }

    // ================= حالة Shizuku =================
    private void updateShizukuStatus() {
        if (shizukuStatus == null) return;
        try {
            if (!Shizuku.pingBinder()) {
                shizukuStatus.setText("Shizuku: غير متصل — شغّل الخدمة");
                shizukuStatus.setTextColor(Color.parseColor("#984555"));
            } else if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                shizukuStatus.setText("Shizuku: يلزم منح الصلاحية");
                shizukuStatus.setTextColor(Color.parseColor("#A87540"));
            } else if (serviceBindFailed) {
                shizukuStatus.setText("Shizuku: فشل بدء خدمة التطبيق");
                shizukuStatus.setTextColor(Color.parseColor("#984555"));
            } else if (userService == null) {
                shizukuStatus.setText("Shizuku: جارٍ الاتصال بالخدمة...");
                shizukuStatus.setTextColor(Color.parseColor("#A87540"));
            } else {
                shizukuStatus.setText("Shizuku: متصل ويعمل بنجاح");
                shizukuStatus.setTextColor(Color.parseColor("#386B55"));
            }
        } catch (Throwable t) {
            Log.e(TAG, "Unable to read Shizuku state", t);
            shizukuStatus.setText("Shizuku: تعذر التحقق من الاتصال");
            shizukuStatus.setTextColor(Color.parseColor("#984555"));
        }
    }

    // ================= فتح اللعبة =================
    private void launchGame(Region region) {
        if (!isPackageInstalled(region.packageName)) {
            showBanner("هذه النسخة غير مثبتة على جهازك!", false);
            return;
        }
        Intent i = getPackageManager().getLaunchIntentForPackage(region.packageName);
        if (i == null) {
            i = new Intent(Intent.ACTION_MAIN)
                    .addCategory(Intent.CATEGORY_LAUNCHER)
                    .setPackage(region.packageName);
        }
        i.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try { startActivity(i); }
        catch (Exception e) { showBanner("تعذر فتح اللعبة", false); }
    }

    // ================= تفعيل الحماية =================
    private void enableProtection(Region region) {
        if (!isPackageInstalled(region.packageName)) {
            showBanner("هذه النسخة (" + region.shortName + ") غير مثبتة على جهازك!", false);
            return;
        }
        if (Build.VERSION.SDK_INT >= 31) {
            AlarmManager am = (AlarmManager) getSystemService(Context.ALARM_SERVICE);
            if (am != null && !am.canScheduleExactAlarms()) {
                new AlertDialog.Builder(this)
                        .setTitle("السماح بالمنبهات الدقيقة")
                        .setMessage("يلزم منح التطبيق إذن «المنبهات والتذكيرات» لجدولة انتهاء التفعيل بعد 180 ثانية.")
                        .setPositiveButton("فتح الإعدادات", (d, w) -> {
                            Intent i = new Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM);
                            i.setData(android.net.Uri.parse("package:" + getPackageName()));
                            startActivity(i);
                        })
                        .setNegativeButton("إلغاء", null).show();
                return;
            }
        }
        ensureShizukuThen(() -> waitForUserService(() -> doEnable(region)));
    }

    // ✅ نسخة مُصلَحة — استخراج مباشر في /data/local/tmp عبر shell
    private void doEnable(Region region) {
        showProgress("جارٍ تنزيل ونقل ملفات الحماية لـ " + region.shortName + "...");
        new Thread(() -> {
            Log.d(TAG, "========== doEnable START ==========");
            Log.d(TAG, "Region: " + region.title + " | pkg: " + region.packageName);

            File appDir = getExternalFilesDir(null);
            if (appDir == null) {
                appDir = getFilesDir();
                Log.w(TAG, "getExternalFilesDir returned null, using getFilesDir");
            }
            Log.d(TAG, "appDir = " + appDir.getAbsolutePath());

            File zipTmp = new File(appDir, PAK_NAME + ".zip.tmp");

            try {
                IUserService svc = requireUserService();
                Log.d(TAG, "UserService acquired");

                // ========== 1) تنزيل ZIP ==========
                Log.d(TAG, "--- Step 1: Download ZIP ---");
                downloadPakFromNetwork(zipTmp);
                Log.d(TAG, "Downloaded ZIP: " + zipTmp.length() + " bytes");
                if (zipTmp.length() <= 0) {
                    throw new IOException("ملف ZIP فارغ بعد التنزيل");
                }

                // ========== 2) انسخ ZIP إلى /data/local/tmp ==========
                Log.d(TAG, "--- Step 2: Copy ZIP to /data/local/tmp ---");
                String zipTmpPath = TMP_DIR + "/" + PAK_NAME + ".zip";
                String cpZip = "cp -f \"" + zipTmp.getAbsolutePath() + "\" \""
                        + zipTmpPath + "\" && chmod 644 \"" + zipTmpPath + "\"";
                Log.d(TAG, "cpZip = " + cpZip);
                String cpZipResult = svc.runCommand(cpZip);
                Log.d(TAG, "cpZipResult = [" + cpZipResult + "]");

                // تحقق
                String checkZip = svc.runCommand("ls -la \"" + zipTmpPath + "\" 2>&1");
                Log.d(TAG, "checkZip = [" + checkZip + "]");

                // ========== 3) استخرج PAK مباشرة في /data/local/tmp ==========
                Log.d(TAG, "--- Step 3: Extract PAK in /data/local/tmp ---");
                String unzip = "cd " + TMP_DIR + " && "
                        + "unzip -o \"" + zipTmpPath + "\" '*/" + PAK_NAME + "' '"
                        + PAK_NAME + "' -d " + TMP_DIR
                        + " 2>&1; echo '---LS---'; ls -la " + TMP_DIR + "/";
                Log.d(TAG, "unzip = " + unzip);
                String unzipResult = svc.runCommand(unzip);
                Log.d(TAG, "unzipResult = [" + unzipResult + "]");

                // ابحث عن PAK
                String findCmd = "find " + TMP_DIR + " -name '" + PAK_NAME
                        + "' -type f 2>/dev/null | head -n 1";
                String extractedPath = svc.runCommand(findCmd).trim();
                Log.d(TAG, "extractedPath = [" + extractedPath + "]");

                // Fallback: استخراج محلي إذا فشل unzip
                if (extractedPath.isEmpty() || !extractedPath.startsWith("/")) {
                    Log.w(TAG, "unzip in tmp failed, falling back to local extraction");
                    File pakLocal = new File(appDir, PAK_NAME + ".extracted");
                    extractEntryFromZip(zipTmp, PAK_NAME, pakLocal);
                    Log.d(TAG, "Extracted locally: " + pakLocal.getAbsolutePath()
                            + " size=" + pakLocal.length());

                    String tmpPak = TMP_DIR + "/" + PAK_NAME;
                    String cpPak = "cp -f \"" + pakLocal.getAbsolutePath() + "\" \""
                            + tmpPak + "\" && chmod 644 \"" + tmpPak + "\"";
                    Log.d(TAG, "cpPak = " + cpPak);
                    String cpPakResult = svc.runCommand(cpPak);
                    Log.d(TAG, "cpPakResult = [" + cpPakResult + "]");

                    String verify = svc.runCommand("ls -la \"" + tmpPak + "\" 2>&1");
                    Log.d(TAG, "verify = [" + verify + "]");

                    if (!verify.contains(PAK_NAME)) {
                        throw new IOException("تعذر نقل PAK إلى /data/local/tmp");
                    }
                    extractedPath = tmpPak;
                    try { pakLocal.delete(); } catch (Throwable ignored) {}
                }

                Log.d(TAG, "✅ PAK ready at: " + extractedPath);

                // ========== 4) انسخ PAK إلى مجلد اللعبة ==========
                Log.d(TAG, "--- Step 4: Copy PAK to game ---");
                String parent = "/storage/emulated/0/Android/data/" + region.packageName
                        + "/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/Paks";
                String target = parent + "/" + PAK_NAME;

                svc.mkdirs(parent);
                svc.deleteFile(target);

                Log.d(TAG, "copyFile: " + extractedPath + " -> " + target);
                boolean ok = svc.copyFile(extractedPath, target);
                Log.d(TAG, "copyFile returned: " + ok);

                if (!ok) {
                    String diag = svc.runCommand(
                            "echo '---src---'; ls -la \"" + extractedPath + "\" 2>&1; "
                                    + "echo '---dst parent---'; ls -la \"" + parent + "\" 2>&1"
                    );
                    Log.e(TAG, "copyFile failed. Diagnostic:\n" + diag);
                    throw new IOException("فشل النسخ عبر UserService");
                }

                // تحقق نهائي
                String finalCheck = svc.runCommand("ls -la \"" + target + "\" 2>&1");
                Log.d(TAG, "finalCheck = [" + finalCheck + "]");

                svc.chmod(target, 0444);
                svc.chown(target);

                // ========== 5) تنظيف ==========
                Log.d(TAG, "--- Step 5: Cleanup ---");
                try { zipTmp.delete(); } catch (Throwable ignored) {}
                try { svc.deleteFile(zipTmpPath); } catch (Throwable ignored) {}
                try { svc.deleteFile(extractedPath); } catch (Throwable ignored) {}

                Log.d(TAG, "========== doEnable SUCCESS ==========");

                final Region rFinal = region;
                final String targetFinal = target;
                ui.post(() -> {
                    hideProgress();
                    updateRegionStatus(rFinal, true);
                    showBanner("تم تفعيل الحماية ✔ سيتم فتح اللعبة الآن", true);
                    sendNotification("تم تفعيل الحماية", rFinal.title + " • " + PAK_NAME);
                    scheduleExpiry(rFinal, targetFinal, 180);
                    ui.postDelayed(() -> launchGame(rFinal), 1500);
                });

            } catch (Throwable t) {
                Log.e(TAG, "doEnable FAILED", t);
                try { zipTmp.delete(); } catch (Throwable ignored) {}
                final String errMsg = t.getMessage() != null ? t.getMessage() : t.toString();
                ui.post(() -> {
                    hideProgress();
                    showBanner("فشل نقل الملف: " + errMsg, false);
                });
            }
        }).start();
    }

    // ================= تنزيل ZIP =================
    private void downloadPakFromNetwork(File dest) throws IOException {
        String urlStr = nativePakUrl();
        if (urlStr == null || urlStr.trim().isEmpty())
            throw new IOException("رابط التحميل فارغ (nativePakUrl)");
        Log.d(TAG, "Downloading ZIP from: " + urlStr);

        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) new URL(urlStr).openConnection();
            conn.setRequestMethod("GET");
            conn.setConnectTimeout(20000);
            conn.setReadTimeout(180000);
            conn.setInstanceFollowRedirects(true);
            conn.setUseCaches(false);

            conn.setRequestProperty("User-Agent", FULL_UA);
            conn.setRequestProperty("Accept", "*/*");
            conn.setRequestProperty("Accept-Language", "en-US,en;q=0.9,ar;q=0.8");
            conn.setRequestProperty("Accept-Encoding", "identity");
            conn.setRequestProperty("Connection", "keep-alive");
            conn.setRequestProperty("Cache-Control", "no-cache");

            int code = conn.getResponseCode();
            Log.d(TAG, "HTTP response code = " + code);
            if (code < 200 || code >= 300) {
                String msg = conn.getResponseMessage();
                throw new IOException("HTTP " + code + " " + (msg != null ? msg : ""));
            }

            try (InputStream in  = conn.getInputStream();
                 OutputStream out = new FileOutputStream(dest)) {
                byte[] buf = new byte[65536];
                int n;
                long total = 0;
                while ((n = in.read(buf)) != -1) {
                    out.write(buf, 0, n);
                    total += n;
                }
                Log.d(TAG, "Downloaded bytes = " + total);
            }
            if (dest.length() == 0) throw new IOException("الملف الذي تم تنزيله فارغ");
            Log.d(TAG, "ZIP downloaded size = " + dest.length());
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    // ================= استخراج PAK من ZIP (محلي) =================
    private void extractEntryFromZip(File zip, String entryName, File dest) throws IOException {
        if (!zip.exists() || zip.length() == 0)
            throw new IOException("ملف ZIP فارغ أو غير موجود");

        boolean found = false;
        try (ZipInputStream zin = new ZipInputStream(
                new BufferedInputStream(new FileInputStream(zip)));
             FileOutputStream out = new FileOutputStream(dest)) {

            ZipEntry e;
            byte[] buf = new byte[65536];
            while ((e = zin.getNextEntry()) != null) {
                String name = e.getName();
                Log.d(TAG, "ZIP entry: " + name);
                if (e.isDirectory()) continue;

                String base = name.substring(name.lastIndexOf('/') + 1);
                if (name.equals(entryName)
                        || name.endsWith("/" + entryName)
                        || base.equals(entryName)) {
                    int n;
                    while ((n = zin.read(buf)) != -1) out.write(buf, 0, n);
                    found = true;
                    break;
                }
            }
        }
        if (!found) throw new IOException("لم يتم العثور على " + entryName + " داخل الـ ZIP");
        if (dest.length() == 0) throw new IOException("الملف المستخرج فارغ");
        Log.d(TAG, "Extracted PAK size = " + dest.length());
    }

    // ================= تنزيل إلى مساحة التطبيق الخاصة =================
    private void downloadPakToPrivateStorage() {
        View downloadButton = findViewById(R.id.download_pak_button);
        downloadButton.setEnabled(false);
        showProgress("جارٍ تنزيل الملف...");
        new Thread(() -> {
            File partial    = new File(getFilesDir(), "pak.zip.part");
            File downloaded = new File(getFilesDir(), "pak.zip");
            HttpURLConnection connection = null;
            try {
                String urlStr = nativePrivateDownloadUrl();
                if (urlStr == null || urlStr.trim().isEmpty())
                    throw new IOException("رابط التحميل فارغ (nativePrivateDownloadUrl)");
                Log.d(TAG, "Private download URL: " + urlStr);

                connection = (HttpURLConnection) new URL(urlStr).openConnection();
                connection.setRequestMethod("GET");
                connection.setConnectTimeout(20000);
                connection.setReadTimeout(120000);
                connection.setInstanceFollowRedirects(true);
                connection.setUseCaches(false);

                connection.setRequestProperty("User-Agent", FULL_UA);
                connection.setRequestProperty("Accept", "*/*");
                connection.setRequestProperty("Accept-Language", "en-US,en;q=0.9,ar;q=0.8");
                connection.setRequestProperty("Accept-Encoding", "identity");
                connection.setRequestProperty("Connection", "keep-alive");

                int response = connection.getResponseCode();
                Log.d(TAG, "Private download HTTP = " + response);
                if (response < 200 || response >= 300)
                    throw new IOException("HTTP " + response);

                try (InputStream input = connection.getInputStream();
                     OutputStream output = new FileOutputStream(partial)) {
                    byte[] buffer = new byte[65536];
                    int count;
                    while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
                }
                if (partial.length() == 0) throw new IOException("الملف الذي تم تنزيله فارغ");

                if (Build.VERSION.SDK_INT >= 26) {
                    try {
                        java.nio.file.Files.move(
                                partial.toPath(),
                                downloaded.toPath(),
                                java.nio.file.StandardCopyOption.REPLACE_EXISTING);
                    } catch (Exception e) {
                        throw new IOException("تعذر حفظ الملف: " + e.getMessage());
                    }
                } else {
                    if (downloaded.exists() && !downloaded.delete())
                        throw new IOException("تعذر استبدال الملف السابق");
                    if (!partial.renameTo(downloaded))
                        throw new IOException("تعذر حفظ الملف");
                }

                ui.post(() -> showBanner("اكتمل التنزيل: " + downloaded.getAbsolutePath(), true));
            } catch (Exception error) {
                try { if (partial.exists()) partial.delete(); } catch (Throwable ignored) {}
                Log.e(TAG, "private download failed", error);
                ui.post(() -> showBanner("فشل التنزيل: " + error.getMessage(), false));
            } finally {
                if (connection != null) connection.disconnect();
                ui.post(() -> {
                    hideProgress();
                    downloadButton.setEnabled(true);
                });
            }
        }).start();
    }

    // ================= إغلاق الحماية =================
    private void disableProtection(Region region) {
        ensureShizukuThen(() -> waitForUserService(() -> new Thread(() -> {
            String target = "/storage/emulated/0/Android/data/" + region.packageName
                    + "/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/Paks/" + PAK_NAME;
            try {
                Runnable t = expiryTasks.remove(region.packageName);
                if (t != null) ui.removeCallbacks(t);

                try {
                    Intent svc = new Intent(this, PakExpiryService.class)
                            .setAction(PakExpiryService.ACTION_CANCEL)
                            .putExtra(PakExpiryService.EXTRA_PATH, target);
                    startService(svc);
                } catch (Exception ignored) {}

                IUserService svc = requireUserService();
                svc.deleteFile(target);

                ui.post(() -> {
                    updateRegionStatus(region, false);
                    showBanner("تم إغلاق الحماية " + region.shortName, true);
                    sendNotification("تم إغلاق الحماية", region.title);
                });
            } catch (Throwable e) {
                Log.e(TAG, "disable failed", e);
                ui.post(() -> showBanner("تعذر الحذف: " + e.getMessage(), false));
            }
        }).start()));
    }

    // ================= جدولة انتهاء =================
    private void scheduleExpiry(Region region, String path, int seconds) {
        Runnable task = () -> {
            try {
                if (userService != null) userService.deleteFile(path);
            } catch (Exception ignored) {}
            ui.post(() -> updateRegionStatus(region, false));
            sendNotification("انتهت مدة الحماية", region.title);
        };
        expiryTasks.put(region.packageName, task);
        ui.postDelayed(task, seconds * 1000L);
    }

    // ================= Shizuku Permission =================
    private void ensureShizukuThen(Runnable ok) {
        try {
            if (!Shizuku.pingBinder()) {
                updateShizukuStatus();
                showBanner("Shizuku غير متصل. شغّل الخدمة من تطبيق Shizuku ثم أعد المحاولة.", false);
                return;
            }
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                waitForUserService(ok);
                return;
            }
            if (!shizukuPermissionRequested) {
                shizukuPermissionRequested = true;
                Shizuku.requestPermission(SHIZUKU_RC);
            }
            showBanner("امنح التطبيق صلاحية Shizuku من النافذة التي ظهرت.", false);
        } catch (Throwable t) {
            Log.e(TAG, "Shizuku check or permission request failed", t);
            shizukuPermissionRequested = false;
            updateShizukuStatus();
            showBanner("تعذر التحقق من Shizuku. أعد تشغيل خدمته ثم حاول مجددًا.", false);
        }
    }

    // ================= Helpers =================
    private boolean isPackageInstalled(String pkg) {
        try { getPackageManager().getPackageInfo(pkg, 0); return true; }
        catch (PackageManager.NameNotFoundException e) { return false; }
    }

    private void showProgress(String msg) {
        if (progressBar != null) progressBar.setVisibility(View.VISIBLE);
        if (globalStatus != null) {
            globalStatus.setVisibility(View.VISIBLE);
            globalStatus.setText(msg);
            globalStatus.setTextColor(Color.parseColor("#292723"));
        }
    }

    private void hideProgress() {
        if (progressBar != null) progressBar.setVisibility(View.GONE);
        if (globalStatus != null) globalStatus.setVisibility(View.GONE);
    }

    private void showBanner(String msg, boolean ok) {
        if (isFinishing() || isDestroyed()) return;
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show();
    }

    private void showDiagnostics() {
        final TextView content = new TextView(this);
        content.setTextColor(Color.rgb(235, 240, 250));
        content.setTextSize(12);
        content.setText("جارٍ جمع سجل التطبيق وShizuku...");
        content.setTextIsSelectable(true);
        int pad = (int) (16 * getResources().getDisplayMetrics().density);
        content.setPadding(pad, pad, pad, pad);

        final AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle("سجل تشخيص Shizuku")
                .setView(content)
                .setNeutralButton("نسخ", null)
                .setNegativeButton("إغلاق", null)
                .create();
        dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_NEUTRAL)
                .setOnClickListener(v -> {
                    String text = content.getText().toString();
                    ClipboardManager clipboard = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
                    if (clipboard != null) {
                        clipboard.setPrimaryClip(ClipData.newPlainText("Shizuku logcat", text));
                        showBanner("تم نسخ سجل التشخيص. الصقه في المحادثة.", true);
                    }
                }));
        dialog.show();

        new Thread(() -> {
            String report = collectDiagnostics();
            ui.post(() -> {
                if (!isFinishing() && dialog.isShowing()) content.setText(report);
            });
        }, "diagnostic-logcat").start();
    }

    private String collectDiagnostics() {
        StringBuilder report = new StringBuilder();
        String appVersion = "غير متاح";
        long appVersionCode = -1;
        try {
            android.content.pm.PackageInfo info = getPackageManager().getPackageInfo(getPackageName(), 0);
            appVersion = info.versionName;
            appVersionCode = Build.VERSION.SDK_INT >= 28 ? info.getLongVersionCode() : info.versionCode;
        } catch (Exception ignored) {}
        report.append("تقرير تشخيص Shizuku\n")
                .append("الوقت: ").append(new java.text.SimpleDateFormat(
                        "yyyy-MM-dd HH:mm:ss", java.util.Locale.getDefault()).format(new java.util.Date()))
                .append("\nإصدار Android: ").append(Build.VERSION.RELEASE)
                .append(" (API ").append(Build.VERSION.SDK_INT).append(")")
                .append("\nإصدار التطبيق: ").append(appVersion)
                .append(" (code ").append(appVersionCode).append(")")
                .append("\nShizuku متصل: ");
        try {
            boolean alive = Shizuku.pingBinder();
            report.append(alive)
                    .append("\nإصدار Shizuku: ").append(alive ? Shizuku.getVersion() : "غير متاح")
                    .append("\nالصلاحية: ").append(alive
                            ? (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED ? "ممنوحة" : "غير ممنوحة")
                            : "غير متاحة")
                    .append("\nUserService مربوط: ").append(serviceBound)
                    .append("\nUserService قيد البدء: ").append(serviceBinding)
                    .append("\nآخر خطأ ربط: ").append(serviceBindError.isEmpty() ? "لا يوجد" : serviceBindError);
        } catch (Throwable t) {
            report.append("خطأ فحص Shizuku: ").append(t).append('\n');
        }
        report.append("\n--- فحص UserService ---\n");
        try {
            IUserService svc = userService;
            if (svc != null) {
                report.append("shell id: ").append(svc.runCommand("id 2>&1"));
                report.append("\nls /data/local/tmp: ")
                        .append(svc.runCommand("ls -la /data/local/tmp/ 2>&1"));
                report.append("\nls external files: ")
                        .append(svc.runCommand("ls -la /storage/emulated/0/Android/data/"
                                + getPackageName() + "/files/ 2>&1"));
            } else {
                report.append("UserService غير متصل\n");
            }
        } catch (Throwable t) {
            report.append("فشل فحص UserService: ").append(t).append('\n');
        }
        report.append("\n--- اختبار Shizuku shell ---\n")
                .append(runShizukuShellProbe()).append('\n');
        report.append("\n--- logcat (آخر 500 سطر) ---\n");
        Process process = null;
        try {
            process = new ProcessBuilder("logcat", "-d", "-t", "500", "-v", "threadtime")
                    .redirectErrorStream(true).start();
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                    process.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) report.append(line).append('\n');
            }
            if (!process.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)) {
                process.destroyForcibly();
                report.append("\nانتهت مهلة قراءة logcat.\n");
            }
        } catch (Throwable t) {
            report.append("تعذر قراءة logcat: ").append(t.getClass().getSimpleName())
                    .append(": ").append(t.getMessage()).append('\n');
        } finally {
            if (process != null) process.destroy();
        }
        report.append("\n--- معلومات الحزمة ---\n");
        try {
            report.append("اسم الحزمة: ").append(getPackageName())
                    .append("\nUserService: ").append(UserService.class.getName())
                    .append("\nVersion: ").append(USER_SERVICE_VERSION).append('\n');
        } catch (Throwable t) {
            report.append("تعذر فحص الحزمة: ").append(t).append('\n');
        }
        return report.toString();
    }

    private void sendNotification(String title, String body) {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm == null) return;
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(new NotificationChannel(
                    NOTIF_CH, "Gook Status", NotificationManager.IMPORTANCE_HIGH));
        }
        NotificationCompat.Builder b = new NotificationCompat.Builder(this, NOTIF_CH)
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setAutoCancel(true);
        nm.notify(1, b.build());
    }

    // ================= Region =================
    private static final class Region {
        final int cardId;
        final String title, packageName, shortName;
        final int iconRes;

        Region(int c, String t, String p, String s, int icon) {
            cardId = c;
            title = t;
            packageName = p;
            shortName = s;
            iconRes = icon;
        }
    }
    
private boolean isVpnActive() {
    try {
        // الطريقة الأولى: فحص واجهات الشبكة (Tun0)
        java.util.List<java.net.NetworkInterface> interfaces = java.util.Collections.list(java.net.NetworkInterface.getNetworkInterfaces());
        for (java.net.NetworkInterface networkInterface : interfaces) {
            if (networkInterface.isUp() && !networkInterface.isLoopback()) {
                String name = networkInterface.getName().toLowerCase();
                if (name.contains("tun") || name.contains("ppp") || name.contains("pptp") || name.contains("ipsec") || name.contains("tap")) {
                    return true;
                }
            }
        }

        // الطريقة الثانية: فحص إعدادات النظام (وهي الأقوى وتكتشف معظم التطبيقات)
        android.net.ConnectivityManager cm = (android.net.ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
        if (cm != null) {
            android.net.Network[] networks = cm.getAllNetworks();
            for (android.net.Network network : networks) {
                android.net.NetworkCapabilities caps = cm.getNetworkCapabilities(network);
                if (caps != null && caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) {
                    return true;
                }
            }
        }

    } catch (Exception e) {
        e.printStackTrace();
    }
    return false; // لا يوجد VPN
}



// 1. دالة فحص الروت باستخدام RootBeer
private boolean isDeviceRooted() {
    try {
        com.scottyab.rootbeer.RootBeer rootBeer = new com.scottyab.rootbeer.RootBeer(this);
        return rootBeer.isRooted(); // تعيد true إذا كان الجهاز مخترقاً
    } catch (Exception e) {
        return false;
    }
}

// 2. دالة فحص الشهادات المثبتة من قبل المستخدم (User CA)
private boolean isUserCertificateInstalled() {
    try {
        // فحص مجلد الشهادات الخاص بالمستخدم (عادة يستخدم في أدوات الاعتراض)
        String userCertPath = "/data/misc/user/0/cacerts-added/";
        java.io.File userCertDir = new java.io.File(userCertPath);
        if (userCertDir.exists() && userCertDir.listFiles() != null && userCertDir.listFiles().length > 0) {
            return true; // يوجد شهادة مثبتة
        }

        // فحص إضافي عبر KeyStore (لأجهزة Android الحديثة)
        java.security.KeyStore ks = java.security.KeyStore.getInstance("AndroidCAStore");
        ks.load(null, null);
        java.util.Enumeration<String> aliases = ks.aliases();
        while (aliases.hasMoreElements()) {
            String alias = aliases.nextElement();
            java.security.cert.X509Certificate cert = (java.security.cert.X509Certificate) ks.getCertificate(alias);
            if (cert != null && cert.getIssuerDN().getName().contains("user")) {
                return true;
            }
        }
    } catch (Exception e) {
        // تجاهل الخطأ
    }
    return false;
}

private boolean isCanaryInstalled() {
    try {
        getPackageManager().getPackageInfo("com.canaveral.canary", 0);
        return true; // إذا وجد التطبيق
    } catch (Exception e) {
        return false; // إذا لم يجده
    }
}
    
}