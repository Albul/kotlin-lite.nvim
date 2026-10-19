package android.content;

/**
 * An intent is an abstract description of an operation to be performed.
 */
public class Intent implements Parcelable, Cloneable {
    private String mAction;

    /**
     * Retrieve the general action to be performed, such as
     * {@link #ACTION_VIEW}.
     */
    public @Nullable String getAction() {
        return mAction;
    }
}
