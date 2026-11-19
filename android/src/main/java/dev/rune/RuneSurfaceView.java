package dev.rune;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.res.AssetManager;
import android.content.res.Configuration;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.AttributeSet;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Choreographer;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowInsets;
import android.view.accessibility.AccessibilityManager;
import android.view.accessibility.AccessibilityNodeProvider;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import java.lang.ref.WeakReference;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Set;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Embeddable Android SurfaceView hosting a Rune GPU surface, input dispatch,
 * virtual accessibility tree ({@link RuneNodes}), and system IME bridge ({@link RuneField}).
 *
 * <p>Works inside any Android {@link Activity}, {@code Fragment}, XML layout, {@code ViewGroup},
 * or Jetpack Compose {@code AndroidView(factory = { RuneSurfaceView(it, nativeFactoryName) })}.
 */
public class RuneSurfaceView extends SurfaceView
        implements SurfaceHolder.Callback, Choreographer.FrameCallback, RuneHostBridge {
    private static final String TAG = "SwiftRune";
    private static final Set<String> LOADED_LIBRARIES = new HashSet<>();

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Runnable delayedWakeRunnable = new Runnable() {
        @Override public void run() {
            wakeTimerScheduled = false;
            requestFrameOnMainThread();
        }
    };
    private final Runnable requestFrameRunnable = new Runnable() {
        @Override public void run() {
            requestFrameOnMainThread();
        }
    };
    private final AccessibilityManager.AccessibilityStateChangeListener observingAccessibility =
            new AccessibilityManager.AccessibilityStateChangeListener() {
                @Override public void onAccessibilityStateChanged(boolean enabled) {
                    runeAction("refresh", -1, null);
                }
            };

    private AccessibilityManager accessibilityManager;
    private RuneNodes nodes;
    private RuneField field;

    private String libraryName;
    private String factoryName;
    private boolean transparent;
    private boolean disposeOnDetach;
    private boolean forwardWindowInsets;
    private boolean hasPendingSafeArea;
    private float pendingTopDp, pendingRightDp, pendingBottomDp, pendingLeftDp;
    private Runnable onCloseListener;

    private long nativeHandle;
    private long semanticPeer;
    private boolean disposed;
    private boolean attached;
    private boolean surfaceReady;
    private boolean windowVisible = true;
    private boolean effectiveVisible;
    private boolean windowFocused;
    private boolean accessibilityRegistered;
    private boolean frameScheduled;
    private boolean wakeTimerScheduled;
    private int surfaceWidth;
    private int surfaceHeight;
    private int lastMouseButtons;

    private Application observedApplication;
    private Application.ActivityLifecycleCallbacks activityLifecycleCallbacks;

    public RuneSurfaceView(Context context) {
        super(context);
        init(context, null);
    }

    public RuneSurfaceView(Context context, String nativeFactoryName) {
        super(context);
        this.factoryName = nativeFactoryName;
        init(context, null);
    }

    public RuneSurfaceView(Context context, String nativeLibraryName, String nativeFactoryName) {
        super(context);
        this.libraryName = nativeLibraryName;
        this.factoryName = nativeFactoryName;
        init(context, null);
    }

    public RuneSurfaceView(Context context, AttributeSet attrs) {
        super(context, attrs);
        init(context, attrs);
    }

    public RuneSurfaceView(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
        init(context, attrs);
    }

    public RuneSurfaceView(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
        init(context, attrs);
    }

    private void init(Context context, AttributeSet attrs) {
        readAttributes(attrs);
        accessibilityManager = (AccessibilityManager) context.getSystemService(Context.ACCESSIBILITY_SERVICE);
        nodes = new RuneNodes(this);
        field = new RuneField(this);
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_YES);
        setFocusable(true);
        setFocusableInTouchMode(true);
        getHolder().setFormat(transparent ? PixelFormat.TRANSLUCENT : PixelFormat.RGBA_8888);
        getHolder().addCallback(this);
        if (!isInEditMode() && libraryName != null && !libraryName.isEmpty()) {
            loadLibraryIfNeeded(libraryName);
        }
    }

    private void readAttributes(AttributeSet attrs) {
        if (attrs == null) return;
        int count = attrs.getAttributeCount();
        for (int i = 0; i < count; i++) {
            String name = attrs.getAttributeName(i);
            if ("runeLibrary".equals(name)) {
                libraryName = attrs.getAttributeValue(i);
            } else if ("runeFactory".equals(name)) {
                factoryName = attrs.getAttributeValue(i);
            } else if ("runeTransparent".equals(name)) {
                transparent = attrs.getAttributeBooleanValue(i, false);
            } else if ("runeForwardInsets".equals(name)) {
                forwardWindowInsets = attrs.getAttributeBooleanValue(i, false);
            } else if ("runeDisposeOnDetach".equals(name)) {
                disposeOnDetach = attrs.getAttributeBooleanValue(i, false);
            }
        }
    }

    private static void loadLibraryIfNeeded(String name) {
        if (name == null || name.isEmpty()) return;
        synchronized (LOADED_LIBRARIES) {
            if (LOADED_LIBRARIES.contains(name)) return;
            System.loadLibrary(name);
            LOADED_LIBRARIES.add(name);
        }
    }

    /** Sets the native shared library name (without "lib" prefix or ".so" suffix) to load before creating the view. */
    public void setNativeLibrary(String libraryName) {
        this.libraryName = libraryName;
        if (!isInEditMode() && libraryName != null && !libraryName.isEmpty()) {
            loadLibraryIfNeeded(libraryName);
        }
    }

    /** Sets the native factory symbol or registered Swift view name. Attaches immediately if already in a window. */
    public void setFactoryName(String factoryName) {
        this.factoryName = factoryName;
        if (!isInEditMode() && !disposed && nativeHandle == 0 && (attached || surfaceReady)) {
            ensureNativeHost();
            syncHostStateAfterAttach();
        }
    }

    public String getFactoryName() {
        return factoryName;
    }

    /** Configures whether the backing SurfaceHolder requests a translucent pixel format. */
    public void setTransparent(boolean transparent) {
        this.transparent = transparent;
        getHolder().setFormat(transparent ? PixelFormat.TRANSLUCENT : PixelFormat.RGBA_8888);
    }

    /** When true, detaching this view from a window immediately disposes the native Rune runtime instead of pausing it. */
    public void setDisposeOnDetach(boolean disposeOnDetach) {
        this.disposeOnDetach = disposeOnDetach;
    }

    /** When true, system bar and display cutout WindowInsets are forwarded as Rune safe-area insets in logical DP. */
    public void setForwardWindowInsets(boolean forwardWindowInsets) {
        this.forwardWindowInsets = forwardWindowInsets;
        if (forwardWindowInsets && attached) {
            requestApplyInsets();
        }
    }

    /** Manually supplies safe-area insets in logical DP to the embedded Rune runtime. */
    public void setSafeAreaInsets(float topDp, float rightDp, float bottomDp, float leftDp) {
        pendingTopDp = topDp;
        pendingRightDp = rightDp;
        pendingBottomDp = bottomDp;
        pendingLeftDp = leftDp;
        hasPendingSafeArea = true;
        if (!isInEditMode() && !disposed && nativeHandle != 0) {
            nativeOnSafeAreaInsetsChanged(nativeHandle, topDp, rightDp, bottomDp, leftDp);
            requestFrame();
        }
    }

    /** Installs a callback invoked when the embedded Rune UI requests closing or quitting. */
    public void setOnCloseListener(Runnable listener) {
        this.onCloseListener = listener;
    }

    /** Returns the native RuneAndroidSurface handle, creating it lazily if a factory name is configured. */
    public long getNativeHandle() {
        if (!isInEditMode() && !disposed) {
            ensureNativeHost();
        }
        return nativeHandle;
    }

    /** Attaches a native RuneAndroidSurface handle created externally via custom JNI. */
    public void attachNativeHandle(long handle) {
        if (disposed || isInEditMode() || handle == 0) return;
        if (nativeHandle != 0 && nativeHandle != handle) {
            nativeDestroy(nativeHandle);
        }
        nativeHandle = handle;
        syncHostStateAfterAttach();
    }

    public boolean isDisposed() {
        return disposed;
    }

    /** Schedules a frame on the next Choreographer VSync. Safe to call from any thread. */
    public void requestFrame() {
        if (disposed || isInEditMode()) return;
        if (Looper.myLooper() == Looper.getMainLooper()) {
            requestFrameOnMainThread();
        } else {
            mainHandler.post(requestFrameRunnable);
        }
    }

    private void requestFrameOnMainThread() {
        if (disposed || !surfaceReady || !effectiveVisible || nativeHandle == 0) return;
        cancelDelayedWake();
        postChoreographerFrame();
    }

    private void postChoreographerFrame() {
        if (frameScheduled || disposed || !surfaceReady || !effectiveVisible || nativeHandle == 0) return;
        frameScheduled = true;
        Choreographer.getInstance().postFrameCallback(this);
    }

    private void scheduleDelayedWake(long delayMs) {
        cancelDelayedWake();
        wakeTimerScheduled = true;
        mainHandler.postDelayed(delayedWakeRunnable, delayMs);
    }

    private void cancelDelayedWake() {
        if (wakeTimerScheduled) {
            mainHandler.removeCallbacks(delayedWakeRunnable);
            wakeTimerScheduled = false;
        }
    }

    private void cancelFrameCallbacks() {
        cancelDelayedWake();
        mainHandler.removeCallbacks(requestFrameRunnable);
        if (frameScheduled) {
            Choreographer.getInstance().removeFrameCallback(this);
            frameScheduled = false;
        }
    }

    private void ensureNativeHost() {
        if (disposed || isInEditMode() || nativeHandle != 0) return;
        if (factoryName == null || factoryName.isEmpty()) return;
        try {
            if (libraryName != null && !libraryName.isEmpty()) {
                loadLibraryIfNeeded(libraryName);
            }
            Context appContext = getContext().getApplicationContext();
            if (appContext == null) appContext = getContext();
            AssetManager assets = appContext.getAssets();
            nativeHandle = nativeCreate(
                    appContext,
                    assets,
                    factoryName,
                    currentDensityDpi(),
                    currentDensity(),
                    isNightMode()
            );
            if (nativeHandle == 0) {
                Log.e(TAG, "Failed to initialize RuneSurfaceView factory '" + factoryName + "'");
                return;
            }
            if (hasPendingSafeArea) {
                nativeOnSafeAreaInsetsChanged(
                        nativeHandle, pendingTopDp, pendingRightDp, pendingBottomDp, pendingLeftDp
                );
            }
        } catch (UnsatisfiedLinkError error) {
            Log.e(TAG, "Native library missing for RuneSurfaceView factory '" + factoryName + "'", error);
        }
    }

    private void syncHostStateAfterAttach() {
        if (nativeHandle == 0 || disposed) return;
        if (hasPendingSafeArea) {
            nativeOnSafeAreaInsetsChanged(
                    nativeHandle, pendingTopDp, pendingRightDp, pendingBottomDp, pendingLeftDp
            );
        }
        Surface surface = getHolder().getSurface();
        if (surfaceReady && surface != null && surface.isValid()) {
            nativeOnSurfaceCreated(nativeHandle, surface);
            int w = surfaceWidth > 0 ? surfaceWidth : getWidth();
            int h = surfaceHeight > 0 ? surfaceHeight : getHeight();
            if (w > 0 && h > 0) {
                nativeOnSurfaceChanged(nativeHandle, surface, w, h, currentDensity(), isNightMode());
            }
        }
        syncVisibility();
        if (windowFocused) {
            nativeOnFocusChanged(nativeHandle, true);
        }
        if (isRuneReaderActive()) {
            runeAction("refresh", -1, null);
        }
        requestFrameOnMainThread();
    }

    private void syncVisibility() {
        boolean visible = !disposed && attached && windowVisible && isShown();
        if (visible == effectiveVisible) return;
        effectiveVisible = visible;
        if (nativeHandle == 0) return;
        nativeOnVisibilityChanged(nativeHandle, visible);
        if (!visible) {
            cancelFrameCallbacks();
            nativeOnSuspendInput(nativeHandle);
        } else if (surfaceReady) {
            requestFrameOnMainThread();
        }
    }

    private int currentDensityDpi() {
        Configuration config = getResources().getConfiguration();
        if (config != null && config.densityDpi != Configuration.DENSITY_DPI_UNDEFINED && config.densityDpi > 0) {
            return config.densityDpi;
        }
        DisplayMetrics metrics = getResources().getDisplayMetrics();
        return metrics != null && metrics.densityDpi > 0 ? metrics.densityDpi : DisplayMetrics.DENSITY_MEDIUM;
    }

    private float currentDensity() {
        DisplayMetrics metrics = getResources().getDisplayMetrics();
        if (metrics != null && metrics.density > 0f) {
            return metrics.density;
        }
        return currentDensityDpi() / 160.0f;
    }

    private boolean isNightMode() {
        Configuration config = getResources().getConfiguration();
        return config != null && (config.uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
    }

    private static Activity findHostingActivity(Context context) {
        Context current = context;
        while (current instanceof ContextWrapper) {
            if (current instanceof Activity) {
                return (Activity) current;
            }
            current = ((ContextWrapper) current).getBaseContext();
        }
        return null;
    }

    private void registerActivityCleanup() {
        if (activityLifecycleCallbacks != null) return;
        final Activity hostActivity = findHostingActivity(getContext());
        if (hostActivity == null) return;
        Application app = hostActivity.getApplication();
        if (app == null) return;
        final WeakReference<Activity> activityRef = new WeakReference<>(hostActivity);
        observedApplication = app;
        activityLifecycleCallbacks = new Application.ActivityLifecycleCallbacks() {
            @Override public void onActivityCreated(Activity activity, Bundle savedInstanceState) {}
            @Override public void onActivityStarted(Activity activity) {}
            @Override public void onActivityResumed(Activity activity) {}
            @Override public void onActivityPaused(Activity activity) {}
            @Override public void onActivityStopped(Activity activity) {}
            @Override public void onActivitySaveInstanceState(Activity activity, Bundle outState) {}
            @Override public void onActivityDestroyed(Activity activity) {
                Activity target = activityRef.get();
                if (target == null || activity == target) {
                    dispose();
                }
            }
        };
        app.registerActivityLifecycleCallbacks(activityLifecycleCallbacks);
    }

    private void unregisterActivityCleanup() {
        if (observedApplication != null && activityLifecycleCallbacks != null) {
            observedApplication.unregisterActivityLifecycleCallbacks(activityLifecycleCallbacks);
        }
        observedApplication = null;
        activityLifecycleCallbacks = null;
    }

    // MARK: - View & Window Lifecycle

    @Override protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        if (isInEditMode() || disposed) return;
        attached = true;
        windowVisible = getWindowVisibility() == VISIBLE;
        registerActivityCleanup();
        if (accessibilityManager != null && !accessibilityRegistered) {
            accessibilityManager.addAccessibilityStateChangeListener(observingAccessibility);
            accessibilityRegistered = true;
        }
        ensureNativeHost();
        if (nativeHandle != 0) {
            nativeOnConfigurationChanged(nativeHandle, currentDensityDpi(), currentDensity(), isNightMode());
        }
        if (forwardWindowInsets) {
            requestApplyInsets();
        }
        syncVisibility();
        if (hasWindowFocus() && !windowFocused) {
            windowFocused = true;
            if (nativeHandle != 0) {
                nativeOnFocusChanged(nativeHandle, true);
            }
        }
        if (isRuneReaderActive()) {
            runeAction("refresh", -1, null);
        }
        if (surfaceReady) {
            requestFrameOnMainThread();
        }
    }

    @Override protected void onDetachedFromWindow() {
        attached = false;
        cancelFrameCallbacks();
        if (accessibilityManager != null && accessibilityRegistered) {
            accessibilityManager.removeAccessibilityStateChangeListener(observingAccessibility);
            accessibilityRegistered = false;
        }
        if (field != null) {
            field.deactivate();
        }
        if (nativeHandle != 0) {
            if (windowFocused) {
                windowFocused = false;
                nativeOnFocusChanged(nativeHandle, false);
            }
            if (effectiveVisible) {
                effectiveVisible = false;
                nativeOnVisibilityChanged(nativeHandle, false);
            }
            nativeOnSuspendInput(nativeHandle);
        } else {
            windowFocused = false;
            effectiveVisible = false;
        }
        super.onDetachedFromWindow();
        Activity hostActivity = findHostingActivity(getContext());
        if (disposeOnDetach || (hostActivity != null && (hostActivity.isFinishing() || hostActivity.isDestroyed()))) {
            dispose();
        }
    }

    @Override protected void onVisibilityChanged(View changedView, int visibility) {
        super.onVisibilityChanged(changedView, visibility);
        if (!isInEditMode() && !disposed) {
            syncVisibility();
        }
    }

    @Override protected void onWindowVisibilityChanged(int visibility) {
        super.onWindowVisibilityChanged(visibility);
        windowVisible = (visibility == VISIBLE);
        if (!isInEditMode() && !disposed) {
            syncVisibility();
        }
    }

    @Override public void onWindowFocusChanged(boolean hasWindowFocus) {
        super.onWindowFocusChanged(hasWindowFocus);
        windowFocused = hasWindowFocus;
        if (isInEditMode() || disposed || nativeHandle == 0) return;
        nativeOnFocusChanged(nativeHandle, hasWindowFocus);
        if (!hasWindowFocus) {
            nativeOnSuspendInput(nativeHandle);
        } else if (surfaceReady && effectiveVisible) {
            requestFrameOnMainThread();
        }
    }

    @Override protected void onFocusChanged(boolean gainFocus, int direction, Rect previouslyFocusedRect) {
        super.onFocusChanged(gainFocus, direction, previouslyFocusedRect);
        if (!gainFocus) {
            if (field != null) field.deactivate();
            if (!isInEditMode() && !disposed && nativeHandle != 0) {
                nativeOnSuspendInput(nativeHandle);
            }
        }
    }

    @Override protected void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        if (isInEditMode() || disposed || nativeHandle == 0) return;
        int dpi = (newConfig != null && newConfig.densityDpi != Configuration.DENSITY_DPI_UNDEFINED && newConfig.densityDpi > 0)
                ? newConfig.densityDpi
                : currentDensityDpi();
        float density = dpi > 0 ? dpi / 160.0f : currentDensity();
        boolean dark = newConfig != null
                ? (newConfig.uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
                : isNightMode();
        nativeOnConfigurationChanged(nativeHandle, dpi, density, dark);
        requestFrameOnMainThread();
    }

    @Override public WindowInsets onApplyWindowInsets(WindowInsets insets) {
        if (forwardWindowInsets && insets != null && !isInEditMode() && !disposed) {
            int[] px = new int[4];
            if (Build.VERSION.SDK_INT >= 30) {
                InsetsApi30.read(insets, px);
            } else {
                readLegacyInsets(insets, px);
            }
            float scale = Math.max(0.5f, currentDensity());
            setSafeAreaInsets(px[0] / scale, px[1] / scale, px[2] / scale, px[3] / scale);
        }
        return super.onApplyWindowInsets(insets);
    }

    @SuppressWarnings("deprecation")
    private static void readLegacyInsets(WindowInsets insets, int[] out) {
        out[0] = insets.getSystemWindowInsetTop();
        out[1] = insets.getSystemWindowInsetRight();
        out[2] = insets.getSystemWindowInsetBottom();
        out[3] = insets.getSystemWindowInsetLeft();
    }

    // Keep API 30 WindowInsets.Type references out of the main class verified on API 24.
    private static final class InsetsApi30 {
        static void read(WindowInsets insets, int[] out) {
            android.graphics.Insets bars = insets.getInsets(
                    WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout()
            );
            out[0] = bars.top;
            out[1] = bars.right;
            out[2] = bars.bottom;
            out[3] = bars.left;
        }
    }

    /** Permanently releases the EGL context/surface, native runtime, and accessibility/IME bridges. */
    public void dispose() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post(new Runnable() {
                @Override public void run() {
                    dispose();
                }
            });
            return;
        }
        if (disposed) return;
        disposed = true;
        attached = false;
        surfaceReady = false;
        effectiveVisible = false;
        windowFocused = false;
        cancelFrameCallbacks();
        getHolder().removeCallback(this);
        if (accessibilityManager != null && accessibilityRegistered) {
            accessibilityManager.removeAccessibilityStateChangeListener(observingAccessibility);
            accessibilityRegistered = false;
        }
        unregisterActivityCleanup();
        if (field != null) {
            field.deactivate();
        }
        semanticPeer = 0;
        long handle = nativeHandle;
        nativeHandle = 0;
        if (handle != 0) {
            nativeDestroy(handle);
        }
    }

    // MARK: - SurfaceHolder.Callback

    @Override public void surfaceCreated(SurfaceHolder holder) {
        if (isInEditMode() || disposed) return;
        ensureNativeHost();
        surfaceReady = true;
        Surface surface = holder.getSurface();
        if (nativeHandle != 0 && surface != null) {
            nativeOnSurfaceCreated(nativeHandle, surface);
            nativeOnConfigurationChanged(nativeHandle, currentDensityDpi(), currentDensity(), isNightMode());
        }
        syncVisibility();
        requestFrameOnMainThread();
    }

    @Override public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        if (isInEditMode() || disposed) return;
        surfaceWidth = width;
        surfaceHeight = height;
        surfaceReady = true;
        ensureNativeHost();
        Surface surface = holder.getSurface();
        if (nativeHandle != 0 && surface != null) {
            nativeOnSurfaceChanged(nativeHandle, surface, width, height, currentDensity(), isNightMode());
        }
        syncVisibility();
        requestFrameOnMainThread();
    }

    @Override public void surfaceDestroyed(SurfaceHolder holder) {
        surfaceReady = false;
        cancelFrameCallbacks();
        if (nativeHandle != 0) {
            nativeOnSuspendInput(nativeHandle);
            nativeOnSurfaceDestroyed(nativeHandle);
        }
    }

    // MARK: - Choreographer.FrameCallback

    @Override public void doFrame(long frameTimeNanos) {
        frameScheduled = false;
        if (disposed || !surfaceReady || !effectiveVisible || nativeHandle == 0) return;
        int w = surfaceWidth > 0 ? surfaceWidth : getWidth();
        int h = surfaceHeight > 0 ? surfaceHeight : getHeight();
        if (w <= 0 || h <= 0) return;
        double delay = nativeDrawFrame(nativeHandle, w, h, currentDensity(), isNightMode());
        if (disposed || !surfaceReady || !effectiveVisible || nativeHandle == 0) return;
        if (Double.isNaN(delay) || Double.isInfinite(delay)) return;
        if (delay == 0.0) {
            postChoreographerFrame();
        } else if (delay > 0.0) {
            double clamped = Math.min(delay, 86400.0);
            long delayMs = Math.max(1L, Math.round(clamped * 1000.0));
            scheduleDelayedWake(delayMs);
        }
    }

    // MARK: - Touch, Pointer, Hover, Scroll, and Key Input

    @Override public boolean onTouchEvent(MotionEvent event) {
        if (isInEditMode() || disposed || nativeHandle == 0) {
            return super.onTouchEvent(event);
        }
        int masked = event.getActionMasked();
        if (masked == MotionEvent.ACTION_DOWN && !hasFocus()) {
            requestFocus();
        }
        if (masked == MotionEvent.ACTION_UP) {
            performClick();
        }
        if (dispatchMotion(event)) {
            requestFrameOnMainThread();
            return true;
        }
        return super.onTouchEvent(event);
    }

    @Override public boolean performClick() {
        super.performClick();
        return true;
    }

    @Override public boolean dispatchHoverEvent(MotionEvent event) {
        if (nodes != null && nodes.hover(event)) return true;
        return super.dispatchHoverEvent(event);
    }

    @Override public boolean onHoverEvent(MotionEvent event) {
        if (isInEditMode() || disposed || nativeHandle == 0) {
            return super.onHoverEvent(event);
        }
        if (dispatchMotion(event)) {
            requestFrameOnMainThread();
            return true;
        }
        return super.onHoverEvent(event);
    }

    @Override public boolean onGenericMotionEvent(MotionEvent event) {
        if (isInEditMode() || disposed || nativeHandle == 0) {
            return super.onGenericMotionEvent(event);
        }
        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_SCROLL
                || action == MotionEvent.ACTION_HOVER_MOVE
                || action == MotionEvent.ACTION_HOVER_ENTER
                || action == MotionEvent.ACTION_HOVER_EXIT) {
            if (dispatchMotion(event)) {
                requestFrameOnMainThread();
                return true;
            }
        }
        return super.onGenericMotionEvent(event);
    }

    private boolean dispatchMotion(MotionEvent event) {
        int action = event.getActionMasked();
        int count = event.getPointerCount();
        int first = event.getActionIndex();
        int end = first + 1;
        if (action == MotionEvent.ACTION_MOVE || action == MotionEvent.ACTION_CANCEL) {
            first = 0;
            end = count;
        }
        if (action == MotionEvent.ACTION_POINTER_DOWN) {
            action = MotionEvent.ACTION_DOWN;
        } else if (action == MotionEvent.ACTION_POINTER_UP) {
            action = MotionEvent.ACTION_UP;
        }
        if (action > MotionEvent.ACTION_HOVER_EXIT || end > count) {
            return false;
        }
        int rawButtons = event.getButtonState();
        int meta = event.getMetaState();
        for (int i = first; i < end; i++) {
            boolean mouse = event.getToolType(i) == MotionEvent.TOOL_TYPE_MOUSE
                    || (action == MotionEvent.ACTION_SCROLL && event.isFromSource(InputDevice.SOURCE_CLASS_POINTER));
            int buttons = (action == MotionEvent.ACTION_UP && mouse) ? lastMouseButtons : rawButtons;
            nativeOnMotion(
                    nativeHandle,
                    action,
                    event.getPointerId(i),
                    mouse,
                    buttons,
                    meta,
                    event.getX(i),
                    event.getY(i),
                    event.getAxisValue(MotionEvent.AXIS_HSCROLL, i),
                    event.getAxisValue(MotionEvent.AXIS_VSCROLL, i)
            );
            if (mouse) {
                lastMouseButtons = rawButtons;
            }
        }
        return true;
    }

    @Override public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (isInEditMode() || disposed || nativeHandle == 0) {
            return super.onKeyDown(keyCode, event);
        }
        int unicode = event.getUnicodeChar(event.getMetaState());
        boolean handled = nativeOnKey(
                nativeHandle,
                KeyEvent.ACTION_DOWN,
                keyCode,
                event.getMetaState(),
                event.getRepeatCount(),
                unicode
        );
        if (handled) {
            requestFrameOnMainThread();
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override public boolean onKeyUp(int keyCode, KeyEvent event) {
        if (isInEditMode() || disposed || nativeHandle == 0) {
            return super.onKeyUp(keyCode, event);
        }
        int unicode = event.getUnicodeChar(event.getMetaState());
        boolean handled = nativeOnKey(
                nativeHandle,
                KeyEvent.ACTION_UP,
                keyCode,
                event.getMetaState(),
                event.getRepeatCount(),
                unicode
        );
        if (handled) {
            requestFrameOnMainThread();
            return true;
        }
        return super.onKeyUp(keyCode, event);
    }

    @SuppressWarnings("deprecation")
    @Override public boolean onKeyMultiple(int keyCode, int repeatCount, KeyEvent event) {
        if (isInEditMode() || disposed || nativeHandle == 0) {
            return super.onKeyMultiple(keyCode, repeatCount, event);
        }
        if (keyCode == KeyEvent.KEYCODE_UNKNOWN && event != null) {
            String chars = event.getCharacters();
            if (chars != null && !chars.isEmpty()) {
                boolean any = false;
                int meta = event.getMetaState();
                for (int i = 0; i < chars.length(); ) {
                    int cp = chars.codePointAt(i);
                    boolean down = nativeOnKey(nativeHandle, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_UNKNOWN, meta, 0, cp);
                    boolean up = nativeOnKey(nativeHandle, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_UNKNOWN, meta, 0, cp);
                    any = any || down || up;
                    i += Character.charCount(cp);
                }
                if (any) {
                    requestFrameOnMainThread();
                    return true;
                }
            }
        }
        return super.onKeyMultiple(keyCode, repeatCount, event);
    }

    // MARK: - Accessibility & IME (RuneNodes / RuneField)

    @Override public AccessibilityNodeProvider getAccessibilityNodeProvider() {
        return nodes;
    }

    @Override public boolean onCheckIsTextEditor() {
        return field != null && field.active();
    }

    @Override public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
        return field != null ? field.connect(outAttrs) : null;
    }

    @Override public final View hostView() {
        return this;
    }

    @Override public final InputMethodManager ime() {
        return (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
    }

    @Override public final boolean runeAction(String op, int id, JSONObject args) {
        if (semanticPeer == 0 || disposed) return false;
        byte[] payload = args == null ? null : args.toString().getBytes(StandardCharsets.UTF_8);
        boolean handled = nativeRuneAction(semanticPeer, op, id, payload);
        if (handled) {
            requestFrame();
        }
        return handled;
    }

    @Override public final boolean isRuneReaderActive() {
        return accessibilityManager != null && accessibilityManager.isEnabled();
    }

    @Override public final boolean clearFocusOnEditorBlur() {
        return false;
    }

    // MARK: - JNI Bridge Callbacks (invoked from CRuneAndroid Semantics.c & AndroidSurfaceHost.c)

    final Class<?> runeHostClass() {
        return RuneSurfaceView.class;
    }

    final void setRunePeer(long peer) {
        semanticPeer = peer;
    }

    final void updateRuneSnapshot(boolean tree, byte[] bytes) {
        if (disposed || nodes == null || field == null) return;
        try {
            JSONObject data = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
            if (tree) nodes.update(data); else field.update(data);
        } catch (JSONException failure) {
            Log.e(TAG, "Invalid semantic snapshot", failure);
        }
    }

    final void requestFrameFromNative() {
        requestFrame();
    }

    final void onRuneCloseRequested() {
        final Runnable listener = onCloseListener;
        if (listener == null) return;
        if (Looper.myLooper() == Looper.getMainLooper()) {
            listener.run();
        } else {
            mainHandler.post(listener);
        }
    }

    final void setSoftKeyboardVisible(boolean show) {
        InputMethodManager manager = ime();
        if (manager == null) return;
        if (show) {
            requestFocus();
            manager.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT);
        } else if (getWindowToken() != null) {
            manager.hideSoftInputFromWindow(getWindowToken(), 0);
        }
    }

    // MARK: - Native Methods

    private native long nativeCreate(
            Context appContext,
            AssetManager assets,
            String factoryName,
            int densityDpi,
            float density,
            boolean dark
    );
    private native void nativeDestroy(long handle);
    private native boolean nativeOnSurfaceCreated(long handle, Surface surface);
    private native void nativeOnSurfaceChanged(long handle, Surface surface, int width, int height, float density, boolean dark);
    private native void nativeOnSurfaceDestroyed(long handle);
    private native double nativeDrawFrame(long handle, int width, int height, float density, boolean dark);
    private native void nativeOnMotion(
            long handle, int action, int pointerId, boolean isMouse,
            int buttons, int meta, float x, float y, float hScroll, float vScroll
    );
    private native boolean nativeOnKey(
            long handle, int action, int keyCode, int meta, int repeatCount, int unicodeChar
    );
    private native void nativeOnFocusChanged(long handle, boolean focused);
    private native void nativeOnVisibilityChanged(long handle, boolean visible);
    private native void nativeOnConfigurationChanged(long handle, int densityDpi, float density, boolean dark);
    private native void nativeOnSafeAreaInsetsChanged(long handle, float top, float right, float bottom, float left);
    private native void nativeOnSuspendInput(long handle);
    private native boolean nativeRuneAction(long peer, String op, int id, byte[] json);
}
