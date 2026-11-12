package ai.wallstreetsahead.data;

import com.azure.storage.file.share.ShareClient;
import com.azure.storage.file.share.ShareClientBuilder;
import com.azure.storage.file.share.ShareDirectoryClient;
import com.azure.storage.file.share.models.ShareFileItem;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.regex.Pattern;
import java.util.stream.Stream;

/**
 * Compares the Azure file share with the local folder and downloads what is missing or changed.
 * It only ever adds or replaces local files; nothing local is deleted.
 */
public final class ShareSync implements AutoCloseable {

    /** Date folders are named MM-DD-YYYY, which does not sort as text, so they are always parsed. */
    static final DateTimeFormatter FOLDER_DATE = DateTimeFormatter.ofPattern("MM-dd-uuuu");
    private static final Pattern DATE_NAME = Pattern.compile("\\d{2}-\\d{2}-\\d{4}");

    /** Recent folders are re-checked because later runs add files to them. */
    static final int OVERLAP_DAYS = 3;
    private static final int THREADS = 8;

    public record Filter(String etf, LocalDate since, LocalDate until, boolean full) {
    }

    public record RemoteFile(String relativePath, long size, LocalDate folderDate) {
    }

    public record Entry(String name, boolean directory, long size) {
    }

    public record Plan(List<RemoteFile> toDownload, int remoteFilesChecked, int alreadyCurrent,
                       LocalDate newestRemoteDate, List<String> topFolders) {
        long totalBytes() {
            return toDownload.stream().mapToLong(RemoteFile::size).sum();
        }

        Map<LocalDate, Integer> countByDate() {
            Map<LocalDate, Integer> byDate = new TreeMap<>();
            for (RemoteFile f : toDownload) {
                if (f.folderDate() != null) {
                    byDate.merge(f.folderDate(), 1, Integer::sum);
                }
            }
            return byDate;
        }
    }

    public record Result(int downloaded, long bytes, List<String> failures) {
    }

    private final Config config;
    private final ShareClient share;
    private final ExecutorService pool = Executors.newFixedThreadPool(THREADS, r -> {
        Thread t = new Thread(r, "wallstreetsahead-sync");
        t.setDaemon(true);
        return t;
    });

    public ShareSync(Config config) {
        this.config = config;
        this.share = new ShareClientBuilder()
                .endpoint(GatewayPolicy.PLACEHOLDER)
                .shareName(config.shareName())
                .addPolicy(new GatewayPolicy(config.apiUrl(), config.apiKey()))
                .buildClient();
    }

    /** Lists one remote folder, relative to the configured remote root. */
    public List<Entry> list(String relativePath) {
        List<Entry> entries = new ArrayList<>();
        for (ShareFileItem item : directory(Config.normaliseRemote(relativePath)).listFilesAndDirectories()) {
            entries.add(new Entry(item.getName(), item.isDirectory(), item.isDirectory() ? 0 : orZero(item.getFileSize())));
        }
        entries.sort(Comparator.comparing(Entry::directory).reversed().thenComparing(Entry::name));
        return entries;
    }

    /** Walks the share and works out which files are missing locally or differ in size. */
    public Plan plan(Filter filter) throws IOException, InterruptedException {
        List<String> topFolders = new ArrayList<>();
        List<Dir> level = new ArrayList<>();
        for (Entry e : list("")) {
            if (e.directory() && isSafeName(e.name()) && matchesEtf(e.name(), filter.etf())) {
                topFolders.add(e.name());
                level.add(new Dir(e.name(), sinceFor(e.name(), filter), null));
            }
        }

        List<RemoteFile> remoteFiles = new ArrayList<>();
        while (!level.isEmpty()) {
            List<Future<Listing>> futures = new ArrayList<>();
            for (Dir dir : level) {
                futures.add(pool.submit(listTask(dir, filter)));
            }
            List<Dir> next = new ArrayList<>();
            for (Future<Listing> f : futures) {
                Listing listing = await(f);
                next.addAll(listing.dirs());
                remoteFiles.addAll(listing.files());
            }
            level = next;
        }

        List<RemoteFile> toDownload = new ArrayList<>();
        LocalDate newest = null;
        int current = 0;
        for (RemoteFile f : remoteFiles) {
            if (f.folderDate() != null && (newest == null || f.folderDate().isAfter(newest))) {
                newest = f.folderDate();
            }
            Path local = localPath(f.relativePath());
            if (Files.isRegularFile(local) && Files.size(local) == f.size()) {
                current++;
            } else {
                toDownload.add(f);
            }
        }
        toDownload.sort(Comparator.comparing(RemoteFile::relativePath));
        return new Plan(toDownload, remoteFiles.size(), current, newest, topFolders);
    }

    /** Downloads every file in the plan. Each file is written to a temporary name and then moved into place. */
    public Result download(Plan plan) throws InterruptedException {
        List<Future<Long>> futures = new ArrayList<>();
        for (RemoteFile f : plan.toDownload()) {
            futures.add(pool.submit(() -> downloadOne(f)));
        }
        int done = 0;
        long bytes = 0;
        List<String> failures = new ArrayList<>();
        for (int i = 0; i < futures.size(); i++) {
            try {
                bytes += futures.get(i).get();
                done++;
            } catch (ExecutionException e) {
                failures.add(plan.toDownload().get(i).relativePath() + ": " + rootMessage(e));
            }
        }
        return new Result(done, bytes, failures);
    }

    /** Newest date folder found locally under the given top-level folder, or null when there is none. */
    public static LocalDate newestLocalDate(Path topFolder) {
        if (!Files.isDirectory(topFolder)) {
            return null;
        }
        try (Stream<Path> children = Files.list(topFolder)) {
            return children.filter(Files::isDirectory)
                    .map(p -> parseDate(p.getFileName().toString()))
                    .filter(d -> d != null)
                    .max(Comparator.naturalOrder())
                    .orElse(null);
        } catch (IOException e) {
            return null;
        }
    }

    static LocalDate parseDate(String name) {
        if (!DATE_NAME.matcher(name).matches()) {
            return null;
        }
        try {
            return LocalDate.parse(name, FOLDER_DATE);
        } catch (DateTimeParseException e) {
            return null;
        }
    }

    @Override
    public void close() {
        pool.shutdownNow();
    }

    private record Dir(String path, LocalDate since, LocalDate folderDate) {
    }

    private record Listing(List<Dir> dirs, List<RemoteFile> files) {
    }

    private Callable<Listing> listTask(Dir dir, Filter filter) {
        return () -> {
            List<Dir> dirs = new ArrayList<>();
            List<RemoteFile> files = new ArrayList<>();
            for (ShareFileItem item : directory(dir.path()).listFilesAndDirectories()) {
                String name = item.getName();
                if (!isSafeName(name)) {
                    continue;
                }
                String path = dir.path() + "/" + name;
                if (item.isDirectory()) {
                    LocalDate date = parseDate(name);
                    if (date != null && !inRange(date, dir.since(), filter.until())) {
                        continue;
                    }
                    dirs.add(new Dir(path, dir.since(), date != null ? date : dir.folderDate()));
                } else {
                    files.add(new RemoteFile(path, orZero(item.getFileSize()), dir.folderDate()));
                }
            }
            return new Listing(dirs, files);
        };
    }

    /** An explicit 'since' wins; a full check has no lower bound; otherwise start just before the newest local folder. */
    private LocalDate sinceFor(String topFolder, Filter filter) {
        if (filter.since() != null) {
            return filter.since();
        }
        if (filter.full()) {
            return null;
        }
        LocalDate newestLocal = newestLocalDate(config.localRoot().resolve(topFolder));
        return newestLocal == null ? null : newestLocal.minusDays(OVERLAP_DAYS);
    }

    private long downloadOne(RemoteFile f) throws IOException {
        Path target = localPath(f.relativePath());
        Files.createDirectories(target.getParent());
        Path temp = target.resolveSibling(target.getFileName() + ".part");
        int slash = f.relativePath().lastIndexOf('/');
        ShareDirectoryClient dir = directory(f.relativePath().substring(0, slash));
        try (OutputStream out = Files.newOutputStream(temp)) {
            dir.getFileClient(f.relativePath().substring(slash + 1)).download(out);
        } catch (RuntimeException | IOException e) {
            Files.deleteIfExists(temp);
            throw e;
        }
        Files.move(temp, target, StandardCopyOption.REPLACE_EXISTING);
        return Files.size(target);
    }

    private ShareDirectoryClient directory(String relativePath) {
        String full = join(config.remoteRoot(), relativePath);
        return full.isEmpty() ? share.getRootDirectoryClient() : share.getDirectoryClient(full);
    }

    /** Remote names are not trusted: the resolved path must stay inside the local root. */
    private Path localPath(String relativePath) throws IOException {
        Path resolved = config.localRoot().resolve(relativePath.replace('/', java.io.File.separatorChar)).normalize();
        if (!resolved.startsWith(config.localRoot())) {
            throw new IOException("Remote path escapes the local folder: " + relativePath);
        }
        return resolved;
    }

    private static boolean isSafeName(String name) {
        return name != null && !name.isBlank() && !name.equals(".") && !name.equals("..")
                && name.indexOf('/') < 0 && name.indexOf('\\') < 0 && name.indexOf(':') < 0;
    }

    private static boolean matchesEtf(String folder, String etf) {
        if (etf == null || etf.isBlank()) {
            return true;
        }
        String want = etf.trim().toUpperCase(Locale.ROOT);
        String have = folder.toUpperCase(Locale.ROOT);
        // ETE_XLE is a misspelt folder that sits alongside the ETF_ folders
        return have.equals(want) || have.equals("ETF_" + want) || have.equals("ETE_" + want);
    }

    private static boolean inRange(LocalDate date, LocalDate since, LocalDate until) {
        return (since == null || !date.isBefore(since)) && (until == null || !date.isAfter(until));
    }

    private static String join(String a, String b) {
        if (a == null || a.isEmpty()) {
            return b == null ? "" : b;
        }
        return b == null || b.isEmpty() ? a : a + "/" + b;
    }

    private static long orZero(Long value) {
        return value == null ? 0 : value;
    }

    private static <T> T await(Future<T> future) throws IOException, InterruptedException {
        try {
            return future.get();
        } catch (ExecutionException e) {
            throw new IOException(rootMessage(e), e.getCause());
        }
    }

    private static String rootMessage(Throwable t) {
        Throwable cause = t.getCause() != null ? t.getCause() : t;
        String message = cause.getMessage();
        return cause.getClass().getSimpleName() + (message == null ? "" : ": " + message.lines().findFirst().orElse(""));
    }
}
