% extractWRFForecast.m
%
% STANDALONE SCRIPT. MATLAB R2018b compatible (Linux).
% TSRI ST 2571, Activity 1 prototype -- WRF-Chem forecast feed with a
% time-lagged ensemble.
%
% Reads the operational WRF-Chem output directly over the sshfs mount
% (only surface fields, ~200 MB of the ~157 GB file; nothing is copied).
%
% EACH CYCLE (hourly at MINUTE_PAST_HOUR):
%   1. Lists the complete runs among the last BACKFILL_FOLDERS dated
%      folders. A run is complete when its wrfout file has EXPECTED_TIMES
%      steps and has not been modified for MIN_AGE_MIN minutes.
%   2. Extracts every complete run that has no station-forecast archive
%      yet (the first time this backfills older runs, ~45 s each).
%   3. For the newest run, also writes the PM2.5 map frames.
%   4. Builds the time-lagged ensemble: the newest run plus earlier runs
%      initialised up to ENS_MAX_AGE_DAYS before it (at most
%      ENS_MAX_MEMBERS), aligned on the newest run's hours. Members are
%      equally weighted; the dashboard shows their mean, their range and
%      how many of them exceed the Thai standard.
%   5. EVERY cycle (also without a new run, since new observations arrive
%      hourly): fits the observation-based forecast correction per station
%      and pollutant and writes forecast_correction.json (see below).
%   Steps 2-4 are skipped when there is no new run.
%
% FORECAST CORRECTION (decaying-weighted mean and variance scaling; log or linear space
% per variable, see COR_VARS -- pollutants, TMD weather, observatory weather / seeing
% and LiDAR PBL height)
%   For each station and variable, pairs of forecast and observed hourly
%   values from the last COR_WINDOW_DAYS (all archived runs, all lead
%   times) are weighted by age with a half-life of COR_HALF_LIFE_DAYS.
%   With x = T(forecast), y = T(observed), where T = ln(. + c) for
%   quantities whose errors grow with the value (pollutants, wind, seeing,
%   PBL height) and T = identity for additive errors (temperature, humidity,
%   dew-point spread):
%     bias:        beta  = mean_w(y) - mean_w(x)
%     variability: scale = sd_w(y) / sd_w(x)        (amplitude of the ups and downs)
%     corrected:   T(F) = x + beta + (scale - 1)(x - mean_w(x)), clipped to the
%                  variable's physical range
%   Matching the observed variance (rather than regressing) keeps peaks
%   sharp instead of damping them. Safeguards: the scale is shrunk towards
%   1 with COR_PRIOR_N pseudo-hours and limited to COR_SCALE_LIMITS; it is
%   only used with COR_MIN_HOURS_SCALE distinct observed hours and when the
%   forecast is correlated with the observations (r >= COR_MIN_CORR) --
%   otherwise only the bias is corrected; with fewer than COR_MIN_HOURS_BIAS
%   distinct hours there is no correction. The dashboard applies the
%   coefficients to the station forecasts and, spread around each station,
%   to the forecast map.
%
% Output file layout (WRF-Chem V4.3.3, d01, 9 km, Lambert conformal):
%   one wrfout file per run, 145 hourly steps (6 days) from 00 UTC.
%   Surface level (bottom_top = 1) is used for PM2.5 and PM10.
%   All output times are Bangkok local time (UTC+7).
%
% RUNS IN THE BACKGROUND (RUN_IN_BACKGROUND = true). TO STOP: stopPlatformTimers
%
% OUTPUTS
%   <outDir>/WRF_StationForecast_<initUTC>.csv  hourly forecast at every PCD
%       station: PM25, PM10 (ug/m3), O3_ppb, CO_ppm, NO2_ppb, SO2_ppb (surface,
%       converted from WRF-Chem ppmv to PCD units), PBLH, T2_C, WS10, WD10
%       (earth-relative), RAIN_1h.
%       One per run -- the ensemble members and the verification archive.
%   <outDir>/WRF_GridPM25_<initUTC>.mat          regridded surface PM2.5 (newest runs)
%   <dashDir>/forecast_stations.json             newest run + ensemble members, per station
%   <dashDir>/forecast_correction.json           correction coefficients per station and pollutant
%   <outDir>/WRF_MetForecast_<initUTC>.csv       hourly weather forecast at every TMD station:
%       T2_C, RH2 (%), WS10 (m/s), WD10, RAIN_1h (mm), PSFC_hPa, PBLH (m)
%   <dashDir>/forecast_met.json                  newest run's weather forecast at TMD stations
%   <outDir>/WRF_AstroForecast_<initUTC>.csv     hourly forecast at each NARIT observatory:
%       T2_C (adjusted to the observatory's elevation with 6.5 K/km), RH2, WS10, WD10,
%       DPS_C (dew-point spread), CLOUD / CLOUD_LOW / CLOUD_MID / CLOUD_HIGH (% of sky,
%       max cloud fraction in the column / below 680 hPa / 680-440 hPa / above 440 hPa,
%       at the nearest grid cell), PWV_mm (precipitable water vapour), SEEING_arcsec
%       (astronomical seeing at 500 nm, as in the NCL script
%       wrf_ExtractData_..._CalculateSeeing_...ncl: in the column above the
%       observatory, Ct = dtheta/dz * sqrt(|dV/dz|), Cn2 = Ct * (80e-6 P/T^2)^2 with
%       P in hPa and T in K, integrated over height (rectangles between levels),
%       seeing = 5.25 lambda^-0.2 (int Cn2)^0.6 rad. Vertical derivatives use a cubic
%       spline, as NCL's ftcurvd does with its spline under tension; the first time
%       step is skipped as in the NCL script, and a non-positive integral gives NaN)
%   <dashDir>/forecast_astro.json                observatories: newest run + time-lagged members
%   (forecast_met.json likewise for the TMD stations, forecast_lidar.json for the
%   LiDAR sites: PBL height, m, from WRF-Chem PBLH; archive WRF_LidarForecast_<initUTC>.csv). Members are the same runs as
%   for PM2.5 (ENS_MAX_MEMBERS, ENS_MAX_AGE_DAYS); fields VAR = newest run, ens_VAR =
%   members x hours, newest first.
%   Astronomy map layers: ACLOUD (total cloud cover, %), ADPS (2 m dew-point spread, degC),
%   APWV (precipitable water vapour, mm; layer thickness from the base-state pressure PB,
%   which differs from the full pressure by well under 1%). The page reuses the RH, WIND
%   and TEMP layers for the astronomy humidity, wind and temperature.
%   Weather map layers (forecast_grid_<V>.json): TEMP (2 m, degC), RH (2 m, %),
%   WIND (10 m speed, m/s), RAIN (3-hour total ending at the frame time, mm), PBLH (m)
%   <dashDir>/forecast_grid_<P>.json             map frames for P = PM25, PM10, O3, CO, NO2, SO2
%                                                (ensemble mean of the time-lagged runs when two or
%                                                more WRF_Grid_<init>.mat archives are available,
%                                                otherwise the newest run; see buildEnsembleGrids)
%                                                (newest run, whole domain; one file per
%                                                pollutant so the page loads only what it shows)
%   <outDir>/lastProcessedRun.mat, download_log.txt

clear; clc;
%% ============================ CONFIG =======================================
cfg.baseDir        = '/home/arun/HPC/Projects/NARITForecastingSystem/tes2';
cfg.filePattern    = 'wrfout_d01_*';
cfg.EXPECTED_TIMES = 145;     % 6-day hourly run incl. t = 0
cfg.MIN_AGE_MIN    = 15;      % file untouched this long = finished writing
cfg.BACKFILL_FOLDERS = 14;    % dated folders searched for complete runs (and backfilled)

% Time-lagged ensemble
cfg.ENS_MAX_MEMBERS  = 5;     % newest run + up to 4 earlier ones
cfg.ENS_MAX_AGE_DAYS = 4;     % oldest member initialised at most this long before the newest
cfg.HIST_DAYS = 7;            % the ensemble reaches this far back before the newest run (= observation span)

% Observation-based correction
cfg.COR_WINDOW_DAYS     = 90;     % training window: all archived data up to 90 days (one season)
cfg.COR_HALF_LIFE_DAYS  = 10;     % weight halves every 10 days back (recent behaviour counts most)
cfg.SKIP_FIRST_H        = 1;      % leave out each run's first hour(s) (initial state) everywhere
% "Do no harm": options none / bias / bias+variability are fitted without the last
% COR_HOLDOUT_H hours and scored on them (RMSE, original units); a more complex option is
% kept only if it lowers that error by COR_MIN_GAIN. Too few held-back hours -> scored on all data.
cfg.COR_HOLDOUT_H         = 72;
cfg.COR_HOLDOUT_MIN_HOURS = 12;
cfg.COR_MIN_GAIN          = 0.02;
cfg.COR_FORCE_BIAS        = {'PM25', 'PM10'};   % always at least bias-corrected (additive bias cannot
                                                % raise the error on the data it is fitted to)
% Short-range blend: the first hours start from the latest observations -- the difference
% d = observed - corrected model (mean of the last BLEND_OBS_HOURS) is added with a weight
% falling linearly from 1 to 0 over tau hours. tau is chosen per variable by replaying the
% last BLEND_TEST_DAYS: forecasts issued every hour, scored over the next BLEND_MAX_LEAD
% hours; no blend (tau 0) unless a blend lowers that error by COR_MIN_GAIN. Additive
% (linear-space) variables only.
cfg.BLEND_VARS      = {'PM25', 'PM10'};
cfg.BLEND_TAUS      = [3 6 12 24];
cfg.BLEND_TEST_DAYS = 7;
cfg.BLEND_MAX_LEAD  = 24;
cfg.BLEND_OBS_HOURS = 3;
% Ensemble outliers: at each hour with >= 3 runs, a run's value is dropped if it is more than
% ENS_OUT_K x the robust spread (1.4826 x MAD) AND more than the minimum difference below from
% the runs' median; values outside the physical range (cfg.QC) are dropped as well.
cfg.ENS_OUT_K   = 3;
cfg.ENS_OUT_MIN = struct('PM25', 15, 'PM10', 25, 'TEMP', 6, 'RH', 30, 'WIND', 8, 'RAIN', Inf, ...
    'ATEMP', 6, 'ARH', 30, 'AWIND', 8, 'ADPS', 8, 'ACLOUD', 40, 'APWV', 10, 'ASEEING', 1, 'PBLH', 1000);
% Thresholds count DISTINCT observed hours (the same hour forecast by several runs counts once)
cfg.COR_MIN_HOURS_BIAS  = 12;     % fewer observed hours -> no correction
cfg.COR_MIN_HOURS_SCALE = 48;     % fewer -> bias only (two full daily cycles needed for variability)
cfg.COR_MIN_CORR        = 0.3;    % weaker forecast-obs correlation -> bias only
cfg.COR_PRIOR_N         = 24;     % pseudo-hours pulling the scale towards 1
cfg.COR_SCALE_LIMITS    = [0.5 2];
cfg.COR_OFFSET = struct('PM25', 1, 'PM10', 1, 'O3', 1, 'CO', 0.01, 'NO2', 0.1, 'SO2', 0.1);  % c in ln(x + c), pollutant units
% Corrected variables: source | dashboard variable | space | offset c (log) | min | max
%   log: x = ln(value + c), for quantities whose errors grow with the value
%   lin: x = value, for quantities with additive errors (temperature, humidity, dew-point spread)
%   Rain, cloud cover and precipitable water are not corrected (no suitable observations,
%   or timing errors that scaling cannot fix).
cfg.COR_VARS = {
    'pcd',   'PM25',    'lin', 0,    0,    Inf;    % additive: a ratio also scales mistimed peaks
    'pcd',   'PM10',    'lin', 0,    0,    Inf;
    'pcd',   'O3',      'log', 1,    0,    Inf;
    'pcd',   'CO',      'log', 0.01, 0,    Inf;
    'pcd',   'NO2',     'log', 0.1,  0,    Inf;
    'pcd',   'SO2',     'log', 0.1,  0,    Inf;
    'tmd',   'TEMP',    'lin', 0,   -Inf,  Inf;
    'tmd',   'RH',      'lin', 0,    0,    100;
    'tmd',   'WIND',    'log', 0.5,  0,    Inf;
    'narit', 'ATEMP',   'lin', 0,   -Inf,  Inf;
    'narit', 'ARH',     'lin', 0,    0,    100;
    'narit', 'AWIND',   'log', 0.5,  0,    Inf;
    'narit', 'ADPS',    'lin', 0,    0,    Inf;
    'narit', 'ASEEING', 'log', 0.1,  0,    Inf;
    'lidar', 'PBLH',    'log', 50,   0,    Inf;
    };
cfg.TMD_WIND_TO_MS = 1;           % same as in exportDashboardData.m (1/3.6 if TMD reports km/h)

% Quality control of the hourly observations used for the correction -- the same checks
% and limits as the dashboard's charts (index.html, QC):
%   range [min max] (values up to `clip` are set to max, e.g. humidity 101.5 -> 100),
%   spike: Hampel filter on +/-3 h, removed if more than 5x the robust spread AND more
%          than `spike` from the neighbours' median (NaN = no spike check),
%   flat:  the same value repeated for 6 h or more is removed (stuck sensor).
%           variable    min    max   spike  flat  clip
cfg.QC = { 'PM25',       0,  1000,    30,    1,   NaN;
           'PM10',       0,  2000,    50,    1,   NaN;
           'O3',         0,   500,    40,    0,   NaN;
           'CO',         0,    50,     2,    0,   NaN;
           'NO2',        0,   500,    40,    0,   NaN;
           'SO2',        0,   500,    20,    0,   NaN;
           'TEMP',     -10,    50,     6,    1,   NaN;
           'RH',         0,   100,    30,    1,   105;
           'WIND',       0,    60,     8,    0,   NaN;
           'ATEMP',    -10,    45,     6,    1,   NaN;
           'ARH',        0,   100,    30,    1,   105;
           'AWIND',      0,    60,     8,    0,   NaN;
           'ADPS',       0,    40,     8,    0,   NaN;
           'ASEEING',  0.1,    10,   NaN,    0,   NaN;
           'PBLH',       0,  5000,  1000,    0,   NaN };
cfg.COR_TAIL_MB         = 40;     % bytes read from the end of the PCD archive
cfg.COR_MAP_RADIUS_KM   = 40;     % dashboard: how far a station's correction spreads on the map
cfg.COR_MAP_PRIOR_W     = 0.1;    % dashboard: fades the map correction to none away from stations

cfg.rootDir      = '/media/arun/Seagate Backup Plus Drive/TSRI_ST_71/Activity1_Platform';
cfg.outDir       = fullfile(cfg.rootDir, 'WRF_Forecast');
cfg.verifDir  = fullfile(cfg.outDir, 'Verification');   % model-observation statistics
cfg.dashDir      = fullfile(cfg.rootDir, 'dashboard', 'dashboard_data');
cfg.stationsFile = fullfile(cfg.rootDir, 'PCD_AllStations_Archive', 'PCD_Stations_latest.csv');
cfg.histFile     = fullfile(cfg.rootDir, 'PCD_AllStations_Archive', 'PCD_History_Archive.csv');
cfg.tmdStationsFile = fullfile(cfg.rootDir, 'TMD_AWS_Archive', 'TMD_AWS_latest.csv');   % from downloadTMDAllStations
cfg.naritStationsFile = fullfile(cfg.rootDir, 'NARIT_Obs_Archive', 'NARIT_Observatories.csv');  % from downloadNARITObservatories
cfg.lidarSitesFile = fullfile(cfg.rootDir, 'LIDAR_PBL', 'LIDAR_Sites.csv');   % from downloadLidarPBL
cfg.ASTRO_CLOUD_MAP = true;   % cloud-cover map frames (reads the 3D cloud field every 3 h, ~350 MB per run)
cfg.ASTRO_PWV_MAP   = true;   % precipitable-water map frames (reads 3D water vapour every 3 h, ~350 MB per run)

% Regular lat/lon grid for the dashboard map. [] = the whole model domain
% (mainland Southeast Asia); or give a box [W S E N] to cut it down.
cfg.GRID_BOX    = [];
cfg.GRID_RES    = 0.1;                      % degrees (~11 km, close to the 9 km model grid)
cfg.GRID_STEP_H = 3;                        % map frame every 3 h

% Map layers: dashboard name | byte step | offset   (value = offset + byte * step, 0..254)
%   PM in ug/m3, O3/NO2/SO2 in ppb, CO in ppm (same units as PCD);
%   TEMP degC, RH %, WIND m/s, RAIN mm per 3 h, PBLH m
cfg.MAP_POLL = {'PM25', 1, 0; 'PM10', 1, 0; 'O3', 1, 0; 'CO', 0.02, 0; 'NO2', 0.5, 0; 'SO2', 0.25, 0; ...
                'TEMP', 0.25, -10; 'RH', 0.5, 0; 'WIND', 0.1, 0; 'RAIN', 0.25, 0; 'PBLH', 20, 0; ...
                'ADPS', 0.1, 0};

cfg.UTC_OFFSET_H = 7;

% Health categories (0 low, 1 moderate, 2 high), after wrf_Surface_Heat/AQI/HeatAQI.ncl:
%   value >= first threshold -> moderate, value > second threshold -> high
cfg.HEALTH_T   = [30 35];     % 2-m temperature (deg C)                  -- as in the NCL
cfg.HEALTH_HI  = [32 41];     % heat index (deg C; NOAA extreme caution / danger)
cfg.HEALTH_PM  = [50 100];    % PM2.5 (ug/m3)                            -- as in the NCL
% Combined = the worse of the two (the NCL's intent; its own ordering let "moderate"
% overwrite "high"). Observed combined risk at a PCD station uses the nearest TMD
% station's temperature and humidity, if within HEALTH_PAIR_KM.
cfg.HEALTH_PAIR_KM = 30;

% WACCM global forecast (one NetCDF per day, 6-hourly, ~1 deg) to fill the map outside the
% WRF-Chem domain: global surface fields (latitudes within WACCM_MAX_LAT, as web maps cannot
% show the poles; longitudes re-centred on -180..180), WACCM's own 6-hourly frames over the
% period of the WRF-Chem map frames, written as forecast_waccm_<VAR>.json. The page
% interpolates them in time to each WRF-Chem frame.
cfg.WACCM_DIR = '/home/arun/HPC/Projects/NARITForecastingSystem/gfs_waccm';
cfg.WACCM_MAX_LAT = 80;
%                 layer    WACCM var   factor  how
cfg.WACCM_VARS = {'PM25',  'PM25_SRF', 1e9,    '2d';      % kg/m3 -> ug/m3 (surface field)
                  'O3',    'O3',       1e9,    'lev';     % mol/mol -> ppb, lowest level
                  'CO',    'CO',       1e6,    'lev';     % mol/mol -> ppm
                  'NO2',   'NO2',      1e9,    'lev';
                  'SO2',   'SO2',      1e9,    'lev';
                  'TEMP',  'T',        1,      'temp';    % K -> deg C, lowest level
                  'RH',    'Q',        1,      'rh';      % from Q, T and pressure
                  'WIND',  'U',        1,      'wind';    % from U and V
                  'PBLH',  'PBLH',     1,      '2d';
                  'ADPS',  'T',        1,      'dps';     % dew-point spread from T, Q and pressure
                  'APWV',  'Q',        1,      'pwv'};    % precipitable water: Q over all levels (mm)
% Health categories are also made from WACCM's TEMP, RH and PM25 (forecast_waccm_H*.json).

% GFS 0.25 deg (gfs.yyyymmdd.t00z.pgrb2.0p25.fxxx, same folder) for cloud cover and rain outside
% the WRF-Chem domain. GRIB2 is converted on the HPC with wgrib2 (conda env in ronald's home),
% regridded to 1 deg (budget interpolation keeps rain amounts), into gfs_extract/gfs_<date>.nc.
cfg.HPC_SSH     = 'ronald@192.168.5.201';
cfg.LOCAL_USER  = 'arun';                              % whose SSH key reaches the HPC (MATLAB may run as root)
cfg.HPC_DATA    = '/ltzfs/ARUN';                       % = /home/arun/HPC on this machine
cfg.GFS_WGRIB2  = '$HOME/envs/grib/bin/wgrib2';
cfg.GFS_DIR     = cfg.WACCM_DIR;
cfg.GFS_OUT     = '/home/arun/HPC/Projects/NARITForecastingSystem/gfs_extract';
cfg.GFS_LAST_F  = 168;                                 % a run counts as complete with this hour

% Bump when the output format changes, so the dashboard files are rebuilt
cfg.FORMAT_VERSION = 16;

cfg.RUN_IN_BACKGROUND = true;
cfg.MINUTE_PAST_HOUR  = 5;
% ===========================================================================

if ~exist(cfg.outDir, 'dir'),  mkdir(cfg.outDir);  end
if ~exist(cfg.dashDir, 'dir'), mkdir(cfg.dashDir); end
cfg.logFile = fullfile(cfg.outDir, 'download_log.txt');

timerName = 'WRFForecastTimer';
existingTimer = timerfind('Name', timerName);
if ~isempty(existingTimer)
    fprintf('A WRF forecast timer is already running. Stopping and replacing it.\n');
    stop(existingTimer);
    delete(existingTimer);
end

runWrfCycleSafe(cfg);

if cfg.RUN_IN_BACKGROUND
    nowLocal = datetime('now', 'TimeZone', 'local');
    nextRun  = dateshift(nowLocal, 'start', 'hour') + minutes(cfg.MINUTE_PAST_HOUR);
    if nextRun <= nowLocal
        nextRun = nextRun + hours(1);
    end
    startDelaySec = max(1, round(seconds(nextRun - nowLocal)));

    wrfTimer = timer( ...
        'Name', timerName, ...
        'ExecutionMode', 'fixedRate', ...
        'Period', 3600, ...
        'StartDelay', startDelaySec, ...
        'BusyMode', 'drop', ...
        'TimerFcn', @(~,~) runWrfCycleSafe(cfg), ...
        'ErrorFcn', @(~,evt) fprintf('WRF forecast timer error: %s\n', evt.Data.message));
    start(wrfTimer);

    fprintf('\nWRF forecast extraction is now running in the background.\n');
    fprintf('Checks hourly at :%02d for a new complete run (next in %.0f s).\n', ...
        cfg.MINUTE_PAST_HOUR, startDelaySec);
    fprintf('To stop it, run:  stopPlatformTimers\n\n');
end


%% ============================ LOCAL FUNCTIONS ===============================

function runWrfCycleSafe(cfg)
try
    runWrfCycle(cfg);
catch ME
    fprintf('[%s] WRF forecast cycle failed: %s\n', datestr(now), ME.message);
    writeLog(cfg.logFile, sprintf('%s | ERROR | %s', datestr(now), ME.message));
end
end


function runWrfCycle(cfg)
if ~exist(cfg.baseDir, 'dir')
    error('Forecast folder not visible: %s -- is the HPC mounted (sshfs with allow_other)?', cfg.baseDir);
end

%% ----- 1. Complete runs, newest first -----
runs = findCompleteRuns(cfg);
if isempty(runs)
    fprintf('[%s] No complete WRF run found in the last %d folders.\n', datestr(now), cfg.BACKFILL_FOLDERS);
    return;
end
newest = runs(1);

%% ----- 2. Extract runs that have no archive yet (newest one with map frames) -----
nNew = 0;
newestDone = false;
newestInit = datetime(newest.tag, 'InputFormat', 'yyyyMMddHH');
for r = 1:numel(runs)
    % Runs inside the ensemble window also need weather / astronomy archives
    % (runs extracted before those were added are redone once, stations only)
    inEns = datetime(runs(r).tag, 'InputFormat', 'yyyyMMddHH') >= newestInit - days(cfg.ENS_MAX_AGE_DAYS);
    needMet   = inEns && exist(cfg.tmdStationsFile, 'file') && ...
        ~exist(fullfile(cfg.outDir, sprintf('WRF_MetForecast_%s.csv', runs(r).tag)), 'file');
    needAstro = inEns && exist(cfg.naritStationsFile, 'file') && ...
        ~exist(fullfile(cfg.outDir, sprintf('WRF_AstroForecast_%s.csv', runs(r).tag)), 'file');
    needLidar = inEns && exist(cfg.lidarSitesFile, 'file') && ...
        ~exist(fullfile(cfg.outDir, sprintf('WRF_LidarForecast_%s.csv', runs(r).tag)), 'file');
    if ~exist(archiveCsv(cfg, runs(r).tag), 'file') || needMet || needAstro || needLidar
        extractRun(cfg, runs(r), r == 1);
        nNew = nNew + 1;
        newestDone = newestDone || (r == 1);
    end
end

%% ----- 3. Skip the rest if nothing changed -----
stateFile = fullfile(cfg.outDir, 'lastProcessedRun.mat');
upToDate = false;
if nNew == 0 && exist(stateFile, 'file') && ...
        exist(fullfile(cfg.dashDir, 'forecast_stations.json'), 'file') && ...
        exist(fullfile(cfg.dashDir, 'forecast_grid_PM25.json'), 'file') && ...
        (~exist(cfg.tmdStationsFile, 'file') || exist(fullfile(cfg.dashDir, 'forecast_met.json'), 'file')) && ...
        (~exist(cfg.naritStationsFile, 'file') || exist(fullfile(cfg.dashDir, 'forecast_astro.json'), 'file')) && ...
        (~exist(cfg.lidarSitesFile, 'file') || exist(fullfile(cfg.dashDir, 'forecast_lidar.json'), 'file'))
    st = load(stateFile);
    upToDate = isfield(st, 'lastRunFile') && strcmp(st.lastRunFile, newest.file) && ...
               isfield(st, 'formatVersion') && st.formatVersion == cfg.FORMAT_VERSION;
end
if upToDate
    fprintf('[%s] Latest complete run (%s) already processed.\n', datestr(now), newest.label);
    computeCorrectionSafe(cfg);
    buildHealthSafe(cfg);
    buildWaccmSafe(cfg);
    buildGfsSafe(cfg);
    return;
end

% Map frames for the newest run if they were not made in step 2
if ~newestDone
    extractRun(cfg, newest, true);
end

%% ----- 4. Time-lagged ensemble + dashboard station file -----
nMem = buildEnsemble(cfg, newest);
buildStationEnsemble(cfg, newest, 'met');
buildStationEnsemble(cfg, newest, 'astro');
buildStationEnsemble(cfg, newest, 'lidar');
buildEnsembleGrids(cfg, newest);

%% ----- 5. Observation-based correction -----
computeCorrectionSafe(cfg);

%% ----- 6. Health categories (maps, station forecasts and observations) -----
buildHealthSafe(cfg);

%% ----- 7. WACCM fill for the maps (outside the WRF-Chem domain) -----
buildWaccmSafe(cfg);

%% ----- 8. GFS cloud cover and rain for the maps (outside the WRF-Chem domain) -----
buildGfsSafe(cfg);

lastRunFile = newest.file; %#ok<NASGU>
formatVersion = cfg.FORMAT_VERSION; %#ok<NASGU>
save(stateFile, 'lastRunFile', 'formatVersion');

msg = sprintf('%s | newest run %s | newly extracted=%d | ensemble members=%d', ...
    datestr(now), newest.label, nNew, nMem);
writeLog(cfg.logFile, msg);
fprintf('[%s] Done: newest run %s, %d newly extracted, ensemble of %d run(s).\n', ...
    datestr(now), newest.label, nNew, nMem);
end


function runs = findCompleteRuns(cfg)
% Struct array (file, label, tag), newest first. tag = init time 'yyyymmddHH' (UTC).
runs = struct('file', {}, 'label', {}, 'tag', {});
d = dir(cfg.baseDir);
d = d([d.isdir]);
names = {d.name};
names = sort(names(~cellfun(@isempty, regexp(names, '^\d{4}-\d{2}-\d{2}$', 'once'))));
for k = numel(names):-1:max(1, numel(names) - cfg.BACKFILL_FOLDERS + 1)
    runDir = fullfile(cfg.baseDir, names{k});
    files = dir(fullfile(runDir, cfg.filePattern));
    if isempty(files)
        continue;
    end
    f = fullfile(runDir, files(1).name);
    ageMin = (now - files(1).datenum) * 24 * 60;
    if ageMin < cfg.MIN_AGE_MIN
        fprintf('  %s: still being written (modified %.0f min ago), skipping.\n', names{k}, ageMin);
        continue;
    end
    tok = regexp(files(1).name, '(\d{4})-(\d{2})-(\d{2})_(\d{2})', 'tokens', 'once');
    if isempty(tok)
        continue;
    end
    try
        vi = ncinfo(f, 'Times');
        nTimes = vi.Size(2);
    catch
        continue;
    end
    if nTimes < cfg.EXPECTED_TIMES
        fprintf('  %s: %d of %d time steps, skipping.\n', names{k}, nTimes, cfg.EXPECTED_TIMES);
        continue;
    end
    runs(end+1) = struct('file', f, 'label', fullfile(names{k}, files(1).name), ...
                         'tag', [tok{:}]); %#ok<AGROW>
end
end


function fn = archiveCsv(cfg, tag)
fn = fullfile(cfg.outDir, sprintf('WRF_StationForecast_%s.csv', tag));
end


function extractRun(cfg, run, doGrid)
% Station forecast CSV for one run; with doGrid, also the map frames.
t0 = tic;
if doGrid
    fprintf('  extracting %s (stations + map) ...\n', run.label);
else
    fprintf('  extracting %s (stations) ...\n', run.label);
end
f = run.file;

lat = double(ncread(f, 'XLAT',  [1 1 1], [Inf Inf 1]));
lon = double(ncread(f, 'XLONG', [1 1 1], [Inf Inf 1]));
[nx, ny] = size(lat);

timesChar = ncread(f, 'Times')';
tUTC = datetime(cellstr(timesChar), 'InputFormat', 'yyyy-MM-dd_HH:mm:ss');
tLoc = tUTC + hours(cfg.UTC_OFFSET_H);
nT   = numel(tUTC);

pm25 = readSurface(f, 'PM2_5_DRY', nx, ny, nT, true);
pm10 = readSurface(f, 'PM10',      nx, ny, nT, true);
pblh = readSurface(f, 'PBLH',      nx, ny, nT, false);
t2   = readSurface(f, 'T2',        nx, ny, nT, false) - 273.15;
u10  = readSurface(f, 'U10',       nx, ny, nT, false);
v10  = readSurface(f, 'V10',       nx, ny, nT, false);
rain = readSurface(f, 'RAINNC',    nx, ny, nT, false) + readSurface(f, 'RAINC', nx, ny, nT, false);
q2   = readSurface(f, 'Q2',        nx, ny, nT, false);
psfc = readSurface(f, 'PSFC',      nx, ny, nT, false);
% 2 m relative humidity from Q2, T2 and surface pressure (Magnus formula)
e    = q2 .* psfc ./ (0.622 + 0.378 * q2);
es   = 611.2 * exp(17.67 * t2 ./ (t2 + 243.5));
rh2  = min(max(100 * e ./ es, 0), 100);
clear q2 e es;
% Gases: WRF-Chem ppmv at the lowest level -> PCD units (ppb; CO in ppm)
o3   = readSurface(f, 'o3',  nx, ny, nT, true) * 1000;
co   = readSurface(f, 'co',  nx, ny, nT, true);
no2  = readSurface(f, 'no2', nx, ny, nT, true) * 1000;
so2  = readSurface(f, 'so2', nx, ny, nT, true) * 1000;

% Grid-relative winds -> earth-relative (Lambert conformal)
if hasVar(f, 'COSALPHA') && hasVar(f, 'SINALPHA')
    cosa = double(ncread(f, 'COSALPHA', [1 1 1], [Inf Inf 1]));
    sina = double(ncread(f, 'SINALPHA', [1 1 1], [Inf Inf 1]));
    ue = u10 .* cosa - v10 .* sina;
    ve = v10 .* cosa + u10 .* sina;
else
    ue = u10;
    ve = v10;
end
clear u10 v10;

rain1h = cat(3, nan(nx, ny), diff(rain, 1, 3));      % hourly rain from accumulated totals
rain1h(rain1h < 0) = 0;
clear rain;
r0 = rain1h; r0(isnan(r0)) = 0;
rain3h = r0 + cat(3, zeros(nx, ny, 1), r0(:, :, 1:end-1)) + cat(3, zeros(nx, ny, 2), r0(:, :, 1:end-2));
clear r0;
wspd = hypot(ue, ve);

% Stations inside the domain
S = readStations(cfg.stationsFile);
inDom = S.lat >= min(lat(:)) & S.lat <= max(lat(:)) & S.lon >= min(lon(:)) & S.lon <= max(lon(:));
S = S(inDom, :);
nS = height(S);

% TMD weather stations inside the domain (if the TMD downloader has run)
SM = readTmdStations(cfg.tmdStationsFile);
if ~isempty(SM)
    inDomM = SM.lat >= min(lat(:)) & SM.lat <= max(lat(:)) & SM.lon >= min(lon(:)) & SM.lon <= max(lon(:));
    SM = SM(inDomM, :);
end
nSM = height(SM);

% Map grid (newest run only)
if doGrid
    box = cfg.GRID_BOX;
    if isempty(box)
        r = cfg.GRID_RES;
        box = [ceil(min(lon(:)) / r) * r, ceil(min(lat(:)) / r) * r, ...
               floor(max(lon(:)) / r) * r, floor(max(lat(:)) / r) * r];
    end
    gridLon = box(1):cfg.GRID_RES:box(3);
    gridLat = box(2):cfg.GRID_RES:box(4);
    [GLON, GLAT] = meshgrid(gridLon, gridLat);       % nLat x nLon
    frameIdx = 1:cfg.GRID_STEP_H:nT;
    nMap = size(cfg.MAP_POLL, 1);
    G = cell(nMap, 1);
    for j = 1:nMap
        G{j} = nan(numel(gridLat), numel(gridLon), numel(frameIdx), 'single');
    end
else
    frameIdx = [];
end

F = scatteredInterpolant(lon(:), lat(:), zeros(numel(lon), 1), 'linear', 'none');
fields = {pm25, pm10, pblh, t2, ue, ve, rain1h, o3, co, no2, so2};
gamF = log(max(rh2, 1) / 100) + 17.62 * t2 ./ (243.12 + t2);
dps  = max(t2 - 243.12 * gamF ./ (17.62 - gamF), 0);                     % 2 m dew-point spread
clear gamF;
mapFields = {pm25, pm10, o3, co, no2, so2, t2, rh2, wspd, rain3h, pblh, dps};   % same order as cfg.MAP_POLL
metFields = {t2, rh2, ue, ve, rain1h, psfc / 100, pblh};
SMV = nan(nSM, nT, numel(metFields));

% NARIT observatories (if the observatory downloader has run)
SA = readObservatories(cfg.naritStationsFile);
if ~isempty(SA)
    SA = SA(SA.lat >= min(lat(:)) & SA.lat <= max(lat(:)) & SA.lon >= min(lon(:)) & SA.lon <= max(lon(:)), :);
end
nSA = height(SA);
astroFields = {t2, rh2, ue, ve};

% LiDAR sites: model PBL height for comparison with the LiDAR retrieval
SL = readLidarSites(cfg.lidarSitesFile);
if ~isempty(SL)
    SL = SL(SL.lat >= min(lat(:)) & SL.lat <= max(lat(:)) & SL.lon >= min(lon(:)) & SL.lon <= max(lon(:)), :);
end
nSL = height(SL);
SLV = nan(nSL, nT);
SAV = nan(nSA, nT, numel(astroFields));
nV = numel(fields);
SV = nan(nS, nT, nV);
for k = 1:nT
    for v = 1:nV
        if all(all(isnan(fields{v}(:, :, k))))
            continue;                                % variable missing from this run
        end
        F.Values = reshape(fields{v}(:, :, k), [], 1);
        SV(:, k, v) = F(S.lon, S.lat);
    end
    if nSM > 0
        for v = 1:numel(metFields)
            if all(all(isnan(metFields{v}(:, :, k))))
                continue;
            end
            F.Values = reshape(metFields{v}(:, :, k), [], 1);
            SMV(:, k, v) = F(SM.lon, SM.lat);
        end
    end
    if nSL > 0
        F.Values = reshape(pblh(:, :, k), [], 1);
        SLV(:, k) = F(SL.lon, SL.lat);
    end
    if nSA > 0
        for v = 1:numel(astroFields)
            F.Values = reshape(astroFields{v}(:, :, k), [], 1);
            SAV(:, k, v) = F(SA.lon, SA.lat);
        end
    end
    gi = find(frameIdx == k, 1);
    if ~isempty(gi)
        for j = 1:numel(mapFields)
            if all(all(isnan(mapFields{j}(:, :, k))))
                continue;                            % variable missing from this run
            end
            F.Values = reshape(mapFields{j}(:, :, k), [], 1);
            G{j}(:, :, gi) = single(F(GLON, GLAT));
        end
    end
end
clear fields mapFields metFields astroFields pm25 pm10 pblh t2 ue ve rain1h rain3h wspd rh2 psfc o3 co no2 so2 dps;

% Cloud-cover map frames: max cloud fraction in each column, every 3 h
mapList = cfg.MAP_POLL;
doCloud = doGrid && cfg.ASTRO_CLOUD_MAP && hasVar(f, 'CLDFRA');
doPwv   = doGrid && cfg.ASTRO_PWV_MAP && hasVar(f, 'QVAPOR') && hasVar(f, 'PB');
if doCloud || doPwv
    Gc = nan(numel(gridLat), numel(gridLon), numel(frameIdx), 'single');
    Gw = Gc;
    if doPwv
        pb = double(ncread(f, 'PB', [1 1 1 1], [Inf Inf Inf 1]));   % base-state pressure, fixed in time
        dpb = pb(:, :, 1:end-1) - pb(:, :, 2:end);
        clear pb;
    end
    for gi = 1:numel(frameIdx)
        if doCloud
            C = ncread(f, 'CLDFRA', [1 1 1 frameIdx(gi)], [Inf Inf Inf 1]);
            F.Values = reshape(100 * double(max(C, [], 3)), [], 1);
            Gc(:, :, gi) = single(F(GLON, GLAT));
        end
        if doPwv
            q = double(ncread(f, 'QVAPOR', [1 1 1 frameIdx(gi)], [Inf Inf Inf 1]));
            w = sum((q(:, :, 1:end-1) + q(:, :, 2:end)) / 2 .* dpb, 3) / 9.81;   % mm
            F.Values = w(:);
            Gw(:, :, gi) = single(F(GLON, GLAT));
        end
    end
    clear C q w dpb;
    if doCloud
        mapList(end+1, :) = {'ACLOUD', 0.5, 0};
        G{end+1} = Gc;
    end
    if doPwv
        mapList(end+1, :) = {'APWV', 0.25, 0};
        G{end+1} = Gw;
    end
end

ws = hypot(SV(:, :, 5), SV(:, :, 6));
wd = mod(atan2d(-SV(:, :, 5), -SV(:, :, 6)), 360);   % direction the wind blows FROM

% Station forecast CSV (ensemble member + verification archive)
[ss, kk] = meshgrid(1:nS, 1:nT);                    % station-major (all hours of station 1 first)
ss = ss(:); kk = kk(:);
lin = sub2ind([nS nT], ss, kk);
P25 = SV(:, :, 1); P10 = SV(:, :, 2); PBL = SV(:, :, 3); T2C = SV(:, :, 4); R1 = SV(:, :, 7);
O3 = SV(:, :, 8); CO = SV(:, :, 9); NO2 = SV(:, :, 10); SO2 = SV(:, :, 11);
tLocStr = cellstr(datestr(tLoc, 'yyyy-mm-dd HH:MM'));
Tout = table(S.stationID(ss), tLocStr(kk), round(P25(lin), 2), round(P10(lin), 2), ...
    round(O3(lin), 2), round(CO(lin), 3), round(NO2(lin), 2), round(SO2(lin), 2), ...
    round(PBL(lin)), round(T2C(lin), 1), round(ws(lin), 1), round(wd(lin)), round(R1(lin), 2), ...
    'VariableNames', {'stationID', 'time_local', 'PM25', 'PM10', 'O3_ppb', 'CO_ppm', 'NO2_ppb', 'SO2_ppb', ...
                      'PBLH', 'T2_C', 'WS10', 'WD10', 'RAIN_1h'});
writetable(Tout, archiveCsv(cfg, run.tag));

if nSL > 0
    [ls, lk] = meshgrid(1:nSL, 1:nT);
    ls = ls(:); lk = lk(:);
    % With a single site SLV is 1 x nT, and indexing a row vector returns a row,
    % so force a column (otherwise table() fails: "same number of rows")
    lPbl = SLV(sub2ind([nSL nT], ls, lk));
    TL = table(SL.code(ls), tLocStr(lk), round(lPbl(:)), ...
        'VariableNames', {'code', 'time_local', 'PBLH'});
    writetable(TL, fullfile(cfg.outDir, sprintf('WRF_LidarForecast_%s.csv', run.tag)));
end

% Weather forecast at TMD stations (archive + newest run for the dashboard)
if nSM > 0
    mws = hypot(SMV(:, :, 3), SMV(:, :, 4));
    mwd = mod(atan2d(-SMV(:, :, 3), -SMV(:, :, 4)), 360);
    [ms, mk] = meshgrid(1:nSM, 1:nT);
    ms = ms(:); mk = mk(:);
    ml = sub2ind([nSM nT], ms, mk);
    MT = SMV(:, :, 1); MR = SMV(:, :, 2); MRn = SMV(:, :, 5); MP = SMV(:, :, 6); MB = SMV(:, :, 7);
    TM = table(SM.stationID(ms), tLocStr(mk), round(MT(ml), 1), round(MR(ml)), round(mws(ml), 1), ...
        round(mwd(ml)), round(MRn(ml), 2), round(MP(ml), 1), round(MB(ml)), ...
        'VariableNames', {'stationID', 'time_local', 'T2_C', 'RH2', 'WS10', 'WD10', 'RAIN_1h', 'PSFC_hPa', 'PBLH'});
    writetable(TM, fullfile(cfg.outDir, sprintf('WRF_MetForecast_%s.csv', run.tag)));

end

% Observing conditions at NARIT observatories
if nSA > 0
    hgt = double(ncread(f, 'HGT', [1 1 1], [Inf Inf 1]));
    F.Values = hgt(:);
    hModel = F(SA.lon, SA.lat);
    dz = SA.elev - hModel;
    dz(~isfinite(dz)) = 0;
    AT  = SAV(:, :, 1) - 0.0065 * dz;                          % lapse-rate adjusted to the site
    AR  = SAV(:, :, 2);
    gam = log(max(AR, 1) / 100) + 17.62 * SAV(:, :, 1) ./ (243.12 + SAV(:, :, 1));
    Td  = 243.12 * gam ./ (17.62 - gam);                       % dew point (Magnus), model air
    ADPS = max(AT - Td, 0);
    AW  = hypot(SAV(:, :, 3), SAV(:, :, 4));
    AWD = mod(atan2d(-SAV(:, :, 3), -SAV(:, :, 4)), 360);

    % Columns at the nearest grid cell: cloud layers and precipitable water
    CL = nan(nSA, nT, 4); PWV = nan(nSA, nT); SEE = nan(nSA, nT);
    for a = 1:nSA
        [~, idx] = min((lat(:) - SA.lat(a)) .^ 2 + ((lon(:) - SA.lon(a)) * cosd(SA.lat(a))) .^ 2);
        [ii, jj] = ind2sub([nx ny], idx);
        cf = reshape(double(ncread(f, 'CLDFRA',  [ii jj 1 1], [1 1 Inf Inf])), [], nT);
        qv = reshape(double(ncread(f, 'QVAPOR',  [ii jj 1 1], [1 1 Inf Inf])), [], nT);
        pp = reshape(double(ncread(f, 'P',       [ii jj 1 1], [1 1 Inf Inf])) + ...
                     double(ncread(f, 'PB',      [ii jj 1 1], [1 1 Inf Inf])), [], nT);
        CL(a, :, 1) = 100 * max(cf, [], 1);
        CL(a, :, 2) = 100 * max(cf .* (pp >= 68000), [], 1);
        CL(a, :, 3) = 100 * max(cf .* (pp < 68000 & pp >= 44000), [], 1);
        CL(a, :, 4) = 100 * max(cf .* (pp < 44000), [], 1);
        dp = pp(1:end-1, :) - pp(2:end, :);
        PWV(a, :) = sum((qv(1:end-1, :) + qv(2:end, :)) / 2 .* dp, 1) / 9.81;   % kg/m2 = mm

        % Seeing (as in the NCL script)
        th  = reshape(double(ncread(f, 'T',   [ii jj 1 1], [1 1 Inf Inf])), [], nT) + 300;   % theta, K
        phs = reshape(double(ncread(f, 'PH',  [ii jj 1 1], [1 1 Inf Inf])) + ...
                      double(ncread(f, 'PHB', [ii jj 1 1], [1 1 Inf Inf])), [], nT) / 9.81;  % staggered height, m
        zm  = (phs(1:end-1, :) + phs(2:end, :)) / 2;                                         % mass levels
        uu  = reshape(mean(double(ncread(f, 'U', [ii jj 1 1], [2 1 Inf Inf])), 1), [], nT);  % de-staggered
        vv  = reshape(mean(double(ncread(f, 'V', [ii jj 1 1], [1 2 Inf Inf])), 2), [], nT);
        phPa = pp / 100;
        tK   = th .* (phPa / 1000) .^ (287 / 1004.5);
        for k = 2:nT                                   % NCL leaves the first time step at 0
            h = zm(:, k) - zm(1, k);                   % height above ground
            dth = splineDeriv(h, th(:, k));
            du  = splineDeriv(h, uu(:, k));
            dv  = splineDeriv(h, vv(:, k));
            Ct  = dth .* sqrt(sqrt(du .^ 2 + dv .^ 2));
            Cn  = Ct .* (80e-6 * phPa(:, k) ./ tK(:, k) .^ 2) .^ 2;
            Ctot = sum(Cn(2:end) .* diff(h));
            if Ctot > 0
                SEE(a, k) = 5.25 * (500e-9) ^ (-0.2) * Ctot ^ 0.6 * 180 / pi * 3600;   % arcsec
            end
        end
    end

    [as, ak] = meshgrid(1:nSA, 1:nT);
    as = as(:); ak = ak(:);
    al = sub2ind([nSA nT], as, ak);
    C1 = CL(:, :, 1); C2 = CL(:, :, 2); C3 = CL(:, :, 3); C4 = CL(:, :, 4);
    TA = table(SA.code(as), tLocStr(ak), round(AT(al), 1), round(AR(al)), round(AW(al), 1), round(AWD(al)), ...
        round(ADPS(al), 1), round(C1(al)), round(C2(al)), round(C3(al)), round(C4(al)), round(PWV(al), 1), ...
        round(SEE(al), 2), ...
        'VariableNames', {'code', 'time_local', 'T2_C', 'RH2', 'WS10', 'WD10', 'DPS_C', ...
                          'CLOUD', 'CLOUD_LOW', 'CLOUD_MID', 'CLOUD_HIGH', 'PWV_mm', 'SEEING_arcsec'});
    writetable(TA, fullfile(cfg.outDir, sprintf('WRF_AstroForecast_%s.csv', run.tag)));

end

if doGrid
    mapNames = mapList(:, 1)'; %#ok<NASGU>
    save(fullfile(cfg.outDir, sprintf('WRF_Grid_%s.mat', run.tag)), ...
        'G', 'mapNames', 'mapList', 'gridLat', 'gridLon', 'tLoc', 'frameIdx');

    for j = 1:size(mapList, 1)
        if all(isnan(G{j}(:)))
            continue;                                % not in this run's output
        end
        step = mapList{j, 2};
        offset = mapList{j, 3};
        Gj = struct();
        Gj.pollutant   = mapList{j, 1};
        Gj.run_file    = run.label;
        Gj.init_local  = datestr(tLoc(1), 'yyyy-mm-dd HH:MM');
        Gj.lat0 = gridLat(1); Gj.lon0 = gridLon(1);
        Gj.dlat = cfg.GRID_RES; Gj.dlon = cfg.GRID_RES;
        Gj.nlat = numel(gridLat); Gj.nlon = numel(gridLon);
        Gj.times_local = cellstr(datestr(tLoc(frameIdx), 'yyyy-mm-dd HH:MM'));
        % Each frame: value / scale rounded to 0..254, 255 = outside the
        % domain; one byte per cell (row-major, south row first), base64.
        Gj.encoding = 'uint8-base64';
        Gj.scale = step;
        Gj.offset = offset;
        Gj.pm25 = cell(numel(frameIdx), 1);          % field name kept for the page; holds this pollutant
        for i = 1:numel(frameIdx)
            fr = G{j}(:, :, i)';
            v  = round((double(fr(:)') - offset) / step);
            bad = ~isfinite(v);
            v  = min(max(v, 0), 254);
            v(bad) = 255;
            Gj.pm25{i} = matlab.net.base64encode(uint8(v));
        end
        writeJson(fullfile(cfg.dashDir, sprintf('forecast_grid_%s.json', mapList{j, 1})), Gj);
    end
end
fprintf('    %d stations x %d h%s in %.0f s\n', nS, nT, ...
    repmat(sprintf(', %d map frames', numel(frameIdx)), 1, doGrid), toc(t0));
end


function nMem = buildEnsemble(cfg, newest)
% Pollutant stations -> forecast_stations.json. PM2.5 as a time-lagged ensemble reaching
% HIST_DAYS back (see gatherEnsemble); the other fields from the newest run.
newestTime = datetime(newest.tag, 'InputFormat', 'yyyyMMddHH');
T0  = readForecastCsv(archiveCsv(cfg, newest.tag));
ids = unique(T0.stationID, 'stable');
nS  = numel(ids);
readFn = @(tag) readForecastCsv(archiveCsv(cfg, tag));
[E, tAx0, nT, usedInit, nOut] = gatherEnsemble(cfg, 'WRF_StationForecast_', readFn, 'stationID', ids, {'PM25'}, newestTime, {'PM25'});
fprintf('  forecast_stations.json: ensemble from %d run(s), %d outlier model values left out\n', numel(usedInit), nOut);
nMem = cfg.ENS_MAX_MEMBERS;
newestL = newestTime + hours(cfg.UTC_OFFSET_H);
extraCols  = {'PM25', 'PBLH', 'RAIN_1h', 'PM10', 'O3_ppb', 'CO_ppm', 'NO2_ppb', 'SO2_ppb'};
extraNames = {'PM25', 'PBLH', 'RAIN1H', 'PM10', 'O3', 'CO', 'NO2', 'SO2'};
extraDec   = [1, 0, 1, 1, 1, 2, 1, 1];
X = placeNewest(T0, extraCols, ids, 'stationID', tAx0, nT, newestL, cfg.SKIP_FIRST_H);
for c = 1:numel(extraNames)                          % same spike checks on the newest run's lines
    X(:, :, c) = despikeModel(X(:, :, c), extraNames{c}, cfg);
end
Xp = X(:, :, 1);  Xp(isnan(E(:, :, 1, 1))) = NaN;  X(:, :, 1) = Xp;   % PM2.5: as in the ensemble

J = struct();
J.run_file   = newest.label;
J.init_utc   = datestr(newestTime, 'yyyy-mm-dd HH:MM');
J.init_local = datestr(newestL, 'yyyy-mm-dd HH:MM');
J.t0_local   = datestr(tAx0, 'yyyy-mm-dd HH:MM:SS');
J.n          = nT;
J.step_h     = 1;
J.n_members  = nMem;
J.ensemble   = sprintf('up to %d most recent runs covering each hour, first %d h of each run and outlier values left out', nMem, cfg.SKIP_FIRST_H);
J.members_init_local = cellstr(datestr(sort(usedInit), 'yyyy-mm-dd HH:MM'));
st = cell(nS, 1);
for s = 1:nS
    r = struct();
    r.id = ids{s};
    for c = 1:numel(extraNames)
        r.(extraNames{c}) = round(X(s, :, c), extraDec(c));
    end
    r.ens = round(reshape(E(s, :, 1, :), nT, nMem)', 1);    % members x hours
    st{s} = r;
end
J.stations = [st{:}];
writeJson(fullfile(cfg.dashDir, 'forecast_stations.json'), J);
end


function computeCorrectionSafe(cfg)
try
    computeCorrection(cfg);
catch ME
    fprintf('[%s] Forecast correction failed: %s\n', datestr(now), ME.message);
    writeLog(cfg.logFile, sprintf('%s | ERROR | correction: %s', datestr(now), ME.message));
end
end


function computeCorrection(cfg)
% Fits the correction for every station and variable in COR_VARS -> forecast_correction.json
%   pairs:  hourly forecast (all archived runs, all lead times) vs hourly observation
%   weight: 0.5 ^ (age in days / COR_HALF_LIFE_DAYS)
%   space:  x = T(forecast), y = T(observed), T = ln(. + c) or identity
%   bias:   beta  = mean_w(y) - mean_w(x)
%   spread: scale = sd_w(y) / sd_w(x), shrunk towards 1 with COR_PRIOR_N pseudo-hours,
%           limited to COR_SCALE_LIMITS, used only with COR_MIN_HOURS_SCALE distinct
%           observed hours and correlation >= COR_MIN_CORR
%   applied (dashboard): T(F) = x + beta + (scale - 1)(x - mean_w(x)), then clipped to [min, max]
tc = tic;
nowL = datetime('now', 'TimeZone', 'Asia/Bangkok');
nowL.TimeZone = '';
tEnd   = dateshift(nowL, 'start', 'hour');
tStart = tEnd - days(cfg.COR_WINDOW_DAYS);
nH = round(hours(tEnd - tStart)) + 1;
dd = (dateshift(tStart, 'start', 'day'):days(1):tEnd)';
months = unique(year(dd) * 100 + month(dd))';

V = cfg.COR_VARS;
% source | forecast archive prefix | id column | id prefix used on the dashboard
specs = {'pcd',   'WRF_StationForecast_', 'stationID', '';
         'tmd',   'WRF_MetForecast_',     'stationID', '';
         'narit', 'WRF_AstroForecast_',   'code',      'A';
         'lidar', 'WRF_LidarForecast_',   'code',      'L'};
fcCol = struct('PM25', 'PM25', 'PM10', 'PM10', 'O3', 'O3_ppb', 'CO', 'CO_ppm', 'NO2', 'NO2_ppb', ...
    'SO2', 'SO2_ppb', 'TEMP', 'T2_C', 'RH', 'RH2', 'WIND', 'WS10', 'ATEMP', 'T2_C', 'ARH', 'RH2', ...
    'AWIND', 'WS10', 'ADPS', 'DPS_C', 'ASEEING', 'SEEING_arcsec', 'PBLH', 'PBLH');

stations = containers.Map();
summary = {};
nPairsAll = 0;
nQC = 0;
VR = {};                    % verification rows (all sources)
holdTxt = {};               % held-back RMSE summary per variable
BL = struct();              % short-range blend per variable
blendTxt = {};
firstPair = NaT;
for d = 1:size(specs, 1)
    rows = find(strcmp(V(:, 1), specs{d, 1}));
    if isempty(rows)
        continue;
    end
    vars = V(rows, 2)';
    nV = numel(vars);

    % --- Observations on an hourly grid (means of the readings nearest each hour) ---
    [oId, oT, oV] = loadCorrectionObs(cfg, specs{d, 1}, vars, tStart, months);
    if isempty(oId)
        continue;
    end
    [ids, ~, si] = unique(oId);
    nS = numel(ids);
    k  = round(hours(oT - tStart)) + 1;
    okO = k >= 1 & k <= nH;
    Obs = nan(nS, nH, nV);
    for v = 1:nV
        g = okO & isfinite(oV(:, v));
        if any(g)
            sm = accumarray([si(g), k(g)], oV(g, v), [nS nH]);
            cn = accumarray([si(g), k(g)], 1, [nS nH]);
            o = sm ./ cn; o(cn == 0) = NaN;
            Obs(:, :, v) = o;
        end
    end
    % Same quality checks as the dashboard charts
    for v = 1:nV
        q = find(strcmp(cfg.QC(:, 1), vars{v}), 1);
        if isempty(q), continue; end
        for s = 1:nS
            [Obs(s, :, v), nr] = qcHourly(Obs(s, :, v), cfg.QC(q, :));
            nQC = nQC + nr;
        end
    end

    % --- Forecast-observation pairs from the archived runs ---
    files = dir(fullfile(cfg.outDir, [specs{d, 2} '*.csv']));
    tags = regexp({files.name}, ['^' specs{d, 2} '(\d{10})\.csv$'], 'tokens', 'once');
    okf = ~cellfun(@isempty, tags);
    tags = cellfun(@(c) c{1}, tags(okf), 'UniformOutput', false);
    if isempty(tags)
        continue;
    end
    initL = datetime(tags, 'InputFormat', 'yyyyMMddHH') + hours(cfg.UTC_OFFSET_H);
    selR = initL >= tStart - days(6) & initL <= nowL;
    tags = tags(selR);  initL = initL(selR);

    G = []; K = []; X = []; Y = []; W = []; XO = []; YO = []; LD = [];
    bl = ismember(vars, cfg.BLEND_VARS) & strcmp(V(rows, 3)', 'lin');
    MB = nan(nS, nH, nV);  BI = -inf(nS, nH, nV);      % newest run's value per hour (for the blend)
    initNum = datenum(initL);
    for f = 1:numel(tags)
        T = readStationCsv(fullfile(cfg.outDir, [specs{d, 2} tags{f} '.csv']), specs{d, 3});
        fid = strcat(specs{d, 4}, T.(specs{d, 3}));
        [tf, fsi] = ismember(fid, ids);
        t  = datetime(T.time_local, 'InputFormat', 'yyyy-MM-dd HH:mm');
        kk = round(hours(t - tStart)) + 1;
        leadH = hours(t - initL(f));
        okr = tf & kk >= 1 & kk <= nH & t <= nowL & leadH >= cfg.SKIP_FIRST_H;   % no initial state
        w = 0.5 .^ (days(nowL - t) / cfg.COR_HALF_LIFE_DAYS);
        for v = 1:nV
            col = fcCol.(vars{v});
            if ~ismember(col, T.Properties.VariableNames)
                continue;                               % older runs lack some columns
            end
            fc = T.(col);
            if bl(v)
                okm = okr & isfinite(fc);
                ii = sub2ind([nS nH nV], fsi(okm), kk(okm), v * ones(sum(okm), 1));
                fv = fc(okm);
                newer = initNum(f) > BI(ii);
                MB(ii(newer)) = fv(newer);  BI(ii(newer)) = initNum(f);
            end
            ob = nan(height(T), 1);
            ob(okr) = Obs(sub2ind([nS nH nV], fsi(okr), kk(okr), v * ones(sum(okr), 1)));
            r = rows(v);
            good = okr & isfinite(fc) & isfinite(ob);
            x = fc(good); y = ob(good);
            if strcmp(V{r, 3}, 'log')
                keep = x >= 0 & y >= 0;
                good(good) = keep;
                x = log(x(keep) + V{r, 4}); y = log(y(keep) + V{r, 4});
            end
            XO = [XO; fc(good)];                %#ok<AGROW>  raw model value
            YO = [YO; ob(good)];                %#ok<AGROW>  observed value
            LD = [LD; ceil(leadH(good) / 24)];  %#ok<AGROW>  lead day 1..6
            if any(good), firstPair = min([firstPair; min(t(good))]); end
            G = [G; (fsi(good) - 1) * nV + v]; %#ok<AGROW>
            K = [K; kk(good)];                  %#ok<AGROW>
            X = [X; x];                         %#ok<AGROW>
            Y = [Y; y];                         %#ok<AGROW>
            W = [W; w(good)];                   %#ok<AGROW>
        end
    end
    if isempty(G)
        continue;
    end
    nPairsAll = nPairsAll + numel(G);

    % --- Fit, choose ("do no harm") and verify per (station, variable) ---
    nG = nS * nV;
    vi = mod(G - 1, nV) + 1;
    test = K > nH - cfg.COR_HOLDOUT_H;                         % most recent hours, held back
    FT = fitGroups(G, K, X, Y, W, ~test, nG, cfg);             % fitted without them
    FA = fitGroups(G, K, X, Y, W, true(size(G)), nG, cfg);     % fitted on everything
    Gt = G(test);
    [~, iu] = unique([G(test) K(test)], 'rows');
    nTest = accumarray(Gt(iu), 1, [nG 1]);
    rmHold = nan(nG, 3);  rmIn = nan(nG, 3);
    for c = 1:3                                                % 1 none, 2 bias, 3 bias+variability
        for basis = 1:2
            if basis == 1, Fp = FT; else, Fp = FA; end
            bb = Fp.beta * (c > 1);  ss = 1 + (Fp.scale - 1) * (c > 2);
            Fc = backTransform(X + bb(G) + (ss(G) - 1) .* (X - Fp.mx(G)), vi, rows, V);
            if basis == 1
                if any(test)
                    rmHold(:, c) = sqrt(accumarray(Gt, (Fc(test) - YO(test)) .^ 2, [nG 1]) ./ max(accumarray(Gt, 1, [nG 1]), 1));
                end
            else
                rmIn(:, c) = sqrt(accumarray(G, (Fc - YO) .^ 2, [nG 1]) ./ max(accumarray(G, 1, [nG 1]), 1));
            end
        end
    end
    nFull = zeros(1, nV); nBias = zeros(1, nV); nNone = zeros(1, nV);
    CB = zeros(nG, 1); CS = ones(nG, 1); CM = zeros(nG, 1);   % chosen coefficients (none = identity)
    CMode = repmat({'none'}, nG, 1);  CBasis = repmat({''}, nG, 1);
    HR = nan(nG, 2);                                           % held-back RMSE: raw, chosen
    for s = 1:nS
        for v = 1:nV
            g = (s - 1) * nV + v;
            if ~FA.okBias(g), continue; end                    % too few matched hours: no entry
            useHold = nTest(g) >= cfg.COR_HOLDOUT_MIN_HOURS && FT.okBias(g);
            if useHold, sc = rmHold(g, :); okF = FT.okFull(g) && FA.okFull(g); CBasis{g} = 'held-back days';
            else,       sc = rmIn(g, :);   okF = FA.okFull(g);                 CBasis{g} = 'all data';
            end
            % Keep an option only if it improves the held-back days AND does not worsen
            % the error over all the data (the bias may differ from week to week)
            noWorse = rmIn(g, :) <= rmIn(g, 1);
            best = 1;
            if sc(2) < sc(1) * (1 - cfg.COR_MIN_GAIN) && noWorse(2), best = 2; end
            if okF && sc(3) < sc(best) * (1 - cfg.COR_MIN_GAIN) && noWorse(3), best = 3; end
            if best == 1 && ismember(vars{v}, cfg.COR_FORCE_BIAS)
                best = 2;                                      % bias at least, by choice
            end
            if useHold, HR(g, :) = [rmHold(g, 1), rmHold(g, best)]; end
            if best == 3
                mode = 'bias+variability'; CB(g) = FA.beta(g); CS(g) = FA.scale(g); nFull(v) = nFull(v) + 1;
            elseif best == 2
                mode = 'bias'; CB(g) = FA.beta(g); nBias(v) = nBias(v) + 1;
            else
                mode = 'none'; nNone(v) = nNone(v) + 1;
            end
            CM(g) = FA.mx(g);  CMode{g} = mode;
            if isKey(stations, ids{s}), st = stations(ids{s}); else, st = struct('id', ids{s}); end
            st.(vars{v}) = struct('mode', mode, 'beta', round(CB(g), 4), 'scale', round(CS(g), 3), ...
                'mf', round(CM(g), 4), 'n', FA.n(g), 'r', round(FA.r(g), 2), 'chosen_on', CBasis{g}, ...
                'eligible_variability', FA.okFull(g));
            stations(ids{s}) = st;
        end
    end

    % --- Verification: raw and (chosen) corrected model vs observations, all leads and per lead day ---
    FC = backTransform(X + CB(G) + (CS(G) - 1) .* (X - CM(G)), vi, rows, V);
    nLD = max([LD; 1]);
    statAll = verifStats(G, nG, YO, XO);   statAllC = verifStats(G, nG, YO, FC);
    gl = (G - 1) * nLD + LD;
    statLD  = verifStats(gl, nG * nLD, YO, XO);  statLDC = verifStats(gl, nG * nLD, YO, FC);
    for s = 1:nS
        for v = 1:nV
            g = (s - 1) * nV + v;
            if statAll(g, 1) == 0, continue; end
            extra = [CMode(g), CBasis(g), num2cell(rmHold(g, :))];
            VR(end+1, :) = [{specs{d, 1}, ids{s}, vars{v}, 0}, num2cell(statAll(g, :)), num2cell(statAllC(g, 4:7)), extra]; %#ok<AGROW>
            for L = 1:nLD
                q = (g - 1) * nLD + L;
                if statLD(q, 1) == 0, continue; end
                VR(end+1, :) = [{specs{d, 1}, ids{s}, vars{v}, L}, num2cell(statLD(q, :)), num2cell(statLDC(q, 4:7)), extra]; %#ok<AGROW>
            end
            if isKey(stations, ids{s}) && isfield(stations(ids{s}), vars{v})
                st = stations(ids{s});
                c = st.(vars{v});
                c.bias_raw = round(statAll(g, 4), 3);  c.rmse_raw = round(statAll(g, 6), 3);
                c.rmse_cor = round(statAllC(g, 6), 3); c.r_raw = round(statAll(g, 7), 2);
                st.(vars{v}) = c;
                stations(ids{s}) = st;
            end
        end
    end
    % --- Short-range blend: choose tau per variable by replaying the last days ---
    for v = find(bl)
        r = rows(v);
        taus = [0 cfg.BLEND_TAUS];  se = zeros(size(taus));  cnt = 0;
        t0s = max(cfg.BLEND_OBS_HOURS, nH - cfg.BLEND_TEST_DAYS * 24 + 1):nH;
        for s = 1:nS
            g = (s - 1) * nV + v;
            M = MB(s, :, v);
            if ~any(isfinite(M)), continue; end
            M = max(M + CB(g) + (CS(g) - 1) .* (M - CM(g)), V{r, 5});   % with the chosen correction
            O = Obs(s, :, v);
            Dif = O - M;
            for t0 = t0s
                dw = Dif(t0 - cfg.BLEND_OBS_HOURS + 1:t0);  dw = dw(isfinite(dw));
                if isempty(dw) || ~isfinite(O(t0)), continue; end
                dd = mean(dw);
                Ld = 1:min(cfg.BLEND_MAX_LEAD, nH - t0);
                if isempty(Ld), continue; end
                okL = isfinite(O(t0 + Ld)) & isfinite(M(t0 + Ld));
                if ~any(okL), continue; end
                Ld = Ld(okL);  o = O(t0 + Ld);  m = M(t0 + Ld);
                for j = 1:numel(taus)
                    if taus(j) == 0, w = zeros(size(Ld)); else, w = max(0, 1 - Ld / taus(j)); end
                    se(j) = se(j) + sum((max(m + w * dd, V{r, 5}) - o) .^ 2);
                end
                cnt = cnt + numel(Ld);
            end
        end
        if cnt == 0, continue; end
        rmB = sqrt(se / cnt);
        [~, jb] = min(rmB);
        if rmB(jb) > rmB(1) * (1 - cfg.COR_MIN_GAIN), jb = 1; end
        BL.(vars{v}) = struct('tau_h', taus(jb), 'rmse_model', round(rmB(1), 3), 'rmse_blend', round(rmB(jb), 3), ...
            'n', cnt, 'lead_max_h', cfg.BLEND_MAX_LEAD, 'obs_hours', cfg.BLEND_OBS_HOURS, ...
            'tau_tested_h', taus, 'rmse_by_tau', round(rmB, 3));
        blendTxt{end+1} = sprintf('%s %d h (RMSE next %d h %.3g->%.3g)', vars{v}, taus(jb), ...
            cfg.BLEND_MAX_LEAD, rmB(1), rmB(jb)); %#ok<AGROW>
    end

    for v = 1:nV
        hv = HR(v:nV:nG, :);                                   % groups of this variable
        hv = hv(all(isfinite(hv), 2), :);
        if ~isempty(hv)
            holdTxt{end+1} = sprintf('%s %.3g->%.3g', vars{v}, median(hv(:, 1)), median(hv(:, 2))); %#ok<AGROW>
        end
        summary{end+1} = sprintf('%s %d/%d/%d', vars{v}, nFull(v), nBias(v), nNone(v)); %#ok<AGROW>
    end
end

J = struct();
J.generated_local = datestr(nowL, 'yyyy-mm-dd HH:MM');
J.method = 'decaying-weighted mean and variance scaling (log or linear space per variable)';
J.window_days    = cfg.COR_WINDOW_DAYS;
J.half_life_days = cfg.COR_HALF_LIFE_DAYS;
J.offsets        = cfg.COR_OFFSET;                    % kept for older pages
J.transforms     = struct();
for r = 1:size(V, 1)
    J.transforms.(V{r, 2}) = struct('type', V{r, 3}, 'offset', V{r, 4}, 'min', V{r, 5}, 'max', V{r, 6});
end
if ~isnat(firstPair), J.pairs_from_local = datestr(firstPair, 'yyyy-mm-dd HH:MM'); end
J.skip_first_h     = cfg.SKIP_FIRST_H;
J.blend            = BL;
J.map_radius_km    = cfg.COR_MAP_RADIUS_KM;
J.map_prior_weight = cfg.COR_MAP_PRIOR_W;
if stations.Count == 0
    J.stations = [];
else
    J.stations = values(stations);                    % cell -> JSON array (fields differ per station)
end
writeJson(fullfile(cfg.dashDir, 'forecast_correction.json'), J);
fprintf('  correction (stations: bias+variability / bias only / none, chosen on held-back days): %s; %d pairs; %d observed hours removed by QC (%.0f s)\n', ...
    strjoin(summary, ', '), nPairsAll, nQC, toc(tc));

% Verification table: one row per station x variable x lead day (0 = all leads), raw and corrected
if ~isempty(VR)
    if ~exist(cfg.verifDir, 'dir'), mkdir(cfg.verifDir); end
    VT = cell2table(VR, 'VariableNames', {'source', 'station_id', 'variable', 'lead_day', ...
        'n_pairs', 'mean_obs', 'mean_model', 'bias_raw', 'mae_raw', 'rmse_raw', 'r_raw', ...
        'bias_cor', 'mae_cor', 'rmse_cor', 'r_cor', 'correction', 'chosen_on', ...
        'rmse_heldback_none', 'rmse_heldback_bias', 'rmse_heldback_biasvar'});
    writetable(VT, fullfile(cfg.verifDir, 'verification_latest.csv'));
    writetable(VT, fullfile(cfg.verifDir, sprintf('verification_%s.csv', datestr(nowL, 'yyyymmdd'))));   % daily snapshot
    a = VT(VT.lead_day == 0, :);
    fprintf('  verification (all leads, median over stations, RMSE raw -> corrected):');
    for v = unique(a.variable, 'stable')'
        m = strcmp(a.variable, v{1});
        fprintf(' %s %.3g->%.3g;', v{1}, median(a.rmse_raw(m), 'omitnan'), median(a.rmse_cor(m), 'omitnan'));
    end
    fprintf('\n  verification on the held-back last %d h (median over stations, RMSE raw -> chosen): %s\n', ...
        cfg.COR_HOLDOUT_H, strjoin(holdTxt, '; '));
    fprintf('  saved: %s\n', fullfile(cfg.verifDir, 'verification_latest.csv'));
end
if ~isempty(blendTxt)
    fprintf('  short-range blend (latest observations fading into the model): %s\n', strjoin(blendTxt, '; '));
end
end


function F = fitGroups(G, K, X, Y, W, m, nG, cfg)
% Weighted moments per group on the pairs in mask m -> coefficients and eligibility
G = G(m); K = K(m); X = X(m); Y = Y(m); W = W(m);
F.n = zeros(nG, 1); F.beta = zeros(nG, 1); F.mx = zeros(nG, 1); F.scale = ones(nG, 1);
F.r = nan(nG, 1); F.okBias = false(nG, 1); F.okFull = false(nG, 1);
if isempty(G), return; end
[~, iu] = unique([G K], 'rows');
F.n = accumarray(G(iu), 1, [nG 1]);
Sw = accumarray(G, W, [nG 1]);
mx = accumarray(G, W .* X, [nG 1]) ./ Sw;   my = accumarray(G, W .* Y, [nG 1]) ./ Sw;
vx = max(accumarray(G, W .* X .^ 2, [nG 1]) ./ Sw - mx .^ 2, 0);
vy = max(accumarray(G, W .* Y .^ 2, [nG 1]) ./ Sw - my .^ 2, 0);
F.r = (accumarray(G, W .* X .* Y, [nG 1]) ./ Sw - mx .* my) ./ sqrt(max(vx .* vy, eps));
F.okBias = F.n >= cfg.COR_MIN_HOURS_BIAS & Sw > 0;
F.okFull = F.okBias & F.n >= cfg.COR_MIN_HOURS_SCALE & vx > 1e-9 & vy > 1e-9 & F.r >= cfg.COR_MIN_CORR;
sc = 1 + (sqrt(vy ./ max(vx, eps)) - 1) .* F.n ./ (F.n + cfg.COR_PRIOR_N);
sc = min(max(sc, cfg.COR_SCALE_LIMITS(1)), cfg.COR_SCALE_LIMITS(2));
F.scale(F.okFull) = sc(F.okFull);
F.beta(F.okBias) = my(F.okBias) - mx(F.okBias);
F.mx(F.okBias) = mx(F.okBias);
end


function F = backTransform(xc, vi, rows, V)
% Corrected values in the correction space -> original units, clipped to the physical range
F = xc;
for v = 1:numel(rows)
    r = rows(v);  m = vi == v;
    if strcmp(V{r, 3}, 'log'), F(m) = exp(xc(m)) - V{r, 4}; end
    F(m) = min(max(F(m), V{r, 5}), V{r, 6});
end
end


function S = verifStats(idx, nIdx, o, f)
% Per group: [n, mean_obs, mean_model, bias, MAE, RMSE, r] (unweighted, model minus obs)
n  = accumarray(idx, 1, [nIdx 1]);
so = accumarray(idx, o, [nIdx 1]);  sf = accumarray(idx, f, [nIdx 1]);
e  = f - o;
se = accumarray(idx, e, [nIdx 1]);  sa = accumarray(idx, abs(e), [nIdx 1]);  s2 = accumarray(idx, e .^ 2, [nIdx 1]);
soo = accumarray(idx, o .^ 2, [nIdx 1]); sff = accumarray(idx, f .^ 2, [nIdx 1]); sof = accumarray(idx, o .* f, [nIdx 1]);
mo = so ./ n;  mf = sf ./ n;
cov = sof ./ n - mo .* mf;
r = cov ./ sqrt(max((soo ./ n - mo .^ 2) .* (sff ./ n - mf .^ 2), eps));
S = [n, mo, mf, se ./ n, sa ./ n, sqrt(s2 ./ n), r];
S(n == 0, 2:end) = NaN;
end


function buildWaccmSafe(cfg)
try
    buildWaccm(cfg);
catch ME
    fprintf('[%s] WACCM layers failed: %s\n', datestr(now), ME.message);
end
end


function buildWaccm(cfg)
% WACCM surface fields on the WRF-Chem map frame times -> forecast_waccm_<VAR>.json
tc = tic;
files = dir(fullfile(cfg.WACCM_DIR, 'waccm.forecast.*.nc'));
gP = fullfile(cfg.dashDir, 'forecast_grid_PM25.json');
if isempty(files) || ~exist(gP, 'file')
    return;
end
GW = jsondecode(fileread(gP));                         % the WRF-Chem frame times to match
tFr = datetime(cellstr(GW.times_local), 'InputFormat', 'yyyy-MM-dd HH:mm') - hours(cfg.UTC_OFFSET_H);   % UTC

% Rebuild only when the WACCM files or the WRF-Chem frames change
sig = sprintf('%s|', files.name);  sig = [sig sprintf('%.6f|', [files.datenum]) GW.init_local '|global-v3|' ...
       strjoin(cfg.WACCM_VARS(:, 1)', ',')];           % rebuilt when the files, the frames or the variable list change
stFile = fullfile(cfg.outDir, 'waccm_state.mat');
if exist(stFile, 'file')
    S0 = load(stFile);
    if isfield(S0, 'sig') && strcmp(S0.sig, sig) && exist(fullfile(cfg.dashDir, 'forecast_waccm_PM25.json'), 'file')
        return;
    end
end

% Grid and the box to read (from the first file)
f1 = fullfile(files(1).folder, files(1).name);
lat = double(ncread(f1, 'lat'));  lon = double(ncread(f1, 'lon'));
iy = find(abs(lat) <= cfg.WACCM_MAX_LAT);
ix = (1:numel(lon))';                                % all longitudes (re-centred below)
nLev = numel(ncread(f1, 'lev'));
hyam = ncread(f1, 'hyam');  hybm = ncread(f1, 'hybm');  P0 = double(ncread(f1, 'P0'));
hyai = double(ncread(f1, 'hyai'));  hybi = double(ncread(f1, 'hybi'));
runInit = waccmRunInit(f1);
ny = numel(iy);  nx = numel(ix);
nV = size(cfg.WACCM_VARS, 1);

% Read every daily file: times from date (yyyymmdd) + datesec
tAll = NaT(0, 1);  A = cell(nV, 1);
[~, fOrd] = sort({files.name});
for fi = fOrd(:)'
    f = fullfile(files(fi).folder, files(fi).name);
    try
        dt = double(ncread(f, 'date'));  ds = double(ncread(f, 'datesec'));
    catch ME
        fprintf('  WACCM: cannot read %s (%s), skipped\n', files(fi).name, ME.message);
        continue;
    end
    tf = datetime(floor(dt / 10000), mod(floor(dt / 100), 100), mod(dt, 100)) + seconds(ds);
    nt = numel(tf);
    rd2 = @(v) permute(reshape(double(ncread(f, v, [ix(1) iy(1) 1], [nx ny Inf])), nx, ny, nt), [2 1 3]);
    rdL = @(v) permute(reshape(double(ncread(f, v, [ix(1) iy(1) nLev 1], [nx ny 1 Inf])), nx, ny, nt), [2 1 3]);
    for v = 1:nV
        name = cfg.WACCM_VARS{v, 2};  fac = cfg.WACCM_VARS{v, 3};
        switch cfg.WACCM_VARS{v, 4}
            case '2d',   X = rd2(name) * fac;
            case 'lev',  X = rdL(name) * fac;
            case 'temp', X = rdL('T') - 273.15;
            case 'wind', X = hypot(rdL('U'), rdL('V'));
            case 'rh'
                q = rdL('Q');  T = rdL('T') - 273.15;
                p = hyam(end) * P0 + hybm(end) * rd2('PS');                  % Pa, lowest level
                e = q .* p ./ (0.622 + 0.378 * q);
                es = 611.2 * exp(17.67 * T ./ (T + 243.5));
                X = min(max(100 * e ./ es, 0), 100);
            case 'dps'
                q = rdL('Q');  T = rdL('T') - 273.15;
                p = hyam(end) * P0 + hybm(end) * rd2('PS');
                e = max(q .* p ./ (0.622 + 0.378 * q), 1e-3);
                g = log(e / 611.2);
                X = max(T - 243.5 * g ./ (17.67 - g), 0);                  % T - dew point
            case 'pwv'
                ps = rd2('PS');                                             % ny x nx x nt
                X = zeros(ny, nx, nt);
                for kl = 1:nLev                                             % level by level (memory)
                    qk = permute(reshape(double(ncread(f, 'Q', [ix(1) iy(1) kl 1], [nx ny 1 Inf])), nx, ny, nt), [2 1 3]);
                    dp = (hyai(kl + 1) - hyai(kl)) * P0 + (hybi(kl + 1) - hybi(kl)) * ps;
                    X = X + qk .* dp;
                end
                X = X / 9.80665;                                            % kg/m2 = mm
        end
        A{v} = cat(3, A{v}, X);
    end
    tAll = [tAll; tf(:)]; %#ok<AGROW>
end
if isempty(tAll)
    return;
end
[tAll, iu] = unique(tAll, 'last');                % later files win for duplicate times
for v = 1:nV, A{v} = A{v}(:, :, iu); end

% WACCM's own frames over the WRF-Chem frame period (plus one step either side, so the page
% can interpolate to the first and last WRF-Chem frames)
keepT = find(tAll >= min(tFr) - hours(6) & tAll <= max(tFr) + hours(6));
nOK = sum(tFr >= min(tAll) & tFr <= max(tAll));
% Longitudes 0..360 -> -180..180 (so the field lines up with the map's world)
lonC = lon(ix);  lonC(lonC >= 180) = lonC(lonC >= 180) - 360;
[lonC, sh] = sort(lonC);
dlat = mean(diff(lat(iy)));  dlon = mean(diff(lonC));
ny = numel(iy);  nx = numel(ix);
scales = [cfg.MAP_POLL; {'ACLOUD', 0.5, 0; 'APWV', 0.25, 0}];
tLoc = cellstr(datestr(tAll(keepT) + hours(cfg.UTC_OFFSET_H), 'yyyy-mm-dd HH:MM'));
meta = struct('source', 'WACCM', 'run_files', {{files(fOrd(:)').name}}, 'run_init_utc', datestr(runInit, 'yyyy-mm-dd HH:MM'), ...
              'init_local', GW.init_local);
for v = 1:nV
    key = cfg.WACCM_VARS{v, 1};
    m = find(strcmp(scales(:, 1), key), 1);
    if isempty(m), continue; end
    writeGlobalLayer(cfg, sprintf('forecast_waccm_%s.json', key), key, A{v}(:, sh, keepT), ...
        lat(iy), lonC, tLoc, scales{m, 2}, scales{m, 3}, meta);
end
% Health categories from WACCM temperature, humidity and PM2.5
iT = find(strcmp(cfg.WACCM_VARS(:, 1), 'TEMP'), 1);  iR = find(strcmp(cfg.WACCM_VARS(:, 1), 'RH'), 1);
iP = find(strcmp(cfg.WACCM_VARS(:, 1), 'PM25'), 1);
if ~isempty(iT) && ~isempty(iR) && ~isempty(iP)
    Tw = A{iT}(:, sh, keepT);  Rw = A{iR}(:, sh, keepT);  Pw = A{iP}(:, sh, keepT);
    [cT, cH, cP] = healthCats(cfg, Tw, Rw, Pw);
    hl = {'HTEMP', cT; 'HHI', cH; 'HPM', cP; 'HTPM', worse(cT, cP); 'HHIPM', worse(cH, cP)};
    for h = 1:size(hl, 1)
        writeGlobalLayer(cfg, sprintf('forecast_waccm_%s.json', hl{h, 1}), hl{h, 1}, hl{h, 2}, lat(iy), lonC, tLoc, 1, 0, meta);
    end
end
writeModelStatus(cfg, 'waccm', runInit, numel(files));
save(stFile, 'sig');
fprintf('  WACCM: %d file(s), %s to %s UTC, global (to %d deg latitude), %d WACCM frames kept, %d of %d WRF-Chem frames covered, %d layers (%.0f s)\n', ...
    numel(files), datestr(tAll(1), 'dd mmm HH:MM'), datestr(tAll(end), 'dd mmm HH:MM'), cfg.WACCM_MAX_LAT, ...
    numel(keepT), nOK, numel(tFr), nV, toc(tc));
end


function writeGlobalLayer(cfg, fname, key, F3, latv, lonv, tLoc, step, offset, meta)
% A global layer (lat x lon x frames) as uint8 base64 frames (255 = missing), like the WRF-Chem maps
nk = size(F3, 3);
fr = cell(nk, 1);
for i = 1:nk
    F = F3(:, :, i)';                                   % lon x lat -> row-major by latitude
    q = round((F(:)' - offset) / step);
    bad = ~isfinite(q);
    q = min(max(q, 0), 254);  q(bad) = 255;
    fr{i} = matlab.net.base64encode(uint8(q));
end
J = meta;
J.pollutant = key;
J.lat0 = latv(1);  J.lon0 = lonv(1);  J.dlat = mean(diff(latv));  J.dlon = mean(diff(lonv));
J.nlat = numel(latv);  J.nlon = numel(lonv);
J.times_local = tLoc;
J.encoding = 'uint8-base64';  J.scale = step;  J.offset = offset;
J.pm25 = fr;                                            % field name kept for the page
writeJson(fullfile(cfg.dashDir, fname), J);
end


function writeModelStatus(cfg, model, runInitUtc, nFiles)
% dashboard_data/global_models.json: run time of each global model (for the status panel)
f = fullfile(cfg.dashDir, 'global_models.json');
S = struct();
if exist(f, 'file')
    try, S = jsondecode(fileread(f)); catch, S = struct(); end
end
S.(model) = struct('run_init_utc', datestr(runInitUtc, 'yyyy-mm-dd HH:MM'), 'files', nFiles, ...
                   'processed_local', datestr(datetime('now'), 'yyyy-mm-dd HH:MM'));
writeJson(f, S);
end


function t = waccmRunInit(f)
% Run start from the time units, e.g. 'days since 2026-10-26 00:00:00'
u = ncreadatt(f, 'time', 'units');
tok = regexp(u, 'since\s+(\d{4}-\d{2}-\d{2})[ T]?(\d{2}:\d{2}:\d{2})?', 'tokens', 'once');
if numel(tok) > 1 && ~isempty(tok{2})
    t = datetime([tok{1} ' ' tok{2}], 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
else
    t = datetime(tok{1}, 'InputFormat', 'yyyy-MM-dd');
end
end


function buildGfsSafe(cfg)
try
    buildGfs(cfg);
catch ME
    fprintf('[%s] GFS layers failed: %s\n', datestr(now), ME.message);
end
end


function buildGfs(cfg)
% GFS cloud cover and 3-hour rain (global, 1 deg) on its own 3-hourly frames
tc = tic;
gP = fullfile(cfg.dashDir, 'forecast_grid_PM25.json');
last = dir(fullfile(cfg.GFS_DIR, sprintf('gfs.*.t00z.pgrb2.0p25.f%03d', cfg.GFS_LAST_F)));
if isempty(last) || ~exist(gP, 'file'), return; end
dates = sort(regexprep({last.name}, '^gfs\.(\d{8})\..*$', '$1'));
R = dates{end};                                           % newest complete run
GW = jsondecode(fileread(gP));
ncFile = fullfile(cfg.GFS_OUT, sprintf('gfs_%s.nc', R));
sig = [R '|' GW.init_local '|v1'];
stFile = fullfile(cfg.outDir, 'gfs_state.mat');
if exist(stFile, 'file') && exist(ncFile, 'file')
    S0 = load(stFile);
    if isfield(S0, 'sig') && strcmp(S0.sig, sig) && exist(fullfile(cfg.dashDir, 'forecast_gfs_RAIN.json'), 'file')
        return;
    end
end

% 1. Extract on the HPC (once per run)
if ~exist(ncFile, 'file')
    hpcDir = strrep(cfg.GFS_DIR, '/home/arun/HPC', cfg.HPC_DATA);
    hpcOut = strrep(cfg.GFS_OUT, '/home/arun/HPC', cfg.HPC_DATA);
    W = cfg.GFS_WGRIB2;  G = '-new_grid_interpolation budget -new_grid latlon 0:360:1 -80:161:1';
    script = [ ...
        sprintf('mkdir -p %s; T=%s/gfs_%s.tmp.grb; O=%s/one.grb; rm -f $T; ', hpcOut, hpcOut, R, hpcOut), ...
        sprintf('for f in $(ls %s/gfs.%s.t00z.pgrb2.0p25.f* | sort); do ', hpcDir, R), ...
        sprintf('rm -f $O; %s $f -match ":TCDC:entire atmosphere:[0-9]+ hour fcst:" %s $O >/dev/null 2>&1 && cat $O >> $T; ', W, G), ...
        sprintf('rm -f $O; %s $f -match ":APCP:surface:0-[0-9]+ hour acc fcst:" -end %s $O >/dev/null 2>&1 && cat $O >> $T; ', W, G), ...
        'done; ', ...
        sprintf('%s $T -netcdf %s/gfs_%s.nc >/dev/null 2>&1 && rm -f $T $O && echo GFS_OK', W, hpcOut, R)];
    fprintf('  GFS: extracting run %s on the HPC (cloud cover and rain, 1 deg)...\n', R);
    % As arun (his SSH key), with the system's libraries rather than MATLAB's
    [~, who] = system('whoami');
    asUser = '';
    if ~strcmp(strtrim(who), cfg.LOCAL_USER), asUser = ['sudo -u ' cfg.LOCAL_USER ' ']; end
    [st, out] = system(sprintf('env -u LD_LIBRARY_PATH %sssh -o BatchMode=yes %s ''%s'' 2>&1', asUser, cfg.HPC_SSH, script));
    if st ~= 0 || isempty(strfind(out, 'GFS_OK')) || ~exist(ncFile, 'file')
        error('GFS extraction on the HPC failed: %s', strtrim(out));
    end
end

% 2. Read: cloud cover (%) and accumulated rain since the start (mm)
lat = double(ncread(ncFile, 'latitude'));  lon = double(ncread(ncFile, 'longitude'));
tS  = double(ncread(ncFile, 'time'));
tU  = datetime(1970, 1, 1) + seconds(tS);                 % verification times (UTC)
C = permute(double(ncread(ncFile, 'TCDC_entireatmosphere')), [2 1 3]);
P = permute(double(ncread(ncFile, 'APCP_surface')), [2 1 3]);
C(C > 1e19) = NaN;  P(P > 1e19) = NaN;
[tU, o] = sort(tU);  C = C(:, :, o);  P = P(:, :, o);
% 3-hour rain: difference of consecutive totals (the first step is its own 0-3 h total)
P3 = nan(size(P));
for k = 1:numel(tU)
    if k == 1 && hours(tU(1) - datetime(R, 'InputFormat', 'yyyyMMdd')) == 3
        P3(:, :, k) = P(:, :, k);
    elseif k > 1 && hours(tU(k) - tU(k - 1)) == 3
        P3(:, :, k) = max(P(:, :, k) - P(:, :, k - 1), 0);
    end
end
% Longitudes 0..360 -> -180..180; frames over the WRF-Chem period (one step either side)
lonC = lon;  lonC(lonC >= 180) = lonC(lonC >= 180) - 360;
[lonC, sh] = sort(lonC);
tFr = datetime(cellstr(GW.times_local), 'InputFormat', 'yyyy-MM-dd HH:mm') - hours(cfg.UTC_OFFSET_H);
keepT = find(tU >= min(tFr) - hours(3) & tU <= max(tFr) + hours(3));
tLoc = cellstr(datestr(tU(keepT) + hours(cfg.UTC_OFFSET_H), 'yyyy-mm-dd HH:MM'));
runInit = datetime(R, 'InputFormat', 'yyyyMMdd');
meta = struct('source', 'GFS', 'run_files', {{sprintf('gfs.%s.t00z.pgrb2.0p25', R)}}, ...
              'run_init_utc', datestr(runInit, 'yyyy-mm-dd HH:MM'), 'init_local', GW.init_local);
writeGlobalLayer(cfg, 'forecast_gfs_ACLOUD.json', 'ACLOUD', C(:, sh, keepT), lat, lonC, tLoc, 0.5, 0, meta);
writeGlobalLayer(cfg, 'forecast_gfs_RAIN.json',   'RAIN',   P3(:, sh, keepT), lat, lonC, tLoc, 0.25, 0, meta);
writeModelStatus(cfg, 'gfs', runInit, numel(dir(fullfile(cfg.GFS_DIR, sprintf('gfs.%s.t00z.pgrb2.0p25.f*', R)))));
save(stFile, 'sig');
fprintf('  GFS: run %s, cloud cover and 3-hour rain, %d frames (%.0f s)\n', R, numel(keepT), toc(tc));
end


function buildHealthSafe(cfg)
try
    buildHealth(cfg);
catch ME
    fprintf('[%s] Health layers failed: %s\n', datestr(now), ME.message);
end
end


function buildHealth(cfg)
% Health categories from temperature, heat index and PM2.5 (see cfg.HEALTH_*):
%   maps     forecast_grid_HTEMP / HHI / HPM / HTPM / HHIPM.json, from the forecast maps
%            (ensemble mean; the station-based corrections are not applied to these maps)
%   stations health.json: per TMD station heat (temperature) and heat index categories, per
%            PCD station air pollution and the two combined categories -- observed (with
%            the same quality checks as the charts) and forecast (corrected ensemble mean)
tc = tic;
dd = cfg.dashDir;
rd = @(f) jsondecode(fileread(fullfile(dd, f)));
names = {'HTEMP', 'HHI', 'HPM', 'HTPM', 'HHIPM'};

% ---------- maps ----------
nMapFr = 0;
fT = fullfile(dd, 'forecast_grid_TEMP.json'); fR = fullfile(dd, 'forecast_grid_RH.json');
fP = fullfile(dd, 'forecast_grid_PM25.json');
if exist(fT, 'file') && exist(fR, 'file') && exist(fP, 'file')
    GT = jsondecode(fileread(fT)); GR = jsondecode(fileread(fR)); GP = jsondecode(fileread(fP));
    nF = numel(GT.pm25);
    same = GT.nlat == GP.nlat && GT.nlon == GP.nlon && GT.nlat == GR.nlat && GT.nlon == GR.nlon && ...
           numel(GP.pm25) == nF && numel(GR.pm25) == nF;
    if same
        fr = cell(nF, numel(names));
        for i = 1:nF
            T = decodeFrame(GT, i);  R = decodeFrame(GR, i);  P = decodeFrame(GP, i);
            [cT, cH, cP] = healthCats(cfg, T, R, P);
            c = {cT, cH, cP, worse(cT, cP), worse(cH, cP)};
            for j = 1:numel(names)
                v = c{j};  v(isnan(v)) = 255;
                fr{i, j} = matlab.net.base64encode(uint8(v(:)'));
            end
        end
        for j = 1:numel(names)
            Gj = GT;
            Gj.pollutant = names{j};  Gj.scale = 1;  Gj.offset = 0;
            Gj.pm25 = fr(:, j);
            writeJson(fullfile(dd, sprintf('forecast_grid_%s.json', names{j})), Gj);
        end
        nMapFr = nF;
    end
end

% ---------- stations: observations ----------
need = {'met_obs.json', 'dashboard.json', 'forecast_met.json', 'forecast_stations.json'};
if ~all(cellfun(@(f) exist(fullfile(dd, f), 'file') == 2, need))
    fprintf('  health: maps %d frames; station files missing, stations skipped\n', nMapFr);
    return;
end
MO = rd('met_obs.json');  DO = rd('dashboard.json');
FM = rd('forecast_met.json');  FS = rd('forecast_stations.json');
COR = struct('stations', []);
if exist(fullfile(dd, 'forecast_correction.json'), 'file'), COR = rd('forecast_correction.json'); end
corMap = containers.Map();
cs = COR.stations;
if isstruct(cs), cs = num2cell(cs); end
for k = 1:numel(cs), corMap(cs{k}.id) = cs{k}; end

tO  = datetime(DO.history_t0_local, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');  nO = DO.history_n;
tOm = datetime(MO.history_t0_local, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
tF  = datetime(FS.t0_local, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');  nFc = FS.n;
tFm = datetime(FM.t0_local, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
offO = round(hours(tOm - tO));  offF = round(hours(tFm - tF));
qT  = cfg.QC(strcmp(cfg.QC(:, 1), 'TEMP'), :);  qR = cfg.QC(strcmp(cfg.QC(:, 1), 'RH'), :);
qP  = cfg.QC(strcmp(cfg.QC(:, 1), 'PM25'), :);

serMap = containers.Map();  ms = MO.series;  if isstruct(ms), ms = num2cell(ms); end
for k = 1:numel(ms), serMap(ms{k}.id) = ms{k}; end
fmMap = containers.Map();   fs = FM.stations; if isstruct(fs), fs = num2cell(fs); end
for k = 1:numel(fs), fmMap(fs{k}.id) = fs{k}; end
pSer = containers.Map();    ps = DO.series;   if isstruct(ps), ps = num2cell(ps); end
for k = 1:numel(ps), pSer(ps{k}.id) = ps{k}; end
pFc = containers.Map();     pf = FS.stations; if isstruct(pf), pf = num2cell(pf); end
for k = 1:numel(pf), pFc(pf{k}.id) = pf{k}; end

% TMD stations: observed and forecast temperature / humidity on the common axes
mst = MO.stations;  if isstruct(mst), mst = num2cell(mst); end
nM = numel(mst);
mLat = nan(nM, 1); mLon = nan(nM, 1);
TO = nan(nM, nO); RO = nan(nM, nO); TFc = nan(nM, nFc); RFc = nan(nM, nFc);
for k = 1:nM
    id = mst{k}.id;  mLat(k) = mst{k}.lat;  mLon(k) = mst{k}.lon;
    if isKey(serMap, id)
        q = serMap(id);
        if isfield(q, 'TEMP'), TO(k, :) = toAxis(qcHourly(q.TEMP, qT), offO, nO); end
        if isfield(q, 'RH'),   RO(k, :) = toAxis(qcHourly(q.RH, qR), offO, nO); end
    end
    if isKey(fmMap, id)
        f = fmMap(id);
        if isfield(f, 'ens_TEMP'), TFc(k, :) = toAxis(corrected(ensMean(f.ens_TEMP), corMap, id, 'TEMP', -Inf, Inf), offF, nFc); end
        if isfield(f, 'ens_RH'),   RFc(k, :) = toAxis(corrected(ensMean(f.ens_RH), corMap, id, 'RH', 0, 100), offF, nFc); end
    end
end
HIO = heatIndexC(TO, RO);  HIF = heatIndexC(TFc, RFc);

out = {};
for k = 1:nM
    [cTo, cHo] = healthCats(cfg, TO(k, :), RO(k, :), []);
    [cTf, cHf] = healthCats(cfg, TFc(k, :), RFc(k, :), []);
    if all(isnan([cTo cTf])), continue; end
    r = struct('id', mst{k}.id, 'kind', 'tmd', 'name', mst{k}.name, 'area', mst{k}.area, ...
               'lat', mst{k}.lat, 'lon', mst{k}.lon);
    r.obs_HTEMP = cTo;  r.obs_HHI = cHo;  r.obs_HI = round(HIO(k, :), 1);
    r.fc_HTEMP  = cTf;  r.fc_HHI  = cHf;  r.fc_HI  = round(HIF(k, :), 1);
    out{end+1} = r; %#ok<AGROW>
end
nTmd = numel(out);

% PCD stations: PM2.5, and the combined categories with the nearest TMD station
pst = DO.stations;  if isstruct(pst), pst = num2cell(pst); end
nPair = 0;
for k = 1:numel(pst)
    id = pst{k}.id;
    PO = nan(1, nO);  PF = nan(1, nFc);
    if isKey(pSer, id)
        q = pSer(id);                                    % a Map value cannot be indexed directly
        if isfield(q, 'PM25'), PO = toAxis(qcHourly(q.PM25, qP), 0, nO); end
    end
    if isKey(pFc, id)
        f = pFc(id);
        if isfield(f, 'ens'), PF = toAxis(corrected(ensMean(f.ens), corMap, id, 'PM25', 0, Inf), 0, nFc); end
    end
    [~, ~, cPo] = healthCats(cfg, [], [], PO);
    [~, ~, cPf] = healthCats(cfg, [], [], PF);
    if all(isnan([cPo cPf])), continue; end
    r = struct('id', id, 'kind', 'pcd', 'name', pst{k}.name, 'area', pst{k}.area, ...
               'lat', pst{k}.lat, 'lon', pst{k}.lon);
    r.obs_HPM = cPo;  r.fc_HPM = cPf;
    % nearest TMD station
    dk = 6371 * 2 * asin(sqrt(sind((mLat - pst{k}.lat) / 2) .^ 2 + ...
         cosd(pst{k}.lat) * cosd(mLat) .* sind((mLon - pst{k}.lon) / 2) .^ 2));
    [dmin, j] = min(dk);
    nanRow = nan(1, nO);  nanRowF = nan(1, nFc);
    if ~isempty(dmin) && dmin <= cfg.HEALTH_PAIR_KM
        [cTo, cHo] = healthCats(cfg, TO(j, :), RO(j, :), []);
        [cTf, cHf] = healthCats(cfg, TFc(j, :), RFc(j, :), []);
        r.pair_id = mst{j}.id;  r.pair_name = mst{j}.name;  r.pair_km = round(dmin, 1);
        r.obs_HTPM = worse(cTo, cPo);  r.obs_HHIPM = worse(cHo, cPo);
        r.fc_HTPM  = worse(cTf, cPf);  r.fc_HHIPM  = worse(cHf, cPf);
        nPair = nPair + 1;
    else
        r.pair_id = '';  r.pair_name = '';  r.pair_km = NaN;
        r.obs_HTPM = nanRow;  r.obs_HHIPM = nanRow;  r.fc_HTPM = nanRowF;  r.fc_HHIPM = nanRowF;
    end
    out{end+1} = r; %#ok<AGROW>
end

H = struct();
H.generated_local = datestr(datetime('now'), 'yyyy-mm-dd HH:MM');
H.obs_t0_local = datestr(tO, 'yyyy-mm-dd HH:MM:SS');  H.obs_n = nO;
H.fc_t0_local  = datestr(tF, 'yyyy-mm-dd HH:MM:SS');  H.fc_n  = nFc;
H.thresholds = struct('HTEMP', cfg.HEALTH_T, 'HHI', cfg.HEALTH_HI, 'HPM', cfg.HEALTH_PM);
H.pair_km = cfg.HEALTH_PAIR_KM;
H.stations = out;
writeJson(fullfile(dd, 'health.json'), H);
fprintf('  health: maps %d frames; %d TMD stations (heat), %d PCD stations (air pollution), %d paired with a TMD station within %d km (%.0f s)\n', ...
    nMapFr, nTmd, numel(out) - nTmd, nPair, cfg.HEALTH_PAIR_KM, toc(tc));
end


function [cT, cH, cP] = healthCats(cfg, T, R, P)
% 0 low, 1 moderate, 2 high; NaN where the input is missing
cat3 = @(x, th) double(x >= th(1)) + double(x > th(2)) + nanIf(x);
cT = []; cH = []; cP = [];
if ~isempty(T), cT = cat3(T, cfg.HEALTH_T); end
if ~isempty(T) && ~isempty(R), cH = cat3(heatIndexC(T, R), cfg.HEALTH_HI); end
if ~isempty(P), cP = cat3(P, cfg.HEALTH_PM); end
end


function z = nanIf(x)
% 0 where x is a number, NaN where it is missing
z = zeros(size(x));  z(isnan(x)) = NaN;
end


function c = worse(a, b)
% The worse of two categories; missing if either is missing
c = max(a, b);  c(isnan(a) | isnan(b)) = NaN;
end


function HI = heatIndexC(Tc, RH)
% NOAA heat index (Rothfusz regression with its adjustments), deg C in, deg C out
TF = Tc * 9 / 5 + 32;
HI = 0.5 * (TF + 61 + (TF - 68) * 1.2 + RH * 0.094);          % simple form (mild conditions)
use = (HI + TF) / 2 >= 80;
T = TF(use);  R = RH(use);
Hr = -42.379 + 2.04901523 * T + 10.14333127 * R - 0.22475541 * T .* R - 6.83783e-3 * T .^ 2 ...
     - 5.481717e-2 * R .^ 2 + 1.22874e-3 * T .^ 2 .* R + 8.5282e-4 * T .* R .^ 2 - 1.99e-6 * T .^ 2 .* R .^ 2;
a1 = R < 13 & T >= 80 & T <= 112;
Hr(a1) = Hr(a1) - ((13 - R(a1)) / 4) .* sqrt((17 - abs(T(a1) - 95)) / 17);
a2 = R > 85 & T >= 80 & T <= 87;
Hr(a2) = Hr(a2) + ((R(a2) - 85) / 10) .* ((87 - T(a2)) / 5);
HI(use) = Hr;
HI = (HI - 32) * 5 / 9;
HI(isnan(Tc) | isnan(RH)) = NaN;
end


function x = decodeFrame(G, i)
% One map frame from a forecast_grid_*.json (uint8 base64, 255 = missing)
s = G.pm25;
if iscell(s), s = s{i}; else, s = s(i, :); end
v = double(matlab.net.base64decode(s));
x = G.offset + v * G.scale;
x(v == 255) = NaN;
end


function m = ensMean(E)
% Ensemble mean over members (rows); a single member arrives as a vector
if isvector(E), m = E(:)'; else, m = mean(E, 1, 'omitnan'); end
end


function x = corrected(x, corMap, id, var, lo, hi)
% Apply the station's chosen additive correction (all health inputs are linear-space)
if isKey(corMap, id)
    c = corMap(id);
    if isfield(c, var)
        k = c.(var);
        if isfield(k, 'mode') && ~strcmp(k.mode, 'none')
            x = x + k.beta + (k.scale - 1) .* (x - k.mf);
        end
    end
end
x = min(max(x, lo), hi);
end


function y = toAxis(x, off, n)
% Place a series starting at offset off (hours) on an axis of n hours
y = nan(1, n);
x = double(x(:)');
idx = (1:numel(x)) + off;
ok = idx >= 1 & idx <= n;
y(idx(ok)) = x(ok);
end


function [x, n] = qcHourly(x, q)
% Range, spike (Hampel, +/-3 h) and stuck-sensor checks on one hourly series.
% q = {name, min, max, spike, flat, clip}; removed values become NaN; n = how many.
mn = q{2}; mx = q{3}; spike = q{4}; flat = q{5}; clip = q{6};
x = double(x(:)');
n = 0;
if isfinite(clip)
    x(x > mx & x <= clip) = mx;                       % small overshoot, e.g. humidity 101 %
end
bad = isfinite(x) & (x < mn | x > mx);
x(bad) = NaN;  n = n + sum(bad);
if isfinite(spike)
    y = x;
    for i = find(isfinite(x))
        w = x(max(1, i - 3):min(numel(x), i + 3));
        w(min(i, 4)) = NaN;                           % leave the value itself out
        w = w(isfinite(w));
        if numel(w) < 4, continue; end
        m = median(w);
        if abs(x(i) - m) > max(5 * 1.4826 * median(abs(w - m)), spike)
            y(i) = NaN;  n = n + 1;
        end
    end
    x = y;
end
if flat
    i = 1;
    while i <= numel(x)
        if ~isfinite(x(i)), i = i + 1; continue; end
        j = i;
        while j < numel(x) && x(j + 1) == x(i), j = j + 1; end
        if j - i + 1 >= 6
            x(i:j) = NaN;  n = n + (j - i + 1);
        end
        i = j + 1;
    end
end
end


function [oId, oT, oV] = loadCorrectionObs(cfg, src, vars, tStart, months)
% Observations for one source as id (dashboard id), local time and one column per variable
oId = {}; oT = NaT(0, 1); oV = zeros(0, numel(vars));
switch src
    case 'pcd'
        [id, t, v, names] = readObsTail(cfg.histFile, cfg.COR_TAIL_MB, tStart);
        if isempty(id), return; end
        oV = nan(numel(id), numel(vars));
        for j = 1:numel(vars)
            c = find(strcmp(names, vars{j}), 1);
            if ~isempty(c), oV(:, j) = v(:, c); end
        end
        oId = id; oT = t;
    case 'tmd'
        A = readMonthly(fullfile(cfg.rootDir, 'TMD_AWS_Archive', 'TMD_AWS_%d.csv'), months, ...
                        {'stationId', 'nameEn', 'province', 'dateTimeLocal'});
        if isempty(A), return; end
        oId = strcat('T', A.stationId);
        oT  = datetime(A.dateTimeLocal, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
        cols = struct('TEMP', 'temperature', 'RH', 'humidity', 'WIND', 'windSpeed');
        oV = nan(height(A), numel(vars));
        for j = 1:numel(vars)
            if isfield(cols, vars{j}) && ismember(cols.(vars{j}), A.Properties.VariableNames)
                oV(:, j) = A.(cols.(vars{j}));
            end
        end
        jw = find(strcmp(vars, 'WIND'), 1);
        if ~isempty(jw), oV(:, jw) = oV(:, jw) * cfg.TMD_WIND_TO_MS; end
    case 'narit'
        dirN = fullfile(cfg.rootDir, 'NARIT_Obs_Archive');
        A = readMonthly(fullfile(dirN, 'NARIT_Obs_%d.csv'), months, {'code', 'timeLocal'});
        S = readMonthly(fullfile(dirN, 'NARIT_Seeing_%d.csv'), months, {'code', 'timeLocal'});
        nA = height(A); nSe = height(S);
        if nA + nSe == 0, return; end
        oV = nan(nA + nSe, numel(vars));
        for j = 1:numel(vars)
            switch vars{j}
                case 'ATEMP', if nA, oV(1:nA, j) = A.temp_C; end
                case 'ARH',   if nA, oV(1:nA, j) = A.rh_pct; end
                case 'AWIND', if nA, oV(1:nA, j) = A.wind_ms; end
                case 'ADPS',  if nA, oV(1:nA, j) = max(A.temp_C - A.dewpoint_C, 0); end
                case 'ASEEING', if nSe, oV(nA + 1:end, j) = S.seeing_arcsec; end
            end
        end
        codes = {}; times = {};
        if nA,  codes = [codes; A.code]; times = [times; A.timeLocal]; end
        if nSe, codes = [codes; S.code]; times = [times; S.timeLocal]; end
        oId = strcat('A', codes);
        oT  = datetime(times, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
    case 'lidar'
        A = readMonthly(fullfile(cfg.rootDir, 'LIDAR_PBL', 'LIDAR_PBL_%d.csv'), months, {'code', 'timeLocal'});
        if isempty(A), return; end
        oId = strcat('L', A.code);
        oT  = datetime(A.timeLocal, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
        oV  = nan(height(A), numel(vars));
        j = find(strcmp(vars, 'PBLH'), 1);
        if ~isempty(j), oV(:, j) = A.pbl_m; end
end
end


function A = readMonthly(pattern, months, textCols)
% Concatenates the monthly CSV archives that exist for the given yyyymm values
A = table();
for m = months
    fn = sprintf(pattern, m);
    if ~exist(fn, 'file')
        continue;
    end
    opts = detectImportOptions(fn, 'FileType', 'text', 'Delimiter', ',', 'Encoding', 'UTF-8');
    tc = textCols(ismember(textCols, opts.VariableNames));
    nc = setdiff(opts.VariableNames, tc);
    if ~isempty(tc), opts = setvartype(opts, tc, 'char'); end
    if ~isempty(nc), opts = setvartype(opts, nc, 'double'); end
    T = readtable(fn, opts);
    if isempty(A)
        A = T;
    else
        A = [A; T]; %#ok<AGROW>
    end
end
end


function [oID, oT, oV, oNames] = readObsTail(histFile, tailMB, tStart)
% Last tailMB of the PCD archive, rows from tStart on.
oID = {}; oT = NaT(0, 1); oV = zeros(0, 0); oNames = {};
if ~exist(histFile, 'file')
    return;
end
fid = fopen(histFile, 'r', 'n', 'UTF-8');
header    = strsplit(strtrim(fgetl(fid)), ',');
dataStart = ftell(fid);
fseek(fid, 0, 'eof');
fileSize = ftell(fid);
startPos = fileSize - tailMB * 1e6;
if startPos > dataStart
    fseek(fid, startPos, 'bof');
    fgetl(fid);                                       % drop the partial first line
else
    fseek(fid, dataStart, 'bof');
end
oNames = header(6:end);                               % stationID,nameEN,lat,lon,DATETIMEDATA,<pollutants>
fmt = ['%q%q%f%f%q' repmat('%f', 1, numel(oNames))];
C = textscan(fid, fmt, 'Delimiter', ',', 'EndOfLine', '\n');
fclose(fid);

nRow = min(cellfun(@numel, C));
t = NaT(nRow, 1);
okT = ~cellfun(@isempty, C{5}(1:nRow));
t(okT) = datetime(C{5}(okT), 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
keep = find(~isnat(t) & t >= tStart);
oID = C{1}(keep);
oT  = t(keep);
oV  = nan(numel(keep), numel(oNames));
for j = 1:numel(oNames)
    col = C{5 + j};
    oV(:, j) = col(keep);
end
end


function buildStationEnsemble(cfg, newest, kind)
% Time-lagged ensemble for the weather (TMD) or astronomy (observatory) station
% forecasts -> forecast_met.json / forecast_astro.json
switch kind
    case 'met'
        prefix = 'WRF_MetForecast_'; idCol = 'stationID'; idPre = '';
        outFile = 'forecast_met.json';
        ensVars = {'T2_C', 'TEMP', 1; 'RH2', 'RH', 0; 'WS10', 'WIND', 1; 'RAIN_1h', 'RAIN', 1};
        extras  = {'WD10', 'WDIR', 0; 'PBLH', 'PBLH', 0};
    case 'lidar'
        prefix = 'WRF_LidarForecast_'; idCol = 'code'; idPre = 'L';
        outFile = 'forecast_lidar.json';
        ensVars = {'PBLH', 'PBLH', 0};
        extras  = cell(0, 3);
    otherwise
        prefix = 'WRF_AstroForecast_'; idCol = 'code'; idPre = 'A';
        outFile = 'forecast_astro.json';
        ensVars = {'T2_C', 'ATEMP', 1; 'RH2', 'ARH', 0; 'WS10', 'AWIND', 1; 'DPS_C', 'ADPS', 1; ...
                   'CLOUD', 'ACLOUD', 0; 'PWV_mm', 'APWV', 1; 'SEEING_arcsec', 'ASEEING', 2};
        extras  = {'WD10', 'AWDIR', 0; 'CLOUD_LOW', 'ACLOUD_LOW', 0; 'CLOUD_MID', 'ACLOUD_MID', 0; ...
                   'CLOUD_HIGH', 'ACLOUD_HIGH', 0};
end
newestFile = fullfile(cfg.outDir, [prefix newest.tag '.csv']);
if ~exist(newestFile, 'file')
    return;
end
newestTime = datetime(newest.tag, 'InputFormat', 'yyyyMMddHH');
newestL = newestTime + hours(cfg.UTC_OFFSET_H);
readOne = @(tag) readStationCsv(fullfile(cfg.outDir, [prefix tag '.csv']), idCol);
T0 = readOne(newest.tag);
ids = unique(T0.(idCol), 'stable');
nS = numel(ids); nV = size(ensVars, 1); nX = size(extras, 1);
[E, tAx0, nT, usedInit, nOut] = gatherEnsemble(cfg, prefix, readOne, idCol, ids, ensVars(:, 1)', newestTime, ensVars(:, 2)');
nMem = cfg.ENS_MAX_MEMBERS;
Ln = placeNewest(T0, ensVars(:, 1)', ids, idCol, tAx0, nT, newestL, cfg.SKIP_FIRST_H);
X  = placeNewest(T0, extras(:, 1)', ids, idCol, tAx0, nT, newestL, cfg.SKIP_FIRST_H);
for v = 1:nV                                         % latest-run line: drop what the ensemble dropped
    Lv = Ln(:, :, v);  Lv(isnan(E(:, :, v, 1))) = NaN;  Ln(:, :, v) = Lv;
end
for x = 1:nX
    X(:, :, x) = despikeModel(X(:, :, x), extras{x, 2}, cfg);
end

J = struct();
J.run_file   = newest.label;
J.init_utc   = datestr(newestTime, 'yyyy-mm-dd HH:MM');
J.init_local = datestr(newestL, 'yyyy-mm-dd HH:MM');
J.t0_local   = datestr(tAx0, 'yyyy-mm-dd HH:MM:SS');
J.n          = nT;
J.step_h     = 1;
J.n_members  = nMem;
J.ensemble   = sprintf('up to %d most recent runs covering each hour, first %d h of each run and outlier values left out', nMem, cfg.SKIP_FIRST_H);
J.members_init_local = cellstr(datestr(sort(usedInit), 'yyyy-mm-dd HH:MM'));
st = cell(nS, 1);
for s = 1:nS
    r = struct('id', [idPre ids{s}]);
    for v = 1:nV
        r.(ensVars{v, 2}) = round(Ln(s, :, v), ensVars{v, 3});
        r.(['ens_' ensVars{v, 2}]) = round(reshape(E(s, :, v, :), nT, nMem)', ensVars{v, 3});
    end
    for x = 1:nX
        r.(extras{x, 2}) = round(X(s, :, x), extras{x, 3});
    end
    st{s} = r;
end
J.stations = [st{:}];
writeJson(fullfile(cfg.dashDir, outFile), J);
fprintf('  %s: %d stations, ensemble from %d run(s), reaching back to %s, %d outlier model values left out\n', ...
    outFile, nS, numel(usedInit), datestr(tAx0, 'dd mmm HH:MM'), nOut);
end


function [E, tAx0, nT, usedInit, nOut] = gatherEnsemble(cfg, prefix, readFn, idCol, ids, cols, newestTime, names)
% Time-lagged ensemble on an axis from HIST_DAYS before the newest run to its end.
% For each hour, the members are the (up to ENS_MAX_MEMBERS) most recent runs that
% cover it; each run's first SKIP_FIRST_H hour(s) are left out. E: stations x hours x
% columns x members (member 1 = most recent run covering that hour).
newestL = newestTime + hours(cfg.UTC_OFFSET_H);
tAx0 = newestL + hours(cfg.SKIP_FIRST_H) - days(cfg.HIST_DAYS);
tEnd = newestL + hours(144);
nT = round(hours(tEnd - tAx0)) + 1;
nS = numel(ids); nC = numel(cols); nM = cfg.ENS_MAX_MEMBERS;
E  = nan(nS, nT, nC, nM);
Cn = zeros(nS, nT, nC);
usedInit = NaT(0, 1);
files = dir(fullfile(cfg.outDir, [prefix '*.csv']));
tags = regexp({files.name}, ['^' prefix '(\d{10})\.csv$'], 'tokens', 'once');
okf = ~cellfun(@isempty, tags);
tags = cellfun(@(c) c{1}, tags(okf), 'UniformOutput', false);
if isempty(tags), return; end
initL = datetime(tags, 'InputFormat', 'yyyyMMddHH') + hours(cfg.UTC_OFFSET_H);
use = initL <= newestL & initL >= tAx0 - days(6);
tags = tags(use); initL = initL(use);
[initL, ord] = sort(initL, 'descend');                % newest first: takes the first member slots
tags = tags(ord);
for f = 1:numel(tags)
    try
        T = readFn(tags{f});
    catch
        continue;
    end
    t = datetime(T.time_local, 'InputFormat', 'yyyy-MM-dd HH:mm');
    [tf, si] = ismember(T.(idCol), ids);
    k = round(hours(t - tAx0)) + 1;
    ok = tf & k >= 1 & k <= nT & hours(t - initL(f)) >= cfg.SKIP_FIRST_H;
    added = false;
    for c = 1:nC
        if ~ismember(cols{c}, T.Properties.VariableNames), continue; end
        v = T.(cols{c});
        g = ok & isfinite(v);
        if ~any(g), continue; end
        idx  = sub2ind([nS nT nC], si(g), k(g), c * ones(sum(g), 1));
        slot = Cn(idx);
        slot = slot(:) + 1;                 % column: with one station Cn is a row vector
        sel  = slot <= nM;
        gi = find(g); gi = gi(sel);
        E(sub2ind([nS nT nC nM], si(gi), k(gi), c * ones(numel(gi), 1), slot(sel))) = v(gi);
        Cn(idx(sel)) = Cn(idx(sel)) + 1;
        added = added || any(sel);
    end
    if added, usedInit(end+1, 1) = initL(f); end       %#ok<AGROW>
end
% Outliers: impossible values and one-hour spikes within each run, then runs far from
% the others at the same hour
nOut = 0;
for c = 1:nC
    [Ec, nn] = despikeModel(E(:, :, c, :), names{c}, cfg);
    nOut = nOut + nn;
    if isfield(cfg.ENS_OUT_MIN, names{c}) && isfinite(cfg.ENS_OUT_MIN.(names{c}))
        med = median(Ec, 4, 'omitnan');
        mad = median(abs(Ec - med), 4, 'omitnan');
        cnt = sum(isfinite(Ec), 4);
        thr = max(cfg.ENS_OUT_K * 1.4826 * mad, cfg.ENS_OUT_MIN.(names{c}));
        bad = isfinite(Ec) & cnt >= 3 & abs(Ec - med) > thr;
        Ec(bad) = NaN;  nOut = nOut + sum(bad(:));
    end
    E(:, :, c, :) = Ec;
end
end


function [A, n] = despikeModel(A, name, cfg)
% Model series (time along dimension 2): values outside the physical range, and one-hour
% spikes -- more than 5x the moving robust spread (7 h) AND more than the minimum jump of the
% observation checks (cfg.QC) from the moving median -- become NaN
n = 0;
q = find(strcmp(cfg.QC(:, 1), name), 1);
if isempty(q), return; end
bad = isfinite(A) & (A < cfg.QC{q, 2} | A > max(cfg.QC{q, 3}, cfg.QC{q, 6}));
A(bad) = NaN;  n = sum(bad(:));
sp = cfg.QC{q, 4};
if isfinite(sp)
    med = movmedian(A, 7, 2, 'omitnan');
    mad = movmad(A, 7, 2, 'omitnan');
    bad = isfinite(A) & abs(A - med) > max(5 * 1.4826 * mad, sp);
    A(bad) = NaN;  n = n + sum(bad(:));
end
end


function L = placeNewest(T, cols, ids, idCol, tAx0, nT, initL, skipH)
% The newest run's columns on the ensemble axis (first hour(s) left out)
nS = numel(ids);
L = nan(nS, nT, numel(cols));
t = datetime(T.time_local, 'InputFormat', 'yyyy-MM-dd HH:mm');
[tf, si] = ismember(T.(idCol), ids);
k = round(hours(t - tAx0)) + 1;
ok = tf & k >= 1 & k <= nT & hours(t - initL) >= skipH;
for c = 1:numel(cols)
    if ~ismember(cols{c}, T.Properties.VariableNames), continue; end
    v = T.(cols{c});
    L(sub2ind([nS nT numel(cols)], si(ok), k(ok), c * ones(sum(ok), 1))) = v(ok);   % explicit size: size(L) drops a trailing 1
end
end


function buildEnsembleGrids(cfg, newest)
% Ensemble-mean map frames: averages each layer of the time-lagged runs' grid
% archives (WRF_Grid_<init>.mat) on the newest run's frame times and rewrites
% forecast_grid_<P>.json. A frame is averaged over the runs that cover it, so
% the last days of the newest run have fewer members. Needs at least 2 runs.
files = dir(fullfile(cfg.outDir, 'WRF_Grid_*.mat'));
tags = regexp({files.name}, '^WRF_Grid_(\d{10})\.mat$', 'tokens', 'once');
okf = ~cellfun(@isempty, tags);
tags = cellfun(@(c) c{1}, tags(okf), 'UniformOutput', false);
if ~ismember(newest.tag, tags)
    return;
end
tagTime = datetime(tags, 'InputFormat', 'yyyyMMddHH');
newestTime = datetime(newest.tag, 'InputFormat', 'yyyyMMddHH');
use = tagTime <= newestTime & tagTime >= newestTime - days(cfg.ENS_MAX_AGE_DAYS);
tags = tags(use); tagTime = tagTime(use);
[tagTime, ord] = sort(tagTime, 'descend');
tags = tags(ord);
nMem = min(numel(tags), cfg.ENS_MAX_MEMBERS);
if nMem < 2
    return;
end
tags = tags(1:nMem); tagTime = tagTime(1:nMem);
gridFile = @(tag) fullfile(cfg.outDir, sprintf('WRF_Grid_%s.mat', tag));

N = load(gridFile(tags{1}), 'mapNames', 'gridLat', 'gridLon', 'tLoc', 'frameIdx');
tFr = N.tLoc(N.frameIdx);
names = N.mapNames;
nL = numel(names);
sz = [numel(N.gridLat), numel(N.gridLon), numel(tFr)];
S = cell(nL, 1); C = cell(nL, 1);
for j = 1:nL
    S{j} = zeros(sz, 'single');
    C{j} = zeros(sz, 'single');
end

used = false(nMem, 1);
for m = 1:nMem
    M = load(gridFile(tags{m}), 'G', 'mapNames', 'gridLat', 'gridLon', 'tLoc', 'frameIdx');
    if numel(M.gridLat) ~= sz(1) || numel(M.gridLon) ~= sz(2) || ~iscell(M.G)
        continue;                                   % different grid or old archive format
    end
    [tf, loc] = ismember(tFr, M.tLoc(M.frameIdx));
    if ~any(tf)
        continue;
    end
    used(m) = true;
    for j = 1:nL
        jm = find(strcmp(M.mapNames, names{j}), 1);
        if isempty(jm)
            continue;
        end
        A = M.G{jm}(:, :, loc(tf));
        good = isfinite(A);
        A(~good) = 0;
        S{j}(:, :, tf) = S{j}(:, :, tf) + A;
        C{j}(:, :, tf) = C{j}(:, :, tf) + single(good);
    end
    clear M A good;
end
nUsed = sum(used);
if nUsed < 2
    return;
end

scales = [cfg.MAP_POLL; {'ACLOUD', 0.5, 0; 'APWV', 0.25, 0}];
for j = 1:nL
    k = find(strcmp(scales(:, 1), names{j}), 1);
    if isempty(k) || ~any(C{j}(:))
        continue;
    end
    Gm = S{j} ./ C{j};
    Gm(C{j} == 0) = NaN;
    step = scales{k, 2}; offset = scales{k, 3};
    Gj = struct();
    Gj.pollutant   = names{j};
    Gj.run_file    = newest.label;
    Gj.init_local  = datestr(N.tLoc(1), 'yyyy-mm-dd HH:MM');
    Gj.n_members   = nUsed;
    Gj.members_init_local = cellstr(datestr(tagTime(used) + hours(cfg.UTC_OFFSET_H), 'yyyy-mm-dd HH:MM'));
    Gj.lat0 = N.gridLat(1); Gj.lon0 = N.gridLon(1);
    Gj.dlat = cfg.GRID_RES; Gj.dlon = cfg.GRID_RES;
    Gj.nlat = sz(1); Gj.nlon = sz(2);
    Gj.times_local = cellstr(datestr(tFr, 'yyyy-mm-dd HH:MM'));
    Gj.encoding = 'uint8-base64';
    Gj.scale = step;
    Gj.offset = offset;
    Gj.pm25 = cell(sz(3), 1);                       % field name kept for the page
    for i = 1:sz(3)
        fr = Gm(:, :, i)';
        v  = round((double(fr(:)') - offset) / step);
        bad = ~isfinite(v);
        v  = min(max(v, 0), 254);
        v(bad) = 255;
        Gj.pm25{i} = matlab.net.base64encode(uint8(v));
    end
    writeJson(fullfile(cfg.dashDir, sprintf('forecast_grid_%s.json', names{j})), Gj);
end
fprintf('  forecast maps: ensemble mean of %d runs\n', nUsed);
end


function T = readStationCsv(file, idCol)
opts = detectImportOptions(file, 'FileType', 'text', 'Delimiter', ',');
opts = setvartype(opts, {idCol, 'time_local'}, 'char');
T = readtable(file, opts);
end


function T = readForecastCsv(file)
opts = detectImportOptions(file, 'FileType', 'text', 'Delimiter', ',');
opts = setvartype(opts, {'stationID', 'time_local'}, 'char');
T = readtable(file, opts);
end


function A = readSurface(f, name, nx, ny, nT, is3D)
% Surface field as nx x ny x nT double; NaN if the variable is missing.
if ~hasVar(f, name)
    A = nan(nx, ny, nT);
    return;
end
if is3D
    A = double(squeeze(ncread(f, name, [1 1 1 1], [Inf Inf 1 Inf])));
else
    A = double(ncread(f, name));
end
A = reshape(A, nx, ny, nT);
end


function tf = hasVar(f, name)
persistent cacheFile cacheVars
if isempty(cacheFile) || ~strcmp(cacheFile, f)
    info = ncinfo(f);
    cacheVars = {info.Variables.Name};
    cacheFile = f;
end
tf = any(strcmp(cacheVars, name));
end


function S = readStations(file)
opts = detectImportOptions(file, 'FileType', 'text', 'Delimiter', ',', 'Encoding', 'UTF-8');
txt = intersect({'stationID', 'nameEN', 'areaEN', 'stationType', 'AQILast_time', 'nameTH', 'areaTH'}, opts.VariableNames);
opts = setvartype(opts, txt, 'char');
opts = setvartype(opts, {'lat', 'lon'}, 'double');
T = readtable(file, opts);
ok = isfinite(T.lat) & isfinite(T.lon);
S = table(T.stationID(ok), T.lat(ok), T.lon(ok), 'VariableNames', {'stationID', 'lat', 'lon'});
end


function d = splineDeriv(x, y)
% dy/dx at x from a cubic spline through (x, y) -- base MATLAB, no toolbox
pp = spline(x, y);
[br, co] = unmkpp(pp);
d = ppval(mkpp(br, co(:, 1:3) .* [3 2 1]), x);
end


function S = readLidarSites(file)
% LiDAR site list written by downloadLidarPBL
S = table();
if ~exist(file, 'file')
    return;
end
opts = detectImportOptions(file, 'FileType', 'text', 'Delimiter', ',', 'Encoding', 'UTF-8');
opts = setvartype(opts, intersect({'code', 'name', 'province'}, opts.VariableNames), 'char');
opts = setvartype(opts, {'lat', 'lon'}, 'double');
T = readtable(file, opts);
ok = isfinite(T.lat) & isfinite(T.lon);
S = table(T.code(ok), T.lat(ok), T.lon(ok), 'VariableNames', {'code', 'lat', 'lon'});
end


function S = readObservatories(file)
% NARIT observatory list written by downloadNARITObservatories
S = table();
if ~exist(file, 'file')
    return;
end
opts = detectImportOptions(file, 'FileType', 'text', 'Delimiter', ',', 'Encoding', 'UTF-8');
opts = setvartype(opts, intersect({'code', 'name', 'province'}, opts.VariableNames), 'char');
opts = setvartype(opts, intersect({'lat', 'lon', 'elev_m'}, opts.VariableNames), 'double');
T = readtable(file, opts);
ok = isfinite(T.lat) & isfinite(T.lon);
S = table(T.code(ok), T.lat(ok), T.lon(ok), T.elev_m(ok), 'VariableNames', {'code', 'lat', 'lon', 'elev'});
end


function S = readTmdStations(file)
% TMD station list (id prefixed with 'T' so it never clashes with PCD ids)
S = table();
if ~exist(file, 'file')
    return;
end
opts = detectImportOptions(file, 'FileType', 'text', 'Delimiter', ',', 'Encoding', 'UTF-8');
txt = intersect({'stationId', 'nameEn', 'province', 'dateTimeLocal'}, opts.VariableNames);
opts = setvartype(opts, txt, 'char');
opts = setvartype(opts, {'lat', 'lon'}, 'double');
T = readtable(file, opts);
ok = isfinite(T.lat) & isfinite(T.lon);
S = table(strcat('T', T.stationId(ok)), T.lat(ok), T.lon(ok), 'VariableNames', {'stationID', 'lat', 'lon'});
end


function writeJson(outFile, data)
tmpFile = [outFile '.tmp'];
fid = fopen(tmpFile, 'w', 'n', 'UTF-8');
if fid == -1
    error('Cannot write %s', tmpFile);
end
fprintf(fid, '%s', jsonencode(data));
fclose(fid);
movefile(tmpFile, outFile, 'f');
end


function writeLog(logFile, msg)
fid = fopen(logFile, 'a');
if fid ~= -1
    fprintf(fid, '%s\n', msg);
    fclose(fid);
end
end
