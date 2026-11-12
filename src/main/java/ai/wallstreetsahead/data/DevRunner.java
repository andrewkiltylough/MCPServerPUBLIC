package ai.wallstreetsahead.data;

/**
 * Run this from the IDE to exercise the Azure comparison without Claude or the MCP protocol.
 * By default it only checks what is missing. Add the argument "fetch" to download as well.
 *
 * Program arguments (all optional): an ETF code such as SPY, the word "full", the word "fetch".
 */
public final class DevRunner {

    public static void main(String[] args) throws Exception {
        String etf = null;
        boolean full = false;
        boolean fetch = false;
        for (String arg : args) {
            if (arg.equalsIgnoreCase("full")) {
                full = true;
            } else if (arg.equalsIgnoreCase("fetch")) {
                fetch = true;
            } else {
                etf = arg;
            }
        }

        Config config = Config.fromEnv();
        System.out.println("Gateway: " + config.apiUrl());
        System.out.println("Share: " + config.shareName() + " / " + config.remoteRoot());
        System.out.println("Local: " + config.localRoot());
        String missing = config.missingApiSettings();
        if (missing != null) {
            System.out.println(missing);
            return;
        }

        try (ShareSync sync = new ShareSync(config)) {
            ShareSync.Plan plan = sync.plan(new ShareSync.Filter(etf, null, null, full));
            System.out.println("Remote files checked: " + plan.remoteFilesChecked());
            System.out.println("Already current locally: " + plan.alreadyCurrent());
            System.out.println("Newest remote date folder: " + plan.newestRemoteDate());
            System.out.println("Files to download: " + plan.toDownload().size());
            plan.toDownload().stream().limit(20).forEach(f -> System.out.println("  " + f.relativePath()));
            if (!fetch) {
                System.out.println("Check only. Add the program argument \"fetch\" to download.");
            } else if (!plan.toDownload().isEmpty()) {
                ShareSync.Result result = sync.download(plan);
                System.out.println("Downloaded " + result.downloaded() + " files into " + config.localRoot());
                result.failures().forEach(f -> System.out.println("  FAILED " + f));
            }
        }
    }
}
