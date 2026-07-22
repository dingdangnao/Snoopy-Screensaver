# ActiveScene Video Trigger Conditions Analysis

## Selection semantics

- The asset index contains 73 AS records representing 65 unique video IDs.
- 49 unique videos have contextual conditions; the other 16 are generic videos.
- Multiple conditions listed for one video use OR semantics. Matching any one condition makes the video eligible.
- A match does not cause immediate playback. It only adds the video to the weighted random selection pool.
- Matching videos compete with generic videos and remain subject to recent-play and long-term play-count balancing.
- AS assets have no authored `dependencies` or `exclusions`; their restrictions come entirely from `info`.

## Weather conditions

| Condition | AS videos |
|---|---|
| Icy, snowy, or winter | `101_AS001` |
| Snowy, icy, or spring/fall/winter | `102_AS025` |
| Sunny, clear, or summer | `102_AS026` |
| Stormy | `103_AS042` |
| Windy | `103_AS043` |
| Rainy or stormy | `103_AS045` |
| Foggy | `104_AS064` |

The current project retrieves weather from Open-Meteo and maps it as follows:

- WMO `0–1`: `clear`, plus `sunny` during daytime
- WMO `45, 48`: `foggy`
- WMO `51–55, 61–65, 80–82`: `rainy`
- WMO `56, 57, 66, 67`: `icy` and `rainy`
- WMO `71–77, 85, 86`: `snowy`
- WMO `95–99`: `stormy`
- Wind speed of at least `29 km/h`: additionally `windy`

When weather support is disabled, no valid city exists, or the weather snapshot has expired, weather-only videos are not eligible. A video that also has a seasonal condition may still become eligible through that condition.

## Daily routine conditions

| Local time | Routine | AS videos |
|---|---|---|
| 05:00–09:59 | `morning` | `102_AS018`, `102_AS029` |
| 10:00–11:59 | `brunch` | `104_AS055` |
| 12:00–13:59 | `lunch` | `101_AS004` |
| 14:00–17:59 | `afternoon` | `103_AS033` |
| 18:00–20:59 | `dinner` | `101_AS004`, `103_AS044` |
| 21:00–22:59 | `bedtime` | `102_AS017`, `103_AS048` |
| 23:00–04:59 | `lateNight` | `103_AS034`, `103_AS048`, `104_AS062` |
| 07:00–10:29 | additional `goingToSchool` and `goingToWork` states | `103_AS037` |

The commute states overlap the ordinary `morning` or `brunch` state. They add `103_AS037` to the weighted pool without removing other morning material. Matching both states does not double its relevance score. A routine match has 3× the base relevance weight, while cooldown and long-term history balancing still prevent it from playing every time.

## Broad time-of-day conditions

| Local time | Time of day | AS videos |
|---|---|---|
| 12:00–17:59 | `afternoon` | `103_AS039` |
| 18:00–22:59 | `evening` | `103_AS039`, `103_AS041`, `104_AS053`, `104_AS057` |
| 23:00–05:59 | `lateNight` | `103_AS039`, `103_AS041`, `104_AS057`, `104_AS070` |

Time-of-day and holiday entries also use OR semantics. Consequently:

- `104_AS057` is not holiday-only; it can appear on an ordinary evening or late night.
- `103_AS039` is not Halloween-only; it can appear from an ordinary afternoon onward.
- `103_AS041` is not limited to the first Peanuts comic-strip anniversary; it can appear in the evening or late at night.
- `104_AS053` is not limited to New Year's Eve; it can appear on an ordinary evening.
- `104_AS070` is not limited to New Year's Day; it can appear on an ordinary late night.

## Seasonal conditions

| Season | Current local date range | AS videos |
|---|---|---|
| `spring` | March 20 through June 20 | `101_AS003`, `101_AS005`, `102_AS013`, `102_AS014`, `102_AS025`, `103_AS030`, `104_AS049`, `104_AS056`, `104_AS061` |
| `summer` | June 21 through September 21 | `101_AS003`, `102_AS013`, `102_AS014`, `102_AS026`, `103_AS030`, `104_AS049`, `104_AS060`, `104_AS061` |
| `fall` | September 22 through December 20 | `101_AS005`, `102_AS014`, `102_AS025`, `103_AS030`, `104_AS063` |
| `winter` | December 21 through March 19 | `101_AS001`, `101_AS005`, `102_AS025`, `103_AS038`, `104_AS063` |

### Season start dates

| Current fixed date | Condition | AS video |
|---|---|---|
| March 20 | `startOfSpring` | `104_AS056` |
| June 21 | `startOfSummer` | `104_AS060` |
| September 22 | `startOfFall` | `103_AS047` |
| December 21 | `startOfWinter` | `103_AS038` |

These dates are stable offline approximations. The screen saver does not calculate the exact astronomical equinox or solstice time for each year.

## General holidays

| Date or range | Event | AS videos |
|---|---|---|
| January 1 | `newYearsDay` | `104_AS057`, `104_AS070` |
| First day of the first lunar month | `lunarNewYear` | `104_AS057` |
| February 14 | `valentinesDay` | `102_AS020` |
| April 22 | `earthDay` | `104_AS054` |
| Second Sunday in May | `mothersDay` | `104_AS058` |
| Third Sunday in June | `fathersDay` | `104_AS058` |
| July 4 | `fourthOfJuly` | `104_AS057` |
| Entire month of October | `halloweenSeason` | `103_AS035` |
| October 31 | `halloween` | `103_AS035`, `103_AS039` |
| November 15 onward | `thanksgivingSeason` | `103_AS046` |
| Fourth Thursday in November | `thanksgiving` | `103_AS032`, `103_AS046` |
| Entire December and January 1–6 | `christmasSeason` | `103_AS036` |
| December 24 | `christmasEve` | `101_AS009`, `102_AS022`, `103_AS036` |
| December 25 | `christmas` | `101_AS009`, `102_AS022`, `103_AS036` |
| December 31 | `newYearsEve` | `104_AS053` |

The runtime also produces `aprilFoolsDay`, `peanutsCharlieBrownDay`, and `peanutsCharlieBrownThanksgiving`, but no current AS video uses these conditions.

## Peanuts and Snoopy anniversaries

| Date | Event | AS video |
|---|---|---|
| July 20 | `peanutsMoonlanding` | `104_AS052` |
| August 10 | `peanutsSnoopysBirthday` | `102_AS023` |
| August 19 | `aviationDay` | `102_AS012` |
| October 2 | `peanutsFirstComicStrip` | `103_AS041` |
| October 4 | `peanutsSnoopyDebut` | `103_AS040` |
| December 16 | `peanutsBeethovensBirthday` | `102_AS024` |

## Generic videos

The following 16 AS videos have no contextual conditions and may enter the selection pool at any time:

`101_AS002`, `101_AS006`, `101_AS007`, `101_AS008`, `101_AS010`, `101_AS011`, `102_AS015`, `102_AS016`, `102_AS019`, `102_AS021`, `102_AS027`, `102_AS028`, `103_AS031`, `104_AS050`, `104_AS051`, `104_AS059`

## Complete per-video condition table

| AS video | Conditions (any one may match) |
|---|---|
| `101_AS001` | Icy, snowy, winter |
| `101_AS002` | Generic |
| `101_AS003` | Spring, summer |
| `101_AS004` | Dinner, lunch |
| `101_AS005` | Fall, winter, spring |
| `101_AS006` | Generic |
| `101_AS007` | Generic |
| `101_AS008` | Generic |
| `101_AS009` | Christmas Eve, Christmas |
| `101_AS010` | Generic |
| `101_AS011` | Generic |
| `102_AS012` | Aviation Day |
| `102_AS013` | Spring, summer |
| `102_AS014` | Spring, summer, fall |
| `102_AS015` | Generic |
| `102_AS016` | Generic |
| `102_AS017` | Bedtime |
| `102_AS018` | Morning |
| `102_AS019` | Generic |
| `102_AS020` | Valentine's Day |
| `102_AS021` | Generic |
| `102_AS022` | Christmas Eve, Christmas |
| `102_AS023` | Snoopy's birthday |
| `102_AS024` | Beethoven's birthday |
| `102_AS025` | Fall, winter, spring, snowy, icy |
| `102_AS026` | Summer, sunny, clear |
| `102_AS027` | Generic |
| `102_AS028` | Generic |
| `102_AS029` | Morning |
| `103_AS030` | Spring, summer, fall |
| `103_AS031` | Generic |
| `103_AS032` | Thanksgiving |
| `103_AS033` | Afternoon routine |
| `103_AS034` | Late-night routine |
| `103_AS035` | Halloween, Halloween season |
| `103_AS036` | Christmas Eve, Christmas season, Christmas |
| `103_AS037` | Going to school and going to work (07:00–10:29) |
| `103_AS038` | Start of winter, winter |
| `103_AS039` | Halloween, afternoon, evening, late night |
| `103_AS040` | Snoopy debut anniversary |
| `103_AS041` | First Peanuts comic-strip anniversary, evening, late night |
| `103_AS042` | Stormy |
| `103_AS043` | Windy |
| `103_AS044` | Dinner |
| `103_AS045` | Rainy, stormy |
| `103_AS046` | Thanksgiving, Thanksgiving season |
| `103_AS047` | Start of fall |
| `103_AS048` | Bedtime, late-night routine |
| `104_AS049` | Spring, summer |
| `104_AS050` | Generic |
| `104_AS051` | Generic |
| `104_AS052` | Moon-landing anniversary |
| `104_AS053` | Evening, New Year's Eve |
| `104_AS054` | Earth Day |
| `104_AS055` | Brunch |
| `104_AS056` | Start of spring, spring |
| `104_AS057` | Lunar New Year, evening, late night, New Year's Day, Fourth of July |
| `104_AS058` | Mother's Day, Father's Day |
| `104_AS059` | Generic |
| `104_AS060` | Start of summer, summer |
| `104_AS061` | Spring, summer |
| `104_AS062` | Late-night routine |
| `104_AS063` | Fall, winter |
| `104_AS064` | Foggy |
| `104_AS070` | Late night, New Year's Day |

## Context currently unused by AS videos

The playback context calculates the following values, but no current AS video uses them:

- `onTheHour`
- `midnight`
- `midday`
- `sunrise`
- `sunset`
- Moon phases

These values may be used by other asset types, such as visitors, weather effects, or scene palettes.
