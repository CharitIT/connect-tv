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
import android.os.Build;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.text.format.DateFormat;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.View;
import android.view.animation.LinearInterpolator;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.TextView;
import android.widget.VideoView;

import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.Random;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Full-screen slideshow of the photos and videos pushed by Connect TV. Used by the screensaver and the preview. */
public class Slideshow extends FrameLayout {
    private static final String IMAGE_EXT = ".*\\.(jpe?g|png|webp|gif|bmp)$";
    private static final String VIDEO_EXT = ".*\\.(mp4|m4v|webm|mkv|mov)$";
    private static final long FADE_MS = 1200;

    static class Config {
        int intervalSec = 12;
        boolean shuffle = true, showClock = true, motion = true, muteVideo = true, contain = false;
    }

    private final ImageView[] images = new ImageView[2];
    private final VideoView video;
    private final TextView clock, message;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Random random = new Random();
    private ExecutorService io;
    private List<File> files = new ArrayList<>();
    private Config cfg = new Config();
    private int front = 0, index = -1;
    private boolean running;
    private AnimatorSet motionAnim;

    private final Runnable advance = this::next;
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            clock.setText(DateFormat.getTimeFormat(getContext()).format(new Date()));
            handler.postDelayed(this, 15000);
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

        clock = new TextView(context);
        clock.setTextColor(Color.WHITE);
        clock.setTextSize(42);
        clock.setShadowLayer(12, 0, 2, 0xAA000000);
        LayoutParams lp = new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM | Gravity.END);
        lp.setMargins(0, 0, 72, 56);
        addView(clock, lp);
    }

    // ---------- lifecycle ----------

    public void start() {
        if (running) return;
        running = true;
        io = Executors.newSingleThreadExecutor();
        cfg = loadConfig();
        clock.setVisibility(cfg.showClock ? VISIBLE : GONE);
        if (cfg.showClock) tick.run();
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

    // ---------- media folder ----------

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
                byte[] buf = new byte[(int) Math.min(f.length(), 65536)];
                int n = in.read(buf);
                JSONObject j = new JSONObject(new String(buf, 0, Math.max(n, 0), StandardCharsets.UTF_8));
                c.intervalSec = Math.max(3, j.optInt("intervalSec", c.intervalSec));
                c.shuffle = j.optBoolean("shuffle", c.shuffle);
                c.showClock = j.optBoolean("showClock", c.showClock);
                c.motion = j.optBoolean("motion", c.motion);
                c.muteVideo = j.optBoolean("muteVideo", c.muteVideo);
                c.contain = "contain".equals(j.optString("fit", "cover"));
                break;
            } catch (Exception ignored) { }
        }
        return c;
    }

    private void rescan() {
        List<File> found = new ArrayList<>();
        for (File dir : folders()) {
            File[] list = dir.listFiles();
            if (list == null) continue;
            for (File f : list) {
                String n = f.getName().toLowerCase();
                if (f.isFile() && (n.matches(IMAGE_EXT) || n.matches(VIDEO_EXT))) found.add(f);
            }
        }
        if (cfg.shuffle) Collections.shuffle(found, random);
        else Collections.sort(found, (a, b) -> a.getName().compareToIgnoreCase(b.getName()));
        files = found;
    }

    // ---------- playback ----------

    private void next() {
        if (!running) return;
        index++;
        if (index >= files.size()) { rescan(); index = 0; }
        if (files.isEmpty()) {
            message.setText("No photos yet.\n\nOpen Connect TV on your laptop and add photos or videos to the screensaver.");
            message.setVisibility(VISIBLE);
            handler.postDelayed(advance, 10000);
            return;
        }
        message.setVisibility(GONE);
        File f = files.get(index);
        if (f.getName().toLowerCase().matches(VIDEO_EXT)) playVideo(f);
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
        cur.setScaleType(cfg.contain ? ImageView.ScaleType.FIT_CENTER : ImageView.ScaleType.CENTER_CROP);
        cur.setImageDrawable(d);
        if (Build.VERSION.SDK_INT >= 28 && d instanceof AnimatedImageDrawable) ((AnimatedImageDrawable) d).start();
        cur.setScaleX(1f); cur.setScaleY(1f); cur.setTranslationX(0f); cur.setTranslationY(0f);
        cur.setAlpha(0f);
        cur.bringToFront();
        message.bringToFront();
        clock.bringToFront();

        long showMs = cfg.intervalSec * 1000L;
        cur.animate().alpha(1f).setDuration(FADE_MS).withEndAction(() -> {
            if (old != images[front]) { old.setImageDrawable(null); old.setAlpha(0f); }
        }).start();

        if (cfg.motion) {
            // Slow "Ken Burns" drift: zoom in slightly and pan in a random direction.
            float scale = 1.08f + random.nextFloat() * 0.06f;
            float dx = (random.nextFloat() - 0.5f) * getWidth() * 0.05f;
            float dy = (random.nextFloat() - 0.5f) * getHeight() * 0.05f;
            if (motionAnim != null) motionAnim.cancel();
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
        handler.postDelayed(advance, showMs);
    }

    private void playVideo(File f) {
        for (ImageView iv : images) { iv.animate().cancel(); iv.setAlpha(0f); iv.setImageDrawable(null); }
        video.setVisibility(VISIBLE);
        video.setOnPreparedListener(mp -> {
            if (cfg.muteVideo) mp.setVolume(0f, 0f);
            video.start();
        });
        video.setOnCompletionListener(mp -> next());
        video.setOnErrorListener((mp, what, extra) -> { next(); return true; });
        video.setVideoPath(f.getAbsolutePath());
    }

    private void stopVideo() {
        if (video.getVisibility() == VISIBLE) {
            try { video.stopPlayback(); } catch (Exception ignored) { }
            video.setVisibility(GONE);
        }
    }
}
