# NappStore iOS

SwiftUI recreation of the supplied NappStore screens: Explore, Installed,
Library, Settings, product filters, product details, logs, and purchase
confirmation.

## Build an IPA without xcodebuild

`build_ipa.sh` invokes `swiftc` with the iPhoneOS SDK, signs with the first
available Apple Development identity and provisioning profile, and writes:

```text
output/NappStore-dev.ipa
```

The script copies only the entitlements from the selected provisioning profile
and removes `platform-application` and
`com.apple.private.security.no-sandbox`. Those private entitlements are not
part of a normal development IPA. Override the automatic selection when
needed:

```bash
SIGN_IDENTITY='Apple Development: Your Name (TEAMID)' \
PROVISIONING_PROFILE='/path/to/profile.mobileprovision' \
./build_ipa.sh
```

Install the staged app on the connected device with:

```bash
APP=$(ls -dt build/ipa-*/Payload/NappStore.app | head -1)
xcrun devicectl device install app --device 00008101-001675681139001E "$APP"
xcrun devicectl device process launch --device 00008101-001675681139001E dev.dothanh.nappstore
```

## Catalog and payments

The app reads JSON or plist catalog files from its Documents `IAPCheck`
directory and, when permitted by a companion bridge, from the shared paths
used by that bridge. It accepts the current `ScanSnapshot` format as well as
common exports containing `products`, `items`, `inAppPurchases`, product IDs,
offers, trial phases, prices, and hidden/listed flags. It does not insert fake
products when no catalog is available.

This checkout also contains local catalog exports under
`CatalogData/ReferenceCatalog`. They are display data copied during development;
their provenance and freshness are not verified at runtime. The current exports
cover CapCut (217 products), YouTube (60), and ChatGPT (6). Any additional JSON
export with a filename such as `com.example.app_v6.json` is grouped by its bundle
ID in the same way. To refresh the local export from a developer-paired phone,
run:

```bash
./sync_reference_catalog.sh dinh
```

To sync another export directory, set `NAPPSTORE_CATALOG_DIR`; every JSON
file in that directory is copied and grouped by its filename/bundle ID:

```bash
NAPPSTORE_CATALOG_DIR="$PWD/my-catalogs" ./sync_reference_catalog.sh dinh
```

The script writes only to NappStore's own developer-accessible container. It
cannot make the app read IAPPay's sandbox at runtime; iOS keeps those app data
containers separate.

StoreKit can fetch and purchase products configured for NappStore's own bundle
ID (`dev.dothanh.nappstore`). A normal sandboxed IPA cannot enumerate or
purchase another app's products simply by changing the product ID; the product
request is associated with the signed app and its App Store configuration. The
Direct button therefore only sends a command to an authorized companion bridge
and never claims that a transaction succeeded or fabricates a receipt.

For a catalog item, the app keeps the numeric Adam ID separate from the
StoreKit product identifier and sends `productNumber`/`offerId` to a companion
when a Direct command is queued. A normal sandboxed IPA still cannot purchase
another app's product: the only transaction Apple can verify in this process is
one belonging to NappStore's own signed bundle. The Direct button therefore
opens the target app and reports “đang chờ bridge”; it never fabricates a
receipt.

Cross-app purchasing requires a separately verified companion operating in the
target app's authorized StoreKit flow. NappStore can send a generic command
(`bundleId`, `productId`, `adamId`, and `mode`) to such a companion, but the IPA
does not itself present another app's Apple sheet or claim that a transaction
succeeded.
