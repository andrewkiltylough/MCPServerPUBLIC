# Azure setup: API keys with usage analytics

How the gateway behind WallStreetsAhead.ai is set up, and how to issue keys for it.

> **The public URL is now `https://api.wallstreetsahead.ai/ClaudeCodePlugin`.**
> The gateway has a custom domain with a free Azure-managed certificate, and the
> data API's path was renamed from `daybyday`. The old
> `premind-apim.azure-api.net` hostname still answers, but `/daybyday` does not:
> anyone who installed before the rename has to update the API URL in their
> settings or reinstall. Their keys are unaffected — a subscription is scoped to
> the API's resource id, which did not change.
>
> **Everything else still says `daybyday` and `premind`, on purpose.** The
> api-ids, the `daybyday-*` named values, the register path, the resource group,
> the APIM instance and the storage account are all **already deployed** and
> never appear in front of a user. Renaming them would mean rescoping every
> subscription for no visible gain. In particular the register path stays
> `daybyday-register`: it is baked into every installer already downloaded, so
> renaming it would silently stop new users getting a key. The report folder
> `SignalMoves/DayByDayRunner` is a path in someone else's system and never
> changes.

The tool no longer holds a storage key. Every request goes through **Azure API Management (APIM)**:

```
Claude tool ──(API key)──▶ API Management ──(managed identity)──▶ Azure Files (premindstock / premind-stock)
```

- Each person gets their own **subscription key**. That is the API key they put in the plugin.
- APIM records every call against the key that made it, so you can see who used it, how often, how much data, and what failed.
- You can turn a key off, regenerate it, or limit it, without touching anyone else's.
- APIM reads the share with its own managed identity. No storage key is on anyone's PC.

These steps use the Azure CLI. Each can also be done in the Azure portal. Replace the names in the first block with your own.

## 1. Choose names

```bash
RG=premind-rg
APIM=premind-apim
STORAGE=premindstock
LOCATION=uksouth
```

## 2. Create API Management

The **Consumption** tier is the cheapest for a small team: there is no monthly fee, the first million calls each month are free, and after that you pay per call. A first full fetch is roughly 10,000 calls; a daily fetch is a few hundred. Use **Basic v2** instead if you want a fixed price and the full built-in analytics pages.

```bash
az apim create -g $RG -n $APIM -l $LOCATION --sku-name Consumption --publisher-name "Premind" --publisher-email you@example.com --enable-managed-identity true
```

## 3. Let APIM read the share

```bash
PRINCIPAL=$(az apim show -g $RG -n $APIM --query identity.principalId -o tsv)
```

```bash
az role assignment create --assignee-object-id $PRINCIPAL --assignee-principal-type ServicePrincipal --role "Storage File Data Privileged Reader" --scope $(az storage account show -g $RG -n $STORAGE --query id -o tsv)
```

This is read-only access. The policy in the next step narrows it further to the DayByDayRunner folder.

## 4. Create the API

```bash
az apim api create -g $RG --service-name $APIM --api-id daybyday --path daybyday --display-name "DayByDay data" --service-url https://$STORAGE.file.core.windows.net --protocols https --subscription-required true
```

```bash
az apim api operation create -g $RG --service-name $APIM --api-id daybyday --operation-id read --display-name "Read" --method GET --url-template "/{*path}" --template-parameters name=path type=string required=true
```

Only `GET` is published, so the API cannot change or delete anything.

Then apply [apim-policy.xml](apim-policy.xml). In the portal: **APIs → DayByDay data → All operations → Inbound processing → </> (code view)**, paste the file, **Save**. Or with the CLI:

```bash
az rest --method put --url "https://management.azure.com$(az apim show -g $RG -n $APIM --query id -o tsv)/apis/daybyday/policies/policy?api-version=2022-08-01" --body "{\"properties\":{\"format\":\"rawxml\",\"value\":$(python -c "import json,sys;print(json.dumps(open('apim-policy.xml').read()))")}}"
```

The API URL people put in the plugin is:

```
https://api.wallstreetsahead.ai/ClaudeCodePlugin
```

## 5. Issue a key per person

In the portal: **API Management → Subscriptions → + Add subscription**.

- **Name**: the person, for example `andrew`. This is the name you will see in the analytics.
- **Scope**: API → DayByDay data.

Open the subscription, choose **Show/hide keys**, and send the person the **primary key** privately. Each subscription has a secondary key so you can rotate without downtime: switch people to the secondary, regenerate the primary.

To cut someone off, set their subscription to **Suspended**.

To limit how much a key can use, put the API in a **Product** with a `quota-by-key` or `rate-limit` policy and issue subscriptions on the product instead. If you add a rate limit, keep it above about 2,000 calls per minute or the first full fetch will be refused part way.

## 6. Turn on analytics

On the **Consumption** tier, gateway logs do not reach Log Analytics even with a diagnostic setting, so use **Application Insights**. `premind-apim` is set up this way: Application Insights resource `premind-apim-insights` (resource group `DiscoveryPipeline`), connected at 100% sampling, with a 0.5 GB daily cap.

1. Create an Application Insights resource in the same region as API Management.
2. **API Management → Monitoring → Application Insights → + Add**, select it, and set sampling to **100%** so every call is counted.
3. In the Application Insights resource, **Usage and estimated costs → Daily cap**: set a cap such as 0.5 GB/day. Normal use is well under 0.1 GB/day and inside the free 5 GB a month.

Only calls made after this is connected are recorded. Data appears within a few minutes.

Usage per key over the last 30 days (Application Insights → **Logs**):

```kusto
requests
| where timestamp > ago(30d)
| summarize Calls = count(), MB = round(sum(todouble(customDimensions["Response Size"])) / 1048576.0, 1), Failed = countif(toint(resultCode) >= 400), LastUsed = max(timestamp) by Key = tostring(customDimensions["Subscription Name"])
| order by Calls desc
```

Daily calls per key as a chart:

```kusto
requests
| where timestamp > ago(30d)
| summarize Calls = count() by bin(timestamp, 1d), Key = tostring(customDimensions["Subscription Name"])
| render timechart
```

Total requests are also charted without any logging under **API Management → Monitoring → Metrics → Requests**.

On **Basic v2** and above, you can instead add a diagnostic setting (**Logs related to ApiManagement Gateway**, **Resource specific**) and use the built-in **Monitoring → Analytics** page and the `ApiManagementGatewayLogs` table.

## 7. Rotate the old storage key

Earlier versions of this tool had the storage account key built into the code, and it is still in the git history. Once everyone has moved to API keys:

```bash
az storage account keys renew -g $RG -n $STORAGE --key primary
```

Check first whether any other Premind application uses that key, and update it with the new one.

## 8. Let the installer issue keys

> **Deployed as of 8 November 2026,** except the role assignment in *Let the
> gateway create subscriptions* below, which still has to be run. Until it is,
> a correct invite code gets `502` because the gateway cannot create the
> subscription. The API, its operation, the three named values and the policy
> are all in place, and the `400` and `403` paths work.

With this in place, the Windows installer asks the user for a name, an
email address and a shared **invite code**, and the gateway issues them their own
key. You hand out one code instead of a key per person, and still get a separate
subscription per email that you can see in the analytics and suspend on its own.

The installer never holds anything that could create a subscription. It knows the
gateway address and whatever code the user typed; the gateway does the creating
with its own managed identity. That matters because anyone who downloads the
setup can pull strings out of it.

### Create the registration API

```bash
az apim api create -g $RG --service-name $APIM --api-id daybyday-register --path daybyday-register --display-name "DayByDay register" --service-url https://management.azure.com --protocols https --subscription-required false
```

```bash
az apim api operation create -g $RG --service-name $APIM --api-id daybyday-register --operation-id register --display-name "Register" --method POST --url-template "/"
```

This one is deliberately `--subscription-required false`: a user has no key yet.
The invite code is the only thing standing in front of it.

**There is no rate limit, because the Consumption tier will not take one.**
`rate-limit`, `rate-limit-by-key`, `quota` and `quota-by-key` are all rejected at
policy validation on Consumption, and that tier has no built-in cache to count
attempts with either. What stands in for it is the entropy of the code — 20
characters from a 32-character alphabet — and the fact that a wrong code is
refused before the policy calls Azure Resource Manager, so bad attempts cost
gateway invocations and nothing else. If the endpoint is ever abused, move to a
paid tier and restore `rate-limit-by-key`, or attach an external Redis cache.

### Add the named values

```bash
APIM_ID=$(az apim show -g $RG -n $APIM --query id -o tsv)
```

```bash
az apim nv create -g $RG --service-name $APIM --named-value-id daybyday-invite-code --display-name daybyday-invite-code --secret true --value "<pick a long random code>"
```

```bash
az apim nv create -g $RG --service-name $APIM --named-value-id daybyday-apim-resource-id --display-name daybyday-apim-resource-id --value "$APIM_ID"
```

```bash
az apim nv create -g $RG --service-name $APIM --named-value-id daybyday-api-url --display-name daybyday-api-url --value "https://api.wallstreetsahead.ai/ClaudeCodePlugin"
```

### Let the gateway create subscriptions

A custom role, so the gateway's identity can create subscriptions and read their
keys and nothing else. The built-in **API Management Service Contributor** also
works but can delete the service itself.

```bash
az role definition create --role-definition "{\"Name\":\"DayByDay subscription issuer\",\"IsCustom\":true,\"Description\":\"Create API Management subscriptions and read their keys.\",\"Actions\":[\"Microsoft.ApiManagement/service/subscriptions/read\",\"Microsoft.ApiManagement/service/subscriptions/write\",\"Microsoft.ApiManagement/service/subscriptions/listSecrets/action\"],\"AssignableScopes\":[\"$APIM_ID\"]}"
```

```bash
az role assignment create --assignee-object-id $(az apim show -g $RG -n $APIM --query identity.principalId -o tsv) --assignee-principal-type ServicePrincipal --role "DayByDay subscription issuer" --scope $APIM_ID
```

### Apply the policy

Apply [apim-register-policy.xml](apim-register-policy.xml) to the
`daybyday-register` API, the same way as the main policy: **APIs → DayByDay
register → All operations → Inbound processing → </> (code view)**, paste, save.

### Check it

```bash
curl -s -i -X POST -H "Content-Type: application/json" -d '{"name":"Test User","email":"test@example.com","code":"<the invite code>"}' "https://api.wallstreetsahead.ai/daybyday-register"
```

`200` returns two lines, `apiUrl=` and `apiKey=`. Delete the test subscription
afterwards, under **Subscriptions**, or it will sit in your analytics.

Other outcomes: `403` wrong code, `409` that email already has a key, `429` more
than five attempts an hour from one address, `502` the gateway could not reach
ARM, which usually means the role assignment above is missing or has not taken
effect yet.

### Things to know

- **The subscription id is a hash of the address, not the address.** A resource
  name travels further than the resource: every create and delete is written to
  the Azure Activity Log, which is kept for 90 days regardless of what happens
  to the subscription itself. An address in the name would therefore outlive the
  record it belongs to, and survive a deletion request. The address is still
  held in plain text in the subscription's **display name**, which is deleted
  with the subscription. Subscriptions created before this change still carry
  the address in their resource name.
- **One key per email, and it is never handed back twice.** A second request for
  the same address gets `409`, so nobody with the invite code can read back
  someone else's key by typing their address. The cost is that a person
  reinstalling on a new PC needs you to reissue, or to copy their key across from
  `%USERPROFILE%\.wallstreetsahead\wallstreetsahead.properties`.
- **The invite code is a shared secret**, so treat it like one: it will end up in
  a group chat eventually. Change it by updating the `daybyday-invite-code` named
  value; keys already issued keep working.
- **Email addresses are not verified.** The name and email are for attribution,
  not proof of identity. If you need them to be real, the alternative is to mail
  the key to the address instead of returning it, which needs an email sender.
- Collecting a name and email makes you the holder of personal data. Say on the
  download page what you collect it for.

## Checking a key works

```bash
curl -s -o /dev/null -w "%{http_code}\n" -H "Ocp-Apim-Subscription-Key: <key>" "https://<APIM>.azure-api.net/daybyday/premind-stock/SignalMoves/DayByDayRunner?restype=directory&comp=list"
```

`200` means the key and the storage access both work. `401` is a bad key. `403` from storage (with an XML body) means the role assignment in step 3 is missing or has not taken effect yet; it can take a few minutes.
