package android.app;

import android.content.ContextWrapper;
import android.content.Intent;
import android.view.Window;

/**
 * An activity is a single, focused thing that the user can do.
 */
public class Activity extends ContextWrapper {
    Intent mIntent;

    private Window mWindow;

    /** Retrieve the current Window for the activity. */
    public Window getWindow() {
        return mWindow;
    }

    /** Return the intent that started this activity. */
    public Intent getIntent() {
        return mIntent;
    }
}
