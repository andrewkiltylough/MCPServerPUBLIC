package ai.wallstreetsahead.data;

import com.azure.core.http.HttpHeaderName;
import com.azure.core.http.HttpPipelineCallContext;
import com.azure.core.http.HttpPipelineNextPolicy;
import com.azure.core.http.HttpPipelineNextSyncPolicy;
import com.azure.core.http.HttpRequest;
import com.azure.core.http.HttpResponse;
import com.azure.core.http.policy.HttpPipelinePolicy;
import reactor.core.publisher.Mono;

/**
 * Sends the Azure Files requests the SDK builds to the API Management gateway instead of the storage account,
 * with the API key attached.
 *
 * The SDK's endpoint parsing drops any path from the URL it is given, so the client is built against
 * {@link #PLACEHOLDER} and each request is re-pointed here.
 */
final class GatewayPolicy implements HttpPipelinePolicy {

    static final String PLACEHOLDER = "https://wallstreetsahead-gateway.invalid";
    private static final HttpHeaderName KEY_HEADER = HttpHeaderName.fromString("Ocp-Apim-Subscription-Key");

    private final String apiUrl;
    private final String apiKey;

    GatewayPolicy(String apiUrl, String apiKey) {
        this.apiUrl = apiUrl;
        this.apiKey = apiKey;
    }

    @Override
    public Mono<HttpResponse> process(HttpPipelineCallContext context, HttpPipelineNextPolicy next) {
        prepare(context.getHttpRequest());
        return next.process();
    }

    @Override
    public HttpResponse processSync(HttpPipelineCallContext context, HttpPipelineNextSyncPolicy next) {
        prepare(context.getHttpRequest());
        return next.processSync();
    }

    private void prepare(HttpRequest request) {
        String url = request.getUrl().toString();
        // retries reuse the request, so only rewrite it once
        if (url.startsWith(PLACEHOLDER)) {
            // the SDK encodes '/' inside directory paths; send plain slashes so the gateway matches them reliably
            request.setUrl(apiUrl + url.substring(PLACEHOLDER.length()).replace("%2F", "/").replace("%2f", "/"));
        }
        request.setHeader(KEY_HEADER, apiKey);
    }
}
