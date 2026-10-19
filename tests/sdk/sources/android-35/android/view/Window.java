package android.view;

/**
 * Abstract base class for a top-level window look and behavior policy.
 */
public abstract class Window {
    /** Returns whether the system is ensuring that the navigation bar has enough contrast. */
    public boolean isNavigationBarContrastEnforced() {
        return false;
    }
}
