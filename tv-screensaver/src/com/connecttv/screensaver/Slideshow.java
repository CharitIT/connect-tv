package com.connecttv.screensaver;

import android.animation.AnimatorSet;
import android.animation.ObjectAnimator;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.ImageDecoder;
import android.graphics.drawable.AnimatedImageDrawable;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
import android.media.ExifInterface;
import android.os.Build;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.text.format.DateFormat;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.View;
import android.view.animation.DecelerateInterpolator;
import android.view.animation.LinearInterpolator;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.VideoView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.Collections;
import java.util.Date;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Full-screen slideshow of the photos and videos pushed by Connect TV. Used by the screensaver and the preview.
 *
 * Folder layout (inside the screensaver folder): photos in the folder itself are the "Main" album;
 * other albums are sub-folders of "albums/". Which album plays comes from config.json: the first
 * matching "schedule" rule, otherwise "album".
 */
public class Slideshow extends FrameLayout {
    private static final String IMAGE_EXT = ".*\\.(jpe?g|png|webp|gif|bmp)$";
    private static final String VIDEO_EXT = ".*\\.(mp4|m4v|webm|mkv|mov)$";
    private static final long FADE_MS = 1200;
    private static final long WEATHER_EVERY_MS = 30 * 60 * 1000L;

    /** One schedule rule. Dates are month*100+day (e.g. 1025); times are minutes after midnight. -1 = not set. */
    static class Rule {
        String album = "";
        int fromDate = -1, toDate = -1, fromMin = -1, toMin = -1;

        boolean matches(Calendar now) {
            int date = (now.get(Calendar.MONTH) + 1) * 100 + now.get(Calendar.DAY_OF_MONTH);
            int min = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE);
            boolean hasDates = fromDate >= 0 && toDate >= 0, hasTimes = fromMin >= 0 && toMin >= 0;
            if (!hasDates && !hasTimes) return false;
            if (hasDates && !inRange(date, fromDate, toDate, true)) return false;
            return !hasTimes || inRange(min, fromMin, toMin, false);
        }

        /** Ranges may wrap (Dec→Jan, 22:00→06:00). Dates include the end day; times don't include the end minute. */
        static boolean inRange(int v, int from, int to, boolean inclusiveEnd) {
            boolean beforeEnd = inclusiveEnd ? v <= to : v < to;
            return from <= to ? (v >= from && beforeEnd) : (v >= from || beforeEnd);
        }
    }

    static class Config {
        int intervalSec = 12;
        boolean shuffle = true, showClock = true, motion = true, muteVideo = true, contain = false, showDate = false;
        String transition = "fade", album = "";
        List<Rule> schedule = new ArrayList<>();
        Set<String> soundOn = new HashSet<>();
        Map<String, String> captions = new HashMap<>();
        Map<String, String> dates = new HashMap<>(); // path → "YYYY-MM-DD" (sent by the phone when EXIF is missing)
        boolean onThisDay = false;
        double lat = Double.NaN, lon = Double.NaN;
        boolean fahrenheit = false;
    }

    private final ImageView[] images = new ImageView[2];
    private final VideoView video;
    private final TextView clock, sub, caption, message;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Random random = new Random();
    private ExecutorService io;
    private List<File> files = new ArrayList<>();
    private File baseDir;
    private Config cfg = new Config();
    private String currentAlbum = "";
    private final Map<String, int[]> takenCache = new HashMap<>(); // path → {year, month, day} or {}
    private final Map<String, String> autoCaptions = new HashMap<>();
    private String weatherText = "";
    private int front = 0, index = -1;
    private boolean running;
    private AnimatorSet motionAnim;

    private final Runnable advance = this::next;
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            updateClock();
            handler.postDelayed(this, 15000);
        }
    };
    private final Runnable weather = new Runnable() {
        @Override public void run() {
            fetchWeather();
            handler.postDelayed(this, WEATHER_EVERY_MS);
        }
    };

    public Slideshow(Context context) {
        super(context);
        setBackgroundColor(Color.BLACK);
        setKeepScreenOn(true);

        video = new VideoView(context);
        addView(video, new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT, Gravity.CENTER));
        video.setVisibility(GONE);

        for (int i = 0; i < 2; i++) {
            images[i] = new ImageView(context);
            images[i].setAlpha(0f);
            addView(images[i], new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT));
        }

        message = new TextView(context);
        message.setTextColor(0xCCFFFFFF);
        message.setTextSize(22);
        message.setGravity(Gravity.CENTER);
        message.setPadding(80, 80, 80, 80);
        message.setVisibility(GONE);
        addView(message, new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT));

        // Bottom right: clock, with date and weather underneath.
        LinearLayout corner = new LinearLayout(context);
        corner.setOrientation(LinearLayout.VERTICAL);
        corner.setGravity(Gravity.END);
        clock = shadowText(context, 42);
        sub = shadowText(context, 20);
        corner.addView(clock);
        corner.addView(sub);
        LayoutParams lp = new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM | Gravity.END);
        lp.setMargins(0, 0, 72, 56);
        addView(corner, lp);

        // Bottom left: the photo's caption.
        caption = shadowText(context, 24);
        caption.setMaxWidth(1100);
        LayoutParams cp = new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM | Gravity.START);
        cp.setMargins(72, 0, 0, 60);
        addView(caption, cp);
    }

    private static TextView shadowText(Context c, int sp) {
        TextView t = new TextView(c);
        t.setTextColor(Color.WHITE);
        t.setTextSize(sp);
        t.setShadowLayer(12, 0, 2, 0xAA000000);
        return t;
    }

    // ---------- lifecycle ----------

    public void start() {
        if (running) return;
        running = true;
        io = Executors.newSingleThreadExecutor();
        cfg = loadConfig();
        clock.setVisibility(cfg.showClock ? VISIBLE : GONE);
        tick.run();
        if (!Double.isNaN(cfg.lat)) weather.run();
        rescan();
        index = -1;
        next();
    }

    public void stop() {
        running = false;
        handler.removeCallbacksAndMessages(null);
        if (motionAnim != null) motionAnim.cancel();
        try { video.stopPlayback(); } catch (Exception ignored) { }
        if (io != null) io.shutdownNow();
    }

    /** Skip to the next item immediately (used by the preview's remote keys). */
    public void skip() {
        if (!running) return;
        handler.removeCallbacks(advance);
        next();
    }

    private void updateClock() {
        Date now = new Date();
        clock.setText(DateFormat.getTimeFormat(getContext()).format(now));
        StringBuilder s = new StringBuilder();
        if (cfg.showDate) s.append(DateFormat.format("EEEE, d MMMM", now));
        if (!weatherText.isEmpty()) s.append(s.length() > 0 ? "   " : "").append(weatherText);
        sub.setText(s);
        sub.setVisibility(s.length() > 0 ? VISIBLE : GONE);
    }

    // ---------- media folder and config ----------

    private List<File> folders() {
        List<File> out = new ArrayList<>();
        File app = getContext().getExternalFilesDir("screensaver");
        if (app != null) out.add(app);
        out.add(new File(Environment.getExternalStorageDirectory(), "Pictures/TVScreensaver"));
        return out;
    }

    private Config loadConfig() {
        Config c = new Config();
        for (File dir : folders()) {
            File f = new File(dir, "config.json");
            if (!f.isFile()) continue;
            try (FileInputStream in = new FileInputStream(f)) {
                JSONObject j = new JSONObject(new String(readAll(in, 1 << 20), StandardCharsets.UTF_8));
                c.intervalSec = Math.max(3, j.optInt("intervalSec", c.intervalSec));
                c.shuffle = j.optBoolean("shuffle", c.shuffle);
                c.showClock = j.optBoolean("showClock", c.showClock);
                c.showDate = j.optBoolean("showDate", c.showDate);
                c.motion = j.optBoolean("motion", c.motion);
                c.muteVideo = j.optBoolean("muteVideo", c.muteVideo);
                c.contain = "contain".equals(j.optString("fit", "cover"));
                c.transition = j.optString("transition", "fade");
                c.album = j.optString("album", "");
                c.onThisDay = j.optBoolean("onThisDay", false);
                JSONObject dates = j.optJSONObject("dates");
                if (dates != null) {
                    JSONArray names = dates.names();
                    if (names != null) for (int i = 0; i < names.length(); i++) {
                        String k = names.optString(i);
                        c.dates.put(k, dates.optString(k));
                    }
                }
                JSONArray sound = j.optJSONArray("soundOn");
                if (sound != null) for (int i = 0; i < sound.length(); i++) c.soundOn.add(sound.optString(i));
                JSONObject caps = j.optJSONObject("captions");
                if (caps != null) {
                    JSONArray names = caps.names();
                    if (names != null) for (int i = 0; i < names.length(); i++) {
                        String k = names.optString(i);
                        c.captions.put(k, caps.optString(k));
                    }
                }
                JSONArray sched = j.optJSONArray("schedule");
                if (sched != null) for (int i = 0; i < sched.length(); i++) {
                    JSONObject r = sched.optJSONObject(i);
                    if (r == null) continue;
                    Rule rule = new Rule();
                    rule.album = r.optString("album", "");
                    rule.fromDate = mmdd(r.optString("from", ""));
                    rule.toDate = mmdd(r.optString("to", ""));
                    rule.fromMin = r.optInt("fromMin", -1);
                    rule.toMin = r.optInt("toMin", -1);
                    c.schedule.add(rule);
                }
                JSONObject w = j.optJSONObject("weather");
                if (w != null && w.has("lat") && w.has("lon")) {
                    c.lat = w.optDouble("lat");
                    c.lon = w.optDouble("lon");
                    c.fahrenheit = "f".equals(w.optString("unit", "c"));
                }
                baseDir = dir;
                break;
            } catch (Exception ignored) { }
        }
        return c;
    }

    /** "10-25" → 1025, or -1. */
    private static int mmdd(String s) {
        try {
            String[] p = s.split("-");
            return p.length == 2 ? Integer.parseInt(p[0]) * 100 + Integer.parseInt(p[1]) : -1;
        } catch (Exception e) {
            return -1;
        }
    }

    private String activeAlbum() {
        Calendar now = Calendar.getInstance();
        for (Rule r : cfg.schedule) if (r.matches(now)) return r.album;
        return cfg.album;
    }

    private void rescan() {
        currentAlbum = activeAlbum();
        autoCaptions.clear();
        List<File> found = cfg.onThisDay ? onThisDay() : new ArrayList<>();
        if (!found.isEmpty()) {
            // Photos taken on this day in earlier years win over the normal album.
            if (cfg.shuffle) Collections.shuffle(found, random);
            files = found;
            return;
        }
        found = scanAlbum(currentAlbum);
        if (found.isEmpty() && !currentAlbum.isEmpty()) found = scanAlbum(""); // empty album: fall back to Main
        if (cfg.shuffle) Collections.shuffle(found, random);
        else Collections.sort(found, (a, b) -> a.getName().compareToIgnoreCase(b.getName()));
        files = found;
    }

    private List<File> scanAlbum(String album) {
        List<File> found = new ArrayList<>();
        for (File dir : folders()) {
            File folder = album.isEmpty() ? dir : new File(new File(dir, "albums"), album);
            File[] list = folder.listFiles();
            if (list == null) continue;
            for (File f : list) {
                String n = f.getName().toLowerCase(Locale.ROOT);
                if (f.isFile() && (n.matches(IMAGE_EXT) || n.matches(VIDEO_EXT))) found.add(f);
            }
        }
        return found;
    }

    /** Photos and videos from every album that were taken on today's date in an earlier year. */
    private List<File> onThisDay() {
        Calendar now = Calendar.getInstance();
        int year = now.get(Calendar.YEAR), month = now.get(Calendar.MONTH) + 1, day = now.get(Calendar.DAY_OF_MONTH);
        List<File> all = scanAlbum("");
        for (File dir : folders()) {
            File[] albums = new File(dir, "albums").listFiles();
            if (albums == null) continue;
            for (File a : albums) if (a.isDirectory()) all.addAll(scanAlbum(a.getName()));
        }
        List<File> out = new ArrayList<>();
        for (File f : all) {
            int[] t = taken(f);
            if (t.length == 3 && t[1] == month && t[2] == day && t[0] < year) {
                out.add(f);
                int ago = year - t[0];
                autoCaptions.put(rel(f), ago == 1 ? "A year ago today" : ago + " years ago today");
            }
        }
        return out;
    }

    /** When a photo was taken: {year, month, day}, or an empty array if unknown. */
    private int[] taken(File f) {
        String key = rel(f);
        int[] cached = takenCache.get(key);
        if (cached != null) return cached;
        int[] t = new int[0];
        String d = cfg.dates.get(key); // "YYYY-MM-DD" from the phone
        try {
            if (d == null && f.getName().toLowerCase(Locale.ROOT).matches(IMAGE_EXT)) {
                ExifInterface exif = new ExifInterface(f.getPath());
                d = exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL);
                if (d == null) d = exif.getAttribute(ExifInterface.TAG_DATETIME);
            }
            if (d != null && d.length() >= 10) {
                t = new int[] { Integer.parseInt(d.substring(0, 4)), Integer.parseInt(d.substring(5, 7)), Integer.parseInt(d.substring(8, 10)) };
                if (t[0] < 1900) t = new int[0];
            }
        } catch (Exception ignored) {
            t = new int[0];
        }
        takenCache.put(key, t);
        return t;
    }

    /** Path relative to the screensaver folder, e.g. "photo.jpg" or "albums/Family/photo.jpg". */
    private String rel(File f) {
        for (File dir : folders()) {
            String base = dir.getAbsolutePath() + "/";
            if (f.getAbsolutePath().startsWith(base)) return f.getAbsolutePath().substring(base.length());
        }
        return f.getName();
    }

    // ---------- playback ----------

    private void next() {
        if (!running) return;
        index++;
        // Start the new album straight away when a schedule rule starts or ends.
        if (index >= files.size() || (autoCaptions.isEmpty() && !activeAlbum().equals(currentAlbum))) { rescan(); index = 0; }
        if (files.isEmpty()) {
            caption.setVisibility(GONE);
            message.setText("No photos yet.\n\nOpen Connect TV on your phone or laptop and add photos or videos to the screensaver.");
            message.setVisibility(VISIBLE);
            handler.postDelayed(advance, 10000);
            return;
        }
        message.setVisibility(GONE);
        File f = files.get(index);
        String text = cfg.captions.get(rel(f));
        if (text == null || text.isEmpty()) text = autoCaptions.get(rel(f));
        caption.setText(text == null ? "" : text);
        caption.setVisibility(text == null || text.isEmpty() ? GONE : VISIBLE);
        if (f.getName().toLowerCase(Locale.ROOT).matches(VIDEO_EXT)) playVideo(f);
        else loadImage(f);
    }

    private void loadImage(File f) {
        final DisplayMetrics dm = getResources().getDisplayMetrics();
        io.submit(() -> {
            Drawable d = decode(f, Math.max(dm.widthPixels, 1280), Math.max(dm.heightPixels, 720));
            handler.post(() -> {
                if (!running) return;
                if (d == null) next(); else showImage(d);
            });
        });
    }

    private Drawable decode(File f, int maxW, int maxH) {
        try {
            if (Build.VERSION.SDK_INT >= 28) {
                return ImageDecoder.decodeDrawable(ImageDecoder.createSource(f), (decoder, info, src) -> {
                    int w = info.getSize().getWidth(), h = info.getSize().getHeight();
                    int sample = 1;
                    while (w / (sample * 2) >= maxW && h / (sample * 2) >= maxH) sample *= 2;
                    decoder.setTargetSampleSize(sample);
                });
            }
            BitmapFactory.Options o = new BitmapFactory.Options();
            o.inJustDecodeBounds = true;
            BitmapFactory.decodeFile(f.getPath(), o);
            int sample = 1;
            while (o.outWidth / (sample * 2) >= maxW && o.outHeight / (sample * 2) >= maxH) sample *= 2;
            o = new BitmapFactory.Options();
            o.inSampleSize = sample;
            Bitmap b = BitmapFactory.decodeFile(f.getPath(), o);
            return b == null ? null : new BitmapDrawable(getResources(), b);
        } catch (Throwable t) {
            return null;
        }
    }

    private void showImage(Drawable d) {
        stopVideo();
        final ImageView old = images[front];
        final ImageView cur = images[1 - front];
        front = 1 - front;

        cur.animate().cancel();
        old.animate().cancel();
        if (motionAnim != null) motionAnim.cancel();
        cur.setScaleType(cfg.contain ? ImageView.ScaleType.FIT_CENTER : ImageView.ScaleType.CENTER_CROP);
        cur.setImageDrawable(d);
        if (Build.VERSION.SDK_INT >= 28 && d instanceof AnimatedImageDrawable) ((AnimatedImageDrawable) d).start();
        cur.setScaleX(1f); cur.setScaleY(1f); cur.setTranslationX(0f); cur.setTranslationY(0f);
        cur.bringToFront();
        message.bringToFront();
        caption.bringToFront();
        ((View) clock.getParent()).bringToFront();

        final long showMs = cfg.intervalSec * 1000L;
        final Runnable clearOld = () -> {
            if (old != images[front]) { old.setImageDrawable(null); old.setAlpha(0f); old.setTranslationX(0f); }
        };

        switch (cfg.transition) {
            case "none":
                cur.setAlpha(1f);
                clearOld.run();
                startMotion(cur, showMs);
                break;
            case "slide": {
                // The new photo pushes the old one off to the left; the slow zoom starts once it has arrived.
                float w = getWidth() > 0 ? getWidth() : 1920f;
                cur.setAlpha(1f);
                cur.setTranslationX(w);
                old.animate().translationX(-w).setDuration(FADE_MS).setInterpolator(new DecelerateInterpolator()).start();
                cur.animate().translationX(0f).setDuration(FADE_MS).setInterpolator(new DecelerateInterpolator())
                        .withEndAction(() -> { clearOld.run(); startMotion(cur, showMs); }).start();
                break;
            }
            default: // fade
                cur.setAlpha(0f);
                cur.animate().alpha(1f).setDuration(FADE_MS).setInterpolator(new LinearInterpolator()).withEndAction(clearOld).start();
                startMotion(cur, showMs);
        }
        handler.postDelayed(advance, showMs);
    }

    /** Slow "Ken Burns" drift: zoom in slightly and pan in a random direction. */
    private void startMotion(ImageView cur, long showMs) {
        if (!cfg.motion || !running) return;
        float scale = 1.08f + random.nextFloat() * 0.06f;
        float dx = (random.nextFloat() - 0.5f) * getWidth() * 0.05f;
        float dy = (random.nextFloat() - 0.5f) * getHeight() * 0.05f;
        motionAnim = new AnimatorSet();
        motionAnim.playTogether(
            ObjectAnimator.ofFloat(cur, View.SCALE_X, 1f, scale),
            ObjectAnimator.ofFloat(cur, View.SCALE_Y, 1f, scale),
            ObjectAnimator.ofFloat(cur, View.TRANSLATION_X, 0f, dx),
            ObjectAnimator.ofFloat(cur, View.TRANSLATION_Y, 0f, dy));
        motionAnim.setInterpolator(new LinearInterpolator());
        motionAnim.setDuration(showMs + FADE_MS * 2);
        motionAnim.start();
    }

    private void playVideo(File f) {
        if (motionAnim != null) motionAnim.cancel();
        for (ImageView iv : images) { iv.animate().cancel(); iv.setAlpha(0f); iv.setImageDrawable(null); iv.setTranslationX(0f); }
        final boolean sound = cfg.soundOn.contains(rel(f)) || !cfg.muteVideo;
        video.setVisibility(VISIBLE);
        video.setOnPreparedListener(mp -> {
            mp.setVolume(sound ? 1f : 0f, sound ? 1f : 0f);
            video.start();
        });
        video.setOnCompletionListener(mp -> next());
        video.setOnErrorListener((mp, what, extra) -> { next(); return true; });
        video.setVideoPath(f.getAbsolutePath());
        caption.bringToFront();
        ((View) clock.getParent()).bringToFront();
    }

    private void stopVideo() {
        if (video.getVisibility() == VISIBLE) {
            try { video.stopPlayback(); } catch (Exception ignored) { }
            video.setVisibility(GONE);
        }
    }

    // ---------- weather (Open-Meteo: free, no account) ----------

    private void fetchWeather() {
        if (io == null || Double.isNaN(cfg.lat)) return;
        final String url = String.format(Locale.ROOT,
            "https://api.open-meteo.com/v1/forecast?latitude=%.3f&longitude=%.3f&current=temperature_2m,weather_code%s",
            cfg.lat, cfg.lon, cfg.fahrenheit ? "&temperature_unit=fahrenheit" : "");
        io.submit(() -> {
            String text = "";
            HttpURLConnection c = null;
            try {
                c = (HttpURLConnection) new URL(url).openConnection();
                c.setConnectTimeout(8000);
                c.setReadTimeout(8000);
                try (InputStream in = c.getInputStream()) {
                    JSONObject cur = new JSONObject(new String(readAll(in, 1 << 16), StandardCharsets.UTF_8)).getJSONObject("current");
                    long t = Math.round(cur.getDouble("temperature_2m"));
                    text = weatherIcon(cur.optInt("weather_code", -1)) + " " + t + "°";
                }
            } catch (Exception ignored) {
                // No internet: just leave the weather out.
            } finally {
                if (c != null) c.disconnect();
            }
            final String result = text;
            handler.post(() -> { weatherText = result; updateClock(); });
        });
    }

    /** WMO weather codes → a simple symbol. */
    private static String weatherIcon(int code) {
        if (code == 0) return "☀";
        if (code <= 2) return "⛅";
        if (code == 3) return "☁";
        if (code == 45 || code == 48) return "🌫";
        if (code >= 51 && code <= 67) return "🌧";
        if (code >= 71 && code <= 77) return "❄";
        if (code >= 80 && code <= 82) return "🌦";
        if (code >= 85 && code <= 86) return "🌨";
        if (code >= 95) return "⛈";
        return "";
    }

    private static byte[] readAll(InputStream in, int max) throws java.io.IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) > 0 && out.size() < max) out.write(buf, 0, n);
        return out.toByteArray();
    }
}
