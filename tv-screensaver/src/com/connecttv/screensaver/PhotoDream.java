package com.connecttv.screensaver;

import android.service.dreams.DreamService;

/** The screensaver ("Daydream") that Android TV starts when the TV is idle. */
public class PhotoDream extends DreamService {
    private Slideshow show;

    @Override
    public void onAttachedToWindow() {
        super.onAttachedToWindow();
        setInteractive(false); // any remote key press wakes the TV
        setFullscreen(true);
        setScreenBright(true);
        show = new Slideshow(this);
        setContentView(show);
    }

    @Override
    public void onDreamingStarted() {
        super.onDreamingStarted();
        if (show != null) show.start();
    }

    @Override
    public void onDreamingStopped() {
        if (show != null) show.stop();
        super.onDreamingStopped();
    }
}
