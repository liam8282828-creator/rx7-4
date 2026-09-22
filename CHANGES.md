## Native Holograma Arma import workspace

- Added a native UIKit entry point from the home screen for Holograma Arma.
- Bundled the principal, robótico, and pared dumps from the web workflow.
- Added local asset selection, automatic bundled-dump defaults, the web Path ID manifest, mode selection for ROBÓTICO/BORDES, and a Files view for each saved import session.

# External source changes

- Default accent color is `#64D841`.
- The `FF` and `FF 2022` patch lists now use selectable options and a
  bottom `Inject` button.
- Injection status displays `Injecting…`, `Success`, or an error state.
- Added `REMOVE AIMS FF` below `BODY DISGUISED` in the `FF` section.
- Added the supplied `REMOVE_AIMS_FF.3105` package to the `FF` resources.
- Patch resources are grouped in `ThreeOneOSFive/Resources/FF`,
  and `ThreeOneOSFive/Resources/FF2022`. The runtime loader supports both
  grouped resources and flat app bundles.
- Removed the unused `cache_res.3105` and `aim_assetindexer.3105` resources
  and their old built-in project references.
- Removed the unused `FF/CHEST_90%.3105` resource and its catalog/build
  references.
- Renamed the FF 2022 reset option to `REMOVE AIMS FF 2022`.
- Injection feedback now stays active for at least two seconds.
- Added a shared fast motion style, press feedback, and cross-fade/spring
  transitions; the injection list is fixed and does not scroll.
- Updated the default accent to the exact color sampled from the supplied
  image: `#64D841`.