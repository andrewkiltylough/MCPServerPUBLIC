package ai.wallstreetsahead.data;

import java.io.IOException;
import java.io.Reader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Properties;

/**
 * Settings for the Azure API Management gateway and the local folder.
 *
 * Each setting is taken from an environment variable if set, otherwise from the
 * local settings file, otherwise from the default below. The API key is a
 * secret: it has no default, is only ever read here and sent to the gateway,
 * and is never logged or returned.
 *
 * The server never talks to the storage account directly. The gateway checks
 * the API key, records usage per key, and reads the share with its own managed
 * identity, so no storage credential is needed on this machine.
 */
public record Config(String apiUrl, String apiKey, String shareName, String remoteRoot, Path localRoot,
		Path settingsFile) {

	private static final String ENV_PREFIX = "WALLSTREETSAHEAD_";
	/**
	 * The prefix this tool used before it was renamed. Still honoured, so a setup
	 * made against the old name keeps working without being touched.
	 */
	private static final String LEGACY_ENV_PREFIX = "DAYBYDAY_";

	public static final String ENV_API_URL = ENV_PREFIX + "API_URL";
	public static final String ENV_API_KEY = ENV_PREFIX + "API_KEY";
	public static final String ENV_SHARE = ENV_PREFIX + "SHARE_NAME";
	public static final String ENV_REMOTE_ROOT = ENV_PREFIX + "REMOTE_ROOT";
	public static final String ENV_LOCAL_ROOT = ENV_PREFIX + "LOCAL_ROOT";
	public static final String ENV_SETTINGS_FILE = ENV_PREFIX + "SETTINGS_FILE";

	/** Keys in the local settings file. */
	public static final String KEY_API_URL = "apiUrl";
	public static final String KEY_API_KEY = "apiKey";
	public static final String KEY_SHARE = "shareName";
	public static final String KEY_REMOTE_ROOT = "remoteRoot";
	public static final String KEY_LOCAL_ROOT = "localRoot";

	/**
	 * The share the DayByDayRunner reports are published to (storage account
	 * premindstock). These two are addresses in someone else's system, not names
	 * of this tool, so they did not change when it was renamed.
	 */
	private static final String DEFAULT_SHARE = "premind-stock";
	/** Folder in the share that holds the ETF_* report folders. */
	private static final String DEFAULT_REMOTE_ROOT = "SignalMoves/DayByDayRunner";

	private static final String DEFAULT_LOCAL_ROOT = "C:\\WallStreetsAhead";
	/** Where the reports were kept before the rename. */
	private static final String LEGACY_LOCAL_ROOT = "C:\\DayByDayRunner";

	public static Config fromEnv() {
		Path settingsFile = settingsFilePath();
		Properties file = load(settingsFile);

		String apiUrl = trimSlashes(firstNonBlank(env(ENV_API_URL), file.getProperty(KEY_API_URL)));
		String apiKey = firstNonBlank(env(ENV_API_KEY), file.getProperty(KEY_API_KEY));
		String share = firstNonBlank(env(ENV_SHARE), file.getProperty(KEY_SHARE), DEFAULT_SHARE);
		String remoteRoot = normaliseRemote(
				firstNonBlank(env(ENV_REMOTE_ROOT), file.getProperty(KEY_REMOTE_ROOT), DEFAULT_REMOTE_ROOT));
		String local = firstNonBlank(env(ENV_LOCAL_ROOT), file.getProperty(KEY_LOCAL_ROOT), defaultLocalRoot());
		return new Config(apiUrl, apiKey, share, remoteRoot, Paths.get(local).toAbsolutePath().normalize(),
				settingsFile);
	}

	/**
	 * Reads an environment variable, falling back to the name this tool used
	 * before it was renamed.
	 */
	private static String env(String name) {
		String value = System.getenv(name);
		if (value == null && name.startsWith(ENV_PREFIX)) {
			value = System.getenv(LEGACY_ENV_PREFIX + name.substring(ENV_PREFIX.length()));
		}
		return value;
	}

	/**
	 * Keeps using the pre-rename folder when it is the one holding the reports. A
	 * machine set up before the rename has thousands of files there, and silently
	 * moving to the new default would download all of them again.
	 */
	private static String defaultLocalRoot() {
		if (!Files.isDirectory(Paths.get(DEFAULT_LOCAL_ROOT)) && Files.isDirectory(Paths.get(LEGACY_LOCAL_ROOT))) {
			return LEGACY_LOCAL_ROOT;
		}
		return DEFAULT_LOCAL_ROOT;
	}

	/**
	 * Returns a message naming what is missing, or null when gateway access is
	 * fully configured.
	 */
	public String missingApiSettings() {
		if (apiKey == null) {
			return "No API key found. Set the plugin's API key (/plugin, then configure wallstreetsahead-data), add "
					+ KEY_API_KEY + "=... to " + settingsFile + " or set the environment variable " + ENV_API_KEY
					+ ", then restart Claude.";
		}
		if (apiUrl == null) {
			return "No API URL found. Set the plugin's API URL, add " + KEY_API_URL + "=... to " + settingsFile
					+ " or set the environment variable " + ENV_API_URL + ", then restart Claude.";
		}
		if (!apiUrl.startsWith("https://")) {
			return "The API URL must start with https:// so the API key is not sent in clear text.";
		}
		if (shareName == null) {
			return "No file share name found. Add " + KEY_SHARE + "=... to " + settingsFile
					+ " or set the environment variable " + ENV_SHARE + ", then restart Claude.";
		}
		return null;
	}

	static String normaliseRemote(String path) {
		if (path == null) {
			return "";
		}
		String p = path.trim().replace('\\', '/');
		while (p.startsWith("/")) {
			p = p.substring(1);
		}
		return trimSlashes(p);
	}

	private static String trimSlashes(String value) {
		if (value == null) {
			return null;
		}
		String v = value;
		while (v.endsWith("/")) {
			v = v.substring(0, v.length() - 1);
		}
		return v;
	}

	/**
	 * Kept in the user's home folder so the secret never sits in the source tree or
	 * the jar.
	 */
	private static Path settingsFilePath() {
		String override = firstNonBlank(env(ENV_SETTINGS_FILE));
		if (override != null) {
			return Paths.get(override).toAbsolutePath().normalize();
		}
		Path home = Paths.get(System.getProperty("user.home"));
		Path current = home.resolve(".wallstreetsahead").resolve("wallstreetsahead.properties");
		if (Files.isRegularFile(current)) {
			return current;
		}
		// a setup made before the rename keeps its key where it already is
		Path legacy = home.resolve(".daybyday").resolve("daybyday.properties");
		if (Files.isRegularFile(legacy)) {
			return legacy;
		}
		// neither exists: name the new location, so the messages below point there
		return current;
	}

	private static Properties load(Path file) {
		Properties props = new Properties();
		if (Files.isRegularFile(file)) {
			try (Reader reader = Files.newBufferedReader(file, StandardCharsets.UTF_8)) {
				props.load(reader);
			} catch (IOException e) {
				// unreadable settings file is treated as absent; the tools then report what is
				// missing
			}
		}
		return props;
	}

	/**
	 * A plugin option the user has not set can arrive as an unexpanded
	 * ${user_config.x} reference, so that counts as blank too.
	 */
	private static String firstNonBlank(String... values) {
		for (String v : values) {
			if (v != null && !v.isBlank() && !v.trim().startsWith("${")) {
				return v.trim();
			}
		}
		return null;
	}
}
