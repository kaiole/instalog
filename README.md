# Instalog

A routine-first nutrition tracker for iOS: a Cronometer-style tracker redesigned around the meals you
eat every day. The main screen shows one section (Breakfast, Lunch, …) and one selected saved meal.
Adjust today's amounts if you need to, then log it with one tap. The entries you've logged sit in the
same section card.

Free, local-only, no account, no ads, no cloud sync.

## Requirements

- Xcode 27 or newer (Swift 6 toolchain). Built and tested with Xcode 27.0, iOS 27 simulator.
- Deployment target: iOS 17.0.
- No paid developer membership, API keys or network access needed.

## Build and run

```sh
open Instalog.xcodeproj          # select the Instalog scheme and an iPhone simulator, then Run
```

Command line:

```sh
xcodebuild -project Instalog.xcodeproj -scheme Instalog \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

On first launch the library is empty. Tap **Load demo routine** to get eight saved meals built from
real USDA foods, four sections (Breakfast, Lunch, Snack, Dinner; Dinner has no assigned meals, so it
shows all of them) and sample calorie/macro targets.

## Using the app

**Core task: log the meals you eat every day in one tap.**

1. **Today screen.** The header shows calories and up to three nutrients you choose, against your
   targets. Below it, the section card (e.g. *Breakfast*) shows what you've already logged there and
   the selected saved meal.
2. **Log a saved meal.** Optionally change an amount in the meal card (this affects only this log),
   then tap the **Log** button at the bottom (it reads **Log again** if you've already logged that meal today). The entry appears in the section card and the totals update.
3. **Switch sections or meals.** Use the ▲ ▼ buttons, swipe vertically on the section header, or tap
   the section name to open the **Sections** sheet. That sheet also lists the foods logged in every
   section, so it doubles as a daily overview.
4. **Add something else.** **Add food** searches the bundled USDA catalog (or lets you create a custom
   food), supports several foods in one entry, and can save the result as a new meal.
5. **Edit or delete an entry.** Tap an entry to change its amounts, move it to another section or
   save it as a meal. Swipe it to reveal **Delete**; an undo toast appears afterwards.
6. **Look at other days.** Tap the date heading to pick a day, or use the ‹ › arrows, to review or log into a past day.
7. **Nutrients.** Tap the summary to see every nutrient, how complete the data is and how it
   compares with your target.

**Settings** (sliders icon, top right):

- **Order sections and assign meals.** Name and order sections and choose which saved meals each one offers.
- **Saved meals.** Create and edit the meals you log (the meal library).
- **Scheduled meals.** Pick a saved meal, a section, a time and the days it repeats (or a single
  date). It logs itself at that time. Before then it shows on Today as a faded row with a clock and
  isn't counted. Tap that row to **Skip today**, **Log now** or **Edit schedule**. Logging by hand
  never cancels a schedule. Missed occurrences are filled in on the day they belong to when the app
  next opens (up to the last 7 days). An optional notification, off by default, is sent after the meal logs.
- **Targets.** Calories and macros are yours to set, and the app warns when macros don't add up to
  the calorie target (4/4/9 kcal per gram). Other nutrients default to FDA Daily Values, with
  per-nutrient overrides and a **Reset all to FDA Daily Values** action.
- **Export or import.** Back up or restore everything as a JSON file.

## Tests

```sh
# Domain, persistence, catalog and acceptance tests (fast, runs on macOS)
cd Packages/InstalogCore && swift test

# UI flow tests on the simulator (drives the app through accessibility elements only)
xcodebuild -project Instalog.xcodeproj -scheme Instalog \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Set `SCREENSHOT_DIR=/some/dir` when running the UI tests to save screenshots of each step.
Debug builds also accept the `--reset-data` launch argument to start with an empty store.

Tests are named after acceptance IDs (AT-01 … AT-37) and defaults (D-01 … D-16).

## Layout

```
Instalog/                     SwiftUI app (presentation only)
  Today/                      main screen: summary, section card, meal card, logged entries
  Sheets/                     sections, entry editor, nutrients, day picker
  Food/                       Add food, search, food detail, custom food form
  Settings/                   settings, sections & meals setup, meal library/editor, targets, export/import
  Resources/Fonts/            Geist and Geist Mono (SIL OFL 1.1)
InstalogUITests/              XCUITest flows
Packages/InstalogCore/        everything testable without UI
  Nutrition/                  nutrient registry + USDA mappings, units, calculator, FDA reference values
  Model/                      foods, saved meals, sections, logged entries + snapshots, targets, preferences
  Domain/                     meal selection, progression policy, logging service, targets, export/import, demo
  Persistence/                SQLite wrapper and the personal store
  Catalog/                    bundled USDA catalog search
  App/DiaryModel.swift        observable state machine behind the main screen
  Resources/catalog.sqlite    USDA SR Legacy catalog (generated, see below)
tools/build_catalog.py        builds catalog.sqlite from USDA CSVs
```

## How it works

- **Sections and meals.** Sections are optional, user-named and ordered. Each section has an
  ordered list of saved meals; the first one is selected at the start of each day. A section with no
  meals assigned offers the whole library in creation order. Logging never reorders anything.
- **Drafts.** The meal card is a draft. Changing an amount only affects the next log; the saved meal
  keeps its defaults. After a successful log the card goes back to its defaults. Edits made while
  browsing other meals or sections are kept with their own meal and never carry over to another one.
- **Logging.** Saved-meal logging and Add food go through one `LoggingService`. It builds immutable
  food snapshots and commits the entry and all of its foods in one SQLite transaction. The UI only
  shows success after the write succeeds, and a second tap during an in-flight save is ignored.
- **Scheduled meals.** A schedule is a saved meal, a section, a time and optional repeat days. The
  app logs it once per day when the time passes, through the same `LoggingService`, and records the
  outcome (logged or skipped) so a deleted entry never logs again. Occurrences before the schedule was
  created or last edited never log, and after a long absence only the last 7 days are filled in.
  Notifications only report; the logging itself happens in the app.
- **Auto-advance** is off by default. When on, it moves to the next section only after a successful
  log from the meal card. It stops at the last section and never runs for Add food. Manual browsing
  (▲ ▼ buttons, a vertical swipe on the section header, or the section list) wraps around.
- **History is stable.** Entries carry their own nutrition snapshots (basis, nutrients, portions), so
  editing or removing a saved meal, food or section never changes past days. Removed sections are
  archived. Their entries keep the section's name, and on days that have such entries an
  "Unsectioned" page appears after the last section.
- **Missing data isn't zero.** Each total tracks how many foods reported the nutrient: *complete*,
  *partial* (shown with a dashed-circle mark and "N of M foods report this"), *unknown* ("no data")
  or *empty*. Partial totals are never presented as complete intake.
- **Units.** Grams, ounces, food-specific USDA portions (normalized to the mass of one portion),
  and for custom foods servings, milliliters and fluid ounces. Volume is converted to mass only when
  the food documents a density. Nothing is rounded until it's displayed.
- **Targets.** You enter calorie and macro targets yourself. For other nutrients, the FDA Daily Values
  (2016) are shown as labelled references (not personalized), and you can override or turn off each one
  or reset them all to the FDA values. A changed target
  takes effect from today, so earlier days keep their old one. Niacin DV (niacin equivalents) isn't
  compared with USDA preformed niacin because the forms differ.
- **Export/import.** Versioned JSON with every record and snapshot. Timestamps are exact numbers
  (seconds since 2001-01-01 UTC) so the round trip is lossless. Import validates the whole file,
  shows a preview, saves a recovery export of your current data, then replaces everything in one
  transaction. Merge import is not supported.

## Food data

`catalog.sqlite` is built from **USDA FoodData Central, SR Legacy (April 2018)**, which is public
domain (CC0): 7,793 foods with their nutrients and household portions, plus an FTS5 search index.
It contains raw USDA nutrient IDs. Mapping them to the app's nutrients, including picking one energy
value and the vitamin D IU→µg conversion, happens in `NutrientRegistry.swift`.

To rebuild it:

```sh
curl -LO https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_csv_2018-04.zip
unzip FoodData_Central_sr_legacy_food_csv_2018-04.zip
python3 tools/build_catalog.py FoodData_Central_sr_legacy_food_csv_2018-04
```

## Known limitations

- **No branded foods.** SR Legacy covers common generic foods and includes only a few brand-name
  items. There's no online branded search, barcode scanning or label scanning. Use custom foods for
  packaged products.
- **SR Legacy is historical** (last updated 2018) and doesn't report some nutrients for many foods,
  such as iodine, biotin and added sugars. Those totals appear as unknown or partial; they are not
  filled in from other foods.
- **Volume units for catalog foods.** USDA records don't publish densities, so milliliters aren't
  offered for them. Use their portions (cup, tbsp, fl oz) instead.
- The entry editor changes amounts, not units, and an entry's time can't be edited.
- Custom foods can't be edited after they're saved. To change one, create a new one.
- The library uses creation order. You can't reorder the whole library globally, only each section.
- Scheduled meals log when the app is open or next launched, not in the background. Notifications
  are scheduled ahead of time, so they can appear before the app has recorded the entry.
- Local only. Uninstalling the app deletes your data unless you exported it or your device backup
  includes it.
- Dark appearance only, matching the design canvas.

## Design notes and deviations

The UI follows the design canvas: colors, Geist type, the section card with logged entries
above the meal chooser, swipe-to-reveal Delete, undo toasts, the sections sheet, Add food, settings
and setup. Where it adds to or differs from the design:

- Tapping the daily summary opens a **Nutrients** sheet with every nutrient, how complete it is and
  how it compares with your target, so micronutrients are visible. In the design, tapping the summary
  opened Settings; summary metrics are still chosen in Settings.
- Add food can build a **multi-food one-off entry** ("Add another food") and offers an explicit
  "Also save as a meal" toggle. This covers ADD-04.
- The entry sheet saves edits on **Done** and asks before discarding unsaved changes. It also has
  **Move to another section** (D-09) and **Save as a meal** for one-offs.
- Setup lists sections with drag handles behind a **Reorder** button. Tapping a section opens its
  ordered meal list. VoiceOver gets Move up / Move down actions in both lists.
- More summary metrics are available than the design's four, still limited to three at a time.
