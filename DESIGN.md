# Pacer Design Spec

Decisions made during planning. Mockups (private link): https://claude.ai/artifact/LxNHtwChNvzyM3mTXsAca6 (Main radar + profile, first-person view). Mockups are final; no further edits planned.

## Hardware and tools
- Cyclace indoor bike, no electronics (no power, speed, cadence, or resistance data)
- Apple Watch, 44mm aluminum, watchOS 10.6.2 (minimum target watchOS 10.0; avoid newer APIs)
- iPhone 13 Pro, iOS 26.6.2 (no Dynamic Island), Xcode 26.6
- Native app required for live Watch data (web apps cannot read HealthKit)

## Climb estimate
- Vertical meters = active kcal x 4184 x efficiency / (body mass kg x 9.81), efficiency about 0.22
- Smooth the live value; calories arrive in steps and lag effort by 30-60 s
- Optional standing toggle (user marks stand/sit); bonus tunable, default conservative 5-10%
- Resistance setting is not measured; keep it consistent between rides for fair comparisons
- Default mountain: Mount Whitney trailhead gain, in feet (verify the figure before release)

## Ghosts
- Ghosts never pause. Each replays recorded ride data exactly, including any rest breaks. The whole activity is always recorded, with or without rests.
- 42-day average: time-weighted average climb rate over indoor cycling workouts in the last 42 days (rolling window)
- Best-ride ghosts: replay the climb-vs-time curve of the best ride by total calories, longest time, highest average heart rate, and best efficiency
- Lanterne rouge: ghost paced on the slowest ride by climb rate; minimum ride length 10 min (adjustable) so junk rides do not qualify
- Chase ghosts: if the rider leads the nearest ghost by more than a set gap (default 150 m), spawn a ghost ahead (default 75 m) at the 42-day pace plus a boost (default 5%); cap 3 spawned; about 5 visible total
- Rides imported from Apple Health have totals only, so they become flat-pace ghosts. Rides recorded in the app keep full curves.
- First ride with no history: use a default target pace

## Rankings (per ride, against all previous rides)
- Total calories, total time, highest average heart rate, efficiency (active kcal / average heart rate)
- Personal-best badges; optional 42-day-only ranks; optional kcal/min as a fairness measure

## Aid station (optional, default off)
- Red cross icon on a dark badge (a plain red cross on white is a protected emblem; avoid for publishing)
- Interval to next stop is random from 10, 15, 20, 25 min of ride time; never the same gap twice in a row
- Rest length default 60 s; watch haptic plus banner
- Clock and ghosts keep running during a rest

## Sprint flags (optional, default off)
- Green flag; 20 s max-effort sprint
- Gap to next sprint is random from 2, 4, 8, 12 min; the same gap may repeat
- Never more than 3 sprints without a rest section; an aid station counts as the rest, otherwise insert a 60 s recovery
- No sprints in the first 5 min (warm-up); if a sprint and a rest collide, the rest goes first
- Fixed climb bonus per completed sprint (setting), since 20 s barely registers in calories or heart rate

## Screens
1. Main: big heart rate, calories, time; aid station and sprint cards; radar strip with ghosts ahead/behind, gaps in ft and seconds, time to catch next ghost; mountain profile with all markers
2. First-person chase view: back view of avatar on a curving switchback road, sunglasses-style frame, rear mirror inset, next-ghost box, checkered finish flag at the summit
   - Avatar: straw farmer's hat, arms at sides, top 3/4 visible
   - Bob rate follows heart rate (about one bob per beat, smoothed); below 110 bpm barely moves, at 111 or higher full bob and runner-style arm pump (threshold adjustable)
   - Road dashes scroll at estimated climb rate (heart rate blend optional)
3. All colors high contrast (no dark text on dark backgrounds)

## Optional extras (later)
- Live Activity on the Lock Screen for use over other apps
- Music controls (MediaPlayer): play, pause, next, previous; phone and/or Watch to be decided

## Build stages
- Stage 0: GitHub repo and Xcode project with Watch target, HealthKit set up, first run on real devices
- Stage 1: Watch workout session, live link to iPhone, climb logic, Main screen
- Stage 2: ghosts, rankings, history and Health import, aid stations, sprints
- Stage 3: first-person view, avatar motion, optional Live Activity and music controls
