package android.os;

/**
 * Information about the current build, extracted from system properties.
 */
public class Build {
    /** The name of the overall product. */
    public static final String PRODUCT = getString("ro.product.name");

    /**
     * Various version strings.
     */
    public static class VERSION {
        /**
         * The SDK version of the software currently running on this hardware
         * device.
         */
        public static final int SDK_INT = SystemProperties.getInt("ro.build.version.sdk", 0);
    }

    /**
     * Enumeration of the currently known SDK version codes.
     */
    public static class VERSION_CODES {
        /** Android 10. */
        public static final int Q = 29;
    }

    private static String getString(String property) {
        return SystemProperties.get(property, "unknown");
    }
}
